import os
import secrets
from dotenv import load_dotenv

from app.settings import Setting

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Load .env file from backend directory
load_dotenv(os.path.join(BACKEND_DIR, '.env'))


def cors_allowed_origins(defaults):
    """Resolve the CORS origin list for browser/Socket.IO clients.

    CORS_ALLOWED_ORIGINS in .env (comma-separated, or "*") replaces the
    built-in defaults entirely — self-hosters list their own hostnames
    there. Unset = the defaults passed by the caller.
    """
    env = os.environ.get("CORS_ALLOWED_ORIGINS", "").strip()
    if env == "*":
        return "*"
    if env:
        return [o.strip() for o in env.split(",") if o.strip()]
    return defaults


def user_agent():
    """User-Agent for MusicBrainz & friends: identifies the app and, when the
    admin has set a contact email in settings, who to talk to."""
    email = Config.CONTACT_EMAIL
    contact = f"; {email}" if email else ""
    return f"NASRadio/1.0 (https://github.com/simpson1045/NASRadio{contact})"


_DEFAULT_SECRET = "dev-secret-key-change-in-production"


def _data_dir():
    """Writable per-install data folder (backend/data, /app/data in Docker)."""
    p = os.environ.get("DATABASE_PATH")
    if p:
        return os.path.dirname(os.path.abspath(p))
    return os.path.join(BACKEND_DIR, "data")


def _load_secret_key():
    """SECRET_KEY signs every login token. Precedence: SECRET_KEY env var, then
    a key persisted in data/secret_key, else generate one and persist it. The
    old public default is never accepted — with it anyone could forge tokens."""
    env = os.environ.get("SECRET_KEY", "").strip()
    if env and env != _DEFAULT_SECRET:
        return env
    path = os.path.join(_data_dir(), "secret_key")
    try:
        with open(path, "r", encoding="utf-8") as f:
            key = f.read().strip()
        if key:
            return key
    except FileNotFoundError:
        pass
    except OSError as e:
        print(f"⚠️ Could not read {path}: {e}")
    key = secrets.token_urlsafe(48)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(key + "\n")
        print(f"🔐 SECRET_KEY not set — generated one and saved it to {path}")
    except OSError as e:
        print(f"⚠️ SECRET_KEY not set and {path} not writable ({e}); "
              f"using a temporary key — all logins reset on restart")
    return key


