# -*- coding: utf-8 -*-
"""Editions Available: every release of an album on MusicBrainz, sorted into
edition types (Dolby Atmos, 5.1 surround, SACD, DVD-Audio, Blu-ray, hi-res,
Japan / SHM-CD, vinyl, remaster / deluxe), cached per release group.

Used by the album page (albums you own: which editions exist and which of them
you have) and the Missing Albums page (albums you don't have yet), plus a
"MusicBrainz gaps" report: Atmos / surround you own that MusicBrainz doesn't
list, so it can be added there (Nov 2026).

MusicBrainz is spotty on Atmos: streaming-only Atmos mixes are often missing
or entered as plain "Digital Media" with "Dolby Atmos" only in the
disambiguation. Everything here is "per MusicBrainz", never "doesn't exist".
"""
import json
import re
from datetime import datetime, timedelta

from app.genre_fetcher import _mb_get

CACHE_DAYS = 7
MAX_PAGES = 5  # 500 releases; the biggest albums (Thriller...) have ~400

# (key, label shown in the app), in display order
EDITION_TYPES = [
    ("atmos", "Dolby Atmos"),
    ("surround", "5.1 / Surround"),
    ("sacd", "SACD"),
    ("dvd_audio", "DVD-Audio / DualDisc"),
    ("bluray", "Blu-ray"),
    ("hires", "Hi-Res"),
    ("japan", "Japan / SHM-CD"),
    ("vinyl", "Vinyl"),
    ("remaster", "Remaster / Deluxe"),
]
_LABELS = dict(EDITION_TYPES)

_SURROUND = re.compile(
    r"\b(5\.1|5\.0|7\.1|4\.0|quad|quadraphonic|multi-?channel|surround)\b")
_HIRES = re.compile(
    r"24[- ]?bit|\b24/(44|48|88|96|176|192)|\bhi-?res\b|high[- ]resolution"
    r"|\b(88\.2|96|176\.4|192) ?khz\b|\bmqa\b")
_JAPAN_FMT = re.compile(r"shm|blu-?spec|hqcd|uhqcd|k2hd")
_REMASTER = re.compile(
    r"remaster|deluxe|anniversary|expanded|legacy edition|collector'?s edition"
    r"|special edition|bonus track")


def classify_text(text, formats=(), country=""):
    """Edition types for one release (or one owned edition's label)."""
    t = (text or "").lower()
    fmts = " ".join(f.lower() for f in formats if f)
    blob = f"{t} {fmts}"
    types = []
    if "atmos" in blob:
        types.append("atmos")
    if _SURROUND.search(blob):
        types.append("surround")
    if "sacd" in fmts or "sacd" in t or "super audio" in blob:
        types.append("sacd")
    # DVD-Audio, or a DualDisc (its DVD side carries the hi-res / 5.1 mix).
    # A plain DVD-Video bundled with the CD is usually music videos (Thriller
    # 25): only counted when the release says it's surround.
    if ("dvd-audio" in fmts or "dualdisc" in fmts or "dvd-audio" in t
            or ("dvd-video" in fmts and _SURROUND.search(blob))):
        types.append("dvd_audio")
    if "blu-ray" in fmts or "blu-ray" in t or "bluray" in t:
        types.append("bluray")
    if _HIRES.search(blob):
        types.append("hires")
    if (country or "").upper() == "JP" or _JAPAN_FMT.search(blob):
        types.append("japan")
    if "vinyl" in fmts or "vinyl" in t:
        types.append("vinyl")
    if _REMASTER.search(t):
        types.append("remaster")
    return types


def _release_entry(rel):
    media = rel.get("media") or []
    formats = []
    for m in media:
        f = m.get("format")
        if f and f not in formats:
            formats.append(f)
    labels = [
        (li.get("label") or {}).get("name")
        for li in (rel.get("label-info") or [])
        if (li.get("label") or {}).get("name")
    ]
    text = f"{rel.get('title') or ''} {rel.get('disambiguation') or ''}"
    return {
        "id": rel.get("id"),
        "title": rel.get("title"),
        "disambiguation": rel.get("disambiguation") or "",
        "date": rel.get("date") or "",
        "country": rel.get("country") or "",
        "formats": formats,
        "track_count": sum(int(m.get("track-count") or 0) for m in media),
        "disc_count": len(media),
        "label": labels[0] if labels else "",
        "status": rel.get("status") or "",
        "types": classify_text(text, formats, rel.get("country")),
    }


