"""Artist discography from MusicBrainz, cached per artist.

The artist page shows every release group MusicBrainz knows for an artist,
tabbed by type, with the ones in the library lit and the rest greyed out.
MusicBrainz is 1 request/second and a prolific artist is 10+ pages, so the
fetch runs in the background and the result lives in `mb_release_groups`
until it's older than REFRESH_AFTER_DAYS (or the user asks for a refresh).

Ownership is decided per request, never cached, so an import lights up the
release the moment it lands:
  1. albums.release_group_mbid == group mbid   (imports since 2026-09)
  2. albums.mbid == group mbid                 (older imports store the RG id)
  3. normalised title match                    (rips, YouTube imports, ...)
Local albums that match nothing are still listed in their own type tab so
nothing simpson1045 owns is ever hidden.

Bootlegs: a release group has no status of its own; the release-group
search index does expose `status` (of any release in the group), so a
group is a bootleg when it appears under status:bootleg and never under
status:official.
"""

import re
import time
from datetime import datetime, timedelta
from difflib import SequenceMatcher
from urllib.parse import quote_plus

import eventlet

from app.genre_fetcher import _mb_get

REFRESH_AFTER_DAYS = 30
PAGE = 100
MAX_PAGES = 30  # 3,000 release groups; nobody simpson1045 listens to has more

CATEGORIES = ["Album", "EP", "Single", "Compilation", "Live", "Bootleg", "Other"]

# artist_id -> monotonic start time of an in-flight fetch
_inflight: dict = {}


# ---------------------------------------------------------------- helpers
def _norm_title(title):
    """Comparison key: lowercase, curly quotes straightened, every bracketed
    tail dropped ("Don't Look Back (USA, SBM EK 35050)" -> "dont look back"),
    punctuation and a leading "the" gone."""
    t = (title or "").lower().replace("’", "'").replace("‘", "'")
    t = re.sub(r"\s*[\(\[][^\)\]]*[\)\]]\s*$", "", t)  # trailing (...) / [...]
    t = re.sub(r"\s*[\(\[][^\)\]]*[\)\]]\s*$", "", t)  # twice for "(a) [b]"
    t = re.sub(r"\s*-\s*(disc|cd)\s*\d+$", "", t)
    t = re.sub(r"[^\w\s]", "", t)
    t = re.sub(r"\s+", " ", t).strip()
    t = re.sub(r"^the ", "", t)
    return t


def categorize(primary_type, secondary_types, is_bootleg=False):
    secs = {s.lower() for s in (secondary_types or [])}
    if is_bootleg:
        return "Bootleg"
    if "compilation" in secs:
        return "Compilation"
    if "live" in secs:
        return "Live"
    if secs & {"remix", "dj-mix", "mixtape/street", "demo", "soundtrack",
               "spokenword", "interview", "audiobook", "audio drama",
               "field recording", "broadcast"}:
        return "Other"
    if primary_type == "Album":
        return "Album"
    if primary_type == "EP":
        return "EP"
    if primary_type == "Single":
        return "Single"
    return "Other"


def local_category(album_type, secondary_types_csv):
    """Same bucketing for a local albums row (mirrors Album.category in Dart)."""
    secs = [s.strip() for s in (secondary_types_csv or "").split(",") if s.strip()]
    return categorize(album_type or "Album", secs)


def _year_of(date_str):
    if date_str and len(date_str) >= 4 and date_str[:4].isdigit():
        return int(date_str[:4])
    return None


def cover_url(mbid, size=250):
    return f"https://coverartarchive.org/release-group/{mbid}/front-{size}"


# ---------------------------------------------------------------- MB calls
def resolve_artist_mbid(artist_name):
    """Best MusicBrainz artist for a name, or None if nothing close."""
    status, data = _mb_get("artist", {"query": f'artist:"{artist_name}"', "limit": 5})
    if status != 200:
        return None, f"MusicBrainz search failed ({status})"
    best, best_score = None, 0.0
    for a in data.get("artists", []):
        score = SequenceMatcher(None, artist_name.lower(), a["name"].lower()).ratio()
        if score > best_score:
            best, best_score = a, score
    if not best or best_score < 0.8:
        return None, "Artist not found in MusicBrainz"
    return best["id"], None


def _browse_release_groups(artist_mbid):
    groups = []
    for page in range(MAX_PAGES):
        status, data = _mb_get(
            "release-group",
            {"artist": artist_mbid, "limit": PAGE, "offset": page * PAGE},
            timeout=30,
        )
        if status != 200:
            raise RuntimeError(f"release-group browse failed ({status})")
        batch = data.get("release-groups", [])
        groups.extend(batch)
        if len(batch) < PAGE:
            break
    return groups


