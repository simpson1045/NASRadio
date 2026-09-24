#!/usr/bin/env python3
"""
NASRadio Transcode Service (containerized).

Pre-transcodes lossless music to AAC 320k for mobile cellular playback.
Reads the source files from the music volume, writes to the transcode cache.

This is the env-configurable version destined to run on the NAS via Container
Manager (migrated from the original WSL2 ~/transcode-service copy). All the
formerly-hardcoded config below now reads from the environment, with defaults
matching the original box so it still runs unchanged on the PC if needed.

Only the BATCH pre-transcoder lives here. Latency-critical on-demand transcodes
(cellular cache-miss) stay on the PC backend via local ffmpeg — see
backend/app/routes.py.
"""

import os
import subprocess
import shutil
import time
import threading
import psycopg2
import psycopg2.extras
from flask import Flask, request, jsonify

app = Flask(__name__)

# ─── Configuration (env-overridable; defaults match the original WSL2 box) ────

# PostgreSQL lives on the PC. When this runs on the NAS, set TRANSCODE_DB_HOST
# to the PC's LAN IP and open Postgres to the NAS (listen_addresses + pg_hba +
# firewall — see backend/docker/README.md).
DB_HOST = os.environ.get("TRANSCODE_DB_HOST", "localhost")
DB_PORT = int(os.environ.get("TRANSCODE_DB_PORT", "5432"))
DB_NAME = os.environ.get("TRANSCODE_DB_NAME", "nasradio")
DB_USER = os.environ.get("TRANSCODE_DB_USER", "nasradio")
DB_PASS = os.environ.get("TRANSCODE_DB_PASS", "nasradio")
DB_URL = os.environ.get(
    "TRANSCODE_DB_URL",
    f"postgresql://{DB_USER}:{DB_PASS}@{DB_HOST}:{DB_PORT}/{DB_NAME}",
)

# Path mapping: the DB stores Windows UNC paths (\\host\HDD Music\...) and some
# legacy Docker paths (/music/...). map_path() rewrites both to the local mount.
# UNC is handled generically (any //host/share/ prefix is stripped), so only the
# legacy Docker prefix and the local mount point need to be configurable.
NAS_DOCKER_PREFIX = os.environ.get("TRANSCODE_DB_PATH_PREFIX", "/music")
LOCAL_MUSIC_PREFIX = os.environ.get("TRANSCODE_MUSIC_DIR", "/mnt/music")

# Where transcoded files are cached. On the NAS this is the .transcode_cache
# subdir of the music share, bind-mounted here — shared with the PC's on-demand
# transcoder so both fill the same cache.
CACHE_DIR = os.environ.get("TRANSCODE_CACHE_DIR", "/mnt/transcode_cache")

# Quality presets (match backend/app/routes.py _get_transcode_paths)
QUALITY_PRESETS = {
    "high": {"codec": "aac", "bitrate": "320k", "ext": "m4a"},
    "medium": {"codec": "aac", "bitrate": "128k", "ext": "m4a"},
    "low": {"codec": "libmp3lame", "bitrate": "96k", "ext": "mp3"},
}

# File extensions that DON'T need transcoding (already compressed, suitable for mobile)
PASSTHROUGH_EXTENSIONS = {".mp3", ".m4a", ".aac", ".opus", ".ogg"}

# File extensions that ALWAYS need transcoding (lossless)
LOSSLESS_EXTENSIONS = {".flac", ".wav", ".aiff", ".wv", ".ape", ".dsf", ".dff", ".alac"}

# Max bitrate for passthrough (bits/sec) — files above this get transcoded
MAX_PASSTHROUGH_BITRATE = 320000

# ─── Global state ─────────────────────────────────────────────────────────────

_batch_running = False
_batch_cancel = False
_batch_progress = {
    "status": "idle",
    "current": 0,
    "total": 0,
    "transcoded": 0,
    "skipped": 0,
    "failed": 0,
    "current_song": "",
    "eta": None,
}


# ─── Helper functions ─────────────────────────────────────────────────────────

def map_path(db_path):
    """Convert DB path to local filesystem path.
    Handles both Windows UNC paths and legacy Docker paths."""
    # Windows UNC: \\nas\Music\Artist\... -> /mnt/music/Artist/...
    if db_path.startswith(("\\\\", "//")):
        # Normalize backslashes to forward slashes
        posix_path = db_path.replace("\\", "/")
        # Strip the UNC share prefix
        # //nas/Music/Artist/... -> /Artist/...
        parts = posix_path.split("/", 4)  # ["", "", "host", "share", "rest"]
        if len(parts) >= 5:
            return os.path.join(LOCAL_MUSIC_PREFIX, parts[4])
        return db_path
    # Legacy Docker: /music/Artist/... -> /mnt/music/Artist/...
    if db_path.startswith(NAS_DOCKER_PREFIX):
        return db_path.replace(NAS_DOCKER_PREFIX, LOCAL_MUSIC_PREFIX, 1)
    return db_path


