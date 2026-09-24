"""Centralized path mapping for NASRadio.

Handles conversion between three path formats:
  - Library path: MUSIC_LIBRARY_PATH (Windows UNC share, or local dir on Linux)
  - Docker/NAS:   /music/Artist/Album/Song.flac
  - Sidecar mount: /mnt/music/Artist/Album/Song.flac (Essentia/transcode services)
"""

import os

from app.config import Config

# The library root is read live from Config.MUSIC_LIBRARY_PATH (a runtime
# setting), never snapshotted here, so a path change applies without restart.

# Legacy library prefixes still baked into old DB song rows from before a
# library move (e.g. an old NAS share name). Rows starting with any of these
# keep mapping to the sidecar mount until a path migration rewrites them.
# LEGACY_LIBRARY_PREFIXES in .env, comma-separated; empty for fresh installs.
LEGACY_UNC_PREFIXES = [
    p.strip() for p in os.environ.get("LEGACY_LIBRARY_PREFIXES", "").split(",") if p.strip()
]

# WSL2 CIFS mount used by Essentia and transcode services
WSL2_MUSIC_MOUNT = "/mnt/music"

# Legacy Docker container mount
DOCKER_MUSIC_MOUNT = "/music"


# Is the configured library a POSIX path (Linux/container) rather than a
# Windows UNC share or drive path? Decides which separator conversions apply.
def _lib_is_posix():
    return Config.MUSIC_LIBRARY_PATH.startswith("/")


def map_docker_to_windows(file_path):
    """Convert legacy Docker path (/music/...) to the configured library path.

    Windows library:  /music/Artist/Song.flac -> \\\\nas\\Music\\Artist\\Song.flac
    Linux library:    /music/Artist/Song.flac -> <MUSIC_LIBRARY_PATH>/Artist/Song.flac
                      (pass-through when the library IS /music)
    """
    normalized = file_path.replace("\\", "/")
    if normalized.startswith("/music"):
        relative = normalized[len("/music"):]
        lib = Config.MUSIC_LIBRARY_PATH
        if _lib_is_posix():
            return lib.rstrip("/") + relative
        return lib + relative.replace("/", "\\")
    return file_path


def map_to_wsl2(file_path, target_mount=WSL2_MUSIC_MOUNT):
    """Convert any path format to WSL2 CIFS mount path.

    Handles legacy Synology-era UNC prefixes (hostname AND raw-IP forms
    still present in older DB rows) and legacy Docker paths.
    """
    normalized = file_path.replace("\\", "/")

    for prefix in LEGACY_UNC_PREFIXES:
        normalized_prefix = prefix.replace("\\", "/")
        if normalized.startswith(normalized_prefix):
            return normalized.replace(normalized_prefix, target_mount, 1)

    if normalized.startswith("/music"):
        return normalized.replace("/music", target_mount, 1)
    return file_path


def ensure_windows_path(file_path):
    """Map legacy Docker /music/ paths onto the configured library path.

    Despite the historical name, this is host-aware: on a Windows host it
    yields a UNC path; on Linux (library at /music) it's a pass-through
    with forward slashes preserved. Non-/music paths always pass through.
    """
    if not file_path:
        return file_path
    normalized = file_path.replace("\\", "/")
    if normalized.startswith("/music"):
        return map_docker_to_windows(normalized if _lib_is_posix() else file_path)
    return file_path
