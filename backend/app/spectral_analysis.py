"""Spectral transcode detection — library-wide batch orchestrator.

Runs spectral_worker.py (see its docstring for the DSP) over every local
FLAC and stamps the verdict onto songs.spectral_cutoff_hz /
songs.transcode_suspect. Mirrors audio_analysis.py's shape: OperationState
for resume/cancel persistence, websocket progress events, background
thread runner.

The worker runs as a subprocess in CHUNKS of files: the ~2-4s
librosa/numpy import is paid once per chunk instead of once per song, and
the eventlet hub never sees the CPU-bound FFT work. Failed songs are NOT
stamped, so the next run retries just those (same semantics as
audio_analysis).
"""

import json
import os
import sys
import tempfile
import threading
import time

import eventlet.tpool
import psycopg2
import psycopg2.extras

from app.extensions import safe_emit
from app.operation_state import OperationState
from app.path_utils import ensure_windows_path
from app.subprocess_helper import safe_subprocess_run

_WORKER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "spectral_worker.py")


def _worker_python():
    """Interpreter for the worker subprocess. Prefer the backend venv:
    the SERVING process can be system Python (the supervised venv parent
    spawns a system-python child that binds the port — observed live on
    the original dev box, 2026-07-07), and system Python has no librosa. sys.executable
    is only a fallback for exotic layouts."""
    venv_py = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "venv", "Scripts", "python.exe",
    )
    return venv_py if os.path.isfile(venv_py) else sys.executable

# Songs per worker invocation. CD FLACs run ~1-3s each over SMB; the odd
# 192k hi-res outlier has been observed at ~40s. 20 × 40s worst case still
# fits the timeout with room for the import.
_CHUNK_SIZE = 20
_CHUNK_TIMEOUT = 1200

_cancel_requested = False


def _emit_progress(current, total, message, status="running", eta=None,
                   analyzed=0, failed=0, suspects=0, current_song=""):
    safe_emit(
        "spectral_progress",
        {
            "current": current,
            "total": total,
            "message": message,
            "status": status,
            "eta": eta,
            "analyzed": analyzed,
            "failed": failed,
            "suspects": suspects,
            "current_song": current_song,
        },
    )


def _run_worker_chunk(songs):
    """Run one worker subprocess over a chunk of songs.

    Returns {song_id: result_dict} for every song the worker reported on.
    Paths go via a temp list file (one per line) — no quoting issues, no
    command-line length limit, and non-ASCII titles survive as UTF-8.
    """
    by_path = {}
    list_path = None
    try:
        with tempfile.NamedTemporaryFile(
            "w", suffix=".txt", delete=False, encoding="utf-8"
        ) as f:
            list_path = f.name
            for song in songs:
                win_path = ensure_windows_path(song["file_path"])
                by_path[win_path] = song["id"]
                f.write(win_path + "\n")

        # tpool, NOT a direct call: safe_subprocess_run uses the ORIGINAL
        # (unpatched) subprocess/threading modules, so its communicate()
        # is a real blocking syscall — called from a green thread it
        # freezes the whole eventlet hub for the entire chunk (~30-60s).
        # Observed live 2026-07-07: API read-timeouts during chunks.
        # tpool runs it on a real OS thread; the hub keeps serving.
        proc = eventlet.tpool.execute(
            safe_subprocess_run,
            [_worker_python(), _WORKER, "--list", list_path],
            timeout=_CHUNK_TIMEOUT,
            capture_output=True,
            text=True,
        )
    finally:
        if list_path:
            try:
                os.unlink(list_path)
            except OSError:
                pass

    results = {}
    for line in (proc.stdout or "").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except ValueError:
            continue
        song_id = by_path.get(r.get("path"))
        if song_id is not None:
            results[song_id] = r

    if proc.returncode != 0:
        first = songs[0]
        print(
            f"[spectral] worker exited rc={proc.returncode} "
            f"(chunk starting at song {first['id']} — {first['title']}; "
            f"{len(results)}/{len(songs)} results parsed)\n"
            f"--- worker stderr (last 2000) ---\n{(proc.stderr or '')[-2000:]}\n"
            f"--- end worker stderr ---"
        )
    return results


