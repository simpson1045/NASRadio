"""
Prowlarr integration for NASRadio
Search indexers and send downloads to Transmission
"""

import base64
import hashlib
import random
import socket
import struct
import time
import re
import requests
from concurrent.futures import ThreadPoolExecutor, wait as _futures_wait
from urllib.parse import urlparse, unquote
from app.config import Config


# =============================================================================
# Swarm probe helpers — talk to trackers directly so the app can show a real
# seeder count instead of whatever a public indexer scraped last week.
# =============================================================================

def _bdecode(data, i=0):
    """Minimal bencode decoder. Returns (value, next_index)."""
    c = data[i:i + 1]
    if c == b"i":
        j = data.index(b"e", i)
        return int(data[i + 1:j]), j + 1
    if c == b"l":
        i += 1
        out = []
        while data[i:i + 1] != b"e":
            v, i = _bdecode(data, i)
            out.append(v)
        return out, i + 1
    if c == b"d":
        i += 1
        out = {}
        while data[i:i + 1] != b"e":
            k, i = _bdecode(data, i)
            v, i = _bdecode(data, i)
            out[k] = v
        return out, i + 1
    j = data.index(b":", i)
    n = int(data[i:j])
    return data[j + 1:j + 1 + n], j + 1 + n


def _bencode(v):
    if isinstance(v, bool):
        v = int(v)
    if isinstance(v, int):
        return b"i%de" % v
    if isinstance(v, bytes):
        return b"%d:" % len(v) + v
    if isinstance(v, str):
        return _bencode(v.encode())
    if isinstance(v, list):
        return b"l" + b"".join(_bencode(x) for x in v) + b"e"
    if isinstance(v, dict):
        return b"d" + b"".join(_bencode(k) + _bencode(v[k]) for k in sorted(v)) + b"e"
    raise TypeError(f"cannot bencode {type(v).__name__}")


def _parse_magnet(magnet):
    """-> (infohash bytes, display name, [tracker urls])"""
    infohash = None
    name = ""
    trackers = []
    for part in magnet.split("?", 1)[-1].split("&"):
        if "=" not in part:
            continue
        k, v = part.split("=", 1)
        k = k.lower()
        v = unquote(v)
        if k == "xt" and v.lower().startswith("urn:btih:"):
            h = v[9:]
            if len(h) == 40:
                infohash = bytes.fromhex(h)
            elif len(h) == 32:
                infohash = base64.b32decode(h.upper())
        elif k == "dn":
            name = v.replace("+", " ")
        elif k == "tr":
            trackers.append(v)
    return infohash, name, trackers


def _parse_torrent_file(raw):
    """-> (infohash bytes, name, [tracker urls])"""
    meta, _ = _bdecode(raw)
    info = meta[b"info"]
    infohash = hashlib.sha1(_bencode(info)).digest()
    name = info.get(b"name", b"").decode("utf-8", "replace")
    trackers = []
    if b"announce" in meta:
        trackers.append(meta[b"announce"].decode("utf-8", "replace"))
    for tier in meta.get(b"announce-list", []):
        for t in tier:
            trackers.append(t.decode("utf-8", "replace"))
    return infohash, name, trackers


def _udp_scrape(host, port, infohash, timeout):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        tx = random.randint(0, 0x7FFFFFFF)
        s.sendto(struct.pack(">QII", 0x41727101980, 0, tx), (host, port))
        data, _ = s.recvfrom(1024)
        action, rtx, conn_id = struct.unpack(">IIQ", data[:16])
        if action != 0 or rtx != tx:
            raise RuntimeError("bad connect reply")
        tx = random.randint(0, 0x7FFFFFFF)
        s.sendto(struct.pack(">QII", conn_id, 2, tx) + infohash, (host, port))
        data, _ = s.recvfrom(1024)
        action, rtx = struct.unpack(">II", data[:8])
        if action == 3:
            raise RuntimeError(data[8:].decode("utf-8", "replace") or "tracker error")
        if action != 2 or rtx != tx or len(data) < 20:
            raise RuntimeError("bad scrape reply")
        seeders, _completed, leechers = struct.unpack(">III", data[8:20])
        return seeders, leechers
    finally:
        s.close()


def _http_scrape(url, infohash, timeout):
    parsed = urlparse(url)
    path = parsed.path
    if "announce" not in path:
        raise RuntimeError("no scrape endpoint")
    scrape_url = url.replace("announce", "scrape", 1)
    r = requests.get(
        scrape_url, params={"info_hash": infohash}, timeout=timeout,
        headers={"User-Agent": "NASRadio/1.0"},
    )
    r.raise_for_status()
    body, _ = _bdecode(r.content)
    if b"failure reason" in body:
        raise RuntimeError(body[b"failure reason"].decode("utf-8", "replace"))
    entry = body.get(b"files", {}).get(infohash)
    if not entry:
        return 0, 0
    return int(entry.get(b"complete", 0)), int(entry.get(b"incomplete", 0))


def _scrape_one(url, infohash, timeout):
    parsed = urlparse(url)
    host = parsed.hostname or ""
    label = f"{host}:{parsed.port}" if parsed.port else host
    try:
        if parsed.scheme == "udp":
            seeders, leechers = _udp_scrape(host, parsed.port or 6969, infohash, timeout)
        elif parsed.scheme in ("http", "https"):
            seeders, leechers = _http_scrape(url, infohash, timeout)
        else:
            raise RuntimeError(f"unsupported scheme {parsed.scheme}")
        return {"host": label, "ok": True, "seeders": seeders, "leechers": leechers}
    except Exception as e:
        msg = str(e) or type(e).__name__
        return {"host": label, "ok": False, "error": msg[:80]}