def _search_rg_ids(artist_mbid, status_value):
    """Release-group ids for `arid:X AND status:<value>` via the search index."""
    ids = set()
    query = f"arid:{artist_mbid} AND status:{status_value}"
    for page in range(MAX_PAGES):
        status, data = _mb_get(
            "release-group",
            {"query": query, "limit": PAGE, "offset": page * PAGE},
            timeout=30,
        )
        if status != 200:
            break  # bootleg tagging is best-effort
        batch = data.get("release-groups", [])
        ids.update(rg["id"] for rg in batch)
        if len(batch) < PAGE:
            break
    return ids


# ---------------------------------------------------------------- storage
def _load_status(db, conn, artist_id):
    cur = db.get_cursor(conn)
    cur.execute(
        "SELECT artist_id, artist_mbid, status, error, fetched_at, total "
        "FROM mb_discography_status WHERE artist_id = %s",
        (artist_id,),
    )
    row = cur.fetchone()
    return dict(row) if row else None


def _set_status(db, artist_id, **fields):
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cols = ["artist_id"] + list(fields.keys())
        vals = [artist_id] + list(fields.values())
        updates = ", ".join(f"{k} = EXCLUDED.{k}" for k in fields)
        cur.execute(
            f"INSERT INTO mb_discography_status ({', '.join(cols)}) "
            f"VALUES ({', '.join(['%s'] * len(vals))}) "
            f"ON CONFLICT (artist_id) DO UPDATE SET {updates}",
            vals,
        )
        conn.commit()
    finally:
        conn.close()


def fetch_artist_discography(db, artist_id):
    """Background job: pull every release group for one artist into the cache."""
    started = time.monotonic()
    try:
        conn = db.get_connection()
        try:
            cur = db.get_cursor(conn)
            cur.execute("SELECT name, mbid FROM artists WHERE id = %s", (artist_id,))
            artist = cur.fetchone()
        finally:
            conn.close()
        if not artist:
            _set_status(db, artist_id, status="error", error="Artist not found")
            return

        artist_mbid = artist["mbid"]
        if not artist_mbid:
            artist_mbid, err = resolve_artist_mbid(artist["name"])
            if not artist_mbid:
                _set_status(db, artist_id, status="error", error=err,
                            fetched_at=datetime.now())
                return

        _set_status(db, artist_id, status="fetching", artist_mbid=artist_mbid, error=None)

        groups = _browse_release_groups(artist_mbid)
        bootleg_ids = _search_rg_ids(artist_mbid, "bootleg")
        official_ids = _search_rg_ids(artist_mbid, "official") if bootleg_ids else set()
        bootleg_only = bootleg_ids - official_ids

        conn = db.get_connection()
        try:
            cur = db.get_cursor(conn)
            cur.execute("DELETE FROM mb_release_groups WHERE artist_id = %s", (artist_id,))
            now = datetime.now()
            for rg in groups:
                secs = rg.get("secondary-types") or []
                is_boot = rg["id"] in bootleg_only
                cur.execute(
                    "INSERT INTO mb_release_groups (artist_id, mbid, title, primary_type, "
                    "secondary_types, first_release_date, year, category, is_bootleg, fetched_at) "
                    "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s) "
                    "ON CONFLICT (artist_id, mbid) DO NOTHING",
                    (
                        artist_id,
                        rg["id"],
                        rg.get("title") or "",
                        rg.get("primary-type"),
                        ", ".join(secs) if secs else None,
                        rg.get("first-release-date") or None,
                        _year_of(rg.get("first-release-date")),
                        categorize(rg.get("primary-type"), secs, is_boot),
                        is_boot,
                        now,
                    ),
                )
            conn.commit()
        finally:
            conn.close()

        _set_status(db, artist_id, status="ready", artist_mbid=artist_mbid,
                    error=None, fetched_at=datetime.now(), total=len(groups))
        print(
            f"📀 Discography cached for artist {artist_id}: {len(groups)} groups, "
            f"{len(bootleg_only)} bootleg-only, {time.monotonic() - started:.0f}s",
            flush=True,
        )
    except Exception as e:
        print(f"🔴 Discography fetch failed for artist {artist_id}: {e}", flush=True)
        try:
            _set_status(db, artist_id, status="error", error=str(e)[:300],
                        fetched_at=datetime.now())
        except Exception:
            pass
    finally:
        _inflight.pop(artist_id, None)


def kick_fetch(db, artist_id):
    """Start a background fetch unless one is already running (or stuck <10 min)."""
    t = _inflight.get(artist_id)
    if t is not None and time.monotonic() - t < 600:
        return False
    _inflight[artist_id] = time.monotonic()
    eventlet.spawn_n(fetch_artist_discography, db, artist_id)
    return True


