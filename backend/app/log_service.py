"""Combined log capture for NASRadio.

Intercepts stdout/stderr from the backend and also accepts log batches
from frontend devices via POST /api/logs. Everything lands in two places:

  1. An in-memory ring buffer (fast, used by the existing hidden log
     viewer — long-press dashboard refresh).
  2. A single rotating file at `backend/logs/combined.log`, prefixed per
     device so a multi-device incident can be read in one place.

File line format:
    2026-04-19 10:23:45.123  [BACKEND]     [INFO]   ✅ PG pool initialized
    2026-04-19 10:23:46.891  [SM-S928U]    [WARN]   ⚠️ Progress save failed
    2026-04-19 10:23:47.103  [DESKTOP-ALP] [ERROR]  Traceback (most recent call last):

Rotation: at 10 MB the current file is renamed to combined.log.1; one
backup is kept (combined.log.2 gets deleted on next rollover). Keeps
disk usage bounded without relying on logrotate.
"""

import collections
import os
import sys
import threading
import re
from datetime import datetime

# The log lock MUST be a native OS lock, not the green one eventlet's
# monkey_patch swaps in for threading.RLock. A green lock is keyed on
# greenlet identity and only works from the hub thread; anything running on
# eventlet.tpool (waveform generation, SMB opens) is a REAL OS thread, and it
# prints. On 2026-09-16 two waveform jobs finished 1 ms apart on two pool
# threads, both hit the green RLock from outside the hub, and it wedged for
# good: every print in the backend then parked its caller forever, after the
# line had already reached the console. Symptoms: /api/stream and /api/logs
# hung, casting "stuck" cycling tracks every 90 s (NPM 504), cast stop timed
# out. A native RLock is safe from greenlets and pool threads alike; the
# critical section is a deque append plus one small file write, so the hub
# never blocks for more than that.
try:
    from eventlet.patcher import original as _eventlet_original
    _native_threading = _eventlet_original("threading")
except Exception:  # not running under eventlet (tests, tooling)
    _native_threading = threading


class LogEntry:
    __slots__ = ("timestamp", "level", "message", "device")

    def __init__(self, level, message, device="BACKEND"):
        self.timestamp = datetime.now().isoformat(timespec="milliseconds")
        self.level = level
        self.message = message
        self.device = device

    def to_dict(self):
        return {
            "timestamp": self.timestamp,
            "level": self.level,
            "message": self.message,
            "device": self.device,
        }


# Level detection patterns (emoji and text-based)
_ERROR_PATTERNS = re.compile(r"⚠️|❌|ERROR|Traceback|FAIL|failed")
_WARNING_PATTERNS = re.compile(r"⏳|WARNING|Warning|WARN|Could not|Cannot")
_SUCCESS_PATTERNS = re.compile(r"✅|🚀|✨")

# Stderr noise that should be info, not error (eventlet/werkzeug logs)
_STDERR_INFO_PATTERNS = re.compile(
    r"accepted \(|"           # eventlet connection accepts
    r"GET /|POST /|PUT /|DELETE /|HEAD /|"  # HTTP request logs
    r"wsgi starting|"         # server startup
    r"WARNING: This is a development"  # werkzeug dev server warning
)

# Exception types whose entire tracebacks are suppressed from logs.
# These fire constantly during normal music streaming whenever a
# client disconnects mid-response (skip song, navigate away, network
# blip) — the server is mid-`send()` of the FLAC file and gets a
# socket-level abort. Useful tracebacks (real bugs) get drowned out
# by hundreds of these per session.
_SUPPRESS_TRACEBACK_EXCEPTIONS = (
    "ConnectionAbortedError",
    "ConnectionResetError",
    "BrokenPipeError",
)

# Specific one-liner stderr lines that are also noise from the same
# class of disconnection events.
_SUPPRESS_LINE_PATTERNS = re.compile(
    r"^\s*Removing descriptor:\s*\d+\s*$"
)


def _infer_level(message):
    """Infer log level from message content."""
    if _ERROR_PATTERNS.search(message):
        return "error"
    if _WARNING_PATTERNS.search(message):
        return "warning"
    return "info"


