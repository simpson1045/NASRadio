"""Chapter parsing for podcast episodes.

Two sources supported (tried in order of preference):
  1. Podcast namespace JSON — <podcast:chapters url="..."/> in the feed item.
     Modern standard, free and fast (one HTTP GET per episode).
  2. ID3v2 CHAP/CTOC frames embedded in the MP3 itself.
     Fallback for feeds that don't publish a chapters URL (Megaphone,
     Anchor, and many others). Requires a partial download of the audio
     file — we use HTTP Range requests to fetch only the ID3 header, not
     the whole file.

PSC (Podlove Simple Chapters) is a third standard but it's inline XML
in the RSS item. If any of simpson1045's feeds ever use it, add handling here.

Both parsers return a list of dicts shaped like:
    {start_time_seconds, end_time_seconds, title, image_url, link_url,
     is_skippable, order_index, source}

Storage lives in the `song_chapters` table (schema in models.py).
"""

import io
import json
import re
import struct
import time
import feedparser
import requests

from app.rss_feeds import _validate_url


# Negative-result cooldown so a song whose chapter fetch fails (a 404 on an
# episode whose audio isn't posted yet, an expired signed URL, a timeout) isn't
# re-probed on EVERY on-play / endpoint / feed-refresh call. Without it a single
# dead URL (e.g. ASOT 1283 that 404s) spams the log dozens of times. We re-probe
# at most once per window, so a producer that embeds chapters a day later is
# still picked up — just not hammered.
_CHAPTER_FAIL_COOLDOWN = {}  # song_id -> unix ts of last all-candidates failure
_CHAPTER_FAIL_COOLDOWN_SEC = 60 * 60  # 1 hour


# Common ad-read titles — chapters matching these get `is_skippable=true`.
# Heuristic, not exhaustive. Users can toggle per-chapter in the UI.
_AD_HEURISTIC = re.compile(
    r"\b(sponsor|ad(vertisement)?|betterhelp|squarespace|nordvpn|"
    r"athletic\s*greens|factor\s*meals|hellofresh|expressvpn|zocdoc|"
    r"manscaped|helix|stamps\.com|shopify|indeed|audible|quip|simplisafe|"
    r"commercial\s*break|ad\s*break|promo|partner\s*message)\b",
    re.IGNORECASE,
)


def _is_likely_ad(title):
    if not title:
        return False
    return bool(_AD_HEURISTIC.search(title))


def parse_chapters_from_feed(feed_url):
    """Scan every item in an RSS feed for <podcast:chapters url="...">.

    Returns a dict of {episode_guid: chapters_url} for feeds that publish
    JSON chapter URLs. Called once per feed refresh — new episodes get
    their chapter URL captured without downloading anything yet.
    """
    _validate_url(feed_url)
    feed = feedparser.parse(feed_url)
    if feed.bozo and not feed.entries:
        return {}

    result = {}
    for entry in feed.entries:
        guid = entry.get("id") or entry.get("link")
        if not guid:
            continue
        # feedparser exposes the podcast: namespace as `podcast_chapters`
        # (underscore-joined) when it recognizes the namespace URI. The
        # attribute is either a dict with 'url' or a list of same.
        chapters_url = None
        raw = entry.get("podcast_chapters")
        if isinstance(raw, dict):
            chapters_url = raw.get("url") or raw.get("href")
        elif isinstance(raw, list) and raw:
            chapters_url = raw[0].get("url") or raw[0].get("href")

        # Fallback: some feeds put the URL in a plain <podcast:chapters>
        # attribute that feedparser exposes as a namespaced key.
        if not chapters_url:
            for k, v in entry.items():
                if k.endswith("_chapters") and isinstance(v, dict):
                    chapters_url = v.get("url") or v.get("href")
                    if chapters_url:
                        break

        if chapters_url:
            result[guid] = chapters_url
    return result


