"""
Force-restart helpers for the WSL-hosted sidecar services
(Essentia on :5005, transcode service on :5006).

Why this exists:
The original /api/essentia/start endpoint only spawns Essentia if it's
not already up. If the existing instance is hung (TF GIL deadlock or
similar — known recurring failure mode), it still answers "alive" to
the start endpoint's pre-check and the start endpoint returns without
doing anything. Meanwhile the backend keeps firing analysis requests
at the dead instance, exhausting DB connections.

The Settings buttons need a different contract: "the user wants a
clean restart, no questions asked." That's what this module provides —
kill the existing process(es) inside WSL, then spawn fresh via the
existing .bat launchers (which are already detached + no-window).

Kept separate from audio_analysis.py / transcode.py so those modules
don't have to know about Windows process spawning quirks.
"""

import os
import subprocess
import time


# Windows process-creation flags.
#
# IMPORTANT: per Microsoft's docs, CREATE_NO_WINDOW is *silently ignored*
# when combined with DETACHED_PROCESS. The pre-existing /api/essentia/start
# endpoint had that broken combo (DETACHED | CREATE_NEW_PROCESS_GROUP |
# CREATE_NO_WINDOW), and the visible PowerShell window that result has
# been an ongoing annoyance — exactly the symptom that got the original
# auto-restart watchdog disabled on 2026-05-28. We use CREATE_NO_WINDOW
# alone (plus CREATE_NEW_PROCESS_GROUP for signal isolation). The child
# gets no console; console subprocesses it invokes (wsl.exe is a console
# subsystem app) inherit "no console" instead of being given a fresh one.
_CREATE_NEW_PROCESS_GROUP = 0x00000200
_CREATE_NO_WINDOW = 0x08000000
_SPAWN_FLAGS = _CREATE_NEW_PROCESS_GROUP | _CREATE_NO_WINDOW


def _repo_root():
    """The NASRadio repo root — two `dirname`s up from app/."""
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _wsl_run(bash_cmd, timeout=15):
    """Run a one-shot bash command inside the Ubuntu WSL distro.

    Returns (returncode, stdout, stderr). On Windows, uses CREATE_NO_WINDOW
    so the wsl.exe call doesn't flash a console window. Timeout-bounded
    so a hung WSL doesn't block the Flask request indefinitely.
    """
    try:
        result = subprocess.run(
            ["wsl.exe", "-d", "Ubuntu", "-e", "bash", "-c", bash_cmd],
            capture_output=True,
            text=True,
            timeout=timeout,
            creationflags=_CREATE_NO_WINDOW,
        )
        return result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return -1, "", f"wsl.exe timed out after {timeout}s"
    except FileNotFoundError:
        return -1, "", "wsl.exe not found (WSL not installed?)"
    except Exception as e:
        return -1, "", f"wsl.exe error: {type(e).__name__}: {e}"


def _kill_in_wsl(pgrep_pattern):
    """Kill all processes inside WSL whose command line matches pgrep_pattern.

    Uses pkill -9 -f to be aggressive — these services hang in C
    extensions where SIGTERM gets ignored. Returns a dict with the kill
    result (matched, killed counts).
    """
    # Count first, kill+recount second. pgrep returns the matching PIDs
    # one per line; piping to wc -l gives us a count even on no-match
    # (exit code 1 → wc still prints 0). The combined kill+recount uses
    # the same trick; the LAST line of stdout is the post-kill count.
    _, before_stdout, _ = _wsl_run(f"pgrep -f '{pgrep_pattern}' | wc -l")
    try:
        before = int(before_stdout.strip())
    except (ValueError, AttributeError):
        before = 0

    _, stdout, stderr = _wsl_run(
        f"pkill -9 -f '{pgrep_pattern}'; sleep 1; pgrep -f '{pgrep_pattern}' | wc -l"
    )
    try:
        last_line = stdout.strip().split("\n")[-1] if stdout.strip() else "0"
        remaining = int(last_line)
    except (ValueError, IndexError):
        remaining = 0

    return {
        "before": before,
        "remaining": remaining,
        "killed": max(0, before - remaining),
        "stderr": stderr.strip() if stderr else "",
    }


def _spawn_wsl_service(start_script_unix_path):
    """Spawn a WSL service detached, by invoking wsl.exe DIRECTLY (skipping
    the .bat wrapper). The .bat just calls `wsl -d Ubuntu -e bash -c
    ~/.../start.sh` itself — going direct removes the cmd.exe link in
    the chain that historically contributed to the visible-window
    problem. CREATE_NO_WINDOW alone (no DETACHED_PROCESS) keeps the
    spawn truly windowless.

    `start_script_unix_path` is the WSL-internal path to the service's
    start.sh (e.g. "~/essentia-service/start.sh").
    """
    try:
        subprocess.Popen(
            ["wsl.exe", "-d", "Ubuntu", "-e", "bash", "-c", start_script_unix_path],
            creationflags=_SPAWN_FLAGS,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            close_fds=True,
        )
        return True, None
    except FileNotFoundError:
        return False, "wsl.exe not found (WSL not installed?)"
    except Exception as e:
        return False, f"spawn failed: {type(e).__name__}: {e}"


