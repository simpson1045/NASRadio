"""
YouTube album search + playlist curation.

The manual workflow this replaces (simpson1045, 2026-09-11): open YouTube, find the
album playlist, copy the *share* link (a full URL drags the 300-video Mix in),
listen to every suspicious video, untick the ones with talking intros or live
outros, download, then import each replacement one at a time.

What lives here:
  search_albums()      playlist-only YouTube search from inside the app
  normalize_playlist() strip a pasted URL down to just the playlist
  curate_playlist()    grade every video against the MusicBrainz track
                       lengths and auto-find a clean replacement for the
                       suspects (Topic-channel uploads, duration-matched)
  find_clean()         the replacement search on its own, for the
                       "see alternatives" sheet
"""

import difflib
import json
import re
import subprocess
import time
from urllib.parse import quote_plus

import eventlet
import requests
from eventlet import tpool
from eventlet.greenpool import GreenPool

MB_HEADERS = {"User-Agent": "NASRadio/1.0 (https://github.com/simpson1045/NASRadio)"}
YTDLP_BASE = ["yt-dlp", "--js-runtimes", "deno", "--remote-components", "ejs:github"]
DEFAULT_TOLERANCE = 10     # seconds off the album cut before a video is suspect
REPLACEMENT_MATCH = 3      # seconds: a replacement this close counts as exact
PLAYLIST_FILTER = "EgIQAw%3D%3D"   # YouTube search "Type: Playlist"

# Things that make a *title* look like not-the-album-cut.
NOISE_RE = re.compile(
    r"\((official|video|audio|hd|hq|remaster(ed)?|lyrics?|lyric video|visuali[sz]er|"
    r"music video|explicit|clean|from [^)]*|feat[^)]*|ft[^)]*)[^)]*\)|\[[^\]]*\]|"
    r"\bofficial (music |lyric )?(video|audio)\b|\bofficial\b|\bhq\b|\bhd\b|\b4k\b",
    re.I,
)
BAD_WORDS_RE = re.compile(
    r"\b(live|cover|karaoke|remix|reaction|tutorial|lesson|drum|guitar|bass|"
    r"instrumental|slowed|sped up|8d|nightcore|edit|demo|acoustic|unplugged|"
    r"interview|behind the scenes|making of|trailer|teaser|full album)\b",
    re.I,
)
VIDEO_WORDS_RE = re.compile(r"\b(official (music )?video|music video|live)\b", re.I)


# ---------------------------------------------------------------------------
# yt-dlp plumbing
# ---------------------------------------------------------------------------

def _cookie_args():
    try:
        from app.youtube_download import YouTubeDownloader
        return YouTubeDownloader()._cookie_args()
    except Exception:
        return []


def _run_ytdlp_json(args, timeout=90):
    """Run yt-dlp with --dump-json --flat-playlist and return parsed lines.
    Runs in tpool so a slow YouTube never blocks the eventlet hub."""
    cmd = [*YTDLP_BASE, *_cookie_args(), "--dump-json", "--flat-playlist",
           "--no-download", "--no-warnings", *args]

    def _go():
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)

    result = tpool.execute(_go)
    if result.returncode != 0 and not result.stdout.strip():
        raise RuntimeError((result.stderr or "yt-dlp failed").strip()[-300:])
    out = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def _fetch_full_info(video_ids, timeout=60):
    """Non-flat info for a few videos, in parallel. Gives channel, duration
    and the description, whose 'Provided to YouTube by' opener is the
    definitive mark of label-supplied album audio (Topic uploads and the
    equivalent tracks on an Official Artist Channel)."""
    if not video_ids:
        return {}
    cmd = [*YTDLP_BASE, *_cookie_args(), "--dump-json", "--no-download",
           "--no-warnings", "--no-playlist",
           *[f"https://www.youtube.com/watch?v={v}" for v in video_ids]]

    def _go():
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)

    result = tpool.execute(_go)
    out = {}
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        if d.get("id"):
            out[d["id"]] = d
    return out


def _is_label_audio(info):
    desc = (info.get("description") or "").lstrip()
    return desc.startswith("Provided to YouTube by") or _is_topic(info.get("channel") or info.get("uploader"))


def _is_topic(channel):
    return bool(channel) and channel.strip().lower().endswith(" - topic")


def _strip_topic(channel):
    if not channel:
        return ""
    c = channel.strip()
    return c[:-8].strip() if c.lower().endswith(" - topic") else c


def _int_or_none(v):
    try:
        return int(v) if v is not None else None
    except (TypeError, ValueError):
        return None


# ---------------------------------------------------------------------------
# URL normalization
# ---------------------------------------------------------------------------

