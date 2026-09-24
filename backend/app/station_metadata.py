"""Live "now playing" metadata for internet-radio stations.

The `stations` table only stores static metadata (name / genre / favicon).
To show what's ACTUALLY streaming right now — the current track's title and
artist — we fetch it out-of-band from the broadcaster. Flutter's audio
players don't reliably surface in-band ICY metadata (especially on Windows),
so we resolve it server-side and hand the app a clean answer.

Dispatch by station host, best source first:
  - Nightride.fm  -> SSE meta feed (structured artist/title for all stations)
  - SomaFM        -> /songs/<id>.json (structured, newest-first)
  - generic       -> Icecast /status-json.xsl 'title', then in-band ICY
                     StreamTitle read straight off the audio socket

Every network call has a short timeout. Callers MUST run this on a tpool
thread — the raw-socket ICY read and the `requests` calls block, and this
codebase runs on eventlet where a blocking syscall stalls the whole hub.
Results are cached per stream URL for a few seconds so many clients polling
at once don't hammer the upstream broadcaster.
"""
import json
import re
import socket
import time
from urllib.parse import urljoin, urlparse

import requests

_TIMEOUT = 5
_CACHE = {}          # stream_url -> (fetched_at_monotonic, payload)
_CACHE_TTL = 15.0
_UA = "NASRadio/1.0 (+station-now-playing)"


def _empty(source=None):
    return {"title": None, "artist": None, "artwork_url": None,
            "source": source, "is_live": True}


def _norm(title, artist, artwork_url=None, source=None):
    title = (title or "").strip() or None
    artist = (artist or "").strip() or None
    return {"title": title, "artist": artist,
            "artwork_url": (artwork_url or "").strip() or None,
            "source": source, "is_live": True}


def _split_streamtitle(s):
    """ICY StreamTitle is conventionally 'Artist - Title'. Return (artist, title).

    If there's no ' - ' separator we can't know the artist, so the whole
    string becomes the title (better to show something than nothing).
    """
    s = (s or "").strip()
    if not s:
        return None, None
    if " - " in s:
        artist, title = s.split(" - ", 1)
        return artist.strip(), title.strip()
    return None, s


# --------------------------------------------------------------------------
# Station-specific adapters
# --------------------------------------------------------------------------

def _nightride(stream_url):
    """https://stream.nightride.fm/chillsynth.mp3 -> station key 'chillsynth'.

    nightride.fm/meta is a Server-Sent-Events feed that, on connect, bursts
    one `data:` line per station with the current track, then stays open and
    only emits on change. We read the opening burst, grab our station, and
    bail — capped by the read timeout so we never hang waiting for a change.
    """
    stem = urlparse(stream_url).path.rsplit("/", 1)[-1]
    key = re.sub(r"\.\w+$", "", stem).lower()
    resp = requests.get(
        "https://nightride.fm/meta", stream=True, timeout=_TIMEOUT,
        headers={"User-Agent": _UA, "Accept": "text/event-stream"},
    )
    # The feed is UTF-8, but requests defaults text/event-stream to Latin-1,
    # which mojibakes accented titles (e.g. "Töge" -> "TÃ¶ge") under
    # iter_lines(decode_unicode=True). Force the correct codec.
    resp.encoding = "utf-8"
    try:
        deadline = time.monotonic() + _TIMEOUT
        for raw in resp.iter_lines(decode_unicode=True):
            if time.monotonic() > deadline:
                break
            if not raw or not raw.startswith("data:"):
                continue
            try:
                items = json.loads(raw[5:].strip())
            except ValueError:
                continue
            for it in items:
                if str(it.get("station", "")).lower() == key:
                    return _norm(it.get("title"), it.get("artist"),
                                 source="nightride")
        return _empty("nightride")
    finally:
        resp.close()


def _somafm(stream_url, homepage=None):
    """SomaFM: prefer the station slug from the homepage URL
    (https://somafm.com/groovesalad -> 'groovesalad'); otherwise derive it
    from the stream filename (groovesalad-128-mp3 -> 'groovesalad').
    songs[0] is the current track.
    """
    sid = None
    if homepage:
        seg = urlparse(homepage).path.rstrip("/").rsplit("/", 1)[-1]
        sid = seg.lower() or None
    if not sid:
        stem = urlparse(stream_url).path.rsplit("/", 1)[-1]
        sid = re.sub(r"-\d.*$", "", stem).lower() or None
    if not sid:
        return _empty("somafm")
    resp = requests.get(f"https://somafm.com/songs/{sid}.json",
                        timeout=_TIMEOUT, headers={"User-Agent": _UA})
    resp.raise_for_status()
    songs = resp.json().get("songs") or []
    if not songs:
        return _empty("somafm")
    cur = songs[0]
    return _norm(cur.get("title"), cur.get("artist"),
                 artwork_url=cur.get("albumArt"), source="somafm")


