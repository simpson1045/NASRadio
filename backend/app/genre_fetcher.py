"""
Genre backfill from MusicBrainz.

The library had no genre field at all (2026-09-11: a year-only "60s/70s
classic rock" playlist put Vince Guaraldi's Charlie Brown Christmas on for
simpson1045's dad). Albums and artists mostly carry a MusicBrainz id already, so
ask MusicBrainz for the community genre votes and store the top few.

Storage (models.py migration):
  albums.genres        TEXT[]   top genres, best first
  albums.genres_source TEXT     'release' | 'release_group' | 'artist' | 'none'
  albums.genres_fetched_at TIMESTAMP
  albums.release_group_mbid TEXT  filled when we had to search by name
  artists.genres       TEXT[]
  artists.genres_fetched_at TIMESTAMP

albums.mbid is a mix of release ids and release-group ids (both are UUIDs,
no way to tell by looking), so lookups try release-group first, then
release. MusicBrainz allows ~1 request/second and sheds load with 503s;
this runs as a background job with retries and progress events.
"""

import time
from urllib.parse import quote_plus

import requests
from app.config import Config, user_agent
from app.extensions import safe_emit

MB = "https://musicbrainz.org/ws/2"
def _headers():
    return {"User-Agent": user_agent()}
MAX_GENRES = 5
MIN_VOTES = 1
_last_call = [0.0]


def _mb_get(path, params=None, timeout=25, retries=7):
    """Polite GET: 1.1s spacing, short retries on 429/503. Returns (status, json).

    MusicBrainz sheds load with a 503 on roughly one request in three when
    busy; its own advice is to retry after about a second, not to back off
    hard. A 4s/8s backoff turned a 1s lookup into 14s (2026-09-11)."""
    params = dict(params or {})
    params["fmt"] = "json"
    url = f"{MB}/{path}"
    for attempt in range(retries):
        wait = 1.1 - (time.monotonic() - _last_call[0])
        if wait > 0:
            time.sleep(wait)
        _last_call[0] = time.monotonic()
        try:
            r = requests.get(url, params=params, headers=_headers(), timeout=timeout)
        except requests.RequestException as e:
            if attempt == retries - 1:
                return 0, {"error": str(e)}
            time.sleep(3 * (attempt + 1))
            continue
        if r.status_code in (429, 503):
            retry_after = r.headers.get("Retry-After")
            try:
                pause = float(retry_after) if retry_after else min(1.5 + attempt, 6.0)
            except ValueError:
                pause = min(1.5 + attempt, 6.0)
            time.sleep(pause)
            continue
        try:
            return r.status_code, r.json()
        except ValueError:
            return r.status_code, {}
    return 503, {"error": "MusicBrainz busy"}


def _top_genres(entity):
    """Merge 'genres' (curated) and 'tags' (raw) into a ranked list."""
    votes = {}
    for g in entity.get("genres") or []:
        name = (g.get("name") or "").strip().lower()
        if name:
            votes[name] = votes.get(name, 0) + int(g.get("count") or 0) + 1
    if not votes:
        # Tags are noisier (can include "seen live", "favorite"); only use
        # them when there are no genre votes at all, and keep the top few.
        for t in entity.get("tags") or []:
            name = (t.get("name") or "").strip().lower()
            if name and len(name) < 30 and int(t.get("count") or 0) >= MIN_VOTES:
                votes[name] = votes.get(name, 0) + int(t.get("count") or 0)
    ranked = sorted(votes.items(), key=lambda kv: (-kv[1], kv[0]))
    return [n for n, _ in ranked[:MAX_GENRES]]


