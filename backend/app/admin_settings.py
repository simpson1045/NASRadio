"""Admin settings API — the backend half of the first-run wizard and of
Settings → Integrations in the app.

    GET  /api/admin/settings                 every setting: value (secrets masked), source, meta
    PUT  /api/admin/settings                 {KEY: value, ...}; value null = reset to env/default
    POST /api/admin/settings/test/<service>  try a connection with the saved values, or with the
                                             unsaved values in the body ({"url": ..., "api_key": ...})
    GET  /api/admin/services                 which optional services are configured (+ sidecar reachability)

Admin-only (full token, role admin), same gate style as the cast blueprint.
Tests are bounded (~5 s each) and never raise — they return {ok, message, details}.
"""

import hashlib
import os
import socket
import time

import requests
from flask import Blueprint, g, jsonify, request

from app import auth
from app import settings as store
from app.config import Config

admin_api = Blueprint("admin_settings", __name__)

_TIMEOUT = 5


@admin_api.before_request
def _admin_gate():
    if request.method == "OPTIONS":
        return None
    token = auth.extract_bearer_token()
    if not token:
        return jsonify({"error": "Authentication required"}), 401
    user, scope = auth.resolve_token(token)
    if not user or scope != "full":
        return jsonify({"error": "Full authentication required"}), 401
    if user.get("role") != "admin":
        return jsonify({"error": "Admin only"}), 403
    g.user = user
    return None


# ── Settings CRUD ──────────────────────────────────────────────────────

_GROUPS = [
    {"id": "library", "label": "Library"},
    {"id": "server", "label": "Server"},
    {"id": "downloads", "label": "Downloads"},
    {"id": "metadata", "label": "Metadata & APIs"},
    {"id": "services", "label": "Sidecar services"},
    {"id": "youtube", "label": "YouTube"},
    {"id": "cast", "label": "Cast & living room"},
]


@admin_api.route("/api/admin/settings", methods=["GET"])
def get_settings():
    return jsonify({"groups": _GROUPS, "settings": store.describe()})


@admin_api.route("/api/admin/settings", methods=["PUT"])
def put_settings():
    """Body: {"PROWLARR_URL": "http://...", "PROWLARR_API_KEY": null, ...}
    null resets the key to its env/default value. A secret sent as an empty
    string is ignored (the UI shows secrets masked as ""), so re-saving a
    form never wipes a stored secret; send null to clear one on purpose."""
    data = request.get_json(silent=True)
    if not isinstance(data, dict) or not data:
        return jsonify({"error": "Send a JSON object of {KEY: value}"}), 400
    unknown = [k for k in data if k not in store.BY_KEY]
    if unknown:
        return jsonify({"error": f"Unknown setting(s): {', '.join(unknown)}"}), 400
    changed, skipped = [], []
    for key, value in data.items():
        spec = store.BY_KEY[key]
        if value is None:
            store.reset_value(key)
            changed.append(key)
            continue
        if spec.get("secret") and value == "":
            skipped.append(key)
            continue
        if spec["type"] == "int":
            try:
                int(str(value).strip())
            except (TypeError, ValueError):
                return jsonify({"error": f"{key} must be a whole number"}), 400
        if spec["type"] == "bool" and not isinstance(value, bool):
            value = str(value).strip().lower() in ("1", "true", "yes", "on")
        store.set_value(key, value)
        changed.append(key)
    return jsonify({"success": True, "changed": changed, "skipped": skipped,
                    "settings": store.describe()})


# ── Connection tests ───────────────────────────────────────────────────

def _val(overrides, key, body_name=None):
    """Unsaved value from the request body if present, else the effective setting."""
    name = body_name or key
    if overrides and name in overrides and overrides[name] not in (None, ""):
        return str(overrides[name]).strip().rstrip("/") if store.BY_KEY[key]["type"] == "url" else str(overrides[name]).strip()
    return getattr(Config, key)


def _ok(message, **details):
    return {"ok": True, "message": message, "details": details}


def _fail(message, **details):
    return {"ok": False, "message": message, "details": details}


def _http_error(e):
    if isinstance(e, requests.exceptions.ConnectTimeout) or isinstance(e, requests.exceptions.ReadTimeout):
        return "Timed out — is the host reachable from the server?"
    if isinstance(e, requests.exceptions.ConnectionError):
        return "Connection refused — wrong host/port, or the service isn't running"
    return str(e)


def _tcp_check(host, port, what):
    if not host:
        return _fail(f"No {what} host configured")
    try:
        with socket.create_connection((host, int(port)), timeout=3):
            pass
        return _ok(f"{what} reachable at {host}:{port}")
    except OSError as e:
        return _fail(f"Can't reach {what} at {host}:{port}: {e}")