# ---------------------------------------------------------------- read side
def build_discography(db, artist_id, refresh=False):
    """The artist page payload. Serves the cache, kicks a fetch when missing,
    stale, or asked to refresh; ownership is computed fresh every call."""
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute("SELECT id, name, mbid FROM artists WHERE id = %s", (artist_id,))
        artist = cur.fetchone()
        if not artist:
            return None

        st = _load_status(db, conn, artist_id)
        cur.execute(
            "SELECT mbid, title, primary_type, secondary_types, first_release_date, "
            "year, category, is_bootleg FROM mb_release_groups WHERE artist_id = %s",
            (artist_id,),
        )
        groups = [dict(r) for r in cur.fetchall()]

        cur.execute(
            "SELECT id, title, year, mbid, release_group_mbid, album_type, secondary_types, "
            "song_count, artwork_path FROM albums WHERE artist_id = %s",
            (artist_id,),
        )
        albums = [dict(r) for r in cur.fetchall()]
    finally:
        conn.close()

    stale = (
        st is None
        or st.get("status") in (None, "error") and not st.get("fetched_at")
        or (st.get("fetched_at") and st["fetched_at"] < datetime.now() - timedelta(days=REFRESH_AFTER_DAYS))
    )
    fetching = artist_id in _inflight and time.monotonic() - _inflight[artist_id] < 600
    if (refresh or stale or (st and st.get("status") == "fetching" and not fetching)) and not fetching:
        kick_fetch(db, artist_id)
        fetching = True

    # ---- ownership
    by_rg = {}
    by_mbid = {}
    for a in albums:
        if a.get("release_group_mbid"):
            by_rg.setdefault(a["release_group_mbid"], a)
        if a.get("mbid"):
            by_mbid.setdefault(a["mbid"], a)
    unmatched = {a["id"]: a for a in albums}
    tabs = {c: [] for c in CATEGORIES}

    def claim(album):
        return unmatched.pop(album["id"], None) is not None

    entries = []
    for rg in groups:
        local = by_rg.get(rg["mbid"]) or by_mbid.get(rg["mbid"])
        if local is not None and local["id"] not in unmatched:
            local = None  # already claimed by an earlier group
        if local is not None:
            claim(local)
        entries.append((rg, local))

    # Title pass for what's left, only against groups still unowned.
    if unmatched:
        norm_local = {a["id"]: _norm_title(a["title"]) for a in unmatched.values()}
        for i, (rg, local) in enumerate(entries):
            if local is not None or not unmatched:
                continue
            rg_norm = _norm_title(rg["title"])
            best, best_score = None, 0.0
            for aid, a in unmatched.items():
                ln = norm_local[aid]
                if not ln:
                    continue
                if ln == rg_norm:
                    best, best_score = a, 1.0
                    break
                score = SequenceMatcher(None, rg_norm, ln).ratio()
                if score > best_score:
                    best, best_score = a, score
            if best is not None and best_score >= 0.9:
                # Prefer same-type matches: a "Greatest Hits" single shouldn't
                # claim a "Greatest Hits" compilation when both exist.
                claim(best)
                entries[i] = (rg, best)

    for rg, local in entries:
        entry = {
            "mbid": rg["mbid"],
            "title": rg["title"],
            "year": rg["year"],
            "first_release_date": rg["first_release_date"],
            "type": rg["primary_type"],
            "secondary_types": [s for s in (rg["secondary_types"] or "").split(", ") if s],
            "is_bootleg": bool(rg["is_bootleg"]),
            "in_library": local is not None,
            "local_album_id": local["id"] if local else None,
            "song_count": local["song_count"] if local else None,
            "has_artwork": bool(local and local.get("artwork_path")),
            "cover_url": cover_url(rg["mbid"]),
        }
        tabs[rg["category"] if rg["category"] in tabs else "Other"].append(entry)

    for a in unmatched.values():
        tabs[local_category(a.get("album_type"), a.get("secondary_types"))].append(
            {
                "mbid": None,
                "title": a["title"],
                "year": a["year"],
                "first_release_date": str(a["year"]) if a["year"] else None,
                "type": a.get("album_type"),
                "secondary_types": [s.strip() for s in (a.get("secondary_types") or "").split(",") if s.strip()],
                "is_bootleg": False,
                "in_library": True,
                "local_album_id": a["id"],
                "song_count": a["song_count"],
                "has_artwork": bool(a.get("artwork_path")),
                "cover_url": None,
            }
        )

    # Release order: oldest first, unknown dates last, then title.
    for c in tabs:
        tabs[c].sort(
            key=lambda e: (
                e["first_release_date"] is None,
                e["first_release_date"] or "",
                (e["title"] or "").lower(),
            )
        )

    counts = {c: {"total": len(v), "owned": sum(1 for e in v if e["in_library"])} for c, v in tabs.items()}
    status = "ready" if groups else ("fetching" if fetching else "error")
    if fetching and groups:
        status = "refreshing"
    return {
        "artist_id": artist_id,
        "artist_name": artist["name"],
        "artist_mbid": (st or {}).get("artist_mbid") or artist["mbid"],
        "status": status,
        "error": (st or {}).get("error") if status == "error" else None,
        "fetched_at": st["fetched_at"].isoformat() if st and st.get("fetched_at") else None,
        "discography": tabs,
        "counts": counts,
        "total_count": sum(v["total"] for v in counts.values()),
        "in_library_count": sum(v["owned"] for v in counts.values()),
    }