# --------------------------------------------------------------------------
# Generic fallbacks (for stations without a dedicated adapter)
# --------------------------------------------------------------------------

def _icecast_status(stream_url):
    """Standard Icecast exposes /status-json.xsl with a 'title' per mount."""
    p = urlparse(stream_url)
    base = f"{p.scheme}://{p.netloc}"
    resp = requests.get(urljoin(base + "/", "status-json.xsl"),
                        timeout=_TIMEOUT, headers={"User-Agent": _UA})
    resp.raise_for_status()
    stats = (resp.json() or {}).get("icestats") or {}
    src = stats.get("source")
    if isinstance(src, list):
        chosen = None
        for s in src:
            if p.path and str(s.get("listenurl", "")).endswith(p.path):
                chosen = s
                break
        src = chosen or (src[0] if src else {})
    src = src or {}
    title = src.get("title") or src.get("yp_currently_playing")
    artist, ttl = _split_streamtitle(title)
    return _norm(ttl, artist, source="icecast")


def _icy_inband(stream_url):
    """Last resort: connect to the audio stream itself with Icy-MetaData:1,
    skip one metadata interval of audio, then read the metadata block and
    parse StreamTitle. Works for most Icecast/SHOUTcast mounts.
    """
    p = urlparse(stream_url)
    host = p.hostname
    port = p.port or (443 if p.scheme == "https" else 80)
    path = p.path or "/"
    if p.query:
        path += "?" + p.query

    sock = socket.create_connection((host, port), timeout=_TIMEOUT)
    try:
        if p.scheme == "https":
            import ssl
            sock = ssl.create_default_context().wrap_socket(
                sock, server_hostname=host)
        req = (f"GET {path} HTTP/1.0\r\nHost: {host}\r\n"
               f"User-Agent: {_UA}\r\nIcy-MetaData: 1\r\n"
               f"Connection: close\r\n\r\n")
        sock.sendall(req.encode())
        sock.settimeout(_TIMEOUT)

        buf = b""
        while b"\r\n\r\n" not in buf and len(buf) < 8192:
            chunk = sock.recv(1024)
            if not chunk:
                break
            buf += chunk
        header_blob, _, rest = buf.partition(b"\r\n\r\n")
        headers = header_blob.decode("latin-1", "replace").lower()
        m = re.search(r"icy-metaint:\s*(\d+)", headers)
        if not m:
            return _empty("icy")
        metaint = int(m.group(1))

        data = rest
        # Read up to (audio interval + 1 length byte).
        while len(data) < metaint + 1:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
        if len(data) < metaint + 1:
            return _empty("icy")
        meta_len = data[metaint] * 16
        if meta_len == 0:
            return _empty("icy")
        need = metaint + 1 + meta_len
        while len(data) < need:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
        # ICY metadata has no declared charset. Modern streams send UTF-8;
        # older ones send Latin-1. Prefer UTF-8, fall back to Latin-1 only if
        # the bytes aren't valid UTF-8 (so we don't mojibake either kind).
        meta_bytes = data[metaint + 1: need]
        try:
            meta = meta_bytes.decode("utf-8")
        except UnicodeDecodeError:
            meta = meta_bytes.decode("latin-1", "replace")
        m2 = re.search(r"StreamTitle='(.*?)';", meta)
        if not m2:
            return _empty("icy")
        artist, ttl = _split_streamtitle(m2.group(1))
        return _norm(ttl, artist, source="icy")
    finally:
        try:
            sock.close()
        except Exception:
            pass


# --------------------------------------------------------------------------
# Dispatch + cache
# --------------------------------------------------------------------------

def _fetch(stream_url, homepage=None):
    host = (urlparse(stream_url).hostname or "").lower()
    try:
        if host.endswith("nightride.fm"):
            return _nightride(stream_url)
        if host.endswith("somafm.com"):
            return _somafm(stream_url, homepage)
        # Generic: try Icecast status JSON first (cheap), then in-band ICY.
        try:
            res = _icecast_status(stream_url)
            if res.get("title") or res.get("artist"):
                return res
        except Exception:
            pass
        return _icy_inband(stream_url)
    except Exception:
        # Never raise into the request path — no metadata is a valid answer.
        return _empty()