def fetch_editions(release_group_mbid):
    """All releases of a release group from MusicBrainz, classified.
    -> dict, or None when MusicBrainz didn't answer."""
    releases = []
    offset = 0
    total = None
    for _ in range(MAX_PAGES):
        status, data = _mb_get(
            "release",
            {"release-group": release_group_mbid, "inc": "media+labels",
             "limit": 100, "offset": offset},
        )
        if status != 200:
            if releases:
                break
            return None
        page = data.get("releases") or []
        total = data.get("release-count", len(page))
        releases.extend(page)
        offset += len(page)
        if not page or offset >= total:
            break

    entries = [_release_entry(r) for r in releases if r.get("id")]
    entries.sort(key=lambda e: (e["date"] or "9999", e["country"]))
    by_type = {k: [e for e in entries if k in e["types"]] for k, _ in EDITION_TYPES}
    return {
        "release_group_mbid": release_group_mbid,
        "release_count": total if total is not None else len(entries),
        "releases_listed": len(entries),
        "types": [
            {"key": k, "label": label, "count": len(by_type[k]),
             "releases": by_type[k][:25]}
            for k, label in EDITION_TYPES
            if by_type[k]
        ],
        "fetched_at": datetime.utcnow().isoformat() + "Z",
    }


_table_ready = [False]


def _ensure_table(cursor):
    if _table_ready[0]:
        return
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS album_editions_names (
            name_key TEXT PRIMARY KEY,
            release_group_mbid TEXT,
            checked_at TIMESTAMP NOT NULL DEFAULT NOW()
        )
        """
    )
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS album_editions_cache (
            release_group_mbid TEXT PRIMARY KEY,
            data JSONB NOT NULL,
            fetched_at TIMESTAMP NOT NULL DEFAULT NOW()
        )
        """
    )
    _table_ready[0] = True


def get_editions(db, release_group_mbid, refresh=False, fetch=True):
    """Cached editions for a release group (refetched after CACHE_DAYS).
    fetch=False: cache only (None when not cached yet)."""
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        _ensure_table(cursor)
        conn.commit()
        cursor.execute(
            "SELECT data, fetched_at FROM album_editions_cache WHERE release_group_mbid = %s",
            (release_group_mbid,),
        )
        row = cursor.fetchone()
        fresh = row and row["fetched_at"] > datetime.utcnow() - timedelta(days=CACHE_DAYS)
        if row and (fresh or not fetch) and not refresh:
            data = row["data"]
            return data if isinstance(data, dict) else json.loads(data)
        if not fetch:
            return None
    finally:
        conn.close()

    data = fetch_editions(release_group_mbid)
    if data is None:
        return None
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute(
            """
            INSERT INTO album_editions_cache (release_group_mbid, data, fetched_at)
            VALUES (%s, %s, NOW())
            ON CONFLICT (release_group_mbid)
            DO UPDATE SET data = EXCLUDED.data, fetched_at = NOW()
            """,
            (release_group_mbid, json.dumps(data)),
        )
        conn.commit()
    finally:
        conn.close()
    return data


_EDITION_SUFFIX = re.compile(r"\s*[\(\[][^\)\]]*[\)\]]")


def base_title(title):
    """'Goodbye Yellow Brick Road (30th Anniversary Deluxe)' -> the album's
    own name; edition text in the title spoils the MusicBrainz search."""
    return _EDITION_SUFFIX.sub("", title or "").strip() or (title or "")


def find_release_group(artist, title):
    """Name search for an album with no stored release group. -> mbid or None.
    Tries the title as stored, then without its edition text."""
    rg = _find_release_group(artist, title)
    plain = base_title(title)
    if not rg and plain != (title or "").strip():
        rg = _find_release_group(artist, plain)
    return rg