class GenreFetcher:
    def __init__(self, db, progress_tracker=None, operation_id=None):
        self.db = db
        self.config = Config()
        self.progress_tracker = progress_tracker
        self.operation_id = operation_id
        self.done = 0
        self.found = 0
        self.missing = 0
        self.failed = 0
        self.cancelled = False

    # ---- plumbing ---------------------------------------------------------

    def _emit(self, current, total, message, status="running"):
        if self.progress_tracker and self.operation_id:
            self.progress_tracker.update_progress(self.operation_id, current, message)
        safe_emit("genre_progress", {
            "operation_id": self.operation_id,
            "current": current, "total": total, "message": message,
            "status": status, "found": self.found, "missing": self.missing,
            "failed": self.failed,
        })

    def _write(self, sql, params):
        conn = self.db.get_connection()
        try:
            cur = self.db.get_cursor(conn)
            cur.execute(sql, params)
            conn.commit()
        finally:
            conn.close()

    def _write_count(self, sql, params=()):
        conn = self.db.get_connection()
        try:
            cur = self.db.get_cursor(conn)
            cur.execute(sql, params)
            n = cur.rowcount
            conn.commit()
            return n
        finally:
            conn.close()

    def _rows(self, sql, params=()):
        conn = self.db.get_connection()
        try:
            cur = self.db.get_cursor(conn)
            cur.execute(sql, params)
            return cur.fetchall()
        finally:
            conn.close()

    # ---- lookups ------------------------------------------------------------

    def genres_for_album_mbid(self, mbid):
        """-> (genres, source, release_group_mbid)"""
        status, rg = _mb_get(f"release-group/{mbid}", {"inc": "genres+tags"})
        if status == 200 and rg.get("id"):
            g = _top_genres(rg)
            return g, ("release_group" if g else "none"), rg["id"]
        status, rel = _mb_get(f"release/{mbid}", {"inc": "release-groups+genres+tags"})
        if status == 200 and rel.get("id"):
            rgroup = rel.get("release-group") or {}
            g = _top_genres(rgroup) or _top_genres(rel)
            src = "release_group" if _top_genres(rgroup) else ("release" if g else "none")
            return g, src, rgroup.get("id")
        return None, "error", None

    def genres_for_artist_mbid(self, mbid):
        status, a = _mb_get(f"artist/{mbid}", {"inc": "genres+tags"})
        if status == 200 and a.get("id"):
            return _top_genres(a)
        return None

    def find_release_group(self, artist, title):
        """Name search for albums with no MBID. -> (rg_mbid, genres) or (None, None)"""
        def term(s):
            s = (s or "").replace('"', "").strip()
            return f'"{s}"' if " " in s else s
        q = f"artist:{term(artist)} AND releasegroup:{term(title)}"
        status, data = _mb_get("release-group", {"query": q, "limit": 3})
        if status != 200:
            return None, None
        for rg in data.get("release-groups") or []:
            if int(rg.get("score", 0)) >= 90:
                g, _src, rgid = self.genres_for_album_mbid(rg["id"])
                return rgid or rg["id"], g
        return None, None

    # ---- passes -------------------------------------------------------------

    def run(self, scope="all", only_missing=True):
        try:
            if scope in ("all", "artists"):
                self._artists_pass(only_missing)
            if scope in ("all", "albums"):
                self._albums_pass(only_missing)
            if scope in ("all", "albums", "fallback"):
                self._artist_fallback_pass()
            msg = (f"Genres done: {self.found} found, {self.missing} with none on MusicBrainz, "
                   f"{self.failed} failed")
            if self.progress_tracker and self.operation_id:
                self.progress_tracker.complete_operation(self.operation_id, msg)
            self._emit(self.done, self.done, msg, "complete")
            print(f"🏷️  {msg}")
        except Exception as e:
            if self.progress_tracker and self.operation_id:
                self.progress_tracker.fail_operation(self.operation_id, str(e))
            self._emit(self.done, self.done, f"Genre fetch failed: {e}", "error")
            raise

    def _artists_pass(self, only_missing):
        where = "mbid IS NOT NULL AND mbid <> ''"
        if only_missing:
            where += " AND genres_fetched_at IS NULL"
        rows = self._rows(f"SELECT id, name, mbid FROM artists WHERE {where} ORDER BY name")
        total = len(rows)
        print(f"🏷️  Genre pass: {total} artists")
        for i, r in enumerate(rows, 1):
            if self.cancelled:
                return
            g = self.genres_for_artist_mbid(r["mbid"])
            if g is None:
                self.failed += 1
            else:
                self.found += 1 if g else 0
                self.missing += 0 if g else 1
                self._write(
                    "UPDATE artists SET genres=%s, genres_fetched_at=NOW() WHERE id=%s",
                    (g, r["id"]),
                )
            self.done += 1
            if i % 10 == 0 or i == total:
                self._emit(i, total, f"Artists {i}/{total}: {r['name']}")

    def _albums_pass(self, only_missing):
        where = "1=1"
        if only_missing:
            where += " AND al.genres_fetched_at IS NULL"
        rows = self._rows(
            f"SELECT al.id, al.title, al.mbid, al.release_group_mbid, ar.name AS artist "
            f"FROM albums al JOIN artists ar ON ar.id = al.artist_id WHERE {where} ORDER BY ar.name, al.title"
        )
        total = len(rows)
        print(f"🏷️  Genre pass: {total} albums")
        for i, r in enumerate(rows, 1):
            if self.cancelled:
                return
            key = r["release_group_mbid"] or r["mbid"]
            genres, source, rgid = (None, "error", None)
            if key:
                genres, source, rgid = self.genres_for_album_mbid(key)
            if genres is None and not key:
                rgid, genres = self.find_release_group(r["artist"], r["title"])
                source = "release_group" if genres else ("none" if rgid else "error")
            if source == "error":
                self.failed += 1
                # Leave genres_fetched_at NULL so a rerun retries it.
            else:
                self.found += 1 if genres else 0
                self.missing += 0 if genres else 1
                self._write(
                    "UPDATE albums SET genres=%s, genres_source=%s, genres_fetched_at=NOW(), "
                    "release_group_mbid=COALESCE(%s, release_group_mbid) WHERE id=%s",
                    (genres or [], source, rgid, r["id"]),
                )
            self.done += 1
            if i % 10 == 0 or i == total:
                self._emit(i, total, f"Albums {i}/{total}: {r['artist']} – {r['title']}")

    def _artist_fallback_pass(self):
        """Albums MusicBrainz had no votes for inherit the artist's genres."""
        count = self._write_count(
            "UPDATE albums al SET genres = ar.genres, genres_source = 'artist' "
            "FROM artists ar WHERE ar.id = al.artist_id AND al.genres_fetched_at IS NOT NULL "
            "AND (al.genres IS NULL OR array_length(al.genres, 1) IS NULL) "
            "AND ar.genres IS NOT NULL AND array_length(ar.genres, 1) > 0"
        )
        print(f"🏷️  Artist-genre fallback applied to {count} albums")
