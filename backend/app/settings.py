"""Runtime settings store.

Every user-facing setting (library path, download client, indexer, API
keys, cast device, public URL ...) resolves in this order:

    1. `app_settings` table in Postgres  — set from the admin UI/API
    2. environment / .env                — the classic self-hoster path
    3. the default in SCHEMA below

Values are read live through the `Setting` descriptors on `Config`, so a
change made through the API takes effect without a restart. The DB read is
cached for a few seconds and falls back to env/defaults when the database
is unreachable (startup, migrations), so importing this module never blocks.

Bootstrap-only values (SECRET_KEY, DATABASE_URL, HOST, PORT, CORS) stay
env-only in config.py — you can't store the database URL in the database.
"""

import os
import time

# type: str | url | path | int | bool. `secret` values are masked by the API.
SCHEMA = [
    # ── Library ────────────────────────────────────────────────────────
    dict(key="MUSIC_LIBRARY_PATH", env="MUSIC_LIBRARY_PATH", default="/music", type="path",
         group="library", label="Music library folder",
         help="Root folder the scanner walks. Inside Docker this is the /music bind mount."),
    dict(key="PODCAST_DOWNLOAD_DIR", env="PODCAST_DOWNLOAD_DIR", default="", type="path",
         group="library", label="Podcast download folder",
         help="Empty = a Podcasts folder inside the music library."),
    dict(key="DOWNLOADS_NASRADIO", env="DOWNLOADS_NASRADIO", default="/downloads/complete/nasradio", type="path",
         group="library", label="Finished downloads folder (NASRadio)",
         help="Where the import queue looks for completed torrents, as this server sees it."),
    dict(key="DOWNLOADS_LIDARR", env="DOWNLOADS_LIDARR", default="/downloads/complete/lidarr", type="path",
         group="library", label="Finished downloads folder (Lidarr)"),

    # ── Server ─────────────────────────────────────────────────────────
    dict(key="PUBLIC_BASE_URL", env="PUBLIC_BASE_URL", default="", type="url",
         group="server", label="Public base URL",
         help="How this server is reached from outside (https://music.example.com). "
              "Used in cast stream URLs, party join links/QR codes and the MusicBrainz callback."),
    dict(key="CONTACT_EMAIL", env="CONTACT_EMAIL", default="", type="str",
         group="server", label="Contact email",
         help="Sent in the User-Agent to MusicBrainz and other APIs that ask for a contact."),
    # Set by the app's first-run wizard when the admin finishes (or skips) it,
    # so no other admin device is shown the wizard again. Not a user-facing
    # field; the settings UI hides `internal` entries.
    dict(key="SETUP_COMPLETED", env="SETUP_COMPLETED", default="false", type="bool",
         group="server", label="Setup wizard completed", internal=True),

    # ── Downloads ──────────────────────────────────────────────────────
    dict(key="TRANSMISSION_URL", env="TRANSMISSION_URL", default="http://localhost:9091", type="url",
         group="downloads", label="Transmission URL"),
    dict(key="TRANSMISSION_USER", env="TRANSMISSION_USER", default="", type="str",
         group="downloads", label="Transmission username"),
    dict(key="TRANSMISSION_PASS", env="TRANSMISSION_PASS", default="", type="str", secret=True,
         group="downloads", label="Transmission password"),
    dict(key="TRANSMISSION_DOWNLOAD_DIR", env="TRANSMISSION_DOWNLOAD_DIR", default="/downloads/complete/nasradio",
         type="path", group="downloads", label="Transmission download folder",
         help="The download folder as Transmission itself sees it (inside its container)."),
    dict(key="PROWLARR_URL", env="PROWLARR_URL", default="http://localhost:9696", type="url",
         group="downloads", label="Prowlarr URL"),
    dict(key="PROWLARR_API_KEY", env="PROWLARR_API_KEY", default="", type="str", secret=True,
         group="downloads", label="Prowlarr API key"),
    dict(key="LIDARR_URL", env="LIDARR_URL", default="http://localhost:8686", type="url",
         group="downloads", label="Lidarr URL"),
    dict(key="LIDARR_API_KEY", env="LIDARR_API_KEY", default="", type="str", secret=True,
         group="downloads", label="Lidarr API key"),

    # ── Metadata & external APIs ───────────────────────────────────────
    dict(key="SPOTIFY_CLIENT_ID", env="SPOTIFY_CLIENT_ID", default="", type="str",
         group="metadata", label="Spotify client ID"),
    dict(key="SPOTIFY_CLIENT_SECRET", env="SPOTIFY_CLIENT_SECRET", default="", type="str", secret=True,
         group="metadata", label="Spotify client secret"),
    dict(key="SPOTIFY_SP_DC", env="SPOTIFY_SP_DC", default="", type="str", secret=True,
         group="metadata", label="Spotify sp_dc cookie",
         help="Unofficial; only needed for Spotify play counts."),
    dict(key="PODCAST_INDEX_KEY", env="PODCAST_INDEX_KEY", default="", type="str",
         group="metadata", label="Podcast Index key"),
    dict(key="PODCAST_INDEX_SECRET", env="PODCAST_INDEX_SECRET", default="", type="str", secret=True,
         group="metadata", label="Podcast Index secret"),
    dict(key="LASTFM_API_KEY", env="LASTFM_API_KEY", default="", type="str",
         group="metadata", label="Last.fm API key (artwork)",
         help="Free key from https://www.last.fm/api. Scrobbling is configured separately."),
    dict(key="FANART_API_KEY", env="FANART_API_KEY", default="", type="str",
         group="metadata", label="fanart.tv API key",
         help="Free key from https://fanart.tv/get-an-api-key."),
    dict(key="ACOUSTID_API_KEY", env="ACOUSTID_API_KEY", default="", type="str",
         group="metadata", label="AcoustID API key"),

    # ── Sidecar services ───────────────────────────────────────────────
    dict(key="ESSENTIA_SERVICE_URL", env="ESSENTIA_SERVICE_URL", default="http://127.0.0.1:5005", type="url",
         group="services", label="Essentia analysis service URL"),
    dict(key="TRANSCODE_SERVICE_URL", env="NASRADIO_TRANSCODE_URL", default="http://127.0.0.1:5006", type="url",
         group="services", label="Transcode service URL"),

    # ── YouTube ────────────────────────────────────────────────────────
    dict(key="YT_DLP_COOKIES_FILE", env="YT_DLP_COOKIES_FILE", default="", type="path",
         group="youtube", label="yt-dlp cookies file"),
    dict(key="YT_DLP_COOKIES_FROM_BROWSER", env="YT_DLP_COOKIES_FROM_BROWSER", default="", type="str",
         group="youtube", label="yt-dlp cookies from browser"),

    # ── Cast / living room (headless cast sender) ──────────────────────
    dict(key="CAST_DEVICE_HOST", env="CAST_DEVICE_HOST", default="", type="str",
         group="cast", label="Default cast device (IP or hostname)"),
    dict(key="CAST_DEVICE_WOL_MAC", env="CAST_DEVICE_WOL_MAC", default="", type="str",
         group="cast", label="Cast device Wake-on-LAN MAC",
         help="Empty = don't try to wake the TV."),
    dict(key="CAST_WOL_BROADCAST", env="CAST_WOL_BROADCAST", default="", type="str",
         group="cast", label="Extra WOL broadcast address",
         help="Your LAN broadcast (e.g. 192.168.1.255). 255.255.255.255 is always tried."),
    dict(key="CAST_RECEIVER_APP_ID", env="CAST_RECEIVER_APP_ID", default="", type="str",
         group="cast", label="Cast receiver app ID",
         help="Your registered Cast application ID whose receiver URL is <Public base URL>/cast/receiver.html."),
    dict(key="DENON_HOST", env="DENON_HOST", default="", type="str",
         group="cast", label="Denon/Marantz receiver IP",
         help="Empty = no AV receiver control."),
    dict(key="DENON_TELNET_PORT", env="DENON_TELNET_PORT", default="23", type="int",
         group="cast", label="Denon telnet port"),
    dict(key="DENON_INPUT_CMD", env="DENON_INPUT_CMD", default="SITV", type="str",
         group="cast", label="Denon input command for the TV",
         help="Raw telnet command selecting the input the TV's audio arrives on (SITV = TV Audio/eARC)."),
]