def _wait_for_health(check_fn, timeout_s=90, interval_s=2):
    """Poll check_fn (boolean returning) until it returns True or timeout.
    Returns (alive: bool, elapsed_seconds: float).
    """
    started = time.time()
    deadline = started + timeout_s
    while time.time() < deadline:
        try:
            if check_fn():
                return True, time.time() - started
        except Exception:
            # check_fn should swallow its own errors and just return False,
            # but if anything leaks we treat it as "not ready" and keep polling.
            pass
        time.sleep(interval_s)
    return False, time.time() - started


# ─────────────────────────────────────────────────────────────────────
# Public API
# ─────────────────────────────────────────────────────────────────────


def force_restart_essentia(timeout_s=120):
    """Kill the WSL Essentia process(es) and spawn a fresh instance.

    Returns a dict suitable for jsonify(): {success, message, kill_result,
    elapsed_seconds, error?}.
    """
    from app.audio_analysis import check_essentia_service, ESSENTIA_SERVICE_URL

    # If Essentia is REMOTE (the NAS container), we don't manage its lifecycle —
    # it self-heals via Docker. The WSL2 kill/spawn below only applies to a local
    # WSL2 service, so skip it: just confirm the remote service is reachable.
    if "127.0.0.1" not in ESSENTIA_SERVICE_URL and "localhost" not in ESSENTIA_SERVICE_URL:
        alive = check_essentia_service(force=True)
        return {
            "success": alive,
            "message": (
                f"Remote Essentia reachable ({ESSENTIA_SERVICE_URL})" if alive else
                f"Remote Essentia unreachable ({ESSENTIA_SERVICE_URL})"
            ),
            "kill_result": {"killed": 0},
            "elapsed_seconds": 0,
        }

    kill_result = _kill_in_wsl("python3 app.py")
    ok, err = _spawn_wsl_service("~/essentia-service/start.sh")
    if not ok:
        return {
            "success": False,
            "error": err,
            "kill_result": kill_result,
        }
    # force=True so the probe cooldown cache can't mask the freshly-restarted
    # service as still-down during the recovery poll.
    alive, elapsed = _wait_for_health(
        lambda: check_essentia_service(force=True), timeout_s=timeout_s
    )
    return {
        "success": alive,
        "message": (
            f"Essentia online (killed {kill_result['killed']} stale process(es), "
            f"restarted in {elapsed:.1f}s)" if alive else
            f"Essentia did NOT come online within {timeout_s}s after restart"
        ),
        "kill_result": kill_result,
        "elapsed_seconds": round(elapsed, 1),
    }


def force_restart_transcode_service(timeout_s=60):
    """Kill the WSL transcode service and spawn a fresh instance.

    Returns the same shape as force_restart_essentia.
    """
    from app.transcode import check_transcode_service

    kill_result = _kill_in_wsl("python3 transcode_service.py")
    ok, err = _spawn_wsl_service("~/transcode-service/start.sh")
    if not ok:
        return {
            "success": False,
            "error": err,
            "kill_result": kill_result,
        }
    alive, elapsed = _wait_for_health(check_transcode_service, timeout_s=timeout_s)
    return {
        "success": alive,
        "message": (
            f"Transcode service online (killed {kill_result['killed']} stale process(es), "
            f"restarted in {elapsed:.1f}s)" if alive else
            f"Transcode service did NOT come online within {timeout_s}s after restart"
        ),
        "kill_result": kill_result,
        "elapsed_seconds": round(elapsed, 1),
    }


def kill_essentia_only():
    """Kill the WSL Essentia process without restarting it.

    Used by /api/analysis/cancel — if Essentia is hung and the workers
    are blocked in 120s HTTP timeouts, just setting cancel_requested
    on the backend doesn't help (the workers can't see the flag until
    their requests return, which they won't). Killing Essentia makes
    every in-flight request fail with ConnectionError immediately,
    workers see cancel_requested on the next iteration, exit cleanly.

    The next Start Analysis click will force-restart Essentia anyway,
    so there's no reason to spin up a fresh instance on cancel.
    """
    return _kill_in_wsl("python3 app.py")


def kill_local_batch_ffmpeg():
    """Kill any orphan local ffmpeg.exe processes that are part of a batch
    transcode (identified by '.transcode_cache' in the command line).

    Returns the count killed. Does NOT touch ffmpeg processes spawned for
    other reasons (e.g. on-demand stream transcode), which don't have
    .transcode_cache in their command line — they write to a different
    location.
    """
    try:
        # Use WMI via PowerShell to inspect command lines (taskkill alone
        # can't filter by command-line content on Windows).
        ps_cmd = (
            "Get-CimInstance Win32_Process -Filter \"Name='ffmpeg.EXE'\" "
            "| Where-Object { $_.CommandLine -match 'transcode_cache' } "
            "| ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; $_.ProcessId } "
            "| Measure-Object | Select-Object -ExpandProperty Count"
        )
        result = subprocess.run(
            ["powershell.exe", "-NoProfile", "-Command", ps_cmd],
            capture_output=True,
            text=True,
            timeout=10,
            creationflags=_CREATE_NO_WINDOW,
        )
        try:
            count = int((result.stdout or "0").strip())
        except ValueError:
            count = 0
        return count
    except Exception as e:
        print(f"[service_restart] kill_local_batch_ffmpeg failed: {e}")
        return 0
