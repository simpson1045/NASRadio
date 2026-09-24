"""
NAS-side transcode module.
Triggers the desktop transcode service (i9-11900 in WSL2) to pre-transcode
lossless music to AAC 320k for mobile cellular playback.
Modeled after audio_analysis.py / Essentia integration.
"""

import os
import time
import requests
import eventlet
from app.extensions import safe_emit

# Transcode service URL — Config.TRANSCODE_SERVICE_URL (runtime setting;
# env NASRADIO_TRANSCODE_URL), read live so a change applies without restart.
from app.config import Config

# Path mapping via shared utility
from app.path_utils import map_to_wsl2, WSL2_MUSIC_MOUNT

# Track whether the polling greenthread is already running
_polling_active = False


def map_path_for_transcode(file_path):
    """Convert local file path to transcode WSL2 service path."""
    return map_to_wsl2(file_path, WSL2_MUSIC_MOUNT)


def _emit_transcode_progress(current, total, message, status="running",
                             eta=None, transcoded=0, skipped=0, failed=0,
                             current_song=""):
    """Emit websocket progress event for transcoding."""
    safe_emit("transcode_progress", {
        "current": current,
        "total": total,
        "message": message,
        "status": status,
        "eta": eta,
        "transcoded": transcoded,
        "skipped": skipped,
        "failed": failed,
        "current_song": current_song,
    })


def check_transcode_service():
    """Check if the desktop transcode service is running.

    Timeout sized for WSL2 networking jitter. /api/health polls this
    every 30s and the Flutter client gives up after 5s total. A slow
    sidecar should not cause a false "server unreachable" banner on
    the main app.

    Previously 1.5s, which spammed "read timeout" warnings in normal
    operation when WSL2 was momentarily busy (2026-05-25 — simpson1045 saw
    "shit ton" of `read timeout` lines even though the service was
    actually up and the UI showed it online). 5s gives WSL2 room to
    breathe without making the health probe feel sluggish.

    Failure modes used to be silently swallowed (return False, no
    log). That made "service is up on my desktop but the app says
    it's not working" undebuggable. Now we log the specific failure
    once per type so the user can see whether it's a connection
    refused, a timeout, a bad status code, or an unexpected body.
    """
    try:
        response = requests.get(f"{Config.TRANSCODE_SERVICE_URL}/health", timeout=5)
        if response.status_code == 200:
            data = response.json()
            ok = data.get("status") == "ok"
            if not ok:
                print(
                    f"[transcode] health: 200 but body says status="
                    f"{data.get('status')!r} (url={Config.TRANSCODE_SERVICE_URL})"
                )
            return ok
        print(
            f"[transcode] health: HTTP {response.status_code} "
            f"(url={Config.TRANSCODE_SERVICE_URL})"
        )
        return False
    except requests.exceptions.ConnectTimeout:
        print(
            f"[transcode] health: connect timeout "
            f"(url={Config.TRANSCODE_SERVICE_URL}) — desktop firewall or routing?"
        )
        return False
    except requests.exceptions.ConnectionError as e:
        # Most common cause when the user says "service is up but app
        # can't reach it": LAN segmentation, Windows Firewall blocking
        # inbound 5006, or service bound to 127.0.0.1 not 0.0.0.0.
        print(
            f"[transcode] health: connection error "
            f"(url={Config.TRANSCODE_SERVICE_URL}): {e}"
        )
        return False
    except requests.exceptions.Timeout:
        print(
            f"[transcode] health: read timeout "
            f"(url={Config.TRANSCODE_SERVICE_URL})"
        )
        return False
    except ValueError as e:
        print(f"[transcode] health: non-JSON body: {e}")
        return False
    except Exception as e:
        print(f"[transcode] health: unexpected error: {type(e).__name__}: {e}")
        return False


def transcode_song(song_id, file_path, quality="high", is_hdcd=False):
    """Transcode a single song via the desktop service.
    Non-blocking from the caller's perspective when used with eventlet.spawn_n.
    """
    try:
        response = requests.post(
            f"{Config.TRANSCODE_SERVICE_URL}/transcode",
            json={
                "song_id": song_id,
                "file_path": map_path_for_transcode(file_path),
                "quality": quality,
                "is_hdcd": is_hdcd,
            },
            timeout=180,  # 3 min timeout (most songs transcode in 1-2s)
        )

        if response.status_code == 200:
            data = response.json()
            status = data.get("status")
            if status == "transcoded":
                print(f"[transcode] Song {song_id}: transcoded in {data.get('elapsed', '?')}s")
            elif status == "already_cached":
                pass  # Already done, no need to log
            elif status == "passthrough":
                pass  # Format suitable for direct playback
            return data
        else:
            print(f"[transcode] Song {song_id}: service returned {response.status_code}")
            return None
    except requests.exceptions.Timeout:
        print(f"[transcode] Song {song_id}: timeout")
        return None
    except requests.exceptions.ConnectionError:
        print(f"[transcode] Song {song_id}: desktop service not reachable")
        return None
    except Exception as e:
        print(f"[transcode] Song {song_id}: error: {e}")
        return None