BY_KEY = {s["key"]: s for s in SCHEMA}

_CACHE_TTL = 15  # seconds
_cache = None
_cache_at = 0.0
_warned = False
_db = None


def _get_db():
    global _db
    if _db is None:
        from app.config import Config      # import here: config imports us
        from app.models import Database
        _db = Database(Config.DATABASE_URL)
    return _db


def _load():
    """All rows of app_settings as {key: value}; cached; never raises."""
    global _cache, _cache_at, _warned
    now = time.time()
    if _cache is not None and now - _cache_at < _CACHE_TTL:
        return _cache
    try:
        db = _get_db()
        conn = db.get_connection()
        try:
            cur = db.get_cursor(conn)
            cur.execute("SELECT key, value FROM app_settings")
            _cache = {r["key"]: r["value"] for r in cur.fetchall()}
        finally:
            conn.close()
        _warned = False
    except Exception as e:
        if not _warned:
            print(f"⚠️ settings: app_settings unavailable ({e}); using .env values")
            _warned = True
        if _cache is None:
            _cache = {}
    _cache_at = now
    return _cache


def invalidate():
    global _cache_at
    _cache_at = 0.0


def _cast(raw, kind, default):
    if raw is None:
        raw = default
    if kind == "bool":
        return str(raw).strip().lower() in ("1", "true", "yes", "on")
    if kind == "int":
        try:
            return int(str(raw).strip())
        except (TypeError, ValueError):
            return int(default)
    value = str(raw).strip()
    if kind == "url":
        value = value.rstrip("/")
    return value