def get_cache_path(song_id, quality="high"):
    """Get the cache file path for a transcoded song."""
    preset = QUALITY_PRESETS.get(quality, QUALITY_PRESETS["high"])
    return os.path.join(CACHE_DIR, f"{song_id}_{quality}_{preset['bitrate']}.{preset['ext']}")


def needs_transcode(file_path, bitrate):
    """Check if a song needs transcoding or can be served as-is."""
    ext = os.path.splitext(file_path)[1].lower()

    # Lossless formats always need transcoding
    if ext in LOSSLESS_EXTENSIONS:
        return True

    # Compressed formats: transcode only if bitrate is too high
    if ext in PASSTHROUGH_EXTENSIONS:
        if bitrate and bitrate > MAX_PASSTHROUGH_BITRATE:
            return True
        return False

    # Unknown format — transcode to be safe
    return True


def transcode_file(input_path, output_path, quality="high"):
    """Transcode a single file to the target quality."""
    preset = QUALITY_PRESETS.get(quality, QUALITY_PRESETS["high"])

    # Write to temp file first, then rename (atomic)
    temp_path = output_path + ".tmp"

    try:
        cmd = [
            "ffmpeg", "-y",
            "-i", input_path,
            "-vn",  # No video
            "-c:a", preset["codec"],
            "-b:a", preset["bitrate"],
        ]

        # Add format and +faststart for M4A (moves moov atom to front for seekability)
        # -f is required because temp file extension (.tmp) isn't recognized by FFmpeg
        if preset["ext"] == "m4a":
            cmd.extend(["-movflags", "+faststart", "-f", "ipod"])
        elif preset["ext"] == "mp3":
            cmd.extend(["-f", "mp3"])

        cmd.append(temp_path)

        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=120,  # 2 minute timeout per song
        )

        if result.returncode != 0:
            # Clean up temp file on failure
            if os.path.exists(temp_path):
                os.remove(temp_path)
            return False, result.stderr[:500]

        # Rename temp to final (atomic on same filesystem)
        os.rename(temp_path, output_path)
        return True, None

    except subprocess.TimeoutExpired:
        if os.path.exists(temp_path):
            os.remove(temp_path)
        return False, "FFmpeg timeout (>120s)"
    except Exception as e:
        if os.path.exists(temp_path):
            os.remove(temp_path)
        return False, str(e)


# ─── Batch processing ────────────────────────────────────────────────────────