def cached_release_group(db, artist, title, fetch=True):
    """find_release_group with a 7-day cache (misses too), so the gaps report
    and Missing Albums don't repeat MusicBrainz name searches."""
    key = f"{(artist or '').strip().lower()}|{(title or '').strip().lower()}"
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        _ensure_table(cursor)
        conn.commit()
        cursor.execute(
            "SELECT release_group_mbid, checked_at FROM album_editions_names WHERE name_key = %s",
            (key,),
        )
        row = cursor.fetchone()
        if row and row["checked_at"] > datetime.utcnow() - timedelta(days=CACHE_DAYS):
            return row["release_group_mbid"], True
        if not fetch:
            return None, False  # not looked up yet
    finally:
        conn.close()
    rg = find_release_group(artist, title)
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute(
            """
            INSERT INTO album_editions_names (name_key, release_group_mbid, checked_at)
            VALUES (%s, %s, NOW())
            ON CONFLICT (name_key) DO UPDATE
            SET release_group_mbid = EXCLUDED.release_group_mbid, checked_at = NOW()
            """,
            (key, rg),
        )
        conn.commit()
    finally:
        conn.close()
    return rg, False


def _find_release_group(artist, title):
    def term(s):
        s = (s or "").replace('"', "").strip()
        return f'"{s}"'
    # primarytype:album first: a plain name search happily returns the
    # single of the same name ("Hysteria", 7 releases) instead of the album.
    base = f"artist:{term(artist)} AND releasegroup:{term(title)}"
    for q in (f"{base} AND primarytype:album", base):
        status, data = _mb_get("release-group", {"query": q, "limit": 5})
        if status != 200:
            return None
        for rg in data.get("release-groups") or []:
            if int(rg.get("score", 0)) >= 90:
                return rg.get("id")
    return None


def owned_types(cursor, album_id):
    """Edition types you have for this album: the album itself plus any other
    editions grouped with it (albums.group_id). Atmos and surround come from
    the files; the rest from the edition name / album title / format."""
    cursor.execute("SELECT id, group_id FROM albums WHERE id = %s", (album_id,))
    row = cursor.fetchone()
    if not row:
        return [], []
    if row["group_id"]:
        cursor.execute(
            "SELECT id, title, edition_label FROM albums WHERE id = %s OR group_id = %s",
            (album_id, row["group_id"]),
        )
    else:
        cursor.execute(
            "SELECT id, title, edition_label FROM albums WHERE id = %s", (album_id,))
    albums = cursor.fetchall()
    ids = [a["id"] for a in albums]
    cursor.execute(
        """
        SELECT MAX(COALESCE(is_atmos, 0)) AS atmos,
               MAX(CASE WHEN COALESCE(is_atmos, 0) = 0 AND COALESCE(audio_channels, 2) > 2
                        THEN 1 ELSE 0 END) AS surround,
               STRING_AGG(DISTINCT LOWER(COALESCE(file_format, '')), ' ') AS formats
        FROM songs WHERE album_id = ANY(%s)
        """,
        (ids,),
    )
    s = cursor.fetchone() or {}
    types = set()
    if s.get("atmos"):
        types.add("atmos")
    if s.get("surround"):
        types.add("surround")
    formats = s.get("formats") or ""
    if "dsf" in formats or "dff" in formats:
        types.add("sacd")
    for a in albums:
        for t in classify_text(f"{a['title'] or ''} {a['edition_label'] or ''}"):
            types.add(t)
    return [k for k, _ in EDITION_TYPES if k in types], ids


def album_editions(db, album_id, refresh=False):
    """Editions for an album you own, with `owned` flags."""
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute(
            """
            SELECT al.id, al.title, al.release_group_mbid, ar.name AS artist
            FROM albums al JOIN artists ar ON ar.id = al.artist_id
            WHERE al.id = %s
            """,
            (album_id,),
        )
        album = cursor.fetchone()
        if not album:
            return None
        owned, _ids = owned_types(cursor, album_id)
    finally:
        conn.close()

    rg = album["release_group_mbid"] or cached_release_group(
        db, album["artist"], album["title"])[0]
    if not rg:
        return {"album_id": album_id, "release_group_mbid": None, "types": [],
                "owned": owned, "note": "No MusicBrainz match for this album"}
    data = get_editions(db, rg, refresh=refresh)
    if data is None:
        return {"album_id": album_id, "release_group_mbid": rg, "types": [],
                "owned": owned, "note": "MusicBrainz didn't answer; try again later"}
    out = dict(data)
    out["album_id"] = album_id
    out["owned"] = owned
    for t in out["types"]:
        t["owned"] = t["key"] in owned
    # Owned but not on MusicBrainz at all: show it, and it's a gap to fill.
    listed = {t["key"] for t in out["types"]}
    out["missing_on_musicbrainz"] = [k for k in owned if k not in listed]
    return out