_LIST_RE = re.compile(r"[?&]list=([A-Za-z0-9_-]+)")


def normalize_playlist(url):
    """If the URL carries a playlist id, return the bare playlist URL plus
    flags. A watch URL with &list=... also carries &v=, &index=, and often
    &start_radio=1, and yt-dlp happily expands the Mix behind it into
    hundreds of entries. Returns None when there's no playlist."""
    m = _LIST_RE.search(url or "")
    if not m:
        return None
    pid = m.group(1)
    return {
        "playlist_id": pid,
        "url": f"https://www.youtube.com/playlist?list={pid}",
        "is_mix": pid.startswith("RD"),           # auto-generated radio / Mix
        "is_topic_album": pid.startswith("OLAK5uy_"),  # auto-generated album
        "was_rewritten": url.strip() != f"https://www.youtube.com/playlist?list={pid}",
    }


# ---------------------------------------------------------------------------
# Album search
# ---------------------------------------------------------------------------

def search_albums(query, limit=12):
    """Playlist-only YouTube search. Two passes (as typed, and + 'full album')
    merged and deduped. Topic-channel results float to the top: those are
    the label's auto-generated album playlists and need no curation."""
    query = (query or "").strip()
    if not query:
        return {"success": False, "error": "query required"}

    seen = {}
    for q in (query, f"{query} full album"):
        url = f"https://www.youtube.com/results?search_query={quote_plus(q)}&sp={PLAYLIST_FILTER}"
        try:
            entries = _run_ytdlp_json(["--playlist-end", "10", url], timeout=60)
        except Exception as e:
            if not seen:
                return {"success": False, "error": str(e)}
            continue
        for e in entries:
            pid = e.get("id")
            if not pid or pid in seen:
                continue
            channel = e.get("channel") or e.get("uploader") or ""
            seen[pid] = {
                "id": pid,
                "title": e.get("title") or "",
                "channel": channel,
                "url": e.get("url") or f"https://www.youtube.com/playlist?list={pid}",
                "video_count": _int_or_none(e.get("playlist_count") or e.get("video_count")),
                "is_topic": _is_topic(channel),
                "is_topic_album": pid.startswith("OLAK5uy_"),
            }

    qn = _norm(query)
    results = list(seen.values())
    for r in results:
        sim = difflib.SequenceMatcher(None, qn, _norm(r["title"])).ratio()
        bad = 1 if BAD_WORDS_RE.search(r["title"]) and "full album" not in r["title"].lower() else 0
        r["score"] = round(sim + (1.0 if r["is_topic"] or r["is_topic_album"] else 0) - 0.3 * bad, 3)
    results.sort(key=lambda r: -r["score"])
    return {"success": True, "query": query, "results": results[:limit]}


# ---------------------------------------------------------------------------
# MusicBrainz: canonical track lengths
# ---------------------------------------------------------------------------

_mb_last = [0.0]


def _mb_get(url, timeout=25):
    """MusicBrainz asks for <= 1 req/s. Cheap global throttle."""
    wait = 1.1 - (time.time() - _mb_last[0])
    if wait > 0:
        eventlet.sleep(wait)
    _mb_last[0] = time.time()
    last = None
    for attempt in range(3):
        r = tpool.execute(lambda: requests.get(url, headers=MB_HEADERS, timeout=timeout))
        if r.status_code in (429, 503):
            # MB sheds load with 503s all the time; back off and retry.
            last = r
            eventlet.sleep(2.0 * (attempt + 1))
            _mb_last[0] = time.time()
            continue
        r.raise_for_status()
        return r.json()
    last.raise_for_status()


def _mb_query_term(s):
    s = re.sub(r'["\[\]\(\)]', "", s or "")
    s = re.sub(r"\s+", " ", s).strip()
    return f'"{s}"' if " " in s else s