def test_library(o):
    path = _val(o, "MUSIC_LIBRARY_PATH", "path")
    if not path:
        return _fail("No library folder configured")
    if not os.path.isdir(path):
        return _fail(f"Folder not found: {path}",
                     hint="Inside Docker this must be the container-side path (the bind mount, usually /music).")
    if not os.access(path, os.R_OK):
        return _fail(f"Folder exists but isn't readable: {path}")
    exts = tuple(Config.SUPPORTED_FORMATS)
    audio, dirs, scanned = 0, 0, 0
    try:
        for root, subdirs, files in os.walk(path):
            dirs += 1
            audio += sum(1 for f in files if f.lower().endswith(exts))
            scanned += len(files)
            if scanned > 5000 or dirs > 400:
                break
    except OSError as e:
        return _fail(f"Error reading folder: {e}")
    partial = scanned > 5000 or dirs > 400
    return _ok(f"Found {audio}{'+' if partial else ''} audio files in {dirs}{'+' if partial else ''} folders",
               audio_files=audio, folders=dirs, partial=partial, writable=os.access(path, os.W_OK))


def test_public_url(o):
    base = _val(o, "PUBLIC_BASE_URL", "url")
    if not base:
        return _fail("No public base URL configured (optional — only needed for cast, party links and MusicBrainz)")
    try:
        r = requests.get(f"{base}/api/ping", timeout=_TIMEOUT)
        if r.status_code == 200 and r.json().get("ok"):
            return _ok(f"{base} answers and is this server", scheme=base.split(":")[0])
        return _fail(f"{base}/api/ping returned HTTP {r.status_code}")
    except Exception as e:
        return _fail(f"{base} unreachable from the server: {_http_error(e)}",
                     hint="The URL must resolve from the server itself as well as from clients.")


def test_transmission(o):
    url = _val(o, "TRANSMISSION_URL", "url")
    user = _val(o, "TRANSMISSION_USER", "user")
    pw = _val(o, "TRANSMISSION_PASS", "password")
    a = (user, pw) if user and pw else None
    rpc = f"{url}/transmission/rpc"
    try:
        r = requests.post(rpc, json={"method": "session-get"}, auth=a, timeout=_TIMEOUT)
        if r.status_code == 401:
            return _fail("Transmission rejected the username/password")
        if r.status_code == 409:
            sid = r.headers.get("X-Transmission-Session-Id", "")
            r = requests.post(rpc, json={"method": "session-get"}, auth=a,
                              headers={"X-Transmission-Session-Id": sid}, timeout=_TIMEOUT)
        if r.status_code != 200:
            return _fail(f"Transmission answered HTTP {r.status_code} at {rpc}")
        args = r.json().get("arguments", {})
        return _ok(f"Transmission {args.get('version', '?')} at {url}",
                   version=args.get("version"), download_dir=args.get("download-dir"))
    except Exception as e:
        return _fail(f"Transmission unreachable at {url}: {_http_error(e)}")


def _arr_status(name, url, key):
    if not key:
        return _fail(f"No {name} API key configured")
    try:
        r = requests.get(f"{url}/api/v1/system/status", headers={"X-Api-Key": key}, timeout=_TIMEOUT)
        if r.status_code == 401:
            return _fail(f"{name} rejected the API key")
        if r.status_code != 200:
            return _fail(f"{name} answered HTTP {r.status_code} at {url}")
        d = r.json()
        return _ok(f"{d.get('appName', name)} {d.get('version', '?')} at {url}", version=d.get("version"))
    except Exception as e:
        return _fail(f"{name} unreachable at {url}: {_http_error(e)}")


def test_prowlarr(o):
    return _arr_status("Prowlarr", _val(o, "PROWLARR_URL", "url"), _val(o, "PROWLARR_API_KEY", "api_key"))


def test_lidarr(o):
    return _arr_status("Lidarr", _val(o, "LIDARR_URL", "url"), _val(o, "LIDARR_API_KEY", "api_key"))


def test_essentia(o):
    url = _val(o, "ESSENTIA_SERVICE_URL", "url")
    try:
        r = requests.get(f"{url}/health", timeout=_TIMEOUT)
        return _ok(f"Essentia service up at {url}") if r.status_code == 200 else _fail(f"Essentia answered HTTP {r.status_code}")
    except Exception as e:
        return _fail(f"Essentia unreachable at {url}: {_http_error(e)}",
                     hint="Optional. Without it, genres/mood/BPM/ReplayGain analysis stays off.")


