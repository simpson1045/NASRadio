# -*- coding: utf-8 -*-
"""Lightweight MusicBrainz artist lookups shared across import paths.

Historically the local scanner, YouTube importer, and RSS importer all created
artists with `INSERT INTO artists (name)` and never recorded an MBID — so 70%+
of the library had none, and the artist-image downloader had to re-run a
MusicBrainz name search on *every* pass (slow). These helpers let import paths
resolve and store the MBID once, at creation time.
"""
import time
import requests

from app.config import user_agent


def _headers():
    return {"User-Agent": user_agent()}
_MB_ARTIST_URL = "https://musicbrainz.org/ws/2/artist/"
# Module-level polite rate limiter — MusicBrainz asks for ~1 request/second.
_last_call = [0.0]


def _norm(s):
    """Loose name key: lowercase, drop apostrophe family + common punctuation."""
    s = (s or "").lower()
    for ch in "ʻʼ‘’'.,&":
        s = s.replace(ch, "")
    return " ".join(s.split())


def lookup_artist_mbid(name, timeout=12):
    """Best-effort MusicBrainz MBID for an artist name.

    Returns the MBID string, or None if there's no confident match (or on any
    network/parse error). Never raises — safe to call inline during import.
    Only accepts a result whose name matches (apostrophe/punctuation-insensitive)
    or whose MusicBrainz search score is >= 95, to avoid storing wrong MBIDs.
    """
    if not name or not name.strip():
        return None
    try:
        since = time.monotonic() - _last_call[0]
        if since < 1.1:
            time.sleep(1.1 - since)
        _last_call[0] = time.monotonic()
        resp = requests.get(
            _MB_ARTIST_URL,
            params={"query": f'artist:"{name}"', "fmt": "json", "limit": 3},
            headers=_headers(),
            timeout=timeout,
        )
        if resp.status_code != 200:
            return None
        target = _norm(name)
        for cand in resp.json().get("artists", []):
            if _norm(cand.get("name")) == target or int(cand.get("score", 0)) >= 95:
                return cand.get("id")
    except Exception:
        return None
    return None