def resolve(key):
    """Effective value for `key`: DB, then env, then default."""
    spec = BY_KEY[key]
    stored = _load()
    if key in stored:
        raw = stored[key]
    else:
        raw = os.environ.get(spec["env"]) if spec.get("env") else None
    return _cast(raw, spec["type"], spec["default"])


def source_of(key):
    """Where the effective value comes from: 'db', 'env' or 'default'."""
    spec = BY_KEY[key]
    if key in _load():
        return "db"
    if spec.get("env") and os.environ.get(spec["env"]) is not None:
        return "env"
    return "default"


def set_value(key, value):
    """Store an override in the database (value None/"" is stored as "")."""
    if key not in BY_KEY:
        raise KeyError(key)
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute(
            """
            INSERT INTO app_settings (key, value, updated_at)
            VALUES (%s, %s, CURRENT_TIMESTAMP)
            ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = CURRENT_TIMESTAMP
            """,
            (key, "" if value is None else str(value)),
        )
        conn.commit()
    finally:
        conn.close()
    invalidate()


def reset_value(key):
    """Drop the database override so env/default applies again."""
    if key not in BY_KEY:
        raise KeyError(key)
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute("DELETE FROM app_settings WHERE key = %s", (key,))
        conn.commit()
    finally:
        conn.close()
    invalidate()


def describe():
    """Every setting with its effective value (secrets masked) and source.
    This is what the admin settings API returns."""
    out = []
    for spec in SCHEMA:
        value = resolve(spec["key"])
        item = {
            "key": spec["key"],
            "group": spec["group"],
            "label": spec["label"],
            "help": spec.get("help", ""),
            "type": spec["type"],
            "secret": bool(spec.get("secret")),
            "internal": bool(spec.get("internal")),
            "source": source_of(spec["key"]),
            "default": spec["default"],
        }
        if spec.get("secret") and value:
            item["value"] = ""
            item["is_set"] = True
        else:
            item["value"] = value
            item["is_set"] = bool(value)
        out.append(item)
    return out


class Setting:
    """Descriptor: `Config.KEY` / `Config().KEY` -> resolve(KEY), live."""

    def __init__(self, key):
        if key not in BY_KEY:
            raise KeyError(f"unknown setting {key}")
        self.key = key

    def __get__(self, obj, owner=None):
        return resolve(self.key)

    def __set__(self, obj, value):
        raise AttributeError(f"use app.settings.set_value({self.key!r}, ...)")