def test_transcode(o):
    url = _val(o, "TRANSCODE_SERVICE_URL", "url")
    try:
        r = requests.get(f"{url}/health", timeout=_TIMEOUT)
        if r.status_code == 200 and r.json().get("status") == "ok":
            return _ok(f"Transcode service up at {url}")
        return _fail(f"Transcode service answered HTTP {r.status_code}")
    except Exception as e:
        return _fail(f"Transcode service unreachable at {url}: {_http_error(e)}",
                     hint="Optional. Without it, mobile AAC transcodes fall back to local ffmpeg.")


def test_spotify(o):
    cid = _val(o, "SPOTIFY_CLIENT_ID", "client_id")
    sec = _val(o, "SPOTIFY_CLIENT_SECRET", "client_secret")
    if not cid or not sec:
        return _fail("Spotify client ID and secret are both required")
    try:
        from spotipy.oauth2 import SpotifyClientCredentials
        tok = SpotifyClientCredentials(client_id=cid, client_secret=sec).get_access_token(as_dict=False)
        return _ok("Spotify credentials accepted") if tok else _fail("Spotify returned no token")
    except Exception as e:
        return _fail(f"Spotify rejected the credentials: {e}")


def test_lastfm(o):
    key = _val(o, "LASTFM_API_KEY", "api_key")
    if not key:
        return _fail("No Last.fm API key configured (artwork lookups will skip Last.fm)")
    try:
        r = requests.get("https://ws.audioscrobbler.com/2.0/",
                         params={"method": "artist.getinfo", "artist": "Cher", "api_key": key, "format": "json"},
                         timeout=_TIMEOUT)
        d = r.json()
        if "error" in d:
            return _fail(f"Last.fm: {d.get('message', 'error ' + str(d['error']))}")
        return _ok("Last.fm API key accepted")
    except Exception as e:
        return _fail(f"Last.fm unreachable: {_http_error(e)}")


def test_fanart(o):
    key = _val(o, "FANART_API_KEY", "api_key")
    if not key:
        return _fail("No fanart.tv API key configured (artist images will skip fanart.tv)")
    try:
        # Van Halen's MusicBrainz artist id — any well-known artist works as a probe.
        r = requests.get("https://webservice.fanart.tv/v3/music/b665b768-0d83-4363-950c-31ed39317c15",
                         params={"api_key": key}, timeout=_TIMEOUT)
        if r.status_code == 200:
            return _ok("fanart.tv API key accepted")
        if r.status_code in (401, 403):
            return _fail("fanart.tv rejected the API key")
        return _fail(f"fanart.tv answered HTTP {r.status_code}")
    except Exception as e:
        return _fail(f"fanart.tv unreachable: {_http_error(e)}")


def test_podcast_index(o):
    key = _val(o, "PODCAST_INDEX_KEY", "api_key")
    sec = _val(o, "PODCAST_INDEX_SECRET", "api_secret")
    if not key or not sec:
        return _fail("Podcast Index key and secret are both required")
    now = str(int(time.time()))
    headers = {"User-Agent": "NASRadio/1.0", "X-Auth-Key": key, "X-Auth-Date": now,
               "Authorization": hashlib.sha1((key + sec + now).encode()).hexdigest()}
    try:
        r = requests.get("https://api.podcastindex.org/api/1.0/categories/list", headers=headers, timeout=_TIMEOUT)
        if r.status_code == 401:
            return _fail("Podcast Index rejected the key/secret")
        if r.status_code != 200:
            return _fail(f"Podcast Index answered HTTP {r.status_code}")
        return _ok("Podcast Index credentials accepted")
    except Exception as e:
        return _fail(f"Podcast Index unreachable: {_http_error(e)}")


def test_acoustid(o):
    key = _val(o, "ACOUSTID_API_KEY", "api_key")
    if not key:
        return _fail("No AcoustID API key configured")
    try:
        # A deliberately bogus fingerprint: a valid key yields a fingerprint error,
        # an invalid key yields error code 4.
        r = requests.get("https://api.acoustid.org/v2/lookup",
                         params={"client": key, "duration": 1, "fingerprint": "AQAA"}, timeout=_TIMEOUT)
        d = r.json()
        err = (d.get("error") or {})
        if err.get("code") == 4:
            return _fail("AcoustID rejected the API key")
        return _ok("AcoustID API key accepted")
    except Exception as e:
        return _fail(f"AcoustID unreachable: {_http_error(e)}")


def test_cast_device(o):
    return _tcp_check(_val(o, "CAST_DEVICE_HOST", "host"), 8009, "Cast device")


