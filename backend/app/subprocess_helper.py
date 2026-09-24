"""Safe subprocess execution that works under eventlet monkey patching.

Uses the ORIGINAL (unpatched) subprocess and threading modules to avoid
deadlocks caused by eventlet's green-patched pipes and timers when running
inside tpool threads.
"""

import sys

# Get the original unpatched modules — eventlet monkey-patches subprocess
# and threading, which causes deadlocks when mixing tpool (real OS threads)
# with green-patched pipe I/O.
try:
    from eventlet.patcher import original
    _subprocess = original("subprocess")
    _threading = original("threading")
except ImportError:
    import subprocess as _subprocess
    import threading as _threading


class SubprocessResult:
    """Drop-in compatible with subprocess.CompletedProcess."""

    def __init__(self, returncode, stdout, stderr):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


def safe_subprocess_run(cmd, timeout=120, capture_output=False, text=False,
                        pid_callback=None, stderr_devnull=False, **kwargs):
    """Run a subprocess with a timeout that actually works under eventlet.

    Uses the original (unpatched) subprocess and threading modules to avoid
    eventlet green-thread deadlocks in pipe I/O and timers.

    IMPORTANT: Only use capture_output when you actually need the output
    (e.g. ffprobe). For fire-and-forget commands (e.g. ffmpeg encoding),
    leave capture_output=False to avoid pipe deadlocks.

    Args:
        cmd: Command list (same as subprocess.run)
        timeout: Seconds before killing the process (default 120)
        capture_output: Capture stdout/stderr (default False)
        text: Decode output as text (default False)
        pid_callback: Called with the process PID after launch (default None)
        stderr_devnull: Send stderr to devnull instead of PIPE (default False)
        **kwargs: Passed through to Popen

    Returns:
        SubprocessResult with returncode, stdout, stderr

    Raises:
        subprocess.TimeoutExpired: If the process exceeds the timeout
    """
    if capture_output:
        kwargs["stdout"] = _subprocess.PIPE
        kwargs["stderr"] = _subprocess.DEVNULL if stderr_devnull else _subprocess.PIPE

    # On Windows, create a new process group for clean kills
    if sys.platform == "win32":
        kwargs.setdefault("creationflags", _subprocess.CREATE_NEW_PROCESS_GROUP)

    # Prevent stdin reads (e.g. ffmpeg interactive prompts) from blocking
    kwargs.setdefault("stdin", _subprocess.DEVNULL)

    # Default stdout/stderr to DEVNULL if not capturing, so pipes don't fill
    kwargs.setdefault("stdout", _subprocess.DEVNULL)
    kwargs.setdefault("stderr", _subprocess.DEVNULL)

    timed_out = _threading.Event()

    proc = _subprocess.Popen(cmd, **kwargs)

    if pid_callback:
        pid_callback(proc.pid)

    def _kill():
        timed_out.set()
        try:
            proc.kill()
        except OSError:
            pass  # Process already exited

    timer = _threading.Timer(timeout, _kill)
    timer.daemon = True
    timer.start()

    try:
        stdout, stderr = proc.communicate()
    finally:
        timer.cancel()

    if text and stdout is not None:
        stdout = stdout.decode("utf-8", errors="replace")
    if text and stderr is not None:
        stderr = stderr.decode("utf-8", errors="replace")

    if timed_out.is_set():
        raise _subprocess.TimeoutExpired(cmd, timeout)

    return SubprocessResult(proc.returncode, stdout, stderr)