def mb_find_release(artist=None, album=None, free_text=None):
    """Find the release group, then the fullest release in it, and return
    its tracks with lengths. Returns None when nothing plausible matches."""
    parts = []
    if artist:
        parts.append(f"artist:{_mb_query_term(artist)}")
    if album:
        parts.append(f"releasegroup:{_mb_query_term(album)}")
    if not parts and free_text:
        parts.append(_mb_query_term(free_text))
    if not parts:
        return None
    q = " AND ".join(parts) + " AND primarytype:album"
    data = _mb_get(f"https://musicbrainz.org/ws/2/release-group?query={quote_plus(q)}&limit=5&fmt=json")
    groups = data.get("release-groups") or []
    if not groups:
        # Retry without the album-type restriction (EPs, singles, comps).
        q = " AND ".join(parts)
        data = _mb_get(f"https://musicbrainz.org/ws/2/release-group?query={quote_plus(q)}&limit=5&fmt=json")
        groups = data.get("release-groups") or []
    if not groups:
        return None
    rg = groups[0]
    if int(rg.get("score", 0)) < 60:
        return None

    rel = _mb_get(
        f"https://musicbrainz.org/ws/2/release?release-group={rg['id']}"
        "&inc=recordings&fmt=json&limit=25"
    )
    releases = rel.get("releases") or []
    if not releases:
        return None

    def _count(r):
        return sum(m.get("track-count", 0) for m in r.get("media", []))

    # Prefer official releases, then the fullest tracklist (deluxe > single disc
    # is fine: extra tracks just won't match anything on the playlist).
    releases.sort(key=lambda r: (r.get("status") != "Official", -_count(r)))
    best = releases[0]
    tracks = []
    pos = 0
    for medium in best.get("media", []):
        for t in medium.get("tracks", []):
            pos += 1
            length_ms = t.get("length") or (t.get("recording") or {}).get("length")
            tracks.append({
                "position": pos,
                "title": t.get("title") or (t.get("recording") or {}).get("title") or "",
                "length": round(length_ms / 1000) if length_ms else None,
            })
    credit = "".join(
        (ac.get("name") or "") + (ac.get("joinphrase") or "")
        for ac in rg.get("artist-credit") or []
    ).strip()
    return {
        "release_group_id": rg["id"],
        "release_id": best.get("id"),
        "artist": credit or artist or "",
        "album": rg.get("title") or album or "",
        "year": (rg.get("first-release-date") or "")[:4] or None,
        "tracks": tracks,
    }


# ---------------------------------------------------------------------------
# Matching + grading
# ---------------------------------------------------------------------------