class ProwlarrClient:
    """Client for interacting with Prowlarr API"""

    def __init__(self):
        self.config = Config()
        self.base_url = self.config.PROWLARR_URL.rstrip("/")
        self.api_key = self.config.PROWLARR_API_KEY

    def _get(self, endpoint, params=None):
        """Make a GET request to Prowlarr API"""
        url = f"{self.base_url}/api/v1/{endpoint}"
        headers = {"X-Api-Key": self.api_key}
        response = requests.get(url, headers=headers, params=params, timeout=120)
        response.raise_for_status()
        return response.json()

    def get_indexers(self):
        """Get list of configured indexers"""
        try:
            indexers = self._get("indexer")
            return {
                "success": True,
                "indexers": [
                    {
                        "id": idx["id"],
                        "name": idx["name"],
                        "protocol": idx["protocol"],
                        "enabled": idx["enable"],
                    }
                    for idx in indexers
                ],
            }
        except Exception as e:
            return {"success": False, "error": str(e)}

    # ---- indexer tiering (resolved by name, cached) ----
    #
    # Fast vs deep is decided by matching the indexer NAME, never a hardcoded
    # ID (Prowlarr renumbers on re-add). The raw indexer list is cached briefly
    # so tiering doesn't cost a round-trip on every single search.
    _indexer_cache = None          # list[{"id", "name", "enable"}]
    _indexer_cache_ts = 0.0
    _INDEXER_CACHE_TTL = 300.0     # seconds

    def _enabled_indexers(self):
        """Enabled indexers as [{"id", "name"}], cached for _INDEXER_CACHE_TTL."""
        now = time.monotonic()
        cache = ProwlarrClient._indexer_cache
        if cache is None or (now - ProwlarrClient._indexer_cache_ts) > self._INDEXER_CACHE_TTL:
            raw = self._get("indexer")  # raises on failure — caller handles
            cache = [
                {"id": idx["id"], "name": idx["name"]}
                for idx in raw
                if idx.get("enable")
            ]
            ProwlarrClient._indexer_cache = cache
            ProwlarrClient._indexer_cache_ts = now
        return cache

    def _is_deep(self, name):
        lowered = name.lower()
        return any(dn in lowered for dn in self.config.PROWLARR_DEEP_INDEXER_NAMES)

    def deep_indexer_ids(self):
        """IDs of enabled indexers whose name marks them 'deep' (e.g. RuTracker)."""
        return [i["id"] for i in self._enabled_indexers() if self._is_deep(i["name"])]

    def fast_indexer_ids(self):
        """IDs of every OTHER enabled indexer — the default fast search set."""
        return [i["id"] for i in self._enabled_indexers() if not self._is_deep(i["name"])]

    # ── Release-title audio layout detection ──────────────────────────────
    # Torrent titles carry the channel fingerprint ("5.1", "2.0", "MCH",
    # "Atmos", "quad"...). Parsed per result so the client can badge/filter
    # surround releases; a "surround:" query prefix filters server-side
    # (drops stereo-tagged, keeps surround + unlabeled) so the existing app
    # gets the feature with no UI change.
    _SURROUND_RE = re.compile(
        r"(?:\b[457]\s*[._]\s*[01]\b|\bquad(?:raphonic)?\b|\bmulti[- ]?ch(?:annel)?\b"
        r"|\bMCH\b|\batmos\b|\bauro[- ]?3d\b|\bsurround\b|\bDTS(?:-|\s)?(?:ES|X|HD\s*MA)?\s*5\b)",
        re.IGNORECASE)
    _STEREO_RE = re.compile(r"(?:\b2\s*[._]\s*0\b|\bstereo\b|\bmono\b)", re.IGNORECASE)

    @classmethod
    def _audio_layout(cls, title):
        """('surround'|'stereo'|'unknown', label) from a release title.
        A title naming both (e.g. "5.1 + 2.0") counts as surround —
        the multichannel layer is present. Upmixes (fake surround
        synthesized from stereo) are labeled so the client can demote."""
        m = cls._SURROUND_RE.search(title or "")
        if m:
            label = re.sub(r"\s*[._]\s*", ".", m.group(0)).strip().upper()
            if re.search(r"\bupmix", title or "", re.IGNORECASE):
                label += " UPMIX"
            return "surround", label
        if cls._STEREO_RE.search(title or ""):
            return "stereo", "2.0"
        return "unknown", None

    # ── Release-title quality fingerprint ─────────────────────────────────
    # Format / bit depth / sample rate / bitrate / source parsed from the
    # release title so the client can filter ("lossless only", "24-bit+",
    # "no MP3"...) without another round-trip. Titles lie less than you'd
    # think — uploaders advertise quality because it's the selling point.
    _FMT_PATTERNS = [  # (regex, canonical format, lossless?)
        (r"\bFLAC\b", "FLAC", True),
        (r"\bALAC\b", "ALAC", True),
        (r"\bAPE\b|\bMonkey'?s Audio\b", "APE", True),
        (r"\bWavPack\b|\bWV\b", "WV", True),
        (r"\b(?:DSD(?:64|128|256|512)?|DSF|DFF|SACD-?R)\b", "DSD", True),
        (r"\b(?:E[- ]?AC-?3|EAC3|DD\+|DDP)\b", "E-AC-3", False),
        (r"\bTrueHD\b", "TrueHD", True),
        (r"\bMLP\b", "MLP", True),  # DVD-Audio's lossless codec (TrueHD's parent)
        (r"\bDTS(?:-|\s)?(?:HD)?(?:\s*MA)?\b", "DTS", None),  # DTS-HD MA lossless, core lossy
        (r"\bAC-?3\b|\bDolby Digital\b", "AC-3", False),
        (r"\bMP3\b|\bLAME\b|\b320\s*kbps\b|\bV0\b", "MP3", False),
        (r"\bAAC\b|\bM4A\b", "AAC", False),
        (r"\bOGG\b|\bVorbis\b|\bOPUS\b", "OGG", False),
        (r"\bWAV\b|\bPCM\b", "WAV", True),
        (r"\bWEB\b.*\bAtmos\b|\bAtmos\b.*\bWEB\b", "E-AC-3", False),  # WEB Atmos rips are DD+ JOC
    ]

    @classmethod
    def _quality_fingerprint(cls, title):
        t = title or ""
        fmt, lossless = None, None
        for pat, name, is_ll in cls._FMT_PATTERNS:
            if re.search(pat, t, re.IGNORECASE):
                fmt = name
                lossless = is_ll
                break
        if fmt == "DTS":  # disambiguate lossless MA vs lossy core
            lossless = bool(re.search(r"DTS[- ]?(?:HD)?[- ]?MA|DTS-?HD", t, re.IGNORECASE))
        # bit depth: "24-bit", "24bit", "16/44.1", "[24/96]", "1bit" (DSD)
        bits = None
        m = re.search(r"\b(16|24|32)\s*[-/ ]?\s*bit\b", t, re.IGNORECASE) \
            or re.search(r"\b(16|24|32)\s*[-/]\s*(?:44|48|88|96|176|192)", t)
        if m:
            bits = int(m.group(1))
        elif re.search(r"\b1\s*bit\b|\bDSD", t, re.IGNORECASE) and fmt == "DSD":
            bits = 1
        # sample rate: 44.1/48/88.2/96/176.4/192 kHz (or slash notation 24/96)
        rate = None
        m = re.search(r"\b(44[.,]1|48|88[.,]2|96|176[.,]4|192)\s*k(?:Hz)?\b", t, re.IGNORECASE) \
            or re.search(r"\b(?:16|24|32)\s*[-/]\s*(44(?:[.,]1)?|48|88(?:[.,]2)?|96|176(?:[.,]4)?|192)\b", t)
        if m:
            rate = m.group(1).replace(",", ".")
        # lossy bitrate: 320/256/192 kbps or V0
        bitrate = None
        m = re.search(r"\b(320|256|192|128)\s*(?:kbps)?\b", t) if fmt in ("MP3", "AAC", "OGG") else None
        if m:
            bitrate = m.group(1) + "kbps"
        elif fmt == "MP3" and re.search(r"\bV0\b", t):
            bitrate = "V0"
        # source medium
        src = None
        for pat, name in [(r"\bSACD\b", "SACD"), (r"\bDVD-?A(?:udio)?\b", "DVD-A"),
                          (r"\bBD(?:-A|Audio| ?Rip)?\b|\bBlu-?ray\b", "Blu-ray"),
                          (r"\bWEB\b", "WEB"), (r"\bVinyl\b|\bLP\b", "Vinyl"),
                          (r"\bCD\b", "CD")]:
            if re.search(pat, t, re.IGNORECASE):
                src = name
                break
        # Atmos: explicit mention, JOC (the E-AC-3 carrier), or TrueHD
        # Atmos combos. Titles advertise it — it's the selling point.
        atmos = bool(re.search(r"\bAtmos\b|\bJOC\b", t, re.IGNORECASE))
        # channel layout as literally titled (5.1/7.1/quad...)
        ch = None
        m = re.search(r"\b(7\.1|5\.1|5\.0|4\.0|QUAD(?:RAPHONIC)?)\b", t,
                      re.IGNORECASE)
        if m:
            ch = m.group(1).upper()
            if ch.startswith("QUAD"):
                ch = "QUAD"
        return {
            "audio_format": fmt,
            "is_lossless": lossless,
            "bit_depth": bits,
            "sample_rate_khz": rate,
            "bitrate": bitrate,
            "source_medium": src,
            "is_atmos": atmos,
            "channels_label": ch,
        }

    def search(self, query, indexer_ids=None, categories=None,
               filter_rutracker_source=False):
        """
        Search for releases across indexers.

        Args:
            query: Search string (e.g., "Alice Cooper Killer")
            indexer_ids: List of specific indexer IDs to search (None = all)
            categories: List of category IDs (3000 = Audio, 3010 = MP3, 3040 = FLAC, etc.)
            filter_rutracker_source: When True, drop any result whose
                upstream source is RuTracker (infoUrl on rutracker.org).
                Knaben aggregates from many trackers and a large fraction
                of its catalog is RuTracker-proxied; while RuTracker's
                origin is down (chronic Cloudflare 521s), those results
                always fail at download time. The deep-search path leaves
                this off so the user can still opt in.
        """
        try:
            # "surround:" prefix — strip it and filter to multichannel releases.
            surround_only = False
            if query and query.strip().lower().startswith("surround:"):
                surround_only = True
                query = query.strip()[len("surround:"):].strip()

            # Escape query for exact matching if it contains special characters
            # Double-quoting tells indexers to treat it as a phrase/exact match
            escaped_query = self._escape_search_query(query)
            params = {"query": escaped_query, "type": "search"}

            # Default to audio categories if not specified
            if categories is None:
                categories = [3000]  # Audio category

            params["categories"] = categories

            if indexer_ids:
                params["indexerIds"] = indexer_ids

            results = self._get("search", params)

            # Tokenize the query into lowercased terms for whole-word
            # post-filtering (see _matches_query). Indexers do loose
            # substring/prefix matching by default, which floods short
            # queries with English-word collisions — e.g. "Winger"
            # matching "Winter Group", "Winged Wheel", "Wintergarden",
            # "Winterland", etc. Filtering on whole-word title presence
            # kills that noise without changing indexer behavior.
            query_terms = [t for t in escaped_query.lower().split() if t]

            # Parse and simplify results
            parsed_results = []
            rutracker_filtered_count = 0
            noise_filtered_count = 0
            for result in results:
                # Drop RuTracker-sourced results when the caller asked.
                # infoUrl is the canonical source pointer — for Knaben
                # proxies it's the original tracker forum page.
                info_url = (result.get("infoUrl") or "").lower()
                if filter_rutracker_source and "rutracker.org" in info_url:
                    rutracker_filtered_count += 1
                    continue

                # Whole-word title filter — drops the indexer-side
                # substring noise described above. Only applies when
                # we actually have query terms; an empty query means
                # the caller is doing a category browse and we let
                # everything through.
                title = result.get("title") or ""
                if query_terms and not self._matches_query(title, query_terms):
                    noise_filtered_count += 1
                    continue

                layout, layout_label = self._audio_layout(title)
                # surround-only: drop stereo-tagged; keep surround AND
                # unlabeled (plenty of multichannel rips don't say so in
                # the title — better to show them than hide them).
                if surround_only and layout == "stereo":
                    noise_filtered_count += 1
                    continue

                # Try multiple sources for download URL
                download_url = result.get("downloadUrl")
                if not download_url:
                    download_url = result.get("magnetUrl")
                if not download_url:
                    # Some indexers put magnet in guid
                    guid = result.get("guid", "")
                    if guid.startswith("magnet:"):
                        download_url = guid

                parsed_results.append(
                    {
                        "guid": result.get("guid"),
                        "indexer": result.get("indexer"),
                        "indexer_id": result.get("indexerId"),
                        "title": result.get("title"),
                        "size": result.get("size", 0),
                        "size_formatted": self._format_size(result.get("size", 0)),
                        "seeders": result.get("seeders", 0),
                        "leechers": result.get("leechers", 0),
                        "protocol": result.get("protocol"),
                        "download_url": download_url,
                        "info_url": result.get("infoUrl"),
                        "categories": result.get("categories", []),
                        "publish_date": result.get("publishDate"),
                        "audio_layout": layout,
                        "audio_layout_label": layout_label,
                        **self._quality_fingerprint(title),
                    }
                )

            # Sort by seeders (descending); in surround mode, titled-surround
            # releases float above unlabeled ones.
            if surround_only:
                parsed_results.sort(
                    key=lambda x: (x["audio_layout"] != "surround", -x["seeders"]))
            else:
                parsed_results.sort(key=lambda x: x["seeders"], reverse=True)

            return {
                "success": True,
                "query": query,
                "result_count": len(parsed_results),
                "results": parsed_results,
                "rutracker_filtered_count": rutracker_filtered_count,
                "noise_filtered_count": noise_filtered_count,
            }

        except Exception as e:
            return {"success": False, "error": str(e)}

    def _matches_query(self, title, query_terms):
        """Whole-word match: every term in ``query_terms`` (already
        lowercased) must appear as a whole word in ``title``. Uses
        regex word boundaries (``\\b``) so "Winger" doesn't match
        inside "Winterland" or "Winged". Case-insensitive; safe for
        titles containing regex metacharacters because each term is
        re.escape'd before being interpolated.

        Returns True when the result should be kept. Stop words and
        common English words in the query are NOT treated specially —
        if you typed it, we look for it. For most music searches this
        is what you want; if it ever over-filters, the call site can
        skip this check by passing an empty query_terms list.
        """
        if not title:
            # Missing title — don't filter; let the caller see it.
            return True
        title_lower = title.lower()
        for term in query_terms:
            pattern = r"\b" + re.escape(term) + r"\b"
            if not re.search(pattern, title_lower):
                return False
        return True

    def _format_size(self, size_bytes):
        """Format bytes to human-readable size"""
        if size_bytes == 0:
            return "Unknown"
        for unit in ["B", "KB", "MB", "GB", "TB"]:
            if size_bytes < 1024:
                return f"{size_bytes:.1f} {unit}"
            size_bytes /= 1024
        return f"{size_bytes:.1f} PB"

    def _escape_search_query(self, query):
        """
        Clean search query for indexer search.
        Just strip double quotes to prevent accidental exact-phrase matching.
        Let indexers handle special characters like apostrophes naturally.
        """
        return query.replace('"', "").strip()