def get_station_now_playing(stream_url, homepage=None, use_cache=True):
    """Return {title, artist, artwork_url, source, is_live} for a station's
    currently-playing track. All-None fields mean "couldn't determine" — the
    caller should just show the station name.

    MUST be called inside eventlet.tpool.execute — it does blocking I/O.
    """
    if not stream_url:
        return _empty()
    now = time.monotonic()
    if use_cache:
        hit = _CACHE.get(stream_url)
        if hit and (now - hit[0]) < _CACHE_TTL:
            return hit[1]
    payload = _fetch(stream_url, homepage)
    _CACHE[stream_url] = (now, payload)
    return payload


# --------------------------------------------------------------------------
# Recently played (play history)
# --------------------------------------------------------------------------
# Only some broadcasters publish history. Nightride's stations are backed by
# their lissen.to platform, which has a public JSON API with timestamps.
# SomaFM's songs JSON is already a newest-first history list. Generic
# Icecast/ICY streams expose only the current title, so they return [].

_RP_CACHE = {}       # stream_url -> (fetched_at_monotonic, rows)
_RP_CACHE_TTL = 30.0


def _lissen_recently_played(stream_url):
    """Nightride stations map 1:1 onto lissen.to radio slugs
    (https://stream.nightride.fm/chillsynth.mp3 -> 'chillsynth').

    GET /api/public/radios/<slug>/recently-played returns the last ~30 plays,
    newest first: {played_at (ISO 8601), title, artist, track_id, source, dj}.
    Cover art lives at /files/covers/<track_id>.png.
    """
    stem = urlparse(stream_url).path.rsplit("/", 1)[-1]
    slug = re.sub(r"\.\w+$", "", stem).lower()
    resp = requests.get(
        f"https://lissen.to/api/public/radios/{slug}/recently-played",
        timeout=_TIMEOUT, headers={"User-Agent": _UA},
    )
    resp.raise_for_status()
    rows = []
    for it in resp.json() or []:
        title = (it.get("title") or "").strip()
        if not title:
            continue
        track_id = it.get("track_id")
        rows.append({
            "title": title,
            "artist": (it.get("artist") or "").strip() or None,
            "played_at": it.get("played_at"),
            "artwork_url": (f"https://lissen.to/files/covers/{track_id}.png"
                            if track_id else None),
            "source": "lissen",
        })
    return rows


def _somafm_recently_played(stream_url, homepage=None):
    """SomaFM's songs JSON is newest-first; songs[0] is the current track, so
    history is the rest. 'date' is epoch seconds (as a string)."""
    sid = None
    if homepage:
        seg = urlparse(homepage).path.rstrip("/").rsplit("/", 1)[-1]
        sid = seg.lower() or None
    if not sid:
        stem = urlparse(stream_url).path.rsplit("/", 1)[-1]
        sid = re.sub(r"-\d.*$", "", stem).lower() or None
    if not sid:
        return []
    resp = requests.get(f"https://somafm.com/songs/{sid}.json",
                        timeout=_TIMEOUT, headers={"User-Agent": _UA})
    resp.raise_for_status()
    rows = []
    for it in (resp.json().get("songs") or [])[1:]:
        title = (it.get("title") or "").strip()
        if not title:
            continue
        played_at = None
        try:
            from datetime import datetime, timezone
            played_at = datetime.fromtimestamp(
                int(it.get("date")), tz=timezone.utc
            ).isoformat().replace("+00:00", "Z")
        except (TypeError, ValueError):
            pass
        rows.append({
            "title": title,
            "artist": (it.get("artist") or "").strip() or None,
            "played_at": played_at,
            "artwork_url": (it.get("albumArt") or "").strip() or None,
            "source": "somafm",
        })
    return rows


def get_station_recently_played(stream_url, homepage=None, use_cache=True):
    """Return a newest-first list of {title, artist, played_at, artwork_url,
    source} for tracks the station recently played. Empty list means the
    broadcaster doesn't publish history (true for generic Icecast/ICY).

    MUST be called inside eventlet.tpool.execute — it does blocking I/O.
    """
    if not stream_url:
        return []
    now = time.monotonic()
    if use_cache:
        hit = _RP_CACHE.get(stream_url)
        if hit and (now - hit[0]) < _RP_CACHE_TTL:
            return hit[1]
    host = (urlparse(stream_url).hostname or "").lower()
    try:
        if host.endswith("nightride.fm") or host.endswith("lissen.to"):
            rows = _lissen_recently_played(stream_url)
        elif host.endswith("somafm.com"):
            rows = _somafm_recently_played(stream_url, homepage)
        else:
            rows = []
    except Exception:
        # Never raise into the request path — no history is a valid answer.
        rows = []
    _RP_CACHE[stream_url] = (now, rows)
    return rows