def _batch_transcode_worker(quality="high"):
    """Background worker that transcodes all untranscoded songs."""
    global _batch_running, _batch_cancel, _batch_progress

    _batch_running = True
    _batch_cancel = False
    _batch_progress = {
        "status": "running",
        "current": 0,
        "total": 0,
        "transcoded": 0,
        "skipped": 0,
        "failed": 0,
        "current_song": "",
        "eta": None,
    }

    try:
        conn = psycopg2.connect(DB_URL)
        cursor = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

        # Get all songs
        cursor.execute("SELECT id, file_path, bitrate, title, artist_id FROM songs ORDER BY id")
        songs = cursor.fetchall()
        conn.close()

        total = len(songs)
        _batch_progress["total"] = total
        start_time = time.time()

        print(f"🔄 Batch transcode starting: {total} songs to check")

        for i, song in enumerate(songs):
            if _batch_cancel:
                _batch_progress["status"] = "cancelled"
                print("❌ Batch transcode cancelled")
                break

            song_id = song["id"]
            file_path = song["file_path"]
            bitrate = song["bitrate"]
            title = song["title"] or f"Song {song_id}"

            _batch_progress["current"] = i + 1
            _batch_progress["current_song"] = title

            # Calculate ETA
            elapsed = time.time() - start_time
            if i > 0:
                per_song = elapsed / i
                remaining = (total - i) * per_song
                mins = int(remaining // 60)
                secs = int(remaining % 60)
                _batch_progress["eta"] = f"{mins}m {secs}s"

            cache_path = get_cache_path(song_id, quality)

            # Skip if already cached
            if os.path.exists(cache_path):
                _batch_progress["skipped"] += 1
                continue

            # Skip if doesn't need transcoding
            if not needs_transcode(file_path, bitrate):
                _batch_progress["skipped"] += 1
                continue

            # Map path and check source exists
            local_path = map_path(file_path)
            if not os.path.exists(local_path):
                print(f"⚠️ File not found: {local_path} (song {song_id})")
                _batch_progress["failed"] += 1
                continue

            # Transcode
            success, error = transcode_file(local_path, cache_path, quality)
            if success:
                size_mb = os.path.getsize(cache_path) / (1024 * 1024)
                _batch_progress["transcoded"] += 1
                if _batch_progress["transcoded"] % 100 == 0:
                    print(f"✅ Progress: {_batch_progress['transcoded']} transcoded, "
                          f"{_batch_progress['skipped']} skipped, "
                          f"{_batch_progress['failed']} failed "
                          f"({i + 1}/{total})")
            else:
                print(f"❌ Failed: {title} (song {song_id}): {error}")
                _batch_progress["failed"] += 1

        if not _batch_cancel:
            _batch_progress["status"] = "complete"
            elapsed = time.time() - start_time
            mins = int(elapsed // 60)
            print(f"✅ Batch transcode complete in {mins}m: "
                  f"{_batch_progress['transcoded']} transcoded, "
                  f"{_batch_progress['skipped']} skipped, "
                  f"{_batch_progress['failed']} failed")

    except Exception as e:
        _batch_progress["status"] = "failed"
        _batch_progress["current_song"] = str(e)
        print(f"❌ Batch transcode error: {e}")

    finally:
        _batch_running = False


# ─── API Endpoints ────────────────────────────────────────────────────────────

@app.route("/health", methods=["GET", "POST"])
def health():
    """Health check endpoint."""
    ffmpeg_path = shutil.which("ffmpeg")
    music_ok = os.path.isdir(LOCAL_MUSIC_PREFIX)
    cache_ok = os.path.isdir(CACHE_DIR)

    return jsonify({
        "status": "ok",
        "ffmpeg": ffmpeg_path is not None,
        "music_mount": music_ok,
        "cache_mount": cache_ok,
        "batch_running": _batch_running,
    })


@app.route("/transcode", methods=["POST"])
def transcode_single():
    """Transcode a single song."""
    data = request.get_json()
    if not data:
        return jsonify({"error": "No JSON body"}), 400

    song_id = data.get("song_id")
    file_path = data.get("file_path")
    quality = data.get("quality", "high")

    if not song_id or not file_path:
        return jsonify({"error": "song_id and file_path required"}), 400

    cache_path = get_cache_path(song_id, quality)

    # Already cached?
    if os.path.exists(cache_path):
        return jsonify({
            "status": "already_cached",
            "song_id": song_id,
            "cache_path": cache_path,
            "size": os.path.getsize(cache_path),
        })

    # Doesn't need transcoding?
    bitrate = data.get("bitrate", 0)
    if not needs_transcode(file_path, bitrate):
        return jsonify({
            "status": "passthrough",
            "song_id": song_id,
            "message": "File format suitable for direct playback",
        })

    # Transcode
    local_path = map_path(file_path)
    if not os.path.exists(local_path):
        return jsonify({"error": f"File not found: {local_path}"}), 404

    start = time.time()
    success, error = transcode_file(local_path, cache_path, quality)
    elapsed = time.time() - start

    if success:
        size = os.path.getsize(cache_path)
        print(f"✅ Transcoded song {song_id} in {elapsed:.1f}s ({size / 1024 / 1024:.1f}MB)")
        return jsonify({
            "status": "transcoded",
            "song_id": song_id,
            "cache_path": cache_path,
            "size": size,
            "elapsed": round(elapsed, 2),
        })
    else:
        return jsonify({
            "status": "failed",
            "song_id": song_id,
            "error": error,
        }), 500


@app.route("/transcode-all", methods=["POST"])
def transcode_all():
    """Start batch transcoding of all untranscoded songs."""
    global _batch_running

    if _batch_running:
        return jsonify({
            "status": "already_running",
            "progress": _batch_progress,
        })

    quality = request.get_json().get("quality", "high") if request.get_json() else "high"

    thread = threading.Thread(target=_batch_transcode_worker, args=(quality,), daemon=True)
    thread.start()

    return jsonify({"status": "started", "message": "Batch transcode started"})


@app.route("/transcode-status", methods=["GET"])
def transcode_status():
    """Get current batch transcode progress."""
    return jsonify(_batch_progress)


@app.route("/transcode-cancel", methods=["POST"])
def transcode_cancel():
    """Cancel running batch transcode."""
    global _batch_cancel

    if not _batch_running:
        return jsonify({"status": "not_running"})

    _batch_cancel = True
    return jsonify({"status": "cancelling"})


# ─── Main ─────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    print("🎵 NASRadio Transcode Service")
    print(f"   Music: {LOCAL_MUSIC_PREFIX} ({'OK' if os.path.isdir(LOCAL_MUSIC_PREFIX) else 'NOT FOUND'})")
    print(f"   Cache: {CACHE_DIR} ({'OK' if os.path.isdir(CACHE_DIR) else 'NOT FOUND'})")
    print(f"   FFmpeg: {shutil.which('ffmpeg') or 'NOT FOUND'}")
    print(f"   DB: {DB_HOST}:{DB_PORT}/{DB_NAME}")
    print()

    app.run(host="0.0.0.0", port=5006, debug=False)