def fetch_chapters_json(chapters_url, timeout=10):
    """Fetch a podcast:chapters JSON URL and parse it into our chapter dict list.

    Podcast Index chapters-1.2 spec: top-level `chapters` array with
    per-entry fields startTime, title, optionally img, url, toc (bool).
    """
    _validate_url(chapters_url)
    response = requests.get(chapters_url, timeout=timeout)
    response.raise_for_status()
    data = response.json()
    entries = data.get("chapters") or []
    chapters = []
    for i, ch in enumerate(entries):
        try:
            start = float(ch.get("startTime", 0))
        except (TypeError, ValueError):
            continue
        end_raw = ch.get("endTime")
        try:
            end = float(end_raw) if end_raw is not None else None
        except (TypeError, ValueError):
            end = None
        title = ch.get("title") or None
        toc = ch.get("toc", True)
        # toc=false is the standard way to mark hidden-from-TOC ads
        is_skippable = (toc is False) or _is_likely_ad(title)
        chapters.append({
            "order_index": i,
            "start_time_seconds": int(start),
            "end_time_seconds": int(end) if end is not None else None,
            "title": title,
            "image_url": ch.get("img"),
            "link_url": ch.get("url"),
            "is_skippable": is_skippable,
            "source": "rss",
        })
    return chapters


def fetch_chapters_from_id3(audio_url, timeout=20, max_tag_bytes=10 * 1024 * 1024):
    """Parse ID3v2 CHAP/CTOC frames from the start of an MP3.

    Downloads just enough to read the ID3 tag (never the audio itself):
      1. Fetch bytes 0-9 — the 10-byte ID3v2 header. The last 4 bytes are
         a synchsafe integer giving the tag body size.
      2. Fetch bytes 0-(10+size) — the complete tag.
      3. Hand the bytes to mutagen.id3.ID3 for parsing.

    Returns chapter dicts in the same shape as fetch_chapters_json.
    Empty list if the file has no chapters. Raises on network or parse
    error — caller wraps in try/except.
    """
    _validate_url(audio_url)

    # Step 1: 10-byte header read.
    r = requests.get(
        audio_url,
        headers={"Range": "bytes=0-9"},
        timeout=timeout,
        stream=True,
    )
    r.raise_for_status()
    header = r.raw.read(10)
    r.close()
    if len(header) < 10 or header[:3] != b"ID3":
        return []  # No ID3v2 tag

    # Synchsafe integer: each byte contributes 7 bits (MSB is 0).
    size_bytes = header[6:10]
    tag_size = (
        (size_bytes[0] << 21)
        | (size_bytes[1] << 14)
        | (size_bytes[2] << 7)
        | size_bytes[3]
    )
    total = 10 + tag_size
    if total > max_tag_bytes:
        # 10 MB tag is pathological — refuse rather than burning RAM.
        return []

    # Step 2: fetch the whole tag (header + body).
    r = requests.get(
        audio_url,
        headers={"Range": f"bytes=0-{total - 1}"},
        timeout=timeout,
        stream=True,
    )
    r.raise_for_status()
    tag_bytes = r.raw.read(total)
    r.close()

    # Step 3: parse with mutagen.
    # mutagen.id3 needs a file-like object; it'll happily read just the tag
    # portion if we give it BytesIO containing at least the declared size.
    from mutagen.id3 import ID3
    try:
        tags = ID3(io.BytesIO(tag_bytes))
    except Exception:
        return []

    chaps = [t for t in tags.values() if t.FrameID == "CHAP"]
    if not chaps:
        return []

    # CTOC (if present) declares child order; fall back to CHAP sort by start.
    ctoc_order = None
    for t in tags.values():
        if t.FrameID == "CTOC":
            ctoc_order = list(t.child_element_ids or [])
            break
    if ctoc_order:
        order_map = {eid: i for i, eid in enumerate(ctoc_order)}
        chaps.sort(key=lambda c: order_map.get(c.element_id, len(order_map)))
    else:
        chaps.sort(key=lambda c: c.start_time or 0)

    chapters = []
    for i, c in enumerate(chaps):
        title = None
        for sub in c.sub_frames.values():
            if sub.FrameID == "TIT2" and sub.text:
                title = sub.text[0]
                break
        start_ms = c.start_time if c.start_time is not None else 0
        end_ms = c.end_time if c.end_time is not None else None
        chapters.append({
            "order_index": i,
            "start_time_seconds": int(start_ms / 1000),
            "end_time_seconds": int(end_ms / 1000) if end_ms else None,
            "title": title,
            "image_url": None,
            "link_url": None,
            "is_skippable": _is_likely_ad(title),
            "source": "id3",
        })
    return chapters