class TransmissionClient:
    """Client for interacting with Transmission RPC"""

    def __init__(self):
        self.config = Config()
        self.base_url = self.config.TRANSMISSION_URL.rstrip("/")
        self.session_id = None
        self.auth = None

        if self.config.TRANSMISSION_USER and self.config.TRANSMISSION_PASS:
            self.auth = (self.config.TRANSMISSION_USER, self.config.TRANSMISSION_PASS)

    def _get_session_id(self):
        """Get CSRF session ID from Transmission"""
        try:
            response = requests.get(
                f"{self.base_url}/transmission/rpc", auth=self.auth, timeout=10
            )
            # Transmission returns 409 with session ID in header
            if response.status_code == 409:
                self.session_id = response.headers.get("X-Transmission-Session-Id")
                return True
            return False
        except requests.exceptions.ConnectionError:
            raise ConnectionError(f"Transmission is not reachable at {self.base_url}. Is the container running?")
        except requests.exceptions.Timeout:
            raise ConnectionError(f"Transmission at {self.base_url} timed out. The service may be hung — try restarting the container.")
        except Exception as e:
            raise ConnectionError(f"Transmission connection failed: {e}")

    def _rpc_call(self, method, arguments=None):
        """Make an RPC call to Transmission.

        If Transmission is unreachable, try to auto-restart the container on the
        NAS once and retry — so a flaky container self-heals instead of erroring
        out to the app."""
        try:
            return self._rpc_call_once(method, arguments)
        except ConnectionError:
            from app.transmission_restart import recover_transmission

            if recover_transmission():
                self.session_id = None  # force a fresh session after restart
                return self._rpc_call_once(method, arguments)
            raise

    def _rpc_call_once(self, method, arguments=None):
        """Make a single RPC call to Transmission (no restart/retry)."""
        if not self.session_id:
            self._get_session_id()

        url = f"{self.base_url}/transmission/rpc"
        headers = {"X-Transmission-Session-Id": self.session_id}

        payload = {"method": method}
        if arguments:
            payload["arguments"] = arguments

        try:
            response = requests.post(
                url, json=payload, headers=headers, auth=self.auth, timeout=30
            )
        except requests.exceptions.ConnectionError:
            raise ConnectionError(f"Transmission is not reachable at {self.base_url}. Is the container running?")
        except requests.exceptions.Timeout:
            raise ConnectionError(f"Transmission at {self.base_url} timed out. The service may be hung — try restarting the container.")

        # If session expired, get new one and retry
        if response.status_code == 409:
            self.session_id = response.headers.get("X-Transmission-Session-Id")
            headers["X-Transmission-Session-Id"] = self.session_id
            response = requests.post(
                url, json=payload, headers=headers, auth=self.auth, timeout=30
            )

        response.raise_for_status()
        return response.json()

    def _resolve_source(self, url, timeout=25):
        """Turn a magnet / .torrent URL / Prowlarr proxy URL into
        ("magnet", str) or ("torrent", bytes). Raises on failure."""
        if url.startswith("magnet:"):
            return "magnet", url
        r = requests.get(url, timeout=timeout, allow_redirects=False)
        hops = 0
        while r.status_code in (301, 302, 303, 307, 308) and hops < 5:
            location = r.headers.get("Location", "")
            if location.startswith("magnet:"):
                return "magnet", location
            r = requests.get(location, timeout=timeout, allow_redirects=False)
            hops += 1
        r.raise_for_status()
        if r.content.startswith(b"<?xml") or "xml" in r.headers.get("content-type", ""):
            match = re.search(r'description="([^"]+)"', r.text)
            raise RuntimeError(match.group(1) if match else "Indexer error")
        if not r.content.startswith(b"d"):
            raise RuntimeError("Indexer did not return a torrent file")
        return "torrent", r.content

    def probe_swarm(self, url, per_tracker_timeout=4, overall_timeout=8):
        """Ask the trackers themselves how many seeders a torrent has.

        Scrapes every tracker on the magnet/.torrent plus our public list,
        in parallel, and reports the MAX seeder count any tracker returned
        (they all describe the same swarm). Verdict:
          alive    - at least one tracker reports a seeder
          dead     - trackers answered, none report a seeder
          unknown  - no tracker answered at all (DHT-only, may still work)
        """
        try:
            kind, payload = self._resolve_source(url)
            if kind == "magnet":
                infohash, name, trackers = _parse_magnet(payload)
            else:
                infohash, name, trackers = _parse_torrent_file(payload)
        except requests.exceptions.Timeout:
            return {"success": False, "error": "Indexer too slow to answer the probe"}
        except Exception as e:
            return {"success": False, "error": str(e)}

        if not infohash:
            return {"success": False, "error": "No infohash in link"}

        # Dedupe (case-insensitive) and fold in the public trackers
        seen = set()
        urls = []
        for t in list(trackers) + list(self.config.PUBLIC_TRACKERS):
            key = t.strip().lower()
            if key and key not in seen:
                seen.add(key)
                urls.append(t.strip())

        results = []
        pool = ThreadPoolExecutor(max_workers=min(24, max(1, len(urls))))
        try:
            futures = [pool.submit(_scrape_one, u, infohash, per_tracker_timeout) for u in urls]
            done, _pending = _futures_wait(futures, timeout=overall_timeout)
            for f in done:
                results.append(f.result())
        finally:
            pool.shutdown(wait=False)

        answered = [r for r in results if r["ok"]]
        seeders = max((r["seeders"] for r in answered), default=0)
        leechers = max((r["leechers"] for r in answered), default=0)
        if seeders > 0:
            verdict = "alive"
        elif answered:
            verdict = "dead"
        else:
            verdict = "unknown"

        # Answered trackers first, then failures, so the list reads well
        results.sort(key=lambda r: (not r["ok"], -r.get("seeders", 0)))
        return {
            "success": True,
            "infohash": infohash.hex(),
            "name": name,
            "seeders": seeders,
            "leechers": leechers,
            "trackers_total": len(urls),
            "trackers_answered": len(answered),
            "verdict": verdict,
            "trackers": results,
        }

    def _enhance_magnet(self, magnet_url):
        """
        Inject public trackers into a magnet link for better peer discovery.

        RuTracker's bt*.t-ru.org trackers have been DDoS'd and government-blocked
        since mid-2025. Magnet links with only those trackers rely on slow DHT.
        Adding public trackers lets Transmission find peers much faster.

        Applied to ALL magnet links — extra trackers never hurt.
        """
        from urllib.parse import quote, unquote

        # Get existing tracker URLs from the magnet (case-insensitive comparison)
        existing_trackers = set()
        for part in magnet_url.split("&"):
            if part.lower().startswith("tr="):
                existing_trackers.add(unquote(part[3:]).lower())

        # Append any public trackers not already present
        enhanced = magnet_url
        added = 0
        for tracker in self.config.PUBLIC_TRACKERS:
            if tracker.lower() not in existing_trackers:
                enhanced += f"&tr={quote(tracker, safe='')}"
                added += 1

        if added > 0:
            print(f"🧲 Enhanced magnet link with {added} public trackers")

        return enhanced

    def add_torrent(self, url, download_dir=None):
        """
        Add a torrent to Transmission

        Args:
            url: Magnet link or torrent URL (can be Prowlarr download URL)
            download_dir: Optional download directory override
        """
        import base64

        try:
            arguments = {}

            # Use provided dir, or default from config
            if download_dir:
                arguments["download-dir"] = download_dir
            elif self.config.TRANSMISSION_DOWNLOAD_DIR:
                arguments["download-dir"] = self.config.TRANSMISSION_DOWNLOAD_DIR

            # Check if it's a magnet link (pass directly) or a URL (fetch torrent file first)
            if url.startswith("magnet:"):
                arguments["filename"] = self._enhance_magnet(url)
            else:
                # Fetch the torrent file from the URL (handles Prowlarr proxy URLs).
                # Prowlarr has to re-fetch the .torrent from the upstream indexer
                # (Knaben, RED, OPS, etc.), and some of those are genuinely slow —
                # 30 s wasn't enough for the Indiana Jones soundtrack via Knaben.
                # Try once with a long timeout, then retry once if we time out.
                fetch_timeout = 90
                max_attempts = 2

                def _fetch_with_retry(req_url):
                    last_err = None
                    for attempt in range(1, max_attempts + 1):
                        try:
                            return requests.get(
                                req_url, timeout=fetch_timeout, allow_redirects=False
                            )
                        except requests.exceptions.Timeout as e:
                            last_err = e
                            print(
                                f"⏱️  Torrent fetch timed out "
                                f"(attempt {attempt}/{max_attempts}, {fetch_timeout}s): {req_url[:80]}..."
                            )
                            if attempt >= max_attempts:
                                raise
                    raise last_err  # unreachable, keeps type checkers happy

                try:
                    response = _fetch_with_retry(url)

                    # Check if redirecting to a magnet link
                    if response.status_code in (301, 302, 303, 307, 308):
                        location = response.headers.get("Location", "")
                        if location.startswith("magnet:"):
                            # Use the magnet link directly (with public trackers)
                            arguments["filename"] = self._enhance_magnet(location)
                        else:
                            # Follow the redirect manually for non-magnet URLs
                            response = requests.get(location, timeout=fetch_timeout)
                            response.raise_for_status()
                            torrent_b64 = base64.b64encode(response.content).decode(
                                "utf-8"
                            )
                            arguments["metainfo"] = torrent_b64
                    elif response.status_code == 200:
                        # Check for Prowlarr error responses (XML error messages)
                        content_type = response.headers.get("content-type", "")
                        if "xml" in content_type or response.content.startswith(
                            b"<?xml"
                        ):
                            import re

                            match = re.search(r'description="([^"]+)"', response.text)
                            error_msg = match.group(1) if match else "Indexer error"
                            return {"success": False, "error": error_msg}
                        # Encode torrent file as base64 for Transmission
                        torrent_b64 = base64.b64encode(response.content).decode("utf-8")
                        arguments["metainfo"] = torrent_b64
                    else:
                        response.raise_for_status()
                except requests.exceptions.Timeout:
                    return {
                        "success": False,
                        "error": (
                            "This indexer is too slow to respond right now. "
                            "Try a different result, or try again later."
                        ),
                    }
                except requests.exceptions.ConnectionError:
                    return {
                        "success": False,
                        "error": (
                            "Can't reach Prowlarr. Check that the Prowlarr "
                            "container is running and the URL is correct."
                        ),
                    }
                except requests.exceptions.HTTPError as e:
                    # Classify the HTTP status into something the user can
                    # actually act on. The raw urllib message includes the
                    # full giant URL blob, which is useless noise in the
                    # snackbar.
                    status = getattr(e.response, "status_code", 0) if e.response is not None else 0
                    if status in (502, 503, 504):
                        msg = (
                            "The indexer's upstream source isn't responding "
                            "right now (this is common for RuTracker-sourced "
                            "results). Try a different result or try again later."
                        )
                    elif status == 500:
                        msg = (
                            "The indexer couldn't fetch this .torrent file — "
                            "the original source may be down or the torrent "
                            "may have been removed. Try a different result."
                        )
                    elif status == 404:
                        msg = (
                            "This torrent is no longer available at the source. "
                            "Try a different result."
                        )
                    elif status in (401, 403):
                        msg = (
                            "Prowlarr rejected the request — API key may be "
                            "wrong, or this indexer needs re-authentication."
                        )
                    elif status == 429:
                        msg = (
                            "Rate-limited by the indexer. Wait a minute and "
                            "try again."
                        )
                    else:
                        msg = f"Indexer returned HTTP {status or '?'}. Try a different result."
                    return {"success": False, "error": msg}
                except requests.exceptions.RequestException as e:
                    # Anything else (DNS, SSL, unknown) — keep the detail
                    # short, no giant URLs.
                    short = type(e).__name__
                    return {
                        "success": False,
                        "error": f"Failed to fetch torrent ({short}). Try a different result.",
                    }

            result = self._rpc_call("torrent-add", arguments)

            if result.get("result") == "success":
                torrent_info = result.get("arguments", {})
                # Could be "torrent-added" or "torrent-duplicate"
                added = torrent_info.get("torrent-added") or torrent_info.get(
                    "torrent-duplicate"
                )

                return {
                    "success": True,
                    "torrent_id": added.get("id") if added else None,
                    "torrent_name": added.get("name") if added else None,
                    "duplicate": "torrent-duplicate" in torrent_info,
                }
            else:
                return {
                    "success": False,
                    "error": result.get("result", "Unknown error"),
                }

        except Exception as e:
            return {"success": False, "error": str(e)}

    def get_torrents(self, ids=None):
        """Get list of torrents with their status and health info"""
        try:
            arguments = {
                "fields": [
                    "id",
                    "name",
                    "status",
                    "percentDone",
                    "eta",
                    "rateDownload",
                    "rateUpload",
                    "totalSize",
                    "downloadDir",
                    "isFinished",
                    "errorString",
                    "doneDate",
                    "addedDate",
                    "peersConnected",
                    "metadataPercentComplete",
                    "trackerStats",
                    "desiredAvailable",
                ]
            }
            if ids:
                arguments["ids"] = ids

            result = self._rpc_call("torrent-get", arguments)

            if result.get("result") == "success":
                torrents = result.get("arguments", {}).get("torrents", [])
                return {
                    "success": True,
                    "torrents": [
                        self._parse_torrent(t)
                        for t in torrents
                        if self._is_nasradio_torrent(t)
                    ],
                }
            else:
                return {
                    "success": False,
                    "error": result.get("result", "Unknown error"),
                }

        except Exception as e:
            return {"success": False, "error": str(e)}

    def _is_nasradio_torrent(self, t):
        """True if the torrent lives in NASRadio's download dir.

        Transmission is shared with Sonarr/Radarr, whose movie and TV
        torrents sit in the session default (/downloads/complete). Only
        torrents under TRANSMISSION_DOWNLOAD_DIR belong to NASRadio, so the
        downloads screen, stop-old-seeders and clear-completed never see or
        touch the video ones.
        """
        music_dir = (self.config.TRANSMISSION_DOWNLOAD_DIR or "").rstrip("/")
        if not music_dir:
            return True
        torrent_dir = (t.get("downloadDir") or "").rstrip("/")
        return torrent_dir == music_dir or torrent_dir.startswith(music_dir + "/")

    def _parse_torrent(self, t):
        """Parse a raw Transmission torrent into our API format with health info"""
        # Seeders/leechers from tracker responses. Every tracker reports the
        # same swarm, so take the MAX across trackers, not the sum: three
        # trackers each seeing one seeder is one seeder, not three. (The sum
        # showed "3 seed" on a magnet that had never connected to anyone.)
        seeders = 0
        leechers = 0
        active_trackers = 0
        total_trackers = len(t.get("trackerStats", []))
        for ts in t.get("trackerStats", []):
            if ts.get("seederCount", -1) >= 0:
                active_trackers += 1
                seeders = max(seeders, ts["seederCount"])
            if ts.get("leecherCount", -1) >= 0:
                leechers = max(leechers, ts["leecherCount"])

        metadata_percent = round(
            t.get("metadataPercentComplete", 0) * 100, 1
        )
        percent_done = round(t["percentDone"] * 100, 1)
        dl_speed = t.get("rateDownload", 0)
        desired = t.get("desiredAvailable", 0)
        status = t.get("status", 0)

        # Compute health status
        if status == 6:  # seeding
            health = "seeding"
        elif dl_speed > 0:
            health = "downloading"
        elif metadata_percent < 100:
            health = "metadata"
        elif desired > 0 or seeders > 0:
            health = "alive"
        elif t.get("peersConnected", 0) > 0:
            health = "stalled"
        else:
            health = "dead"

        return {
            "id": t["id"],
            "name": t["name"],
            "status": self._status_to_string(t["status"]),
            "percent_done": percent_done,
            "eta": t.get("eta", -1),
            "download_speed": dl_speed,
            "upload_speed": t.get("rateUpload", 0),
            "total_size": t.get("totalSize", 0),
            "download_dir": t.get("downloadDir", ""),
            "is_finished": t.get("isFinished", False),
            "error": t.get("errorString", ""),
            "done_date": t.get("doneDate", 0),
            "added_date": t.get("addedDate", 0),
            "peers_connected": t.get("peersConnected", 0),
            # New health fields
            "metadata_percent": metadata_percent,
            "seeders": seeders,
            "leechers": leechers,
            "active_trackers": active_trackers,
            "total_trackers": total_trackers,
            "health": health,
        }

    def _status_to_string(self, status):
        """Convert Transmission status code to string"""
        status_map = {
            0: "stopped",
            1: "check_wait",
            2: "checking",
            3: "download_wait",
            4: "downloading",
            5: "seed_wait",
            6: "seeding",
        }
        return status_map.get(status, "unknown")

    def stop_torrent(self, torrent_id):
        """Stop a torrent"""
        try:
            result = self._rpc_call("torrent-stop", {"ids": [torrent_id]})
            return {"success": result.get("result") == "success"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def remove_torrent(self, torrent_id, delete_data=False):
        """Remove a torrent, optionally deleting data"""
        try:
            result = self._rpc_call(
                "torrent-remove",
                {"ids": [torrent_id], "delete-local-data": delete_data},
            )
            return {"success": result.get("result") == "success"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def stop_old_seeders(self, max_seed_minutes=30):
        """Stop torrents that have been seeding longer than max_seed_minutes"""
        import time

        try:
            result = self.get_torrents()
            if not result["success"]:
                return {"success": False, "error": "Failed to get torrents"}

            stopped = []
            now = time.time()
            max_seed_seconds = max_seed_minutes * 60

            for torrent in result["torrents"]:
                # Check if seeding and has a done_date
                if torrent["status"] == "seeding" and torrent["done_date"] > 0:
                    seed_duration = now - torrent["done_date"]
                    if seed_duration > max_seed_seconds:
                        stop_result = self.stop_torrent(torrent["id"])
                        if stop_result["success"]:
                            stopped.append(
                                {
                                    "id": torrent["id"],
                                    "name": torrent["name"],
                                    "seed_duration_minutes": round(
                                        seed_duration / 60, 1
                                    ),
                                }
                            )

            return {
                "success": True,
                "stopped_count": len(stopped),
                "stopped": stopped,
            }
        except Exception as e:
            return {"success": False, "error": str(e)}

    def inject_trackers(self, torrent_ids=None):
        """
        Add public trackers to existing torrents in Transmission.

        Uses torrent-set with trackerList (Transmission 4.x format) to inject
        public trackers alongside the originals. Each tracker gets its own tier.

        Args:
            torrent_ids: List of specific torrent IDs (None = all torrents)
        """
        try:
            # Get current tracker lists for each torrent
            arguments = {"fields": ["id", "name", "trackerList"]}
            if torrent_ids:
                arguments["ids"] = torrent_ids

            result = self._rpc_call("torrent-get", arguments)
            if result.get("result") != "success":
                return {"success": False, "error": "Failed to get torrents"}

            torrents = result.get("arguments", {}).get("torrents", [])
            updated = []

            for torrent in torrents:
                current_list = torrent.get("trackerList", "").strip()
                existing_urls = {
                    line.strip().lower()
                    for line in current_list.split("\n")
                    if line.strip()
                }

                # Build new list: keep original + add missing public trackers
                new_list = current_list.rstrip()
                added = 0
                for tracker in self.config.PUBLIC_TRACKERS:
                    if tracker.lower() not in existing_urls:
                        new_list += f"\n\n{tracker}"
                        added += 1

                if added > 0:
                    try:
                        self._rpc_call(
                            "torrent-set",
                            {"ids": [torrent["id"]], "trackerList": new_list},
                        )
                        updated.append(
                            {
                                "id": torrent["id"],
                                "name": torrent["name"],
                                "trackers_added": added,
                            }
                        )
                    except Exception as e:
                        print(
                            f"⚠️ Failed to inject trackers for {torrent['name']}: {e}"
                        )

            return {
                "success": True,
                "updated_count": len(updated),
                "updated": updated,
            }
        except Exception as e:
            return {"success": False, "error": str(e)}

    def clear_completed(self, delete_data=False):
        """Remove all completed/stopped torrents that are 100% done"""
        try:
            result = self.get_torrents()
            if not result["success"]:
                return {"success": False, "error": "Failed to get torrents"}

            removed = []
            for torrent in result["torrents"]:
                # Remove if 100% done AND stopped (not actively seeding)
                if torrent["percent_done"] >= 100 and torrent["status"] == "stopped":
                    remove_result = self.remove_torrent(
                        torrent["id"], delete_data=delete_data
                    )
                    if remove_result["success"]:
                        removed.append(
                            {
                                "id": torrent["id"],
                                "name": torrent["name"],
                            }
                        )

            return {
                "success": True,
                "removed_count": len(removed),
                "removed": removed,
            }
        except Exception as e:
            return {"success": False, "error": str(e)}