def test_denon(o):
    return _tcp_check(_val(o, "DENON_HOST", "host"), _val(o, "DENON_TELNET_PORT", "port") or 23, "Denon receiver")


TESTS = {
    "library": test_library,
    "public_url": test_public_url,
    "transmission": test_transmission,
    "prowlarr": test_prowlarr,
    "lidarr": test_lidarr,
    "essentia": test_essentia,
    "transcode": test_transcode,
    "spotify": test_spotify,
    "lastfm": test_lastfm,
    "fanart": test_fanart,
    "podcast_index": test_podcast_index,
    "acoustid": test_acoustid,
    "cast_device": test_cast_device,
    "denon": test_denon,
}


@admin_api.route("/api/admin/settings/test/<service>", methods=["POST"])
def test_service(service):
    fn = TESTS.get(service)
    if not fn:
        return jsonify({"error": f"Unknown service '{service}'", "services": sorted(TESTS)}), 404
    overrides = request.get_json(silent=True) or {}
    try:
        result = fn(overrides)
    except Exception as e:  # a test must never 500 the wizard
        result = _fail(f"Test failed: {e}")
    result["service"] = service
    return jsonify(result)


# ── Services summary ───────────────────────────────────────────────────

@admin_api.route("/api/admin/services", methods=["GET"])
def services_summary():
    """Configured-or-not for every optional integration, plus live reachability
    for the two sidecars (cheap, cached by their own health probes)."""
    from app.audio_analysis import check_essentia_service
    from app.transcode import check_transcode_service

    c = Config
    song_count = None
    try:
        db = store._get_db()
        conn = db.get_connection()
        try:
            cur = db.get_cursor(conn)
            cur.execute("SELECT COUNT(*) AS n FROM songs")
            song_count = cur.fetchone()["n"]
        finally:
            conn.close()
    except Exception:
        pass
    out = {
        "library": {"configured": bool(c.MUSIC_LIBRARY_PATH), "path": c.MUSIC_LIBRARY_PATH,
                    "exists": os.path.isdir(c.MUSIC_LIBRARY_PATH) if c.MUSIC_LIBRARY_PATH else False,
                    "song_count": song_count},
        "public_url": {"configured": bool(c.PUBLIC_BASE_URL), "url": c.PUBLIC_BASE_URL},
        "transmission": {"configured": bool(c.TRANSMISSION_URL), "url": c.TRANSMISSION_URL,
                         "auth": bool(c.TRANSMISSION_USER and c.TRANSMISSION_PASS)},
        "prowlarr": {"configured": bool(c.PROWLARR_URL and c.PROWLARR_API_KEY), "url": c.PROWLARR_URL},
        "lidarr": {"configured": bool(c.LIDARR_URL and c.LIDARR_API_KEY), "url": c.LIDARR_URL},
        "essentia": {"configured": bool(c.ESSENTIA_SERVICE_URL), "url": c.ESSENTIA_SERVICE_URL},
        "transcode": {"configured": bool(c.TRANSCODE_SERVICE_URL), "url": c.TRANSCODE_SERVICE_URL},
        "spotify": {"configured": bool(c.SPOTIFY_CLIENT_ID and c.SPOTIFY_CLIENT_SECRET),
                    "playcounts": bool(c.SPOTIFY_SP_DC)},
        "lastfm": {"configured": bool(c.LASTFM_API_KEY)},
        "fanart": {"configured": bool(c.FANART_API_KEY)},
        "podcast_index": {"configured": bool(c.PODCAST_INDEX_KEY and c.PODCAST_INDEX_SECRET)},
        "acoustid": {"configured": bool(c.ACOUSTID_API_KEY)},
        "youtube_cookies": {"configured": bool(c.YT_DLP_COOKIES_FILE or c.YT_DLP_COOKIES_FROM_BROWSER)},
        "cast_device": {"configured": bool(c.CAST_DEVICE_HOST), "host": c.CAST_DEVICE_HOST,
                        "receiver_app": bool(c.CAST_RECEIVER_APP_ID), "wol": bool(c.CAST_DEVICE_WOL_MAC)},
        "denon": {"configured": bool(c.DENON_HOST), "host": c.DENON_HOST},
    }
    try:
        out["essentia"]["reachable"] = bool(check_essentia_service())
    except Exception:
        out["essentia"]["reachable"] = False
    try:
        out["transcode"]["reachable"] = bool(check_transcode_service())
    except Exception:
        out["transcode"]["reachable"] = False
    return jsonify({"services": out, "setup_completed": bool(c.SETUP_COMPLETED)})