def persist_chapters(db, song_id, chapters):
    """Write parsed chapters for a song, replacing any existing rows.

    Idempotent — call after every refetch. Small transactions so a single
    failed song doesn't cascade.
    """
    if not chapters:
        return 0
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute("DELETE FROM song_chapters WHERE song_id = %s", (song_id,))
        for ch in chapters:
            cursor.execute(
                """
                INSERT INTO song_chapters (
                    song_id, order_index, start_time_seconds,
                    end_time_seconds, title, image_url, link_url,
                    is_skippable, source
                )
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    song_id,
                    ch["order_index"],
                    ch["start_time_seconds"],
                    ch["end_time_seconds"],
                    ch["title"],
                    ch["image_url"],
                    ch["link_url"],
                    ch["is_skippable"],
                    ch["source"],
                ),
            )
        conn.commit()
        return len(chapters)
    except Exception as e:
        conn.rollback()
        print(f"[chapters] persist song {song_id}: {e}")
        return 0
    finally:
        conn.close()


def ensure_chapters_for_song(db, song_id):
    """Populate chapters for a podcast song if they're not already cached.

    Safe to call frequently — returns early if song_chapters already has
    rows for this song. Intended for use from on-play triggers and the
    /api/songs/<id>/chapters endpoint.

    Tries ID3 against the resolved CDN URL (or source URL if no resolved).
    Returns the number of chapters stored (0 if none found).
    """
    # Skip if every candidate failed recently — avoids re-probing (and logging)
    # a dead URL on every call.
    _ts = _CHAPTER_FAIL_COOLDOWN.get(song_id)
    if _ts is not None and (time.time() - _ts) < _CHAPTER_FAIL_COOLDOWN_SEC:
        return 0

    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute(
            "SELECT COUNT(*) as n FROM song_chapters WHERE song_id = %s",
            (song_id,),
        )
        if cursor.fetchone()["n"] > 0:
            return 0  # Already cached, no work

        cursor.execute(
            """
            SELECT id, source_type, resolved_url, source_url, file_path
              FROM songs WHERE id = %s
            """,
            (song_id,),
        )
        row = cursor.fetchone()
        if not row or row.get("source_type") != "podcast":
            return 0

        # Candidate URLs to probe, in order. resolved_url is fastest but its
        # signed CDN signature expires (~1 day for Audioboom) and then returns
        # 403 — so fall back to source_url, which re-resolves to a freshly
        # signed URL on each fetch.
        candidates = []
        for u in (row.get("resolved_url"), row.get("source_url"), row.get("file_path")):
            if u and u not in candidates:
                candidates.append(u)
        if not candidates:
            return 0
    finally:
        conn.close()

    chapters = []
    last_err = None
    for url in candidates:
        try:
            chapters = fetch_chapters_from_id3(url)
            last_err = None
            break  # URL worked (empty list just means no embedded chapters)
        except Exception as e:
            last_err = e  # e.g. expired signed URL → try the next candidate
            continue

    if last_err is not None:
        # Every candidate failed — back off so we don't re-probe (and re-log)
        # this song until the cooldown elapses.
        _CHAPTER_FAIL_COOLDOWN[song_id] = time.time()
        # Only log when every candidate failed — a stale resolved_url that
        # then succeeds via source_url shouldn't spam the log.
        print(f"[chapters] song {song_id}: ID3 fetch failed: {last_err}")
        return 0

    if not chapters:
        return 0

    return persist_chapters(db, song_id, chapters)