def analyze_all_spectra(db_url, force_reanalyze=False):
    """Scan every local FLAC for lossy-transcode spectra. Resumable:
    only rows without spectral_analyzed_at are queued unless force."""
    global _cancel_requested
    _cancel_requested = False

    op_state = OperationState(db_url)

    conn = psycopg2.connect(db_url)
    cursor = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    where = "" if force_reanalyze else "AND spectral_analyzed_at IS NULL"
    cursor.execute(
        f"""
        SELECT id, file_path, title FROM songs
        WHERE source_type = 'local'
          AND LOWER(file_path) LIKE '%%.flac'
          AND file_path NOT LIKE 'http%%'
          {where}
        ORDER BY id
        """
    )
    songs = cursor.fetchall()
    conn.close()

    total = len(songs)
    if total == 0:
        op_state.complete_operation("spectral_analysis", "All FLACs already scanned")
        return {"success": True, "message": "All FLACs already scanned", "analyzed": 0}

    op_state.start_operation("spectral_analysis", total, "Starting spectral scan...")
    _emit_progress(0, total, f"Starting spectral scan of {total} FLACs...")

    analyzed = failed = suspects = 0
    chunk_times = []

    for start in range(0, total, _CHUNK_SIZE):
        if _cancel_requested or op_state.get_state("spectral_analysis")["status"] == "cancelled":
            op_state.cancel_operation("spectral_analysis")
            _emit_progress(start, total, "Cancelled by user", "cancelled",
                           analyzed=analyzed, failed=failed, suspects=suspects)
            return {"success": False, "message": "Cancelled",
                    "analyzed": analyzed, "failed": failed, "suspects": suspects}

        chunk = songs[start:start + _CHUNK_SIZE]
        done = start + len(chunk)

        if chunk_times:
            avg = sum(chunk_times[-10:]) / len(chunk_times[-10:])
            remaining_s = ((total - done) / _CHUNK_SIZE) * avg
            if remaining_s < 3600:
                eta = f"{int(remaining_s / 60)}m"
            else:
                eta = f"{int(remaining_s / 3600)}h {int((remaining_s % 3600) / 60)}m"
        else:
            eta = "calculating..."

        op_state.update_progress(
            "spectral_analysis", done,
            message=f"Scanning: {chunk[0]['title']}",
            eta=eta,
            extra_data={"analyzed": analyzed, "failed": failed, "suspects": suspects},
        )
        _emit_progress(done, total, f"Scanning: {chunk[0]['title']}", eta=eta,
                       analyzed=analyzed, failed=failed, suspects=suspects,
                       current_song=chunk[0]["title"])

        t0 = time.time()
        try:
            results = _run_worker_chunk(chunk)
        except Exception as e:  # incl. TimeoutExpired — skip chunk, keep going
            print(f"[spectral] chunk at offset {start} failed: {type(e).__name__}: {e}")
            failed += len(chunk)
            continue
        chunk_times.append(time.time() - t0)

        conn = psycopg2.connect(db_url)
        cursor = conn.cursor()
        for song in chunk:
            r = results.get(song["id"])
            if not r or "error" in r:
                if r:
                    print(f"[spectral] song {song['id']} ({song['title']}): {r['error']}")
                failed += 1
                continue
            cursor.execute(
                """
                UPDATE songs SET
                    spectral_cutoff_hz = %s,
                    transcode_suspect = %s,
                    spectral_analyzed_at = CURRENT_TIMESTAMP
                WHERE id = %s
                """,
                (r["cutoff_hz"], 1 if r["suspect"] else 0, song["id"]),
            )
            analyzed += 1
            if r["suspect"]:
                suspects += 1
                print(
                    f"🚩 [spectral] TRANSCODE SUSPECT: song {song['id']} "
                    f"({song['title']}) — cutoff {r['cutoff_hz']} Hz, "
                    f"cliff {r['cliff_db']} dB"
                )
            safe_emit(
                "spectral_result",
                {
                    "song_id": song["id"],
                    "title": song["title"],
                    "cutoff_hz": r["cutoff_hz"],
                    "cliff_db": r["cliff_db"],
                    "suspect": r["suspect"],
                },
            )
        conn.commit()
        conn.close()

    op_state.complete_operation(
        "spectral_analysis",
        f"Scanned {analyzed} FLACs — {suspects} suspected transcodes, {failed} failed",
    )
    _emit_progress(total, total,
                   f"Complete! {suspects} suspected transcodes ({analyzed} scanned, {failed} failed)",
                   "complete", analyzed=analyzed, failed=failed, suspects=suspects)
    return {"success": True, "analyzed": analyzed, "failed": failed,
            "suspects": suspects, "total": total}


def start_spectral_background(db_url, force_reanalyze=False):
    """Start the spectral scan in a background thread (green under eventlet;
    the heavy work is all in subprocesses, so the hub stays responsive)."""
    op_state = OperationState(db_url)
    if op_state.get_state("spectral_analysis")["status"] == "running":
        return {"success": False, "error": "Spectral scan already in progress"}

    thread = threading.Thread(
        target=analyze_all_spectra, args=(db_url, force_reanalyze), daemon=True
    )
    thread.start()
    return {"success": True, "message": "Spectral scan started in background"}


def cancel_spectral(db_url):
    """Cancel a running scan. Takes effect at the next chunk boundary
    (worst case ~a chunk's runtime; the in-flight worker finishes)."""
    global _cancel_requested
    _cancel_requested = True
    OperationState(db_url).cancel_operation("spectral_analysis")
    return {"success": True, "message": "Cancellation requested"}


def get_spectral_state(db_url):
    """Operation state + coverage/suspect stats."""
    state = OperationState(db_url).get_state("spectral_analysis")

    conn = psycopg2.connect(db_url)
    cursor = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    cursor.execute(
        """
        SELECT
            COUNT(*) AS total_flacs,
            COUNT(spectral_analyzed_at) AS scanned,
            COUNT(*) FILTER (WHERE transcode_suspect = 1) AS suspects
        FROM songs
        WHERE source_type = 'local' AND LOWER(file_path) LIKE '%%.flac'
        """
    )
    stats = cursor.fetchone()
    conn.close()

    state.update(stats)
    state["coverage_percent"] = round(
        (stats["scanned"] / stats["total_flacs"] * 100) if stats["total_flacs"] else 0, 1
    )
    return state


def get_suspects(db_url):
    """All flagged songs with context, worst (lowest cutoff) first."""
    conn = psycopg2.connect(db_url)
    cursor = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    cursor.execute(
        """
        SELECT s.id, s.title, s.spectral_cutoff_hz, s.file_path,
               ar.name AS artist_name, al.title AS album_title
        FROM songs s
        JOIN artists ar ON s.artist_id = ar.id
        JOIN albums al ON s.album_id = al.id
        WHERE s.transcode_suspect = 1
        ORDER BY s.spectral_cutoff_hz ASC, s.id
        """
    )
    rows = [dict(r) for r in cursor.fetchall()]
    conn.close()
    return rows