class Config:
    """Configuration for the NASRadio backend.

    Plain attributes are bootstrap values read once from env/.env. `Setting(...)`
    attributes are live: they resolve through app.settings (database override,
    then env, then default) on every access, so admin changes apply without a
    restart. The schema, defaults and env names live in app/settings.py.
    """

    # ── Bootstrap (env only) ───────────────────────────────────────────
    SECRET_KEY = _load_secret_key()
    DEBUG = os.environ.get("DEBUG", "false").lower() == "true"

    DATA_DIR = _data_dir()
    # Legacy SQLite path; still anchors waveforms/ and youtube_staging/ under data/
    DATABASE_PATH = os.environ.get("DATABASE_PATH") or os.path.join(DATA_DIR, "nasradio.db")
    DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://nasradio:nasradio@localhost:5432/nasradio")

    HOST = os.environ.get("HOST", "0.0.0.0")
    try:
        PORT = int(os.environ.get("PORT", "5002"))
    except ValueError:
        PORT = 5002

    # ── Library ────────────────────────────────────────────────────────
    MUSIC_LIBRARY_PATH = Setting("MUSIC_LIBRARY_PATH")
    DOWNLOADS_NASRADIO = Setting("DOWNLOADS_NASRADIO")
    DOWNLOADS_LIDARR = Setting("DOWNLOADS_LIDARR")

    class _Derived:
        def __init__(self, fn):
            self.fn = fn

        def __get__(self, obj, owner=None):
            return self.fn()

    DOWNLOADS_ALLOWED = _Derived(lambda: [Config.DOWNLOADS_NASRADIO, Config.DOWNLOADS_LIDARR])
    # Default: a Podcasts folder inside the music library
    PODCAST_DOWNLOAD_DIR = _Derived(
        lambda: Setting("PODCAST_DOWNLOAD_DIR").__get__(None) or os.path.join(Config.MUSIC_LIBRARY_PATH, "Podcasts")
    )

    # Supported audio formats
    SUPPORTED_FORMATS = [
        ".mp3",
        ".flac",
        ".m4a",
        ".ogg",
        ".wav",
        ".aac",
        ".opus",
        ".wv",
        ".ape",
        ".aiff",
        ".dsf",
        ".dff",
    ]

    # Album artwork
    ARTWORK_FOLDER = "artwork"
    ARTWORK_FORMATS = [
        "folder.jpg",
        "folder.png",
        "cover.jpg",
        "cover.png",
        "album.jpg",
        "album.png",
    ]

    # ── Server identity ────────────────────────────────────────────────
    PUBLIC_BASE_URL = Setting("PUBLIC_BASE_URL")
    CONTACT_EMAIL = Setting("CONTACT_EMAIL")
    SETUP_COMPLETED = Setting("SETUP_COMPLETED")

    # ── External services & API keys (all optional) ────────────────────
    SPOTIFY_CLIENT_ID = Setting("SPOTIFY_CLIENT_ID")
    SPOTIFY_CLIENT_SECRET = Setting("SPOTIFY_CLIENT_SECRET")
    SPOTIFY_SP_DC = Setting("SPOTIFY_SP_DC")

    LIDARR_URL = Setting("LIDARR_URL")
    LIDARR_API_KEY = Setting("LIDARR_API_KEY")

    PROWLARR_URL = Setting("PROWLARR_URL")
    PROWLARR_API_KEY = Setting("PROWLARR_API_KEY")
    # Indexer tiering is resolved by NAME at request time, not by hardcoded
    # numeric IDs — Prowlarr renumbers indexers whenever one is removed/re-added,
    # so baked-in IDs silently rot. "Deep" = the slow-but-deep-catalog trackers
    # kept OFF the default fast search and exposed behind the app's opt-in
    # "Also search RuTracker" button. Matched case-insensitively as a substring
    # of the indexer name. See ProwlarrClient.fast_indexer_ids()/.deep_indexer_ids().
    PROWLARR_DEEP_INDEXER_NAMES = ["rutracker"]

    TRANSMISSION_URL = Setting("TRANSMISSION_URL")
    TRANSMISSION_USER = Setting("TRANSMISSION_USER")
    TRANSMISSION_PASS = Setting("TRANSMISSION_PASS")
    # Download dir as Transmission sees it (inside its own container)
    TRANSMISSION_DOWNLOAD_DIR = Setting("TRANSMISSION_DOWNLOAD_DIR")

    # Auto-restart: when Transmission is unreachable, SSH into the host
    # running it and bounce its docker-compose stack, then retry the request
    # once. Synology-era feature — default OFF; enable only with NAS_SSH_*
    # set for a host where this restart recipe actually applies. Env only.
    TRANSMISSION_AUTO_RESTART = os.environ.get("TRANSMISSION_AUTO_RESTART", "false").lower() == "true"
    NAS_SSH_HOST = os.environ.get("NAS_SSH_HOST", "")
    NAS_SSH_PORT = int(os.environ.get("NAS_SSH_PORT", "22"))
    NAS_SSH_USER = os.environ.get("NAS_SSH_USER", "")
    NAS_SSH_PASSWORD = os.environ.get("NAS_SSH_PASSWORD", "")
    TRANSMISSION_COMPOSE_DIR = os.environ.get("TRANSMISSION_COMPOSE_DIR", "/docker/transmission")
    TRANSMISSION_RESTART_USE_SUDO = os.environ.get("TRANSMISSION_RESTART_USE_SUDO", "true").lower() == "true"
    TRANSMISSION_RESTART_COOLDOWN = int(os.environ.get("TRANSMISSION_RESTART_COOLDOWN", "90"))

    # RSS / Podcast settings
    RSS_REFRESH_INTERVAL = 1800  # 30 minutes
    PODCAST_INDEX_KEY = Setting("PODCAST_INDEX_KEY")
    PODCAST_INDEX_SECRET = Setting("PODCAST_INDEX_SECRET")

    # Artwork source APIs — register your own free keys
    # (https://www.last.fm/api, https://fanart.tv/get-an-api-key).
    LASTFM_API_KEY = Setting("LASTFM_API_KEY")
    FANART_API_KEY = Setting("FANART_API_KEY")
    ACOUSTID_API_KEY = Setting("ACOUSTID_API_KEY")

    # Sidecar services (optional). When unreachable, analysis-driven features
    # stay dormant and transcoding falls back to local ffmpeg.
    ESSENTIA_SERVICE_URL = Setting("ESSENTIA_SERVICE_URL")
    TRANSCODE_SERVICE_URL = Setting("TRANSCODE_SERVICE_URL")

    # yt-dlp YouTube cookies (age-gated videos). File takes precedence.
    # File: Netscape-format cookies.txt exported from a browser.
    # Browser: a browser name (chrome, firefox, edge, ...); yt-dlp reads its
    # profile directly — reliable with Firefox, fragile with Chromium on Windows.
    YT_DLP_COOKIES_FILE = Setting("YT_DLP_COOKIES_FILE")
    YT_DLP_COOKIES_FROM_BROWSER = Setting("YT_DLP_COOKIES_FROM_BROWSER")

    # ── Headless cast sender / living room ─────────────────────────────
    CAST_DEVICE_HOST = Setting("CAST_DEVICE_HOST")
    CAST_DEVICE_WOL_MAC = Setting("CAST_DEVICE_WOL_MAC")
    CAST_WOL_BROADCAST = Setting("CAST_WOL_BROADCAST")
    CAST_RECEIVER_APP_ID = Setting("CAST_RECEIVER_APP_ID")
    DENON_HOST = Setting("DENON_HOST")
    DENON_TELNET_PORT = Setting("DENON_TELNET_PORT")
    DENON_INPUT_CMD = Setting("DENON_INPUT_CMD")

    # Podcast refactor feature flag (Phase 3 of PODCAST_REFACTOR_PLAN.md).
    # When True: player and UI query the unified `songs` table for podcast
    # episodes (new path, no negative IDs, chapter-aware).
    PODCAST_UNIFIED_MODEL = os.environ.get("PODCAST_UNIFIED_MODEL", "false").lower() == "true"

    # Public trackers to inject into magnet links for better peer discovery
    PUBLIC_TRACKERS = [
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.tracker.cl:1337/announce",
        "udp://tracker.openbittorrent.com:6969/announce",
        "udp://open.stealth.si:80/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://exodus.desync.com:6969/announce",
        "udp://tracker.tiny-vps.com:6969/announce",
        "http://tracker.opentrackr.org:1337/announce",
        "udp://explodie.org:6969/announce",
        "udp://tracker.moeking.me:6969/announce",
        "udp://tracker1.bt.moack.co.kr:80/announce",
        "udp://tracker.theoks.net:6969/announce",
    ]