def _norm(s):
    s = (s or "").lower()
    s = s.replace("’", "'").replace("&", "and")
    s = re.sub(r"[^a-z0-9' ]+", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def _clean_title(title, artist=None, album=None):
    t = title or ""
    t = NOISE_RE.sub(" ", t)
    for name in (artist, album):
        if name:
            t = re.sub(rf"^\s*{re.escape(name)}\s*[-–:|]\s*", "", t, flags=re.I)
            t = re.sub(rf"\s*[-–|]\s*{re.escape(name)}\s*$", "", t, flags=re.I)
    t = re.sub(r"^\s*\d{1,2}\s*[.\-)]\s*", "", t)   # "03. Title"
    return _norm(t)


def _match_tracks(yt_tracks, mb_tracks, artist, album):
    """Best MB track per YouTube entry by fuzzy title. Falls back to position
    when the counts line up and the title is hopeless."""
    mb_norm = [(_norm(m["title"]), m) for m in mb_tracks]
    matched = []
    for i, yt in enumerate(yt_tracks):
        ct = _clean_title(yt.get("title"), artist, album)
        best, best_r = None, 0.0
        for n, m in mb_norm:
            if not n:
                continue
            r = difflib.SequenceMatcher(None, ct, n).ratio()
            if n in ct or ct in n:
                r = max(r, 0.9)
            if r > best_r:
                best, best_r = m, r
        if best is not None and best_r >= 0.55:
            matched.append((best, round(best_r, 2)))
        elif len(yt_tracks) == len(mb_tracks):
            matched.append((mb_tracks[i], 0.0))
        else:
            matched.append((None, 0.0))
    return matched


def _grade(yt, mb, tolerance):
    """-> (verdict, reason). verdict: ok | suspect | unverified"""
    channel = yt.get("channel") or yt.get("uploader") or ""
    dur = yt.get("duration")
    title = yt.get("title") or ""
    if _is_topic(channel):
        return "ok", "Topic upload (album audio)"
    # "(Live)", "cover", "remix"... in the YouTube title but not in the album
    # track title is a different recording no matter how long it runs. The
    # live Ballroom Blitz is 242s against a 239s album cut.
    bad = BAD_WORDS_RE.search(title)
    if bad and not (mb and BAD_WORDS_RE.search(mb.get("title") or "")):
        return "suspect", f'title says "{bad.group(0).lower()}", album track doesn\'t'
    if mb and mb.get("length") and dur:
        delta = dur - mb["length"]
        if abs(delta) <= tolerance:
            return "ok", f"length matches album cut ({delta:+d}s)"
        how = "longer" if delta > 0 else "shorter"
        return "suspect", f"{abs(delta)}s {how} than the album cut"
    if BAD_WORDS_RE.search(title) or VIDEO_WORDS_RE.search(title):
        return "suspect", "title looks like a video or live take, no album length to check"
    return "unverified", "no MusicBrainz match to check against"


# ---------------------------------------------------------------------------
# Replacement search
# ---------------------------------------------------------------------------

def find_clean(artist, title, target_duration=None, exclude_id=None, limit=8, album_title=None):
    """Search YouTube for a clean upload of one track. Topic-channel uploads
    that match the album length are what we want; everything else is scored
    down. Returns candidates best-first; best is 'replacement' if it clears
    the bar."""
    # The search title is the album track name. Strip anything video-ish
    # that leaked in from a YouTube title ("(Live)", "Official Video").
    want_live = bool(re.search(r"\blive\b", album_title or "", re.I))
    search_title = BAD_WORDS_RE.sub(" ", NOISE_RE.sub(" ", title or "")) if not want_live else title
    search_title = re.sub(r"\s+", " ", search_title).strip(" -–")
    q = f"{artist} {search_title}".strip()
    if not q:
        return {"success": False, "error": "artist/title required"}
    try:
        entries = _run_ytdlp_json([f"ytsearch{limit}:{q}"], timeout=60)
    except Exception as e:
        return {"success": False, "error": str(e)}

    # YouTube Music ranks the label audio first, where plain search buries
    # it under official videos and fan uploads. Its flat results carry no
    # channel or duration, so fetch full info for the top few.
    seen_ids = {e.get("id") for e in entries}
    try:
        ytm = _run_ytdlp_json(
            ["--playlist-end", "4", f"https://music.youtube.com/search?q={quote_plus(q)}"],
            timeout=60,
        )
    except Exception:
        ytm = []
    need_full = [e["id"] for e in ytm if e.get("id") and e["id"] != exclude_id]
    full = _fetch_full_info(need_full[:3]) if need_full else {}
    label_ids = set()
    for vid, info in full.items():
        if _is_label_audio(info):
            label_ids.add(vid)
        if vid in seen_ids:
            # Upgrade the plain-search copy with real fields.
            for e in entries:
                if e.get("id") == vid:
                    e.update({k: info.get(k) for k in ("channel", "uploader", "duration", "title")})
        else:
            entries.append({k: info.get(k) for k in ("id", "title", "channel", "uploader", "duration")})
            seen_ids.add(vid)

    artist_n = _norm(artist)
    cands = []
    for e in entries:
        vid = e.get("id")
        if not vid or vid == exclude_id:
            continue
        channel = e.get("channel") or e.get("uploader") or ""
        dur = _int_or_none(e.get("duration"))
        t = e.get("title") or ""
        score = 0.0
        is_topic = _is_topic(channel) or vid in label_ids
        chan_n = _norm(_strip_topic(channel))
        if is_topic:
            # Label audio, but whose? "Montrose - Topic" has a "Rock the
            # Nation" too. A Topic channel for another artist is a miss.
            if artist_n and chan_n and chan_n != artist_n and artist_n not in chan_n:
                score -= 3
            else:
                score += 3
        elif artist_n and chan_n == artist_n:
            score += 1.5   # the artist's own channel: usually clean audio uploads
        delta = None
        if dur and target_duration:
            delta = dur - target_duration
            if abs(delta) <= REPLACEMENT_MATCH:
                score += 3
            elif abs(delta) <= DEFAULT_TOLERANCE:
                score += 1
            elif abs(delta) <= 20:
                score -= 1
            else:
                score -= 5   # a different recording entirely
        if BAD_WORDS_RE.search(t) and not want_live:
            score -= 2
        if VIDEO_WORDS_RE.search(t):
            score -= 1
        sim = difflib.SequenceMatcher(None, _norm(search_title), _clean_title(t, artist)).ratio()
        score += sim
        cands.append({
            "id": vid,
            "title": t,
            "channel": channel,
            "duration": dur,
            "url": f"https://www.youtube.com/watch?v={vid}",
            "is_topic": is_topic,
            "delta": delta,
            "score": round(score, 2),
        })
    cands.sort(key=lambda c: -c["score"])
    best = cands[0] if cands and cands[0]["score"] >= 3.0 else None
    return {"success": True, "candidates": cands, "replacement": best}


# ---------------------------------------------------------------------------
# The whole thing
# ---------------------------------------------------------------------------

def _guess_artist_album(entries, artist_hint=None, album_hint=None):
    """Work out who/what this playlist is from its own metadata."""
    first = entries[0] if entries else {}
    p_title = first.get("playlist_title") or first.get("playlist") or ""
    p_channel = first.get("playlist_channel") or first.get("playlist_uploader") or ""
    artist = artist_hint or ""
    album = album_hint or ""
    if _is_topic(p_channel):
        artist = artist or _strip_topic(p_channel)
        album = album or re.sub(r"^album\s*[-–]\s*", "", p_title, flags=re.I)
    if (not artist or not album) and " - " in p_title:
        a, b = p_title.split(" - ", 1)
        artist = artist or a.strip()
        album = album or re.sub(r"\(?full album\)?", "", b, flags=re.I).strip(" -–|")
    if not artist:
        # Most common video channel on the playlist, minus " - Topic"
        chans = {}
        for e in entries:
            c = _strip_topic(e.get("channel") or e.get("uploader") or "")
            if c:
                chans[c] = chans.get(c, 0) + 1
        if chans:
            artist = max(chans, key=chans.get)
    return artist.strip(), album.strip(), p_title, p_channel


def curate_playlist(url, artist=None, album=None, tolerance=DEFAULT_TOLERANCE, auto_replace=True):
    norm = normalize_playlist(url)
    if not norm:
        return {"success": False, "error": "Not a playlist URL"}
    if norm["is_mix"]:
        return {"success": False, "error": "That's a YouTube Mix (auto-generated radio), not an album playlist."}

    try:
        entries = _run_ytdlp_json([norm["url"]], timeout=120)
    except Exception as e:
        return {"success": False, "error": f"Couldn't read playlist: {e}"}
    if not entries:
        return {"success": False, "error": "Playlist is empty or private"}

    artist, album, p_title, p_channel = _guess_artist_album(entries, artist, album)

    tracks = []
    for e in entries:
        vid = e.get("id")
        if not vid:
            continue
        channel = e.get("channel") or e.get("uploader") or ""
        tracks.append({
            "id": vid,
            "title": e.get("title") or "",
            "uploader": e.get("uploader"),
            "channel": channel,
            "duration": _int_or_none(e.get("duration")),
            "url": f"https://www.youtube.com/watch?v={vid}",
            "is_topic": _is_topic(channel),
        })

    mb = None
    mb_error = None
    try:
        mb = mb_find_release(artist or None, album or None, free_text=p_title)
    except Exception as e:
        mb_error = str(e)[:120]

    matches = _match_tracks(tracks, mb["tracks"], artist, album) if mb else [(None, 0.0)] * len(tracks)

    for t, (m, conf) in zip(tracks, matches):
        t["mb_title"] = m["title"] if m else None
        t["mb_length"] = m["length"] if m else None
        t["mb_position"] = m["position"] if m else None
        t["match_confidence"] = conf
        t["delta"] = (t["duration"] - m["length"]) if (m and m.get("length") and t["duration"]) else None
        verdict, reason = _grade(t, m, tolerance)
        t["verdict"] = verdict
        t["reason"] = reason
        t["replacement"] = None
        t["alternatives"] = []

    # Replacement searches for the suspects, a few at a time.
    def _fix(t):
        try:
            title = t["mb_title"] or _clean_title(t["title"], artist, album)
            r = find_clean(artist or "", title, t["mb_length"] or t["duration"],
                           exclude_id=t["id"], album_title=t["mb_title"])
            if r.get("success"):
                t["alternatives"] = r["candidates"][:6]
                t["replacement"] = r["replacement"] if auto_replace else None
        except Exception as e:
            t["reason"] += f" (replacement search failed: {str(e)[:60]})"

    pool = GreenPool(4)
    for t in tracks:
        if t["verdict"] == "suspect":
            pool.spawn_n(_fix, t)
    pool.waitall()

    summary = {
        "ok": sum(1 for t in tracks if t["verdict"] == "ok"),
        "suspect": sum(1 for t in tracks if t["verdict"] == "suspect"),
        "unverified": sum(1 for t in tracks if t["verdict"] == "unverified"),
        "replaced": sum(1 for t in tracks if t["replacement"]),
    }
    return {
        "success": True,
        "url": norm["url"],
        "playlist_id": norm["playlist_id"],
        "url_was_rewritten": norm["was_rewritten"],
        "playlist_title": p_title,
        "playlist_channel": p_channel,
        "artist": artist,
        "album": album,
        "tolerance": tolerance,
        "musicbrainz": {
            "matched": bool(mb),
            "release_group_id": mb["release_group_id"] if mb else None,
            "album": mb["album"] if mb else None,
            "artist": mb["artist"] if mb else None,
            "year": mb["year"] if mb else None,
            "track_count": len(mb["tracks"]) if mb else 0,
            "error": mb_error,
        },
        "summary": summary,
        "track_count": len(tracks),
        "tracks": tracks,
    }