def editions_by_name(db, artist, title, refresh=False):
    """Editions for an album you don't have (Missing Albums)."""
    rg, _cached = cached_release_group(db, artist, title)
    if not rg:
        return {"release_group_mbid": None, "types": [],
                "note": "No MusicBrainz match for this album"}
    data = get_editions(db, rg, refresh=refresh)
    if data is None:
        return {"release_group_mbid": rg, "types": [],
                "note": "MusicBrainz didn't answer; try again later"}
    return data


_scan = {"running": False}


def gaps_scan_running():
    return _scan["running"]


def start_gaps_scan(db):
    """Fill the caches for every Atmos / surround album in the background
    (MusicBrainz, ~1-4 s per album). False if a scan is already running."""
    if _scan["running"]:
        return False
    import eventlet

    def run():
        try:
            r = gaps_report(db, max_fetch=100000)
            print(f"🎚️ [editions] gaps scan done: {len(r['gaps'])} gaps, "
                  f"{len(r['no_musicbrainz_link'])} without a MusicBrainz match")
        except Exception as e:
            print(f"🎚️ [editions] gaps scan failed: {e}")
        finally:
            _scan["running"] = False

    _scan["running"] = True
    eventlet.spawn_n(run)
    return True


def gaps_report(db, max_fetch=15):
    """Atmos / surround you own that MusicBrainz doesn't list for that album.
    Fetches at most `max_fetch` uncached release groups per call (1 s each);
    the rest are reported as pending, so calling again continues the scan."""
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute(
            """
            SELECT al.id, al.title, al.release_group_mbid, ar.name AS artist,
                   MAX(COALESCE(s.is_atmos, 0)) AS atmos,
                   MAX(CASE WHEN COALESCE(s.is_atmos, 0) = 0 AND COALESCE(s.audio_channels, 2) > 2
                            THEN 1 ELSE 0 END) AS surround
            FROM albums al
            JOIN artists ar ON ar.id = al.artist_id
            JOIN songs s ON s.album_id = al.id
            GROUP BY al.id, al.title, al.release_group_mbid, ar.name
            HAVING MAX(COALESCE(s.is_atmos, 0)) = 1
                OR MAX(CASE WHEN COALESCE(s.is_atmos, 0) = 0 AND COALESCE(s.audio_channels, 2) > 2
                            THEN 1 ELSE 0 END) = 1
            ORDER BY ar.name, al.title
            """
        )
        albums = cursor.fetchall()
    finally:
        conn.close()

    gaps, no_link, pending, ok = [], [], 0, 0
    fetched = 0
    for a in albums:
        owned = (["atmos"] if a["atmos"] else []) + (["surround"] if a["surround"] else [])
        rg = a["release_group_mbid"]
        if not rg:
            # Not linked to MusicBrainz: look it up by name. The cache first
            # (a "no match" is cached too); a fresh lookup counts as a fetch.
            rg, known = cached_release_group(db, a["artist"], a["title"], fetch=False)
            if not known:
                if fetched >= max_fetch:
                    pending += 1
                    continue
                rg, _ = cached_release_group(db, a["artist"], a["title"])
                fetched += 1
        if not rg:
            no_link.append({"album_id": a["id"], "artist": a["artist"],
                            "album": a["title"], "owned": owned})
            continue
        data = get_editions(db, rg, fetch=False)
        if data is None:
            if fetched >= max_fetch:
                pending += 1
                continue
            data = get_editions(db, rg)
            fetched += 1
            if data is None:
                pending += 1
                continue
        listed = {t["key"] for t in data.get("types", [])}
        # A 5.1 mix usually ships on SACD / DVD-Audio / Blu-ray discs.
        if listed & {"sacd", "dvd_audio", "bluray"}:
            listed.add("surround")
        missing = [k for k in owned if k not in listed]
        if missing:
            gaps.append({
                "album_id": a["id"], "artist": a["artist"], "album": a["title"],
                "release_group_mbid": rg, "owned": owned,
                "missing_on_musicbrainz": [_LABELS[k] for k in missing],
                "musicbrainz_url": f"https://musicbrainz.org/release-group/{rg}",
            })
        else:
            ok += 1
    return {
        "albums_with_spatial": len(albums),
        "gaps": gaps,
        "no_musicbrainz_link": no_link,
        "already_listed": ok,
        "pending": pending,
        "complete": pending == 0,
    }