def _ensure_polling():
    """Start the polling greenthread if a batch is running and polling isn't active."""
    global _polling_active
    if _polling_active:
        return
    try:
        status = get_transcode_status()
        if status and status.get("status") == "running":
            eventlet.spawn_n(_poll_transcode_progress)
    except Exception:
        pass


def _poll_transcode_progress():
    """Poll the desktop transcode service for progress and emit WebSocket updates.
    Runs in an eventlet greenthread, polls every 2 seconds until batch completes.
    """
    global _polling_active
    _polling_active = True
    try:
        while True:
            eventlet.sleep(2)
            try:
                status = get_transcode_status()
                if not status:
                    break

                batch_status = status.get("status", "idle")
                current = status.get("current", 0)
                total = status.get("total", 0)
                transcoded = status.get("transcoded", 0)
                skipped = status.get("skipped", 0)
                failed = status.get("failed", 0)
                current_song = status.get("current_song", "")
                eta = status.get("eta")

                if batch_status == "running":
                    msg = f"Transcoding: {current_song}" if current_song else f"Transcoding {current}/{total}..."
                    _emit_transcode_progress(
                        current, total, msg, "running",
                        eta=eta, transcoded=transcoded, skipped=skipped,
                        failed=failed, current_song=current_song,
                    )
                elif batch_status == "complete":
                    _emit_transcode_progress(
                        total, total,
                        f"Complete! {transcoded} transcoded, {skipped} skipped, {failed} failed",
                        "complete", transcoded=transcoded, skipped=skipped, failed=failed,
                    )
                    break
                elif batch_status == "cancelled":
                    _emit_transcode_progress(
                        current, total, "Cancelled", "cancelled",
                        transcoded=transcoded, skipped=skipped, failed=failed,
                    )
                    break
                elif batch_status == "idle":
                    break
            except Exception as e:
                print(f"[transcode] Progress poll error: {e}")
                break
    finally:
        _polling_active = False


def start_transcode_background(quality="high"):
    """Trigger batch transcoding on the desktop service.
    Returns immediately — the desktop service runs the batch in a background thread.
    Spawns a polling greenthread to emit WebSocket progress updates.
    """
    try:
        response = requests.post(
            f"{Config.TRANSCODE_SERVICE_URL}/transcode-all",
            json={"quality": quality},
            timeout=10,
        )

        if response.status_code == 200:
            data = response.json()
            status = data.get("status")
            if status == "started":
                print("[transcode] Batch transcoding started on desktop")
                eventlet.spawn_n(_poll_transcode_progress)
                return {"success": True, "status": "started"}
            elif status == "already_running":
                print("[transcode] Batch transcoding already running on desktop")
                eventlet.spawn_n(_poll_transcode_progress)
                return {"success": True, "status": "already_running"}
        return {"success": False, "error": f"HTTP {response.status_code}"}
    except requests.exceptions.ConnectionError:
        print("[transcode] Desktop transcode service not reachable")
        return {"success": False, "error": "Service not reachable"}
    except Exception as e:
        print(f"[transcode] Error starting batch: {e}")
        return {"success": False, "error": str(e)}


def get_transcode_status():
    """Get current batch transcode progress from the desktop service.
    Auto-starts WebSocket polling if a batch is running and polling isn't active.
    """
    try:
        response = requests.get(
            f"{Config.TRANSCODE_SERVICE_URL}/transcode-status",
            timeout=5,
        )
        if response.status_code == 200:
            data = response.json()
            # Auto-start polling if batch is running but no poller active
            if data.get("status") == "running" and not _polling_active:
                eventlet.spawn_n(_poll_transcode_progress)
            return data
        print(
            f"[transcode] transcode-status: HTTP {response.status_code} "
            f"(url={Config.TRANSCODE_SERVICE_URL})"
        )
        return None
    except Exception as e:
        print(
            f"[transcode] transcode-status: {type(e).__name__}: {e} "
            f"(url={Config.TRANSCODE_SERVICE_URL})"
        )
        return None


def cancel_transcode():
    """Cancel running batch transcode on the desktop service."""
    try:
        response = requests.post(
            f"{Config.TRANSCODE_SERVICE_URL}/transcode-cancel",
            timeout=5,
        )
        if response.status_code == 200:
            return response.json()
        print(
            f"[transcode] transcode-cancel: HTTP {response.status_code} "
            f"(url={Config.TRANSCODE_SERVICE_URL})"
        )
        return None
    except Exception as e:
        print(
            f"[transcode] transcode-cancel: {type(e).__name__}: {e}"
        )
        return None