class _TeeWriter:
    """Writes to both the original stream and the log buffer.

    Includes a multi-line traceback filter: when a Python traceback
    starts and its terminating exception line names one of
    `_SUPPRESS_TRACEBACK_EXCEPTIONS`, the whole traceback is dropped
    from both the in-memory buffer/file log AND the raw stdout/stderr
    stream the process was launched with. Eventlet writes
    `ConnectionAbortedError` tracebacks any time a streaming client
    disconnects mid-response, which during normal use happens
    constantly — those tracebacks were drowning out real errors AND
    cluttering the live PowerShell window the backend runs in.

    Lines are buffered until a newline arrives so the suppression
    decision happens before anything is forwarded to the original
    stream. Non-stderr (stdout) lines pass through unchanged.
    """

    def __init__(self, original, log_service, is_stderr=False):
        self._original = original
        self._log_service = log_service
        self._is_stderr = is_stderr
        self._line_buffer = ""
        # Multi-line traceback suppression state (stderr only).
        self._tb_buffer = []          # buffered (raw_line, stripped) tuples
        self._tb_active = False       # currently inside a traceback?

    def write(self, text):
        # Buffer lines so suppression can run on whole units before we
        # forward anything to the underlying stream.
        self._line_buffer += text
        while "\n" in self._line_buffer:
            nl = self._line_buffer.index("\n")
            raw_line = self._line_buffer[: nl + 1]
            self._line_buffer = self._line_buffer[nl + 1 :]
            self._handle_raw_line(raw_line)

    def _handle_raw_line(self, raw_line):
        """Route a single newline-terminated line. `raw_line` keeps the
        trailing '\\n' (and any '\\r') so passthrough writes to the
        original stream preserve formatting."""
        stripped = raw_line.strip()

        if not stripped:
            # Blank line. If mid-traceback, this terminates it; the
            # flush decides whether to write it through.
            if self._is_stderr and self._tb_active:
                self._flush_traceback_buffer(raw_line)
            else:
                self._write_original(raw_line)
            return

        if self._is_stderr:
            # Drop standalone noise lines from both stream + log.
            if _SUPPRESS_LINE_PATTERNS.match(stripped):
                return

            # Start of a traceback: open the buffer.
            if stripped.startswith("Traceback (most recent call last):"):
                if self._tb_active:
                    self._flush_traceback_buffer()
                self._tb_active = True
                self._tb_buffer = [(raw_line, stripped)]
                return

            if self._tb_active:
                self._tb_buffer.append((raw_line, stripped))
                if _is_exception_terminator(stripped):
                    self._flush_traceback_buffer()
                return

        # Default path — write to both original stream and log.
        self._write_original(raw_line)
        self._emit_line(stripped)

    def _flush_traceback_buffer(self, trailing_blank=None):
        """End the current traceback. If its terminating exception is in
        the suppress list, drop everything (including the trailing blank
        line if provided). Otherwise replay all buffered lines to both
        the original stream and the log."""
        if not self._tb_active:
            return
        buffered = self._tb_buffer
        self._tb_buffer = []
        self._tb_active = False
        if not buffered:
            return
        last_stripped = buffered[-1][1]
        for exc_name in _SUPPRESS_TRACEBACK_EXCEPTIONS:
            if last_stripped.startswith(exc_name + ":") or last_stripped == exc_name:
                # Suppress entire traceback — and eat the trailing blank
                # line so we don't leave a mysterious gap in the console.
                return
        # Not suppressed — replay verbatim.
        for raw_line, stripped in buffered:
            self._write_original(raw_line)
            self._emit_line(stripped)
        if trailing_blank is not None:
            self._write_original(trailing_blank)

    def _write_original(self, text):
        if self._original:
            try:
                self._original.write(text)
            except Exception:
                pass

    def _emit_line(self, line):
        if self._is_stderr and _STDERR_INFO_PATTERNS.search(line):
            level = "info"
        elif self._is_stderr:
            level = _infer_level(line) if _infer_level(line) != "info" else "warning"
        else:
            level = _infer_level(line)
        self._log_service._add(level, line)

    def flush(self):
        if self._original:
            try:
                self._original.flush()
            except Exception:
                pass

    # Forward attribute lookups to original stream (encoding, fileno, etc.)
    def __getattr__(self, name):
        return getattr(self._original, name)


# Matches a Python exception "terminator" line — the last line of a
# traceback, e.g. `ConnectionAbortedError: [WinError 10053] ...` or
# `ValueError: invalid literal`. Exception class name optionally
# qualified with a module path, followed by `:` (or end of line).
_EXCEPTION_TERMINATOR = re.compile(r"^[A-Za-z_][\w.]*(?:Error|Exception|Warning)(?::|$)")


def _is_exception_terminator(line):
    return bool(_EXCEPTION_TERMINATOR.match(line))


class LogService:
    # Rotate when the current file exceeds this size (roughly 10 MB).
    MAX_FILE_BYTES = 10 * 1024 * 1024

    def __init__(self, max_lines=2000, log_file_path=None):
        self._buffer = collections.deque(maxlen=max_lines)
        self._lock = _native_threading.RLock()  # see module header — never a green lock
        # Resolve log file path lazily — backend/logs/combined.log
        if log_file_path is None:
            backend_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            log_file_path = os.path.join(backend_dir, "logs", "combined.log")
        self._log_file_path = log_file_path
        self._ensure_log_dir()

    @property
    def log_file_path(self):
        return self._log_file_path

    def _ensure_log_dir(self):
        try:
            os.makedirs(os.path.dirname(self._log_file_path), exist_ok=True)
        except Exception as e:
            print(f"[log_service] Could not create log dir: {e}")

    def _rotate_if_needed(self):
        """If the current log exceeds MAX_FILE_BYTES, move it to .1 and
        start fresh. Drops any existing .1 backup. Called inline from
        _add; cost is a single stat + os.replace when full."""
        try:
            size = os.path.getsize(self._log_file_path)
        except OSError:
            return
        if size < self.MAX_FILE_BYTES:
            return
        backup = self._log_file_path + ".1"
        try:
            if os.path.exists(backup):
                os.remove(backup)
            os.replace(self._log_file_path, backup)
        except Exception as e:
            print(f"[log_service] Rotation failed: {e}")

    def _write_line_to_file(self, entry):
        """Append a formatted line for the given entry to combined.log."""
        try:
            self._rotate_if_needed()
            ts = entry.timestamp.replace("T", " ")[:23]
            device = (entry.device or "UNKNOWN")[:12].ljust(12)
            level = (entry.level or "info").upper().ljust(5)
            line = f"{ts}  [{device}]  [{level}]  {entry.message}\n"
            with open(self._log_file_path, "a", encoding="utf-8") as f:
                f.write(line)
        except Exception:
            # Don't let a log-write failure crash a request handler. The
            # in-memory ring buffer still has the entry.
            pass

    def _add(self, level, message, device="BACKEND"):
        with self._lock:
            entry = LogEntry(level, message, device=device)
            self._buffer.append(entry)
            self._write_line_to_file(entry)

    def ingest_from_device(self, device_name, entries):
        """Accept a batch of log entries from a connected device.

        entries: list of {timestamp, level, message} dicts. We honor the
        device's timestamp where possible but still stamp a server-side
        arrival time for correlation. Messages that already contain a
        timestamp prefix from the device-side logger aren't stripped —
        the reader can tell the source from the [device] column.
        """
        if not isinstance(entries, list):
            return 0
        count = 0
        with self._lock:
            for raw in entries:
                if not isinstance(raw, dict):
                    continue
                message = raw.get("message")
                if not message:
                    continue
                level = raw.get("level") or "info"
                if level not in ("info", "warning", "error"):
                    level = _infer_level(message)
                entry = LogEntry(level, str(message), device=device_name or "DEVICE")
                # Preserve the device's timestamp if provided; else the
                # LogEntry constructor already stamped server-local time.
                ts = raw.get("timestamp")
                if isinstance(ts, str):
                    entry.timestamp = ts
                self._buffer.append(entry)
                self._write_line_to_file(entry)
                count += 1
        return count

    def get_recent(self, lines=200, level=None, search=None, device=None):
        """Get recent log entries, optionally filtered."""
        with self._lock:
            result = list(self._buffer)

        if level:
            result = [e for e in result if e.level == level]
        if device:
            device_lower = device.lower()
            result = [e for e in result if (e.device or "").lower() == device_lower]
        if search:
            search_lower = search.lower()
            result = [e for e in result if search_lower in e.message.lower()]

        return [e.to_dict() for e in result[-lines:]]

    def install(self):
        """Install stdout/stderr interceptors. Call once at startup."""
        sys.stdout = _TeeWriter(sys.stdout, self)
        sys.stderr = _TeeWriter(sys.stderr, self, is_stderr=True)
        # Session separator — easy to eyeball in the combined log.
        self._add("info", "─" * 72)
        self._add("info", f"NASRadio backend session started at {datetime.now().isoformat(timespec='seconds')}")
        self._add("info", "─" * 72)


# Singleton instance
log_service = LogService()
