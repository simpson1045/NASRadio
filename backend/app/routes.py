from flask import Blueprint, jsonify, send_file, request, Response, stream_with_context, redirect, g
from app.models import Database
from app import auth
from app.config import Config
from app.progress_tracker import progress_tracker
from app.artwork_search import ArtworkSearch
from app.playlists import Playlists
from app.spotify_import import SpotifyImporter, cancel_import
from app.discovery import SpotifyDiscovery
from app.spotify_playcount import SpotifyPlayCount
from app.extensions import socketio, safe_emit
import os
import json
import time
import uuid
import eventlet
import eventlet.tpool
from eventlet.timeout import Timeout as EventletTimeout
import threading
from app.subprocess_helper import safe_subprocess_run
from app.path_utils import ensure_windows_path


# ──────────────────────────────────────────────────────────────────────
# SMB resilience helpers
#
# On a Windows host, audio file paths live on a UNC share (MUSIC_LIBRARY_PATH).
# When SMB is healthy, os.path.exists / os.path.getsize on a UNC path
# return in <1 ms. When the SMB session goes stale (network blip, NAS
# reboot, Windows credential refresh), the same calls can block for
# 30-60 seconds before returning. Eventlet does not monkey-patch file
# I/O, so a blocking syscall on the hub thread stops every other
# greenthread from being dispatched until it returns.
#
# Without this guard, one stale-SMB stream request was enough to wedge
# the entire backend: /api/logs, /api/health, and every other stream
# request piled up behind the hung syscall. This actually happened in
# session 2026-05-08 — a backend restart cleared stuck file handles
# inside the running process but did nothing to prevent recurrence.
#
# Two-layer protection:
#   1. tpool.execute runs the syscall on a real OS thread from a pool,
#      so the hub thread stays free to dispatch other greenthreads
#      while one syscall is in progress.
#   2. eventlet.Timeout caps the wall-clock wait — if the syscall
#      doesn't return within SMB_CALL_TIMEOUT_S, we raise SmbUnavailable
#      and the caller can return a fast 503 instead of hanging
#      indefinitely.
#
# Trade-off: tpool's pool size is 20 by default, and we can't kill an
# OS thread cleanly from Python. Under prolonged SMB outage tpool can
# fill up with stuck threads; once exhausted, new tpool calls queue.
# In practice once 20 stream requests are stuck, restart is the right
# answer anyway, and at least the hub keeps serving non-streaming
# requests until then.
# ──────────────────────────────────────────────────────────────────────

SMB_CALL_TIMEOUT_S = 5


class SmbUnavailable(Exception):
    """Raised when a UNC filesystem call exceeds SMB_CALL_TIMEOUT_S, or
    when the SMB circuit breaker is open and is short-circuiting the
    call without going to tpool."""


# ──────────────────────────────────────────────────────────────────────
# SMB circuit breaker.
#
# The per-call timeout above stops a single stale syscall from hanging
# any one request indefinitely — but tpool's pool size is only 20, and
# eventlet can't kill an OS thread cleanly from Python. So during a
# real SMB outage every stream/health/list request that touches the
# share generates a stuck tpool thread that eats its slot for ~5s
# before the eventlet.Timeout fires. With 20 slots and ~5s per zombie,
# 4 stuck requests/second is enough to fully saturate tpool. Once
# tpool is saturated, NEW tpool calls (including totally unrelated
# ones — image fetches, ffmpeg runs, subprocess shazam) queue
# arbitrarily long behind the zombies.
#
# The circuit breaker prevents that. After SMB_BREAKER_FAILURE_THRESHOLD
# timeouts within SMB_BREAKER_FAILURE_WINDOW_S seconds, the breaker
# opens. While open, _smb_call short-circuits — it raises SmbUnavailable
# immediately without going to tpool, costing essentially zero
# (microseconds + no tpool slot). The caller still gets a fast 503.
# After SMB_BREAKER_COOLDOWN_S seconds the breaker enters half-open:
# the next single call is allowed through as a probe. If the probe
# succeeds, the breaker closes and normal traffic resumes; if it fails,
# the breaker re-opens for another cooldown.
#
# Net effect during an SMB outage:
#   - First ~3 requests pay ~5s each before tripping the breaker.
#   - Every subsequent request returns a 503 in microseconds without
#     consuming a tpool slot.
#   - A single 5-second "probe" call goes out every ~10s while down.
#   - Unrelated tpool work (image downloads, ffmpeg) keeps flowing.
#   - No backend restart needed when the share comes back — the next
#     probe succeeds and the breaker closes automatically.
#
# Tunables — kept conservative for a home NAS:
#   threshold=3 / window=30s catches a real outage quickly without
#   tripping on a single transient blip; cooldown=10s recovers fast
#   when the share comes back without flooding it during the outage.
# ──────────────────────────────────────────────────────────────────────

SMB_BREAKER_FAILURE_THRESHOLD = 3
SMB_BREAKER_FAILURE_WINDOW_S = 30
SMB_BREAKER_COOLDOWN_S = 10


class _SmbBreaker:
    def __init__(self):
        self._lock = threading.Lock()
        # Sliding window of recent failure times (monotonic seconds).
        # When this window has THRESHOLD entries the breaker opens.
        self._failure_times = []
        # None when CLOSED. Monotonic seconds when OPEN/HALF_OPEN —
        # we transition to HALF_OPEN once monotonic - _opened_at >=
        # cooldown. We don't represent half-open as a separate stored
        # state; it's derived from elapsed time + the in-flight flag.
        self._opened_at = None
        # Only one probe call is allowed at a time in half-open state;
        # this guard prevents a thundering herd of probes during the
        # transition window.
        self._probe_in_flight = False

    def _classify(self, now):
        """Returns 'closed' | 'open' | 'half_open'. Caller holds lock."""
        if self._opened_at is None:
            return "closed"
        if now - self._opened_at >= SMB_BREAKER_COOLDOWN_S:
            return "half_open"
        return "open"

    def allow(self):
        """Returns True if the caller should proceed with the SMB call;
        False if the caller should immediately raise SmbUnavailable.

        In half-open, returns True for at most one concurrent probe and
        False for everyone else until the probe completes."""
        now = time.monotonic()
        with self._lock:
            state = self._classify(now)
            if state == "closed":
                return True
            if state == "open":
                return False
            if self._probe_in_flight:
                return False
            self._probe_in_flight = True
            return True

    def record_success(self):
        with self._lock:
            was_open = self._opened_at is not None
            if was_open:
                # Probe succeeded → CLOSED.
                print("🟢 SMB circuit breaker CLOSED — share is back")
                self._opened_at = None
                self._failure_times.clear()
            self._probe_in_flight = False

    def record_failure(self):
        now = time.monotonic()
        with self._lock:
            was_half_open_probe = self._probe_in_flight
            self._probe_in_flight = False

            if was_half_open_probe:
                # Probe failed → re-open and reset the cooldown clock.
                print("🟠 SMB circuit breaker re-OPENED — probe failed, cooling down "
                      f"another {SMB_BREAKER_COOLDOWN_S}s")
                self._opened_at = now
                return

            # Slide the failure window and append.
            cutoff = now - SMB_BREAKER_FAILURE_WINDOW_S
            self._failure_times = [t for t in self._failure_times if t >= cutoff]
            self._failure_times.append(now)

            if (self._opened_at is None and
                    len(self._failure_times) >= SMB_BREAKER_FAILURE_THRESHOLD):
                # Tripped → OPEN.
                print(f"🔴 SMB circuit breaker OPEN — {len(self._failure_times)} failures "
                      f"in {SMB_BREAKER_FAILURE_WINDOW_S}s, short-circuiting for "
                      f"{SMB_BREAKER_COOLDOWN_S}s")
                self._opened_at = now
                self._failure_times.clear()


_smb_breaker = _SmbBreaker()


def _smb_call(fn, *args, timeout=SMB_CALL_TIMEOUT_S, **kwargs):
    """Run a blocking filesystem call on a tpool thread, capped by a
    wall-clock timeout AND by the module-level circuit breaker.

    Returns whatever fn returns; raises SmbUnavailable if the call
    overruns the deadline OR if the breaker is currently open."""
    if not _smb_breaker.allow():
        raise SmbUnavailable("SMB circuit breaker is open")
    t = EventletTimeout(timeout, SmbUnavailable)
    try:
        result = eventlet.tpool.execute(fn, *args, **kwargs)
        _smb_breaker.record_success()
        return result
    except SmbUnavailable:
        _smb_breaker.record_failure()
        raise
    finally:
        t.cancel()


def smb_exists(path):
    """os.path.exists, hub-friendly + timeout-bounded.
    Returns True/False on a clean stat; raises SmbUnavailable on stale SMB."""
    return _smb_call(os.path.exists, path)


def smb_getsize(path):
    """os.path.getsize, hub-friendly + timeout-bounded.
    Returns int on success; raises SmbUnavailable on stale SMB or
    propagates OSError from genuine missing/permission errors."""
    return _smb_call(os.path.getsize, path)


# ── SMB latency instrumentation ────────────────────────────────────────────
# The "song took 10s to load after an idle pause" gremlin (diagnosed
# 2026-06-28) was INVISIBLE: a cold SMB session re-handshake makes the first
# stat crawl toward SMB_CALL_TIMEOUT_S, smb_exists_with_retry ladders it up to
# ~10s, and then it *succeeds* — so nothing was ever logged. This wrapper makes
# any slow SMB op shout in the log so we can catch it red-handed next time.
SMB_SLOW_WARN_S = 1.0


def _timed_smb(label, fn, *args, **kwargs):
    """Run an SMB helper; if it takes longer than SMB_SLOW_WARN_S, print how
    long it took. Returns/raises exactly what `fn` does (the caller's existing
    SmbUnavailable handling is untouched)."""
    t0 = time.monotonic()
    try:
        return fn(*args, **kwargs)
    finally:
        dt = time.monotonic() - t0
        if dt >= SMB_SLOW_WARN_S:
            print(f"🐌 [smb] {label}: {dt:.2f}s — cold SMB session re-warming "
                  f"(the keepalive's persistent handle should prevent this; if "
                  f"you see it repeatedly, the handle dropped)")


def _backfill_file_size(song_id, size):
    """Cache a freshly-stat'd file size back into the DB so the NEXT play of
    this song skips the SMB stat entirely. Fire-and-forget — failure is
    harmless, we just stat again next time. (~24% of rows ship without a size.)"""
    try:
        db = get_db()
        conn = db.get_connection()
        cur = db.get_cursor(conn)
        cur.execute(
            "UPDATE songs SET file_size = %s "
            "WHERE id = %s AND (file_size IS NULL OR file_size = 0)",
            (int(size), song_id),
        )
        conn.commit()
        conn.close()
    except Exception:
        pass


# ── Hub-friendly file streaming ────────────────────────────────────────────
# Flask's send_file() reads the file on the eventlet HUB thread. For a big FLAC
# off the NAS over SMB, one slow read froze the ENTIRE backend — every other
# request (waveform, next/prev, screen loads) queued behind it. That's the
# "why does everything wait on one thing" bug. These helpers read each chunk on
# a tpool worker thread instead, so a slow read blocks only that one stream, not
# the whole event loop. (Same idea psycogreen already does for DB queries.)
_STREAM_CHUNK_BYTES = 512 * 1024  # 512 KB per read


def _open_at(path, offset):
    """open(path,'rb') + seek(offset) — one tpool round-trip for both."""
    fh = open(path, "rb")
    if offset:
        fh.seek(offset)
    return fh


def _tpool_file_stream(fh, length):
    """Yield up to `length` bytes from already-open `fh`, reading each chunk on
    a tpool thread so the read never blocks the event loop. Closes `fh` when
    done or if the client disconnects (GeneratorExit hits the finally)."""
    try:
        remaining = length
        while remaining > 0:
            chunk = eventlet.tpool.execute(
                fh.read, min(_STREAM_CHUNK_BYTES, remaining)
            )
            if not chunk:
                break
            remaining -= len(chunk)
            yield chunk
    finally:
        try:
            eventlet.tpool.execute(fh.close)
        except Exception:
            pass


SMB_OPEN_TIMEOUT_S = 12  # streaming opens get more room than a quick stat — a
                         # transient slow CREATE on the NAS must not 503 a cast.


def _open_stream_fh(file_path, start, song_id):
    """Open `file_path` (seeked to `start`) for streaming, with a roomier timeout
    and ONE retry.

    The tpool serve put a hard 5s cap on the open where send_file used to
    block-then-succeed; a single transient slow open then 503'd the WHOLE cast
    load — "1st song took forever and isn't even playing" (observed 2026-06-28).
    A retry + the longer timeout ride out a blip. The 🐌 line surfaces the real
    open duration so a *recurring* slow open (vs a one-off) is visible next time.

    Returns the open handle, or None if the share is genuinely unreachable."""
    for attempt in range(2):
        t0 = time.monotonic()
        try:
            fh = _smb_call(_open_at, file_path, start, timeout=SMB_OPEN_TIMEOUT_S)
            dt = time.monotonic() - t0
            if dt >= SMB_SLOW_WARN_S:
                print(f"🐌 [smb] open song {song_id}: {dt:.2f}s (attempt {attempt + 1})")
            return fh
        except SmbUnavailable:
            dt = time.monotonic() - t0
            print(f"⚠️ [stream] Song {song_id}: open attempt {attempt + 1} timed out "
                  f"after {dt:.2f}s" + (" — retrying" if attempt == 0 else " — giving up"))
            if attempt == 0:
                time.sleep(0.5)
    return None


# ── Pre-warm: eat the ~7s NAS cold-open BEFORE the user plays ───────────────
# The NAS caches a file/directory on first access (the ~7s cold-open). Opening
# the file we're ABOUT to need, ahead of time, means the real open is instant.
# That matters most for casting: a webOS/Chromecast receiver won't wait 7s for
# the first byte — it times out and plays nothing. The local app player WILL
# wait, which is why Bluetooth/local "just works" through the same 7s. simpson1045's
# idea: warm on device-connect (app open) so it's hot before the first cast.
_PREWARM_RECENT = {}      # song_id -> monotonic time last warmed
_PREWARM_DEDUP_S = 20     # don't re-warm the same song within this window


def _prewarm_file(song_id):
    """Open + lightly read a song's file on a tpool thread to pull it into the
    NAS cache. Fire-and-forget; safe to call from anywhere. Deduped so a skip
    storm can't spawn a pile of opens."""
    now = time.monotonic()
    if now - _PREWARM_RECENT.get(song_id, 0) < _PREWARM_DEDUP_S:
        return
    _PREWARM_RECENT[song_id] = now
    try:
        db = get_db()
        conn = db.get_connection()
        cur = db.get_cursor(conn)
        cur.execute("SELECT file_path FROM songs WHERE id = %s", (song_id,))
        row = cur.fetchone()
        conn.close()
        if not row or not row.get("file_path"):
            return
        path = ensure_windows_path(row["file_path"])

        def _warm():
            fh = open(path, "rb")
            try:
                fh.read(65536)  # touch the head so the NAS pulls the file in
            finally:
                fh.close()

        t0 = time.monotonic()
        _smb_call(_warm, timeout=SMB_OPEN_TIMEOUT_S)
        dt = time.monotonic() - t0
        print(f"🔥 [prewarm] song {song_id} warmed in {dt:.2f}s"
              + (" — was COLD, saved the user this wait" if dt >= SMB_SLOW_WARN_S
                 else " (already warm)"))
    except SmbUnavailable:
        print(f"⚠️ [prewarm] song {song_id}: SMB unavailable")
    except Exception as e:
        print(f"⚠️ [prewarm] song {song_id}: {e}")


def _prewarm_device_song(device_id):
    """When a device connects (app opened), warm the file for that device's
    last/restored song so the first play — especially a cast — is instant."""
    try:
        db = get_db()
        conn = db.get_connection()
        cur = db.get_cursor(conn)
        cur.execute(
            "SELECT current_song_id FROM playback_state WHERE device_id = %s",
            (device_id,),
        )
        row = cur.fetchone()
        conn.close()
        if row and row.get("current_song_id"):
            print(f"🔥 [prewarm] device {device_id[:8]} connected — warming "
                  f"restored song {row['current_song_id']}")
            _prewarm_file(row["current_song_id"])
    except Exception as e:
        print(f"⚠️ [prewarm] device-connect warm failed: {e}")


def smb_exists_with_retry(path, retries=2, delay_s=0.5):
    """smb_exists with auto-retries on SmbUnavailable.

    The lookahead pre-warm HEAD that the playback engine fires when
    <15s remain on the current track lands on an idle SMB session
    often enough to trip a stat() timeout on the first try, even
    when the share is perfectly healthy. The retries catch the
    cold-cache window: by the time we retry ~500ms later the SMB
    redirector has usually re-established the session and the stat
    succeeds.

    Bumped 2026-06-01 from 1 retry × 300ms to 2 retries × 500ms after
    seeing the original setting still log SMB-unreachable on lookahead
    pre-warms — the deep-cold case needs more time for the session to
    fully wake.

    Doesn't bypass the circuit breaker — once enough genuine
    failures accumulate, the breaker opens and further retries
    short-circuit. So this only masks transient session blips,
    not real outages.
    """
    last_err = None
    for attempt in range(retries + 1):
        try:
            return smb_exists(path)
        except SmbUnavailable as e:
            last_err = e
            if attempt < retries:
                time.sleep(delay_s)
    raise last_err
import re
import traceback
import shutil
import subprocess
from datetime import date, datetime, timedelta
import requests as mb_requests

api = Blueprint("api", __name__)
config = Config()


@api.before_request
def _require_auth():
    """Gate every API route behind a valid bearer token, except the small
    allowlist (login, ping). This is what closes the app to the public — curl
    or app, no token means 401. CORS preflight passes through untouched."""
    if request.method == "OPTIONS":
        return None
    if request.endpoint in auth.EXEMPT_ENDPOINTS:
        return None
    token = auth.extract_bearer_token()
    if not token:
        return jsonify({"error": "Authentication required"}), 401
    user, scope = auth.resolve_token(token)
    if not user:
        return jsonify({"error": "Invalid or expired token"}), 401
    # A media-scoped token (used in stream/artwork URLs) is read-only — it can
    # ONLY fetch media, never reach the mutating API.
    if scope == "media" and not auth.is_media_request(request.path, request.method):
        return jsonify({"error": "Media token not allowed here"}), 403
    g.user = user
    g.token_scope = scope
    return None


def _error_response(e, status=500):
    """Log the full error server-side, return a safe message to the client."""
    print(f"❌ API error: {e}")
    traceback.print_exc()
    return jsonify({"error": "Internal server error"}), status

# Song recognition: runs ShazamIO in a subprocess to avoid eventlet/asyncio conflicts
def _recognize_with_shazam(audio_path):
    """Run ShazamIO in a separate Python process (eventlet monkey-patches break asyncio)."""
    import json as _json
    script = f'''
import asyncio, json, sys
from shazamio import Shazam

async def main():
    shazam = Shazam()
    result = await shazam.recognize(sys.argv[1])
    print(json.dumps(result))

asyncio.run(main())
'''
    result = eventlet.tpool.execute(safe_subprocess_run,
        ["python", "-c", script, audio_path],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode != 0:
        raise RuntimeError(f"ShazamIO subprocess failed: {result.stderr.strip()}")
    return _json.loads(result.stdout.strip())

# Base directory for the backend (parent of app/)
APP_BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def get_db():
    """Get database instance"""
    return Database(config.DATABASE_URL)


# Short-lived cache of sidecar (Essentia / transcode) health so that
# every /api/health request doesn't pay the per-probe latency. Cleared
# and refreshed when older than 10s. See health_check() for context.
_sidecar_status_cache: dict = {}


@api.route("/api/ping", methods=["GET"])
def ping():
    """Ultra-cheap liveness probe — NO DB query, NO sidecar checks.

    Used by the app's LAN-vs-WAN network detection. /api/health pings the DB
    and probes Essentia/Transcode, so a hung sidecar or a momentarily-busy
    backend can push it past the app's short detection timeout and wrongly
    bounce the app out to the slow public WAN (Cloudflare) endpoint. This
    route always answers instantly, keeping "is the local server reachable?"
    decoupled from "is every sidecar healthy?".
    """
    return jsonify({"ok": True})


@api.route("/api/client-config", methods=["GET"])
def client_config():
    """Non-secret server settings every signed-in client needs: which Cast
    receiver app to launch (empty = Google's default media receiver) and the
    public base URL. Admin-only detail lives under /api/admin/*."""
    return jsonify({
        "app": "NASRadio",
        "cast_receiver_app_id": config.CAST_RECEIVER_APP_ID,
        "public_base_url": config.PUBLIC_BASE_URL,
    })


# ========================
# Authentication
# ========================


@api.route("/api/auth/login", methods=["POST"])
def auth_login():
    """Exchange username + password for a bearer token."""
    data = request.get_json(silent=True) or {}
    username = (data.get("username") or "").strip()
    password = data.get("password") or ""
    if not username or not password:
        return jsonify({"error": "Username and password required"}), 400

    user = auth.authenticate(username, password)
    if not user:
        return jsonify({"error": "Invalid username or password"}), 401

    token = auth.generate_token(user["id"], user["token_version"])
    return jsonify({"token": token, "user": auth.public_user(user)})


@api.route("/api/auth/me", methods=["GET"])
def auth_me():
    """Return the currently-authenticated user (validates the token)."""
    return jsonify({"user": auth.public_user(g.user)})


# ========================
# First-run setup (no token required — see auth.EXEMPT_ENDPOINTS)
# ========================


@api.route("/api/setup/status", methods=["GET"])
def setup_status():
    """Does this server still need its first admin? The app shows the
    create-admin screen instead of login while this is true."""
    try:
        needs_setup = auth.user_count() == 0
    except Exception as e:
        return jsonify({"error": f"Database unavailable: {e}"}), 503
    return jsonify({"app": "NASRadio", "needs_setup": needs_setup})


@api.route("/api/setup/admin", methods=["POST"])
def setup_admin():
    """Create the first admin account. Works exactly once — while the users
    table is empty — then answers 409 forever. Returns a login token so the
    app can continue straight into the setup wizard."""
    data = request.get_json(silent=True) or {}
    result = auth.bootstrap_admin(data.get("username", ""), data.get("password", ""))
    if not result.get("success"):
        return jsonify({"error": result.get("error")}), result.get("status", 400)
    user = auth.get_user_by_id(result["id"])
    token = auth.generate_token(user["id"], user["token_version"])
    return jsonify({"success": True, "token": token, "user": auth.public_user(user)})


@api.route("/api/auth/media-token", methods=["GET"])
def auth_media_token():
    """Issue a read-only media-scoped token for embedding in stream/artwork
    URLs (which native players, image loaders, and Chromecast fetch directly
    and can't send an auth header for). Requires a full session token."""
    token = auth.generate_token(g.user["id"], g.user["token_version"], scope="media")
    return jsonify({"media_token": token})


@api.route("/api/auth/change-password", methods=["POST"])
def auth_change_password():
    """Change the current user's password. Bumps token_version, which logs out
    every other device (their old tokens stop verifying)."""
    data = request.get_json(silent=True) or {}
    current = data.get("current_password") or ""
    new = data.get("new_password") or ""
    if len(new) < 8:
        return jsonify({"error": "New password must be at least 8 characters"}), 400

    user = auth.get_user_by_id(g.user["id"])
    if not user or not auth.verify_password(current, user["password_hash"]):
        return jsonify({"error": "Current password is incorrect"}), 401

    db = get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute(
            "UPDATE users SET password_hash = %s, token_version = token_version + 1 WHERE id = %s",
            (auth.hash_password(new), user["id"]),
        )
        conn.commit()
    finally:
        conn.close()

    # Re-issue a token for THIS session so the caller isn't logged out too
    fresh = auth.get_user_by_id(user["id"])
    token = auth.generate_token(fresh["id"], fresh["token_version"])
    return jsonify({"success": True, "token": token})


# ---- Admin: user management (all admin-only) ----


@api.route("/api/users", methods=["GET"])
@auth.require_admin
def admin_list_users():
    return jsonify({"users": auth.list_users()})


@api.route("/api/users", methods=["POST"])
@auth.require_admin
def admin_create_user():
    data = request.get_json(silent=True) or {}
    result = auth.create_user_account(
        data.get("username", ""), data.get("password", ""), data.get("role", "user")
    )
    return jsonify(result) if result.get("success") else (jsonify(result), 400)


@api.route("/api/users/<int:user_id>/password", methods=["POST"])
@auth.require_admin
def admin_set_password(user_id):
    data = request.get_json(silent=True) or {}
    result = auth.set_user_password(user_id, data.get("password", ""))
    return jsonify(result) if result.get("success") else (jsonify(result), 400)


@api.route("/api/users/<int:user_id>/role", methods=["POST"])
@auth.require_admin
def admin_set_role(user_id):
    data = request.get_json(silent=True) or {}
    result = auth.set_user_role(user_id, data.get("role", "user"))
    return jsonify(result) if result.get("success") else (jsonify(result), 400)


@api.route("/api/users/<int:user_id>/revoke", methods=["POST"])
@auth.require_admin
def admin_revoke_user(user_id):
    return jsonify(auth.revoke_user(user_id))


@api.route("/api/users/<int:user_id>", methods=["DELETE"])
@auth.require_admin
def admin_delete_user(user_id):
    if user_id == auth.current_user_id():
        return jsonify({"success": False, "error": "You can't delete your own account"}), 400
    result = auth.delete_user_account(user_id)
    return jsonify(result) if result.get("success") else (jsonify(result), 400)


@api.route("/api/health", methods=["GET"])
def health_check():
    """Health check endpoint with DB ping and pool diagnostics.

    Returns the list of current pool leaseholders too — the phone's
    System Logs screen shows this so you can see live who's holding
    a connection when the pool gets tight. Query ?holders=0 to skip
    the holder scan for lower overhead.
    """
    try:
        db = get_db()
        conn = db.get_connection()
        cursor = db.get_cursor(conn)
        cursor.execute("SELECT 1")
        conn.close()

        # Pool diagnostics
        pool = db._pool
        pool_info = {}
        if pool:
            # ThreadedConnectionPool tracks used/free connections internally
            pool_info = {
                "minconn": pool.minconn,
                "maxconn": pool.maxconn,
                "closed": pool.closed,
            }
            # Count connections currently checked out vs available
            if hasattr(pool, '_used') and hasattr(pool, '_pool'):
                pool_info["checked_out"] = len(pool._used)
                pool_info["available"] = len(pool._pool)
                pool_info["total_created"] = len(pool._used) + len(pool._pool)

        include_holders = request.args.get("holders", "1") != "0"
        if include_holders:
            from app.models import get_pool_holders
            pool_info["holders"] = get_pool_holders()

        # Check external services with a short cache.
        #
        # Both probes go to sidecar services via HTTP and each has a 5s
        # timeout. Done sequentially on every /api/health that's up to
        # 10s of wait — long enough that the desktop client's 8s timeout
        # gives up, the failure counter trips, and the "Server unreachable"
        # banner shows even though the server itself (and streaming, and
        # search) is perfectly healthy.
        #
        # The desktop and mobile clients both poll /api/health every 30s;
        # caching the sidecar status for 10s means back-to-back probes
        # don't re-hit the sidecars, and a single /api/health request
        # never pays more than one probe cost per sidecar.
        from time import time as _now
        cache = _sidecar_status_cache
        if cache and (_now() - cache["ts"]) < 10:
            essentia_ok = cache["essentia"]
            transcode_ok = cache["transcode"]
        else:
            essentia_ok = False
            transcode_ok = False
            try:
                from app.audio_analysis import check_essentia_service
                essentia_ok = check_essentia_service()
            except Exception:
                pass
            try:
                from app.transcode import check_transcode_service
                transcode_ok = check_transcode_service()
            except Exception:
                pass
            _sidecar_status_cache.clear()
            _sidecar_status_cache.update({
                "ts": _now(),
                "essentia": essentia_ok,
                "transcode": transcode_ok,
            })

        return jsonify({
            "status": "ok",
            "pool": pool_info,
            "essentia": essentia_ok,
            "transcode": transcode_ok,
        })
    except Exception as e:
        return _error_response(e)


@api.route("/api/fix-legacy-paths", methods=["POST"])
@auth.require_admin
def fix_legacy_paths():
    """One-time migration: convert Docker /music/ paths to Windows UNC in the DB."""
    NAS_MUSIC_UNC = config.MUSIC_LIBRARY_PATH

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Find all songs with legacy /music/ paths
        cursor.execute("SELECT id, file_path FROM songs WHERE file_path LIKE '/music/%' OR file_path LIKE '/music\\\\%'")
        legacy_songs = cursor.fetchall()

        if not legacy_songs:
            conn.close()
            return jsonify({"updated": 0, "message": "No legacy paths found"})

        updated = 0
        for song in legacy_songs:
            new_path = ensure_windows_path(song["file_path"])
            if new_path != song["file_path"]:
                cursor.execute("UPDATE songs SET file_path = %s WHERE id = %s", (new_path, song["id"]))
                updated += 1

        conn.commit()
        conn.close()
        print(f"Fixed {updated} legacy Docker paths to Windows UNC")
        return jsonify({"updated": updated, "message": f"Fixed {updated} legacy paths"})
    except Exception as e:
        conn.rollback()
        conn.close()
        return _error_response(e)


def extract_title_from_filename(filename, artist_name=None, album_name=None):
    """
    Extract clean track title and track number from filename by removing known artist/album names
    and track number patterns. Handles virtually all common naming conventions.

    Returns: tuple (title, track_number) where track_number is 0 if not found
    """

    # Remove extension
    title = os.path.splitext(filename)[0]
    original = title  # Keep for fallback
    track_number = 0

    # Normalize for comparison (but keep original case for result)
    def normalize(s):
        if not s:
            return ""
        # Remove special chars, collapse spaces, lowercase
        s = re.sub(r"[_\-\.\'\"\(\)\[\]]", " ", s)
        s = re.sub(r"\s+", " ", s).strip().lower()
        return s

    normalized_title = normalize(title)
    normalized_artist = normalize(artist_name) if artist_name else ""
    normalized_album = normalize(album_name) if album_name else ""

    # Try to remove artist name from filename (various positions)
    if normalized_artist and normalized_artist in normalized_title:
        # Find where artist appears and remove it
        artist_pattern = re.compile(
            r"[\s\-_\.]*"
            + re.escape(artist_name).replace(r"\ ", r"[\s\-_\.]+")
            + r"[\s\-_\.]*",
            re.IGNORECASE,
        )
        title = artist_pattern.sub(" ", title)

    # Try to remove album name from filename
    if normalized_album and normalized_album in normalize(title):
        album_pattern = re.compile(
            r"[\s\-_\.]*"
            + re.escape(album_name).replace(r"\ ", r"[\s\-_\.]+")
            + r"[\s\-_\.]*",
            re.IGNORECASE,
        )
        title = album_pattern.sub(" ", title)

    # Now handle track numbers in various formats and extract the number

    # Pattern 1: Disc-Track format at start (e.g., "1-01 Title" or "101 Title" for disc 1 track 01)
    disc_track_match = re.match(r"^\s*(\d)[_\-\.\s]?(\d{2})[\s\-_\.]+", title)
    if disc_track_match:
        track_number = int(disc_track_match.group(2))  # Get track part
        title = re.sub(r"^\s*\d[_\-\.\s]?\d{2}[\s\-_\.]+", "", title)
    else:
        # Pattern 2: Track number at start with various separators
        track_match = re.match(r"^\s*(\d{1,3})[\s\-_\.]+", title)
        if track_match:
            track_number = int(track_match.group(1))
            title = re.sub(r"^\s*\d{1,3}[\s\-_\.]+", "", title)

    # Pattern 3: Track number at end in parentheses (rare but happens)
    if track_number == 0:
        end_match = re.search(r"\s*\((\d{1,2})\)\s*$", title)
        if end_match:
            track_number = int(end_match.group(1))
            title = re.sub(r"\s*\(\d{1,2}\)\s*$", "", title)

    # Clean up multiple separators and whitespace
    title = re.sub(r"[\-_\.]{2,}", " ", title)
    title = re.sub(r"\s+", " ", title)
    title = title.strip(" -_.")

    # If we stripped everything, fall back to original minus just track number
    if not title or len(title) < 2:
        title = re.sub(r"^\d{1,3}[\s\-_\.]+", "", original)
        title = re.sub(r"[\s\-_\.]+\d{1,3}$", "", title)
        title = title.strip(" -_.")

    # Final fallback - just return original without extension
    if not title:
        title = original

    return (title, track_number)


@api.route("/api/artists", methods=["GET"])
def get_artists():
    """Get all artists in the music library.

    Excludes artists whose only songs are podcast episodes — those
    live in the podcast section, not here. Podcast hosts like
    'Armin van Buuren' that ALSO have local music still show up
    because the EXISTS check only requires at least one local track.
    """
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    cursor.execute(
        """
        SELECT artists.* FROM artists
        WHERE EXISTS (
            SELECT 1 FROM songs
            WHERE songs.artist_id = artists.id
              AND songs.source_type = 'local'
        )
        ORDER BY artists.name
        """
    )
    artists = [dict(row) for row in cursor.fetchall()]

    conn.close()
    return jsonify(artists)


@api.route("/api/artist/<int:artist_id>", methods=["GET"])
def get_artist(artist_id):
    """Get artist details with albums and featured songs"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    # Get artist
    cursor.execute("SELECT * FROM artists WHERE id = %s", (artist_id,))
    artist = dict(cursor.fetchone())

    # Get albums where this artist is the PRIMARY artist
    cursor.execute(
        "SELECT * FROM albums WHERE artist_id = %s ORDER BY year, title", (artist_id,)
    )
    artist["albums"] = [dict(row) for row in cursor.fetchall()]

    # Get songs where this artist is associated but the song's ALBUM
    # belongs to a different primary artist. Two cases collapse into one:
    #
    #   1) Featured/guest credit — artist is in song_artists junction
    #      for the song, but is not the song's primary artist. Album
    #      naturally belongs to whoever the primary is.
    #
    #   2) Primary-but-orphan — artist IS the song's primary, but the
    #      album it lives on belongs to a different artist (compilations,
    #      "Various Artists" releases, soundtracks). Without this case,
    #      artists like "+44" who have a track on a Various Artists comp
    #      but no albums of their own showed "No music found" even though
    #      we counted "1 song" for them. (Bug surfaced on 2026-05-26.)
    #
    # The condition is: (artist linked to song) AND (album's primary != this).
    # We then exclude albums already shown in the artist's "albums" list
    # implicitly via that album.artist_id != this check.
    cursor.execute(
        """
        SELECT DISTINCT songs.id, songs.title, songs.artist_id, songs.album_id,
               songs.track_number, songs.disc_number, songs.duration,
               songs.file_path, songs.file_size, songs.bitrate,
               albums.title as album_title, albums.artwork_path,
               primary_artist.name as artist_name,
               sa.loudness, sa.integrated_loudness_lufs, sa.true_peak_dbfs
        FROM songs
        JOIN albums ON songs.album_id = albums.id
        JOIN artists as primary_artist ON songs.artist_id = primary_artist.id
        LEFT JOIN song_artists ON song_artists.song_id = songs.id
                              AND song_artists.artist_id = %s
        LEFT JOIN song_analysis sa ON songs.id = sa.song_id
        WHERE (songs.artist_id = %s OR song_artists.artist_id = %s)
          AND albums.artist_id != %s
        ORDER BY songs.title
        """,
        (artist_id, artist_id, artist_id, artist_id),
    )

    featured_songs = []
    for row in cursor.fetchall():
        song = dict(row)
        # Get all artists for this song
        cursor.execute(
            """
            SELECT artists.id, artists.name
            FROM song_artists
            JOIN artists ON song_artists.artist_id = artists.id
            WHERE song_artists.song_id = %s
            ORDER BY song_artists.position
            """,
            (song["id"],),
        )
        song["artists"] = [
            {"id": r["id"], "name": r["name"]} for r in cursor.fetchall()
        ]
        featured_songs.append(song)

    artist["featured_songs"] = featured_songs

    conn.close()
    return jsonify(artist)


# Album types the app understands. Primary type lives in albums.album_type;
# Compilation/Live/etc. live in albums.secondary_types (comma-separated).
_VALID_PRIMARY_TYPES = {"Album", "Single", "EP", "Broadcast", "Other"}


def _infer_album_type(track_count, artist_name):
    """Heuristic (album_type, secondary_types) from a release's shape.
    1 track -> Single, 2-6 -> EP, 7+ -> Album; a Various-Artists release is
    tagged Compilation. Used for import + the one-time backfill."""
    name = (artist_name or "").strip().lower()
    if name in ("various artists", "various", "va", "v/a"):
        return "Album", "Compilation"
    if track_count <= 1:
        return "Single", None
    if track_count <= 6:
        return "EP", None
    return "Album", None


@api.route("/api/albums/backfill-types", methods=["POST"])
def backfill_album_types():
    """One-time pass: infer album_type for music albums that have none, without
    overwriting any type already set (e.g. from a MusicBrainz match)."""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute(
            """
            SELECT a.id, a.artist_id, ar.name AS artist_name,
                   (SELECT COUNT(*) FROM songs s WHERE s.album_id = a.id) AS track_count
            FROM albums a
            JOIN artists ar ON a.artist_id = ar.id
            -- NULL/'' = never typed; lowercase 'album' = the importer's
            -- un-inferred hardcoded default (MusicBrainz sets 'Album'), so
            -- treat it as needing inference too. Real user/MB types (proper
            -- case) are left untouched.
            WHERE (a.album_type IS NULL OR a.album_type = '' OR a.album_type = 'album')
              AND EXISTS (
                  SELECT 1 FROM songs s
                  WHERE s.album_id = a.id AND s.source_type = 'local'
              )
            """
        )
        rows = cursor.fetchall()
        updated = 0
        for r in rows:
            atype, sec = _infer_album_type(r["track_count"] or 0, r["artist_name"])
            if sec:
                cursor.execute(
                    "UPDATE albums SET album_type = %s, secondary_types = %s WHERE id = %s",
                    (atype, sec, r["id"]),
                )
            else:
                cursor.execute(
                    "UPDATE albums SET album_type = %s WHERE id = %s",
                    (atype, r["id"]),
                )
            updated += 1
        conn.commit()
        conn.close()
        return jsonify({"success": True, "updated": updated, "scanned": len(rows)})
    except Exception as e:
        conn.close()
        return _error_response(e)


@api.route("/api/album/<int:album_id>/type", methods=["POST"])
def set_album_type(album_id):
    """Manually set an album's type. Body: {album_type, secondary_types}.
    album_type is a primary type (Album/Single/EP); secondary_types is an
    optional comma-separated string (Compilation/Live/Soundtrack/...)."""
    data = request.get_json() or {}
    album_type = data.get("album_type")
    secondary_types = data.get("secondary_types")

    if album_type not in _VALID_PRIMARY_TYPES:
        return jsonify(
            {"error": f"album_type must be one of {sorted(_VALID_PRIMARY_TYPES)}"}
        ), 400

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute("SELECT id FROM albums WHERE id = %s", (album_id,))
        if not cursor.fetchone():
            conn.close()
            return jsonify({"error": "Album not found"}), 404
        cursor.execute(
            "UPDATE albums SET album_type = %s, secondary_types = %s WHERE id = %s",
            (album_type, (secondary_types or None), album_id),
        )
        conn.commit()
        conn.close()
        return jsonify(
            {
                "success": True,
                "album_id": album_id,
                "album_type": album_type,
                "secondary_types": secondary_types or None,
            }
        )
    except Exception as e:
        conn.close()
        return _error_response(e)


def _set_scrobble_exclusion(table, entity_id, excluded):
    # table is a fixed literal ('albums'/'artists'), never user input.
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute(f"SELECT id FROM {table} WHERE id = %s", (entity_id,))
        if not cursor.fetchone():
            conn.close()
            return jsonify({"error": "Not found"}), 404
        cursor.execute(
            f"UPDATE {table} SET exclude_from_scrobble = %s WHERE id = %s",
            (bool(excluded), entity_id),
        )
        conn.commit()
        conn.close()
        return jsonify({"success": True, "id": entity_id, "excluded": bool(excluded)})
    except Exception as e:
        conn.close()
        return _error_response(e)


@api.route("/api/album/<int:album_id>/scrobble-exclude", methods=["POST"])
def set_album_scrobble_exclusion(album_id):
    """Toggle whether this album's plays scrobble to Last.fm. Body: {excluded: bool}."""
    data = request.get_json() or {}
    return _set_scrobble_exclusion("albums", album_id, data.get("excluded", True))


@api.route("/api/artist/<int:artist_id>/scrobble-exclude", methods=["POST"])
def set_artist_scrobble_exclusion(artist_id):
    """Toggle whether this artist's plays scrobble to Last.fm. Body: {excluded: bool}."""
    data = request.get_json() or {}
    return _set_scrobble_exclusion("artists", artist_id, data.get("excluded", True))


@api.route("/api/albums", methods=["GET"])
def get_albums():
    """Get all albums in the music library.

    Excludes albums that are actually podcast feeds — they appear in
    the podcast section instead. An album qualifies as a music album
    if it has at least one local song.
    """
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    cursor.execute(
        """
        SELECT albums.*, artists.name as artist_name
        FROM albums
        JOIN artists ON albums.artist_id = artists.id
        WHERE EXISTS (
            SELECT 1 FROM songs
            WHERE songs.album_id = albums.id
              AND songs.source_type = 'local'
        )
        ORDER BY albums.title
        """
    )
    albums = [dict(row) for row in cursor.fetchall()]

    conn.close()
    return jsonify(albums)


@api.route("/api/album/<int:album_id>/disc-names", methods=["GET"])
def get_album_disc_names(album_id):
    """Get disc names for an album"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    cursor.execute(
        "SELECT disc_number, disc_name FROM disc_names WHERE album_id = %s ORDER BY disc_number",
        (album_id,),
    )
    disc_names = {
        str(row["disc_number"]): row["disc_name"] for row in cursor.fetchall()
    }

    conn.close()
    return jsonify(disc_names)


@api.route("/api/albums/search", methods=["GET"])
def search_albums():
    """Search albums by name"""
    query = request.args.get("q", "").strip()
    if len(query) < 2:
        return jsonify({"albums": []})

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    normalized_query = re.sub(r"[^a-z0-9 ]", "", query.lower())
    strip_punct = "regexp_replace(LOWER({}), '[^a-z0-9 ]', '', 'g')"

    search_pattern = f"%{normalized_query}%"
    cursor.execute(
        f"""
        SELECT albums.*, artists.name as artist_name
        FROM albums
        JOIN artists ON albums.artist_id = artists.id
        WHERE {strip_punct.format('albums.title')} LIKE %s
           OR similarity({strip_punct.format('albums.title')}, %s) > 0.3
        ORDER BY
            CASE WHEN {strip_punct.format('albums.title')} LIKE %s THEN 0 ELSE 1 END,
            albums.title
        LIMIT 50
        """,
        (search_pattern, normalized_query, search_pattern),
    )
    albums = [dict(row) for row in cursor.fetchall()]

    conn.close()
    return jsonify({"albums": albums})


## ─────────── Browse: Genres, Years, Decades ───────────


@api.route("/api/browse/genres", methods=["GET"])
def browse_genres():
    """Get all unique genres with song counts (from Essentia analysis)"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    cursor.execute(
        "SELECT genres FROM song_analysis WHERE genres IS NOT NULL AND genres != '[]'"
    )
    rows = cursor.fetchall()
    conn.close()

    # Parse JSON genre arrays and count occurrences
    from collections import Counter
    import json

    genre_counts = Counter()
    for row in rows:
        try:
            genres = json.loads(row["genres"])
            for g in genres:
                # Genre format from Essentia: {"genre": "Rock---Alternative Rock", "confidence": 0.5}
                if isinstance(g, dict):
                    genre_name = g.get("genre", "")
                    confidence = g.get("confidence", 0)
                    # Only count genres with reasonable confidence
                    if genre_name and confidence >= 0.1:
                        genre_counts[genre_name] += 1
                elif isinstance(g, str):
                    genre_counts[g] += 1
        except (json.JSONDecodeError, TypeError):
            continue

    # Sort by count descending, return as list
    result = [
        {"genre": genre, "count": count}
        for genre, count in genre_counts.most_common()
    ]

    return jsonify(result)


@api.route("/api/browse/genre/<path:genre>/songs", methods=["GET"])
def browse_genre_songs(genre):
    """Get songs matching a specific genre"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    limit = request.args.get("limit", 100, type=int)
    offset = request.args.get("offset", 0, type=int)

    # Search for genre in the JSON array (using LIKE for simplicity)
    cursor.execute(
        """
        SELECT s.id, s.title, s.artist_id, s.album_id, s.track_number,
               s.disc_number, s.duration, s.file_path, s.file_size, s.bitrate,
               s.play_count, s.is_explicit, s.is_hdcd, s.audio_codec, s.audio_channels, s.is_atmos, sa.loudness, sa.integrated_loudness_lufs, sa.true_peak_dbfs,
               ar.name as artist_name, al.title as album_title
        FROM songs s
        JOIN song_analysis sa ON s.id = sa.song_id
        JOIN artists ar ON s.artist_id = ar.id
        JOIN albums al ON s.album_id = al.id
        WHERE sa.genres LIKE %s
        ORDER BY s.title
        LIMIT %s OFFSET %s
    """,
        (f"%{genre}%", limit, offset),
    )
    songs = [dict(row) for row in cursor.fetchall()]

    # Get total count for pagination
    cursor.execute(
        """
        SELECT COUNT(*) as total FROM songs s
        JOIN song_analysis sa ON s.id = sa.song_id
        WHERE sa.genres LIKE %s
    """,
        (f"%{genre}%",),
    )
    total = cursor.fetchone()["total"]

    conn.close()
    return jsonify({"songs": songs, "total": total, "genre": genre})


@api.route("/api/browse/years", methods=["GET"])
def browse_years():
    """Get all unique album years with counts"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    cursor.execute(
        """
        SELECT year, COUNT(*) as album_count, SUM(song_count) as song_count
        FROM albums
        WHERE year IS NOT NULL AND year > 0
        GROUP BY year
        ORDER BY year DESC
    """
    )
    years = [dict(row) for row in cursor.fetchall()]

    conn.close()
    return jsonify(years)


@api.route("/api/browse/decades", methods=["GET"])
def browse_decades():
    """Get albums grouped by decade with counts"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    cursor.execute(
        """
        SELECT (year / 10 * 10) as decade,
               COUNT(*) as album_count,
               SUM(song_count) as song_count
        FROM albums
        WHERE year IS NOT NULL AND year > 0
        GROUP BY decade
        ORDER BY decade DESC
    """
    )
    decades = [dict(row) for row in cursor.fetchall()]

    conn.close()
    return jsonify(decades)


@api.route("/api/browse/year/<int:year>/albums", methods=["GET"])
def browse_year_albums(year):
    """Get albums from a specific year"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    cursor.execute(
        """
        SELECT albums.*, artists.name as artist_name
        FROM albums
        JOIN artists ON albums.artist_id = artists.id
        WHERE albums.year = %s
        ORDER BY artists.name, albums.title
    """,
        (year,),
    )
    albums = [dict(row) for row in cursor.fetchall()]

    conn.close()
    return jsonify(albums)


@api.route("/api/browse/decade/<int:decade>/albums", methods=["GET"])
def browse_decade_albums(decade):
    """Get albums from a decade (e.g., 1990 = 1990-1999)"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    cursor.execute(
        """
        SELECT albums.*, artists.name as artist_name
        FROM albums
        JOIN artists ON albums.artist_id = artists.id
        WHERE albums.year >= %s AND albums.year < %s
        ORDER BY albums.year, artists.name, albums.title
    """,
        (decade, decade + 10),
    )
    albums = [dict(row) for row in cursor.fetchall()]

    conn.close()
    return jsonify(albums)


## ─────────── End Browse Endpoints ───────────


@api.route("/api/album/<int:album_id>", methods=["GET"])
def get_album(album_id):
    """Get album details with songs"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    # Get album with artist name
    cursor.execute(
        """
        SELECT albums.*, artists.name as artist_name 
        FROM albums 
        JOIN artists ON albums.artist_id = artists.id 
        WHERE albums.id = %s
    """,
        (album_id,),
    )
    result = cursor.fetchone()
    if not result:
        conn.close()
        return jsonify({"error": "Album not found"}), 404
    album = dict(result)

    # Get songs with loudness from analysis
    cursor.execute(
        """SELECT songs.*, sa.loudness, sa.integrated_loudness_lufs, sa.true_peak_dbfs 
           FROM songs 
           LEFT JOIN song_analysis sa ON songs.id = sa.song_id
           WHERE songs.album_id = %s 
           ORDER BY songs.disc_number, songs.track_number""",
        (album_id,),
    )
    songs = [dict(row) for row in cursor.fetchall()]

    # Add all artists for each song
    for song in songs:
        # Every song here belongs to this album, but `songs.*` carries no
        # album_title — so stamp it on each one. Without this the client's
        # Song.fromJson falls back to "Unknown Album" when playSong rebuilds
        # the queue from this endpoint, which breaks the Now-Playing display
        # and the special-waveform (lightsaber/DNA/EVH) album detection.
        song["album_title"] = album["title"]
        cursor.execute(
            """
            SELECT artists.id, artists.name
            FROM song_artists
            JOIN artists ON song_artists.artist_id = artists.id
            WHERE song_artists.song_id = %s
            ORDER BY song_artists.position
            """,
            (song["id"],),
        )
        artist_list = [
            {"id": row["id"], "name": row["name"]} for row in cursor.fetchall()
        ]
        song["artists"] = (
            artist_list
            if artist_list
            else [{"id": song["artist_id"], "name": album["artist_name"]}]
        )

    album["songs"] = songs

    # Album editions (ALBUM_EDITIONS_SPEC.md §4): sibling editions of
    # the same group, with a spatial summary so the picker can badge.
    if album.get("group_id"):
        cursor.execute(
            """SELECT a.id, a.title, a.edition_label,
                      COALESCE(MAX(s.audio_channels), 2) AS max_channels,
                      COALESCE(MAX(s.is_atmos), 0) AS has_atmos,
                      COUNT(s.id) AS song_count
               FROM albums a LEFT JOIN songs s ON s.album_id = a.id
               WHERE a.group_id = %s
               GROUP BY a.id, a.title, a.edition_label
               ORDER BY a.id""",
            (album["group_id"],),
        )
        album["editions"] = [dict(r) for r in cursor.fetchall()]

    # Get disc names
    cursor.execute(
        "SELECT disc_number, disc_name FROM disc_names WHERE album_id = %s ORDER BY disc_number",
        (album_id,),
    )
    disc_names = {row["disc_number"]: row["disc_name"] for row in cursor.fetchall()}
    album["disc_names"] = disc_names

    conn.close()
    return jsonify(album)


@api.route("/api/songs", methods=["GET"])
def get_songs():
    """Get songs with pagination"""
    page = request.args.get("page", 1, type=int)
    per_page = request.args.get("per_page", 50, type=int)
    per_page = min(per_page, 200)  # Cap at 200
    offset = (page - 1) * per_page

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    # Get total count — music library only, podcasts live elsewhere.
    cursor.execute("SELECT COUNT(*) as count FROM songs WHERE source_type = 'local'")
    total = cursor.fetchone()["count"]

    # Get paginated songs
    cursor.execute(
        """
        SELECT songs.id, songs.title, songs.artist_id, songs.album_id, songs.track_number,
               songs.disc_number, songs.duration, songs.file_path, songs.file_size, songs.bitrate,
               songs.is_explicit, songs.is_hdcd, songs.audio_codec, songs.audio_channels, songs.is_atmos, sa.loudness, sa.integrated_loudness_lufs, sa.true_peak_dbfs,
               songs.spectral_cutoff_hz, songs.transcode_suspect,
               artists.name as artist_name, albums.title as album_title
        FROM songs
        JOIN artists ON songs.artist_id = artists.id
        JOIN albums ON songs.album_id = albums.id
        LEFT JOIN song_analysis sa ON songs.id = sa.song_id
        WHERE songs.source_type = 'local'
        ORDER BY songs.title
        LIMIT %s OFFSET %s
        """,
        (per_page, offset),
    )
    songs = [dict(row) for row in cursor.fetchall()]

    # Batch fetch all artists for these songs in one query
    if songs:
        song_ids = [s["id"] for s in songs]
        placeholders = ",".join(["%s"] * len(song_ids))
        cursor.execute(
            f"""
            SELECT song_artists.song_id, artists.id, artists.name 
            FROM song_artists 
            JOIN artists ON song_artists.artist_id = artists.id 
            WHERE song_artists.song_id IN ({placeholders})
            ORDER BY song_artists.song_id, song_artists.position
            """,
            song_ids,
        )

        # Group artists by song_id
        song_artists_map = {}
        for row in cursor.fetchall():
            sid = row["song_id"]
            if sid not in song_artists_map:
                song_artists_map[sid] = []
            song_artists_map[sid].append({"id": row["id"], "name": row["name"]})

        # Assign artists to songs
        for song in songs:
            artists = song_artists_map.get(song["id"])
            song["artists"] = (
                artists
                if artists
                else [{"id": song["artist_id"], "name": song["artist_name"]}]
            )

    conn.close()
    return jsonify(
        {
            "songs": songs,
            "total": total,
            "page": page,
            "per_page": per_page,
            "total_pages": (total + per_page - 1) // per_page,
        }
    )


def _get_transcode_paths(song_id, quality):
    """Get cache paths and format info for a transcoded song."""
    quality_presets = {
        "high": ("aac", "320k", "m4a"),
        "medium": ("aac", "128k", "m4a"),
        "low": ("mp3", "96k", "mp3"),
    }
    preset = quality_presets.get(quality, ("aac", "320k", "m4a"))
    fmt, bitrate, ext_out = preset

    # Store transcoded files on the NAS alongside the music library
    music_lib = Config.MUSIC_LIBRARY_PATH
    cache_dir = os.path.join(music_lib, ".transcode_cache")
    os.makedirs(cache_dir, exist_ok=True)
    cache_key = f"{song_id}_{quality}_{bitrate}"
    cache_file = os.path.join(cache_dir, f"{cache_key}.{ext_out}")
    temp_file = cache_file + ".tmp"
    transcode_mime = "audio/mp4" if fmt == "aac" else "audio/mpeg"

    return fmt, bitrate, cache_file, temp_file, transcode_mime


# Module-level cooldown: songs whose transcode has failed recently.
# Map song_id → unix-timestamp of last failure. While a song is in
# this dict and the cooldown hasn't elapsed, we skip the FFmpeg
# attempt entirely. Without it, an unreachably-slow FLAC over UNC
# would trigger a fresh 5-minute FFmpeg subprocess on every play —
# burning CPU + network bandwidth that the streaming threads need.
_TRANSCODE_FAIL_COOLDOWN = {}
_TRANSCODE_FAIL_COOLDOWN_SECONDS = 60 * 30  # 30 minutes


def _transcode_to_cache(file_path, song_id, quality, is_hdcd=False):
    """Transcode a song to a cached file (blocking, NAS-local fallback).
    Returns (cache_file, mime_type) or (None, None) on failure.
    Primary transcoding is done by the desktop service — this is only used
    as a fallback when the desktop service is unavailable.
    """
    file_path = ensure_windows_path(file_path)

    ffmpeg_path = shutil.which("ffmpeg")
    if not ffmpeg_path:
        print(f"⚠️ [transcode] FFmpeg not found, cannot transcode song {song_id}")
        return None, None

    fmt, bitrate, cache_file, temp_file, transcode_mime = _get_transcode_paths(song_id, quality)

    if os.path.exists(cache_file):
        return cache_file, transcode_mime

    # Recent-failure cooldown — if this song's transcode failed within the
    # last `_TRANSCODE_FAIL_COOLDOWN_SECONDS`, don't retry. Otherwise a
    # song whose source FLAC is genuinely slow over the UNC share fires
    # a fresh FFmpeg subprocess on every play, each one fighting the
    # streaming threads for SMB bandwidth.
    last_fail = _TRANSCODE_FAIL_COOLDOWN.get(song_id)
    if last_fail and (time.time() - last_fail) < _TRANSCODE_FAIL_COOLDOWN_SECONDS:
        return None, None

    if os.path.exists(temp_file):
        # A .tmp is either a LIVE transcode or a CORPSE from a hard-killed
        # writer (nightly-restart kill, dead service job — nothing removes
        # the .tmp on a kill, only on a clean failure). A corpse wedges
        # every future play of this song in the 60s wait below — the
        # 2026-07-02 outage left 17 of them, some dating to April. A live
        # job finishes in ~15s, so anything older than 10 minutes is a
        # corpse: remove it and transcode fresh.
        try:
            tmp_age = time.time() - os.path.getmtime(temp_file)
        except OSError:
            tmp_age = 0.0
        if tmp_age > 600:
            print(
                f"🧟 [transcode] Song {song_id}: stale .tmp "
                f"({int(tmp_age)}s old) — removing corpse, transcoding fresh"
            )
            try:
                os.remove(temp_file)
            except OSError:
                pass
        else:
            print(f"⏳ [transcode] Song {song_id}: transcode already in progress, waiting...")
            for _ in range(600):  # Up to 60 seconds
                eventlet.sleep(0.1)
                if os.path.exists(cache_file):
                    return cache_file, transcode_mime
            print(f"⚠️ [transcode] Song {song_id}: timed out waiting for in-progress transcode")
            return None, None

    t_start = time.time()
    hdcd_tag = " [HDCD]" if is_hdcd else ""
    print(f"🔄 [transcode] Song {song_id}{hdcd_tag}: NAS fallback transcoding to {fmt} {bitrate}...")

    # Build ffmpeg command — inject HDCD decode filter for HDCD-flagged songs.
    # Constrain to a single CPU thread so the background transcode doesn't
    # starve the streaming greenthreads + their SMB read activity. The
    # job is opportunistic anyway; throughput per-job matters less than
    # not jamming the rest of the server.
    hdcd_args = ["-af", "hdcd"] if is_hdcd else []
    cpu_args = ["-threads", "1"]

    if fmt == "aac":
        ffmpeg_cmd = [
            ffmpeg_path, "-i", file_path,
        ] + hdcd_args + cpu_args + [
            "-vn", "-c:a", "aac", "-b:a", bitrate,
            "-movflags", "+faststart",
            "-f", "mp4", temp_file,
        ]
    else:
        ffmpeg_cmd = [
            ffmpeg_path, "-i", file_path,
        ] + hdcd_args + cpu_args + [
            "-vn", "-c:a", "libmp3lame", "-b:a", bitrate,
            "-f", "mp3", temp_file,
        ]

    try:
        # Run FFmpeg in a real OS thread so it doesn't block the eventlet
        # event loop. Bumped 120s → 300s — under SMB load on the NAS,
        # a 200MB FLAC can take longer to read+decode+encode than 120s,
        # and the timeout was firing on perfectly recoverable transcodes.
        result = eventlet.tpool.execute(safe_subprocess_run, ffmpeg_cmd, capture_output=True, timeout=300)
        elapsed = time.time() - t_start
        if result.returncode != 0:
            stderr = result.stderr.decode("utf-8", errors="replace")[:500]
            print(f"⚠️ [transcode] Song {song_id}: FFmpeg failed after {elapsed:.2f}s: {stderr}")
            if os.path.exists(temp_file):
                os.remove(temp_file)
            _TRANSCODE_FAIL_COOLDOWN[song_id] = time.time()
            return None, None
        else:
            os.rename(temp_file, cache_file)
            size = os.path.getsize(cache_file)
            print(f"✅ [transcode] Song {song_id}: cached {size} bytes in {elapsed:.2f}s → {cache_file}")
            # Clear any prior cooldown on success.
            _TRANSCODE_FAIL_COOLDOWN.pop(song_id, None)
            return cache_file, transcode_mime
    except Exception as e:
        print(f"⚠️ [transcode] Song {song_id}: FFmpeg error: {e}")
        if os.path.exists(temp_file):
            os.remove(temp_file)
        _TRANSCODE_FAIL_COOLDOWN[song_id] = time.time()
        return None, None


def _opportunistic_precache(file_path, song_id, quality, is_hdcd):
    """Background pre-cache of a lossless track to AAC for later mobile use.

    Runs in a greenthread off the serve path. Prefers the dedicated (off-box)
    transcode service; if that's DOWN it SKIPS rather than falling back to local
    FFmpeg. Local FFmpeg reads the source FLAC off the NAS over SMB and starves
    the streaming greenthreads — that contention is what produced multi-second
    stream serves and the ~10s crossfade stalls on the desktop (the dedicated
    service was down, so every lossless play spawned a local 5-minute FFmpeg job
    fighting playback for the SMB share). The pre-cache is non-urgent, so
    dropping it when the fast path is unavailable is the right trade.
    """
    try:
        # Is it already cached? This stat used to live on the HOT serve path —
        # moved here 2026-06-28 because a slow negative SMB stat on an uncached
        # file added up to ~7s to the song's serve latency (caught via the 🐌
        # instrumentation). Off the serve path, its latency no longer matters.
        _, _, cache_file, _, _ = _get_transcode_paths(song_id, quality)
        try:
            if _timed_smb(f"precache cache-check song {song_id}", smb_exists, cache_file):
                return  # already cached — nothing to do
        except SmbUnavailable:
            return  # share flaky — skip the non-urgent pre-cache
        from app.transcode import check_transcode_service, transcode_song
        if check_transcode_service():
            print(f"🔄 [transcode] Song {song_id}: opportunistic pre-cache via dedicated service")
            transcode_song(song_id, file_path, quality, is_hdcd=is_hdcd)
        else:
            print(
                f"⏭️ [transcode] Song {song_id}: skipped opportunistic pre-cache — "
                "transcode service down (would starve playback via local FFmpeg)"
            )
    except Exception as e:
        print(f"⚠️ [transcode] Song {song_id}: opportunistic pre-cache error: {e}")


def _trigger_desktop_transcode(song_id, file_path, quality="high", is_hdcd=False):
    """Fire-and-forget: ask the desktop transcode service to transcode this song.
    Non-blocking — if the service is down, we just log and move on.
    """
    try:
        from app.transcode import transcode_song
        eventlet.spawn_n(transcode_song, song_id, file_path, quality, is_hdcd=is_hdcd)
    except Exception as e:
        print(f"⚠️ [transcode] Could not trigger desktop transcode for song {song_id}: {e}")


# --- Pipeline reconciler ----------------------------------------------------
# Imports are supposed to leave every song transcoded (mobile AAC cache) and
# Essentia-analyzed, but the only triggers were fire-once at scan time — a
# service-down window at that moment, a mid-batch kill (nightly restart), or
# a yt-dlp import (skips the scanner entirely) stranded songs forever. The
# 2026-07-02 "mobile is dead" pileup was exactly this: recent FLAC imports
# with no AAC cache. This sweep runs shortly after startup and every
# 30 minutes; when eligible work exists and the service is up and idle it
# kicks the existing batch machinery (all of which no-ops safely when busy).

_RECONCILER_STARTUP_DELAY_S = 120
_RECONCILER_INTERVAL_S = 1800
_RECONCILER_CANCEL_GRACE_S = 6 * 3600  # honor an explicit user cancel this long


def _reconcile_pipelines():
    """One sweep: kick transcode/analysis batches if work is stranded."""
    # TRANSCODE — lossless library songs with no 'high' AAC cache file.
    # One cache-dir listing + one DB query; only kicks the (NAS) batch when
    # something is actually missing, so idle sweeps don't churn the service.
    try:
        from app.transcode import check_transcode_service, start_transcode_background

        music_lib = Config.MUSIC_LIBRARY_PATH
        cache_dir = os.path.join(music_lib, ".transcode_cache")
        cached_ids = set()
        for name in os.listdir(cache_dir):
            if name.endswith("_high_320k.m4a"):
                head = name.split("_", 1)[0]
                if head.isdigit():
                    cached_ids.add(int(head))

        db = get_db()
        conn = db.get_connection()
        cursor = db.get_cursor(conn)
        try:
            cursor.execute(
                "SELECT id FROM songs WHERE podcast_feed_id IS NULL "
                "AND file_path NOT ILIKE 'http%' "
                "AND (file_path ILIKE '%.flac' OR file_path ILIKE '%.wav' "
                "     OR file_path ILIKE '%.ape')"
            )
            lossless_ids = {row["id"] for row in cursor.fetchall()}
        finally:
            conn.close()

        missing = lossless_ids - cached_ids
        if missing:
            if check_transcode_service():
                print(
                    f"🔁 [reconciler] {len(missing)} lossless songs missing AAC "
                    "cache — kicking transcode batch"
                )
                start_transcode_background()
            else:
                print(
                    f"⏭️ [reconciler] {len(missing)} songs need transcoding but "
                    "the service is down — retrying next sweep"
                )
    except Exception as e:
        print(f"⚠️ [reconciler] transcode sweep error: {e}")

    # ANALYSIS — songs with no song_analysis row (same eligibility filter the
    # batch uses). Skips while a batch runs, and honors a recent explicit
    # cancel (the 2026-06-01 auto-resume trap) instead of resurrecting it.
    try:
        from app.audio_analysis import (
            OperationState,
            check_essentia_service,
            start_analysis_background,
        )

        db = get_db()
        conn = db.get_connection()
        cursor = db.get_cursor(conn)
        try:
            cursor.execute(
                "SELECT COUNT(*) AS n FROM songs s "
                "LEFT JOIN song_analysis sa ON sa.song_id = s.id "
                "LEFT JOIN song_analysis_failures f ON f.song_id = s.id "
                "WHERE sa.song_id IS NULL AND s.podcast_feed_id IS NULL "
                "AND s.podcast_episode_id IS NULL "
                "AND s.file_path NOT ILIKE 'http%' "
                "AND (s.duration IS NULL OR s.duration <= 1800) "
                "AND (f.song_id IS NULL OR (f.permanent = FALSE AND f.attempts < 2))"
            )
            unanalyzed = cursor.fetchone()["n"]
        finally:
            conn.close()

        if unanalyzed:
            op_state = OperationState(config.DATABASE_URL)
            state = op_state.get_state("audio_analysis")
            status = state.get("status")
            age_s = _op_state_age_s(state)
            # A LIVE batch touches its state on every song (seconds apart);
            # 'running' with no heartbeat for 15+ min is a corpse. The
            # 06-15 batch died 06-17 and sat 'running' for 15 DAYS, blocking
            # both start_analysis_background's guard and this sweep.
            if status == "running" and age_s > 900:
                print(
                    f"🧟 [reconciler] analysis state says 'running' but last "
                    f"heartbeat was {int(age_s / 60)} min ago — marking failed "
                    "and restarting"
                )
                op_state.fail_operation(
                    "audio_analysis",
                    "stale 'running' state — batch died without updating",
                )
                status = "failed"
            if status == "running":
                pass  # a batch is already chewing through it
            elif status == "cancelled" and _op_state_age_s(state) < _RECONCILER_CANCEL_GRACE_S:
                print(
                    f"⏸️ [reconciler] {unanalyzed} songs unanalyzed but analysis "
                    "was cancelled recently — honoring the cancel"
                )
            elif check_essentia_service():
                print(
                    f"🔁 [reconciler] {unanalyzed} songs missing analysis — "
                    "starting Essentia batch"
                )
                start_analysis_background(config.DATABASE_URL)
            else:
                print(
                    f"⏭️ [reconciler] {unanalyzed} songs need analysis but "
                    "Essentia is down — retrying next sweep"
                )
    except Exception as e:
        print(f"⚠️ [reconciler] analysis sweep error: {e}")


def _op_state_age_s(state):
    """Seconds since the operation state was last touched. Unknown → huge
    (treat an unparseable timestamp as ancient so it can't block forever)."""
    ts = state.get("updated_at") or state.get("completed_at")
    try:
        if hasattr(ts, "timestamp"):
            return time.time() - ts.timestamp()
        from datetime import datetime
        return time.time() - datetime.fromisoformat(str(ts)).timestamp()
    except Exception:
        return float("inf")


def start_pipeline_reconciler(app):
    """Start the self-healing transcode/analysis sweep greenthread."""

    def _loop():
        eventlet.sleep(_RECONCILER_STARTUP_DELAY_S)
        while True:
            with app.app_context():
                _reconcile_pipelines()
            eventlet.sleep(_RECONCILER_INTERVAL_S)

    eventlet.spawn_n(_loop)
    print("🔁 Pipeline reconciler started — transcode/analysis self-heal every 30 min")


@api.route("/api/prefetch/<int:song_id>", methods=["POST"])
def prefetch_song(song_id):
    """Pre-transcode a song in the background so it's cached for instant playback.
    With pre-transcoding, this mainly serves as a fallback — the desktop service
    should have already transcoded most songs. If not, trigger it now.
    """
    quality = request.args.get("quality", "high")
    if quality == "lossless":
        return jsonify({"status": "skipped", "reason": "lossless needs no transcode"}), 200

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    cursor.execute("SELECT file_path FROM songs WHERE id = %s", (song_id,))
    row = cursor.fetchone()
    conn.close()

    if not row or not os.path.exists(row["file_path"]):
        return jsonify({"status": "skipped", "reason": "song not found"}), 200

    # Check if already cached or in progress
    _, _, cache_file, temp_file, _ = _get_transcode_paths(song_id, quality)
    if os.path.exists(cache_file):
        return jsonify({"status": "cached"}), 200
    if os.path.exists(temp_file):
        return jsonify({"status": "already_transcoding"}), 200

    # Transcode locally in background — no external service needed
    file_path = row["file_path"]
    eventlet.spawn_n(_transcode_to_cache, file_path, song_id, quality)

    return jsonify({"status": "transcoding"}), 202


def _podcast_stream_url(cursor, song_id, row):
    """Return a fresh CDN URL for a podcast song, resolving if needed.

    Uses the cached resolved_url if it exists and hasn't expired.
    Otherwise resolves the tracker chain now, updates the row, and
    returns the fresh URL. Falls back to the original tracker URL if
    resolution fails (at least something will play, just slowly).

    Also fires a greenthread to populate chapters if they haven't been
    cached yet for this song — first-play triggers the ID3 parse, every
    subsequent play hits the cache. Non-blocking, never affects the
    returned URL.
    """
    resolved_url = row.get("resolved_url")
    expires_at = row.get("resolved_url_expires_at")
    source_url = row.get("source_url") or row.get("file_path")

    # Fire-and-forget chapter fetch. Safe to call every time; the helper
    # short-circuits if chapters already exist.
    eventlet.spawn_n(_ensure_chapters_async, song_id)

    # 60s grace window — don't hand out a URL that'll expire mid-playback.
    if resolved_url and (expires_at is None or expires_at > datetime.utcnow() + timedelta(seconds=60)):
        return resolved_url

    # Need to resolve now. Try to; if it fails, fall back to the original URL.
    try:
        final_url, new_expires = resolve_audio_url(source_url)
        cursor.execute(
            """
            UPDATE songs
               SET resolved_url = %s,
                   resolved_url_expires_at = %s,
                   source_url = COALESCE(source_url, %s)
             WHERE id = %s
            """,
            (final_url, new_expires, source_url, song_id),
        )
        return final_url
    except Exception as e:
        print(f"[stream] Podcast song {song_id}: resolve failed ({e}), falling back to source URL")
        return source_url


def _ensure_chapters_async(song_id):
    """Background wrapper around ensure_chapters_for_song — safe for greenthread."""
    try:
        from app.chapters import ensure_chapters_for_song
        db = get_db()
        n = ensure_chapters_for_song(db, song_id)
        if n:
            print(f"[chapters] Song {song_id}: cached {n} chapter(s) from ID3")
    except Exception as e:
        print(f"[chapters] Song {song_id}: {e}")


@api.route("/api/stream/<int:song_id>", methods=["GET", "HEAD"])
def stream_song(song_id):
    """Stream audio file — simple 3-path approach with pre-transcoded cache.
    For transcoded (non-lossless) requests:
      1. Cache hit → send_file (instant, seekable, complete file)
      2. Not cached → serve original file as fallback + trigger desktop transcode
    Lossless requests always serve the original file.

    Podcast rows (source_type='podcast') short-circuit with a 302 redirect
    to the resolved CDN URL — bypasses the tracker chain on every play.
    """
    t_start = time.time()
    range_header = request.headers.get("Range", "none")

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    cursor.execute(
        "SELECT file_path, duration, is_hdcd, source_type, file_size, "
        "resolved_url, resolved_url_expires_at, source_url "
        "FROM songs WHERE id = %s",
        (song_id,),
    )
    row = cursor.fetchone()

    if not row:
        conn.close()
        return jsonify({"error": "Song not found"}), 404

    # Podcast short-circuit: redirect to resolved CDN URL.
    if row.get("source_type") == "podcast":
        target = _podcast_stream_url(cursor, song_id, row)
        conn.commit()
        conn.close()
        elapsed = time.time() - t_start
        print(f"🎙️ [stream] Podcast song {song_id}: 302 → CDN ({elapsed:.3f}s)")
        return redirect(target, code=302)

    conn.close()

    file_path = ensure_windows_path(row["file_path"])
    is_hdcd = row.get("is_hdcd") == 1

    # SMB-resilient stat. If the share is stale, return 503 fast so the
    # phone shows a brief error instead of an indefinite spinner — and the
    # eventlet hub stays free for /api/logs, /api/health, and other
    # streams behind us. See _smb_call comment block above.
    try:
        # Use the retrying variant here specifically because lookahead
        # pre-warm HEADs land on cold SMB sessions and the first stat()
        # often fails before the redirector wakes the session back up.
        if not _timed_smb(f"exists song {song_id}", smb_exists_with_retry, file_path):
            return jsonify({"error": "File not found"}), 404
    except SmbUnavailable:
        print(f"🔴 [stream] Song {song_id}: SMB share unreachable on stat({file_path})")
        return jsonify({"error": "Storage unavailable"}), 503

    quality = request.args.get("quality", "lossless")

    # Cast surround: multichannel PCM sources get a pre-baked E-AC-3 sidecar
    # (<file>.cast.m4a) so the C2's eARC carries 5.1 to the Denon instead of
    # folding raw >2ch PCM to stereo. Sidecar missing → fall through and serve
    # the original (stereo at the TV, but it plays).
    #
    # NOTE: no send_file() here — swap the path and fall through to the
    # Range-aware tpool streamer below. send_file serves 8KB chunks on the
    # eventlet hub thread, which produced audible DD+ decoder blips on the
    # receiver (a compressed bitstream mutes+relocks on any stall; PCM just
    # absorbs the same hiccup).
    _serving_sidecar = False
    if quality == "cast":
        _cast_sidecar = os.path.splitext(file_path)[0] + ".cast.m4a"
        try:
            if smb_exists(_cast_sidecar):
                file_path = _cast_sidecar
                _serving_sidecar = True
                row["file_size"] = None   # sidecar size ≠ original's; stat below
                print(f"🎬 [stream] Song {song_id}: CAST SIDECAR — {request.method} "
                      f"Range={range_header}")
        except SmbUnavailable:
            print(f"[stream] Song {song_id}: SMB unreachable on sidecar stat")
            return jsonify({"error": "Storage unavailable"}), 503
        quality = "lossless"  # serve via the hardened lossless path below

    # Already-compressed formats: serve original on cellular too. Re-encoding
    # an OPUS/MP3/AAC/M4A/OGG file to lossy AAC is pointless (already small,
    # and generation-loss isn't worth the CPU/latency). Lossless inputs still
    # go through transcode for the bandwidth savings.
    _passthrough_compressed = {".mp3", ".m4a", ".aac", ".opus", ".ogg", ".oga"}
    _stream_ext = os.path.splitext(file_path)[1].lower()

    if quality != "lossless" and _stream_ext not in _passthrough_compressed:
        fmt, bitrate, cache_file, temp_file, transcode_mime = _get_transcode_paths(song_id, quality)

        # Path 1: Cache hit — pre-transcoded file ready, instant seekable playback
        try:
            cache_hit = smb_exists(cache_file)
        except SmbUnavailable:
            print(f"🔴 [stream] Song {song_id}: SMB share unreachable on cache stat")
            return jsonify({"error": "Storage unavailable"}), 503
        if cache_hit:
            elapsed = time.time() - t_start
            try:
                size = smb_getsize(cache_file)
            except SmbUnavailable:
                return jsonify({"error": "Storage unavailable"}), 503
            print(f"⚡ [stream] Song {song_id}: CACHE HIT — {size} bytes, {request.method} Range={range_header} ({elapsed:.3f}s)")
            return send_file(cache_file, mimetype=transcode_mime, conditional=True)

        # Path 2: Not cached — serve the ORIGINAL immediately; the
        # opportunistic pre-cache below transcodes in the background for
        # every later play. The old behavior transcoded INLINE, sending
        # ZERO response bytes for 14s (or up to 60s stuck behind another
        # request's job) — mobile players time out at ~8 silent seconds
        # and Source-error → skip, which is exactly the 2026-07-02
        # "mobile playback is dead" symptom. A first play costs full-fat
        # bandwidth once; a song that PLAYS beats a song that's small.
        print(
            f"🔄 [stream] Song {song_id}: NO CACHE — serving original now, "
            f"background transcode will cover the next play ({quality})"
        )

    # Lossless or fallback — serve original file
    ext = os.path.splitext(file_path)[1].lower()
    mime_types = {
        ".mp3": "audio/mpeg",
        ".flac": "audio/flac",
        ".wav": "audio/wav",
        ".aac": "audio/aac",
        ".m4a": "audio/mp4",
        ".ogg": "audio/ogg",
        ".opus": "audio/opus",
        ".wma": "audio/x-ms-wma",
        ".aiff": "audio/aiff",
        ".ape": "audio/ape",
        ".wv": "audio/wavpack",
        ".dsf": "audio/dsf",
        ".dff": "audio/dff",
    }
    mime_type = mime_types.get(ext, "audio/mpeg")

    # Opportunistic background transcode: if this is a lossless format and
    # we don't have a "high" quality cache yet, transcode in the background
    # so it's ready for mobile playback later. SMB-stale stat here is
    # non-fatal — we just skip the prefetch and serve the original.
    lossless_exts = {".flac", ".wav", ".aiff", ".ape", ".wv", ".dsf", ".dff"}
    if ext in lossless_exts:
        # Pre-cache a mobile-friendly copy in the background. The "is it already
        # cached?" SMB stat now lives INSIDE _opportunistic_precache — it used to
        # be right here on the hot path, where a slow NEGATIVE stat on an
        # uncached file added up to ~7s to the serve (caught red-handed
        # 2026-06-28: song 41320 stat'd its missing 'high' cache for 7.1s while
        # cached songs served instantly). Only ever uses the dedicated off-box
        # service, never local FFmpeg (which starves playback).
        eventlet.spawn_n(_opportunistic_precache, file_path, song_id, "high", is_hdcd)

    elapsed = time.time() - t_start
    # Size: prefer the value already in the DB so we skip an SMB stat on the hot
    # path entirely. Only stat (and backfill) when the row doesn't have it.
    size = row.get("file_size") or 0
    if not size:
        try:
            size = _timed_smb(f"getsize song {song_id}", smb_getsize, file_path)
        except SmbUnavailable:
            print(f"🔴 [stream] Song {song_id}: SMB share unreachable on getsize({file_path})")
            return jsonify({"error": "Storage unavailable"}), 503
        if not _serving_sidecar:   # never write the sidecar's size onto the song row
            eventlet.spawn_n(_backfill_file_size, song_id, size)
        size_src = "stat" if _serving_sidecar else "stat+backfill"
    else:
        size_src = "db"
    print(f"📁 [stream] Song {song_id}: serving original {ext} — {size} bytes ({size_src}), {request.method} Range={range_header} ({elapsed:.3f}s)")

    # Parse the HTTP Range (the player + the cast device both seek/stream via
    # byte ranges). Then serve via the hub-friendly tpool stream above instead
    # of send_file(), so a slow SMB read can't freeze the whole backend.
    start, end, status = 0, size - 1, 200
    if range_header and range_header != "none" and range_header.startswith("bytes="):
        spec = range_header.split("=", 1)[1].split(",", 1)[0].strip()
        s, _, e = spec.partition("-")
        try:
            if s:
                start = int(s)
                end = int(e) if e else size - 1
            elif e:  # suffix range: last N bytes
                start = max(0, size - int(e))
        except ValueError:
            start, end = 0, size - 1
        if start >= size or start > end:
            return Response("", status=416,
                            headers={"Content-Range": f"bytes */{size}"})
        end = min(end, size - 1)
        status = 206
    length = end - start + 1

    headers = {
        "Content-Type": mime_type,
        "Accept-Ranges": "bytes",
        "Content-Length": str(length),
        "Cache-Control": "no-cache",
    }
    if status == 206:
        headers["Content-Range"] = f"bytes {start}-{end}/{size}"

    if request.method == "HEAD":
        resp = Response("", status=status, headers=headers)
        # Werkzeug zeroes Content-Length for an empty body — force the real size
        # so a HEAD reports what a GET would return.
        resp.automatically_set_content_length = False
        resp.headers["Content-Length"] = str(length)
        return resp

    fh = _open_stream_fh(file_path, start, song_id)
    if fh is None:
        print(f"🔴 [stream] Song {song_id}: SMB unreachable on open (after retry)")
        return jsonify({"error": "Storage unavailable"}), 503

    return Response(
        stream_with_context(_tpool_file_stream(fh, length)),
        status=status,
        headers=headers,
    )


@api.route("/api/search", methods=["GET"])
def search():
    """Search for artists, albums, or songs"""
    from app.utils import normalize_text_for_search

    query = request.args.get("q", "")

    if not query:
        return jsonify({"artists": [], "albums": [], "songs": []})

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    # Normalize the search query for special character matching
    normalized_query = normalize_text_for_search(query)
    search_term = f"%{normalized_query}%"

    # Strip punctuation helper for consistent matching
    strip_punct_sql = "regexp_replace(LOWER({}), '[^a-z0-9 ]', '', 'g')"

    # Search artists - punct stripping + fuzzy fallback.
    # Music-library search: hide artists that only host podcasts.
    cursor.execute(
        f"""SELECT * FROM artists
            WHERE ({strip_punct_sql.format('name')} LIKE %s
               OR similarity({strip_punct_sql.format('name')}, %s) > 0.3
               OR EXISTS (
                  SELECT 1 FROM artist_aliases aa
                  WHERE aa.artist_id = artists.id
                    AND {strip_punct_sql.format('aa.alias')} LIKE %s))
              AND EXISTS (
                  SELECT 1 FROM songs
                  WHERE songs.artist_id = artists.id
                    AND songs.source_type = 'local')
            ORDER BY
                CASE
                    WHEN {strip_punct_sql.format('name')} = %s THEN 0
                    WHEN EXISTS (
                        SELECT 1 FROM artist_aliases aa
                        WHERE aa.artist_id = artists.id
                          AND {strip_punct_sql.format('aa.alias')} = %s) THEN 0
                    WHEN {strip_punct_sql.format('name')} LIKE %s THEN 1
                    WHEN {strip_punct_sql.format('name')} LIKE %s THEN 2
                    ELSE 3
                END,
                song_count DESC,
                name
            LIMIT 20""",
        (
            search_term, normalized_query, search_term,  # WHERE: name LIKE, similarity, alias LIKE
            normalized_query, normalized_query,            # rank 0: exact name, exact alias
            f"{normalized_query}%", search_term,           # rank 1: name prefix, rank 2: name substring
        ),
    )
    artists = [dict(row) for row in cursor.fetchall()]

    # Search albums - hide podcast-feed albums from music search.
    cursor.execute(
        f"""
        SELECT albums.*, artists.name as artist_name
        FROM albums
        JOIN artists ON albums.artist_id = artists.id
        WHERE ({strip_punct_sql.format('albums.title')} LIKE %s
           OR {strip_punct_sql.format('artists.name')} LIKE %s
           OR similarity({strip_punct_sql.format('albums.title')}, %s) > 0.3)
          AND EXISTS (
              SELECT 1 FROM songs
              WHERE songs.album_id = albums.id
                AND songs.source_type = 'local')
        ORDER BY
            CASE WHEN {strip_punct_sql.format('albums.title')} LIKE %s THEN 0 ELSE 1 END,
            albums.title
        LIMIT 20
    """,
        (search_term, search_term, normalized_query, search_term),
    )
    albums = [dict(row) for row in cursor.fetchall()]

    # Search songs - split query into terms and match all across title/artist/album
    # Use regexp_replace to strip punctuation from DB values (matches normalize_text_for_search)
    terms = normalized_query.split()
    strip_punct = "regexp_replace(LOWER({field}), '[^a-z0-9 ]', '', 'g')"

    # Build WHERE clause: each term must appear in title, artist, or album
    where_conditions = []
    params = []
    for term in terms:
        term_pattern = f"%{term}%"
        where_conditions.append(
            f"({strip_punct.format(field='songs.title')} LIKE %s"
            f" OR {strip_punct.format(field='primary_artist.name')} LIKE %s"
            f" OR {strip_punct.format(field='albums.title')} LIKE %s"
            f" OR {strip_punct.format(field='collab_artist.name')} LIKE %s)"
        )
        params.extend([term_pattern, term_pattern, term_pattern, term_pattern])

    where_clause = " AND ".join(where_conditions) if where_conditions else "1=1"

    # Also include fuzzy/trigram matches for typo tolerance (pg_trgm)
    fuzzy_clause = (
        f"similarity({strip_punct.format(field='songs.title')}, %s) > 0.3"
        f" AND {strip_punct.format(field='primary_artist.name')} LIKE %s"
    )
    # Extract artist terms (last word(s) that match an artist pattern)
    # Simple heuristic: use the full normalized query for title similarity
    # and require at least one term to match the artist
    artist_pattern = f"%{terms[-1]}%" if terms else "%%"

    # Add relevance scoring parameters (each used twice - exact and partial)
    relevance_params = [
        normalized_query,  # exact album
        f"%{normalized_query}%",  # partial album
        normalized_query,  # exact song title
        f"%{normalized_query}%",  # partial song title
        normalized_query,  # exact artist
    ]

    cursor.execute(
        f"""
        SELECT songs.id, songs.title, songs.artist_id, songs.album_id, songs.track_number,
               songs.disc_number, songs.duration, songs.file_path, songs.file_size, songs.bitrate,
               songs.is_explicit, songs.is_hdcd, songs.audio_codec, songs.audio_channels, songs.is_atmos, sa.loudness, sa.integrated_loudness_lufs, sa.true_peak_dbfs,
               primary_artist.name as artist_name, albums.title as album_title
        FROM songs
        JOIN artists AS primary_artist ON songs.artist_id = primary_artist.id
        JOIN albums ON songs.album_id = albums.id
        LEFT JOIN song_analysis sa ON songs.id = sa.song_id
        WHERE songs.source_type = 'local'
          AND songs.id IN (
            SELECT DISTINCT songs.id
            FROM songs
            JOIN artists AS primary_artist ON songs.artist_id = primary_artist.id
            JOIN albums ON songs.album_id = albums.id
            LEFT JOIN song_artists ON songs.id = song_artists.song_id
            LEFT JOIN artists AS collab_artist ON song_artists.artist_id = collab_artist.id
            WHERE songs.source_type = 'local'
              AND (({where_clause})
               OR ({fuzzy_clause}))
        )
        ORDER BY
            CASE
                WHEN regexp_replace(LOWER(albums.title), '[^a-z0-9 ]', '', 'g') = %s THEN 0
                WHEN regexp_replace(LOWER(albums.title), '[^a-z0-9 ]', '', 'g') LIKE %s THEN 1
                WHEN regexp_replace(LOWER(songs.title), '[^a-z0-9 ]', '', 'g') = %s THEN 2
                WHEN regexp_replace(LOWER(songs.title), '[^a-z0-9 ]', '', 'g') LIKE %s THEN 3
                WHEN regexp_replace(LOWER(primary_artist.name), '[^a-z0-9 ]', '', 'g') = %s THEN 4
                ELSE 5
            END,
            albums.title,
            songs.disc_number,
            songs.track_number
        LIMIT 50
    """,
        params + [normalized_query, artist_pattern] + relevance_params,
    )
    songs = [dict(row) for row in cursor.fetchall()]

    # Add all artists for each song
    for song in songs:
        cursor.execute(
            """
            SELECT artists.id, artists.name 
            FROM song_artists 
            JOIN artists ON song_artists.artist_id = artists.id 
            WHERE song_artists.song_id = %s
            ORDER BY song_artists.position
            """,
            (song["id"],),
        )
        artist_list = [
            {"id": row["id"], "name": row["name"]} for row in cursor.fetchall()
        ]
        song["artists"] = (
            artist_list
            if artist_list
            else [{"id": song["artist_id"], "name": song["artist_name"]}]
        )

    conn.close()

    return jsonify({"artists": artists, "albums": albums, "songs": songs})


@api.route("/api/debug/search", methods=["GET"])
def debug_search():
    """Debug search query"""
    from app.utils import normalize_text_for_search

    query = request.args.get("q", "")

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    normalized_query = normalize_text_for_search(query)
    terms = normalized_query.split()

    # Test: find Van Halen II songs and check if they match
    cursor.execute(
        """
        SELECT songs.title, 
               LOWER(songs.title) as norm_title,
               artists.name as artist,
               albums.title as album
        FROM songs
        JOIN artists ON songs.artist_id = artists.id
        JOIN albums ON songs.album_id = albums.id
        WHERE albums.title = 'Van Halen II'
        LIMIT 5
    """
    )

    vh2_songs = [dict(row) for row in cursor.fetchall()]

    # Check which terms match
    for song in vh2_songs:
        song["term_matches"] = {}
        for term in terms:
            pattern = f"%{term}%"
            matches_title = term in song["norm_title"]
            matches_artist = term in normalize_text_for_search(song["artist"])
            matches_album = term in normalize_text_for_search(song["album"])
            song["term_matches"][term] = {
                "title": matches_title,
                "artist": matches_artist,
                "album": matches_album,
                "any": matches_title or matches_artist or matches_album,
            }

    conn.close()

    return jsonify(
        {
            "query": query,
            "normalized": normalized_query,
            "terms": terms,
            "vh2_songs": vh2_songs,
        }
    )


@api.route("/api/debug/sql", methods=["GET"])
def debug_sql():
    """Debug the actual SQL query"""
    from app.utils import normalize_text_for_search

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    # Simple direct test - does LIKE work with NORMALIZE?
    cursor.execute(
        """
        SELECT songs.title, LOWER(songs.title) as norm
        FROM songs
        WHERE LOWER(songs.title) LIKE '%you%'
        LIMIT 10
    """
    )

    direct_results = [dict(row) for row in cursor.fetchall()]

    conn.close()

    return jsonify({"direct_like_results": direct_results})


@api.route("/api/debug/fullquery", methods=["GET"])
def debug_fullquery():
    """Debug the full search query"""
    from app.utils import normalize_text_for_search

    query = request.args.get("q", "van halen you")
    normalized_query = normalize_text_for_search(query)
    terms = normalized_query.split()

    # Build WHERE clause exactly like the real search (with punct stripping)
    strip_punct = "regexp_replace(LOWER({}), '[^a-z0-9 ]', '', 'g')"
    where_conditions = []
    params = []
    for term in terms:
        term_pattern = f"%{term}%"
        where_conditions.append(
            f"({strip_punct.format('songs.title')} LIKE %s OR {strip_punct.format('primary_artist.name')} LIKE %s OR {strip_punct.format('albums.title')} LIKE %s OR {strip_punct.format('collab_artist.name')} LIKE %s)"
        )
        params.extend([term_pattern, term_pattern, term_pattern, term_pattern])

    where_clause = " AND ".join(where_conditions)

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    sql = f"""
        SELECT DISTINCT songs.id, songs.title,
               primary_artist.name as artist_name, albums.title as album_title 
        FROM songs 
        JOIN artists AS primary_artist ON songs.artist_id = primary_artist.id 
        JOIN albums ON songs.album_id = albums.id 
        LEFT JOIN song_artists ON songs.id = song_artists.song_id
        LEFT JOIN artists AS collab_artist ON song_artists.artist_id = collab_artist.id
        WHERE {where_clause}
        LIMIT 10
    """

    cursor.execute(sql, params)
    results = [dict(row) for row in cursor.fetchall()]

    conn.close()

    return jsonify(
        {
            "query": query,
            "terms": terms,
            "params": params,
            "where_clause": where_clause,
            "result_count": len(results),
            "results": results,
        }
    )


@api.route("/api/logs", methods=["GET"])
def get_logs():
    """Get recent server + device logs from the in-memory ring buffer.

    Supports optional filters: ?level=error, ?device=SM-S928U, ?search=x.
    The combined file at backend/logs/combined.log is the canonical long-
    term record; this endpoint is for quick in-app inspection.
    """
    from app.log_service import log_service

    lines = request.args.get("lines", 200, type=int)
    level = request.args.get("level")  # "info", "error", "warning"
    device = request.args.get("device")
    search = request.args.get("search")

    entries = log_service.get_recent(lines=lines, level=level, search=search, device=device)
    return jsonify({
        "logs": entries,
        "count": len(entries),
        "log_file_path": log_service.log_file_path,
    })


@api.route("/api/logs/ingest", methods=["POST"])
def ingest_device_logs():
    """Receive a batch of frontend log entries from a connected device.

    Body:
      {
        "device_id": "abc123",       // optional stable id
        "device_name": "SM-S928U",   // human-readable, shown in logs
        "entries": [
          {"timestamp": "2026-04-19T...", "level": "error", "message": "..."},
          ...
        ]
      }

    Devices post on a periodic schedule so a multi-device incident can
    be reassembled from a single backend log file. Returns the count of
    entries actually ingested.
    """
    from app.log_service import log_service

    data = request.get_json(silent=True) or {}
    device_name = (data.get("device_name") or "").strip() or "DEVICE"
    entries = data.get("entries")

    if not isinstance(entries, list) or not entries:
        return jsonify({"ingested": 0}), 200

    count = log_service.ingest_from_device(device_name, entries)
    return jsonify({"ingested": count})


@api.route("/api/rescan", methods=["POST"])
@auth.require_admin
def rescan_library():
    """Manually trigger library rescan"""
    from app.scanner import MusicScanner

    # Generate unique operation ID
    operation_id = f"scan_{uuid.uuid4().hex[:8]}"

    def run_scan():
        """Run scan in background thread"""
        db = get_db()
        scanner = MusicScanner(db, progress_tracker, operation_id)
        scanner.scan_library()

        # Auto-trigger audio analysis for new songs
        try:
            from app.audio_analysis import check_essentia_service, start_analysis_background
            if check_essentia_service():
                result = start_analysis_background(config.DATABASE_URL)
                if result.get("success"):
                    print("Auto-started audio analysis for new songs")
        except Exception as e:
            print(f"Could not auto-start analysis: {e}")

        # Auto-trigger transcoding for new songs (desktop service preferred, local fallback)
        try:
            from app.transcode import check_transcode_service, start_transcode_background
            if check_transcode_service():
                result = start_transcode_background()
                if result.get("success"):
                    print("Auto-started desktop transcoding for new songs")
            elif not _batch_transcode["running"]:
                result = _start_local_batch_transcode(quality="high", workers=4)
                if result.get("success"):
                    print(f"Auto-started local transcoding: {result.get('message')}")
        except Exception as e:
            print(f"Could not auto-start transcoding: {e}")

    # Start scan in background thread
    thread = threading.Thread(target=run_scan)
    thread.daemon = True
    thread.start()

    # Return immediately with operation ID
    return jsonify({"message": "Library scan started", "operation_id": operation_id})


@api.route("/api/scan-folder", methods=["POST"])
@auth.require_admin
def scan_folder():
    """Scan a specific folder within the music library"""
    from app.scanner import MusicScanner

    data = request.get_json()
    target_folder = data.get("folder_path")

    if not target_folder:
        return jsonify({"error": "folder_path is required"}), 400

    # Generate unique operation ID
    operation_id = f"folder_scan_{uuid.uuid4().hex[:8]}"

    def run_scan():
        """Run folder scan in background thread"""
        db = get_db()
        scanner = MusicScanner(db, progress_tracker, operation_id)
        scanner.scan_folder(target_folder)

        # Auto-trigger audio analysis for new songs
        try:
            from app.audio_analysis import check_essentia_service, start_analysis_background
            if check_essentia_service():
                result = start_analysis_background(config.DATABASE_URL)
                if result.get("success"):
                    print("Auto-started audio analysis for new songs")
        except Exception as e:
            print(f"Could not auto-start analysis: {e}")

        # Auto-trigger transcoding for new songs (desktop service preferred, local fallback)
        try:
            from app.transcode import check_transcode_service, start_transcode_background
            if check_transcode_service():
                result = start_transcode_background()
                if result.get("success"):
                    print("Auto-started desktop transcoding for new songs")
            elif not _batch_transcode["running"]:
                result = _start_local_batch_transcode(quality="high", workers=4)
                if result.get("success"):
                    print(f"Auto-started local transcoding: {result.get('message')}")
        except Exception as e:
            print(f"Could not auto-start transcoding: {e}")

    # Start scan in background thread
    thread = threading.Thread(target=run_scan)
    thread.daemon = True
    thread.start()

    # Return immediately with operation ID
    return jsonify({"message": "Folder scan started", "operation_id": operation_id})


@api.route("/api/scan-new", methods=["POST"])
@auth.require_admin
def scan_new_files():
    """Incremental scan - only import new files not already in database"""
    from app.scanner import MusicScanner
    from app.scanner_incremental import scan_new_files_only

    # Generate unique operation ID
    operation_id = f"incremental_scan_{uuid.uuid4().hex[:8]}"

    def run_scan():
        """Run incremental scan in background thread"""
        db = get_db()
        scanner = MusicScanner(db, progress_tracker, operation_id)
        scan_new_files_only(scanner)

        # Auto-trigger audio analysis for new songs
        try:
            from app.audio_analysis import check_essentia_service, start_analysis_background
            if check_essentia_service():
                result = start_analysis_background(config.DATABASE_URL)
                if result.get("success"):
                    print("Auto-started audio analysis for new songs")
        except Exception as e:
            print(f"Could not auto-start analysis: {e}")

        # Auto-trigger desktop transcoding for new songs
        try:
            from app.transcode import check_transcode_service, start_transcode_background
            if check_transcode_service():
                result = start_transcode_background()
                if result.get("success"):
                    print("Auto-started desktop transcoding for new songs")
        except Exception as e:
            print(f"Could not auto-start transcoding: {e}")

    # Start scan in background thread
    thread = threading.Thread(target=run_scan)
    thread.daemon = True
    thread.start()

    # Return immediately with operation ID
    return jsonify(
        {"message": "Incremental scan started", "operation_id": operation_id}
    )


@api.route("/api/cleanup-missing", methods=["POST"])
@auth.require_admin
def cleanup_missing_files():
    """Remove database entries for files that no longer exist"""

    operation_id = f"cleanup_{uuid.uuid4().hex[:8]}"

    def run_cleanup():
        db = get_db()
        conn = db.get_connection()
        try:
            cursor = db.get_cursor(conn)

            progress_tracker.start_operation(operation_id, 0, "cleanup")

            # Emit initial status
            safe_emit(
                "cleanup_progress",
                {
                    "operation_id": operation_id,
                    "current": 0,
                    "total": 0,
                    "message": "Starting cleanup...",
                    "status": "running",
                    "missing_count": 0,
                },
            )

            # Get all songs
            cursor.execute("SELECT id, title, file_path FROM songs")
            songs = cursor.fetchall()
            total = len(songs)
            missing_ids = []

            for i, song in enumerate(songs):
                # Check for cancellation
                if progress_tracker.is_cancelled(operation_id):
                    progress_tracker.fail_operation(operation_id, "Cancelled by user")
                    safe_emit(
                        "cleanup_progress",
                        {
                            "operation_id": operation_id,
                            "current": i,
                            "total": total,
                            "message": "Cancelled by user",
                            "status": "cancelled",
                            "missing_count": len(missing_ids),
                        },
                    )
                    return

                song_id, title, file_path = song

                # file_path is already absolute in the database
                if not os.path.exists(file_path):
                    missing_ids.append(song_id)

                if i % 100 == 0:
                    progress_tracker.operations[operation_id]["total"] = total
                    progress_tracker.update_progress(
                        operation_id,
                        i,
                        f"Checking {i}/{total} files... ({len(missing_ids)} missing)",
                    )
                    safe_emit(
                        "cleanup_progress",
                        {
                            "operation_id": operation_id,
                            "current": i,
                            "total": total,
                            "message": f"Checking files... ({len(missing_ids)} missing)",
                            "status": "running",
                            "missing_count": len(missing_ids),
                        },
                    )

            progress_tracker.update_progress(
                operation_id,
                total,
                f"Found {len(missing_ids)} missing files. Cleaning up...",
            )

            if missing_ids:
                # NOTE: previously these used f"... IN ({','.join('%s' * N)})"
                # which is BROKEN — '%s' * N is a string like '%s%s%s' (no
                # separator), and join then comma-separates each *character*,
                # producing '%,s,%,s,%,s'. psycopg2 saw '%,' and threw
                # "unsupported format character ','". Rewritten to use
                # WHERE col = ANY(%s) which takes a Python list directly,
                # no placeholder gymnastics, and works for any list length.
                cursor.execute(
                    "DELETE FROM playlist_songs WHERE song_id = ANY(%s)",
                    (missing_ids,),
                )
                cursor.execute(
                    "DELETE FROM song_artists WHERE song_id = ANY(%s)",
                    (missing_ids,),
                )
                cursor.execute(
                    "DELETE FROM favorites WHERE item_type = 'song' AND item_id = ANY(%s)",
                    (missing_ids,),
                )
                cursor.execute(
                    "DELETE FROM play_history WHERE song_id = ANY(%s)",
                    (missing_ids,),
                )
                cursor.execute(
                    "DELETE FROM songs WHERE id = ANY(%s)",
                    (missing_ids,),
                )

                # Clean up orphaned albums (albums with no songs)
                cursor.execute(
                    """
                    DELETE FROM albums WHERE id NOT IN (SELECT DISTINCT album_id FROM songs)
                """
                )
                orphaned_albums = cursor.rowcount

                # Clean up orphaned artists (artists with no songs or albums)
                cursor.execute(
                    """
                    DELETE FROM artists WHERE id NOT IN (
                        SELECT DISTINCT artist_id FROM songs
                        UNION
                        SELECT DISTINCT artist_id FROM albums
                        UNION
                        SELECT DISTINCT artist_id FROM song_artists
                    )
                """
                )
                orphaned_artists = cursor.rowcount

                conn.commit()

                progress_tracker.complete_operation(
                    operation_id,
                    f"Removed {len(missing_ids)} missing songs, {orphaned_albums} empty albums, {orphaned_artists} orphaned artists",
                )
                safe_emit(
                    "cleanup_progress",
                    {
                        "operation_id": operation_id,
                        "current": total,
                        "total": total,
                        "message": f"Removed {len(missing_ids)} songs, {orphaned_albums} albums, {orphaned_artists} artists",
                        "status": "complete",
                        "missing_count": len(missing_ids),
                    },
                )
            else:
                progress_tracker.complete_operation(operation_id, "No missing files found")
                safe_emit(
                    "cleanup_progress",
                    {
                        "operation_id": operation_id,
                        "current": total,
                        "total": total,
                        "message": "No missing files found",
                        "status": "complete",
                        "missing_count": 0,
                    },
                )
        finally:
            conn.close()

    thread = threading.Thread(target=run_cleanup)
    thread.daemon = True
    thread.start()

    return jsonify({"message": "Cleanup started", "operation_id": operation_id})


@api.route("/api/enrich-explicit", methods=["POST"])
def enrich_explicit_tags():
    """Bulk enrich is_explicit from Spotify for songs with NULL values"""

    operation_id = f"explicit_{uuid.uuid4().hex[:8]}"

    def run_enrichment():
        conn = None
        try:
            discovery = SpotifyDiscovery()
            sp = discovery.sp

            db = get_db()
            conn = db.get_connection()
            cursor = db.get_cursor(conn)

            # Get all songs with NULL explicit status
            cursor.execute(
                """
                SELECT s.id, s.title, ar.name as artist_name
                FROM songs s
                JOIN artists ar ON s.artist_id = ar.id
                WHERE s.is_explicit IS NULL
                ORDER BY ar.name, s.title
                """
            )
            songs = cursor.fetchall()
            total = len(songs)

            if total == 0:
                safe_emit(
                    "explicit_progress",
                    {
                        "operation_id": operation_id,
                        "current": 0,
                        "total": 0,
                        "message": "All songs already have explicit data",
                        "status": "complete",
                    },
                )
                return

            progress_tracker.start_operation(operation_id, total, "explicit_enrichment")

            safe_emit(
                "explicit_progress",
                {
                    "operation_id": operation_id,
                    "current": 0,
                    "total": total,
                    "message": f"Starting explicit enrichment for {total} songs...",
                    "status": "running",
                },
            )

            tagged_explicit = 0
            tagged_clean = 0
            not_found = 0
            errors = 0

            for i, song in enumerate(songs):
                # Check for cancellation
                if progress_tracker.is_cancelled(operation_id):
                    progress_tracker.fail_operation(operation_id, "Cancelled by user")
                    safe_emit(
                        "explicit_progress",
                        {
                            "operation_id": operation_id,
                            "current": i,
                            "total": total,
                            "message": "Cancelled by user",
                            "status": "cancelled",
                        },
                    )
                    return

                song_id = song["id"]
                title = song["title"]
                artist = song["artist_name"]

                try:
                    query = f'track:"{title}" artist:"{artist}"'
                    results = sp.search(q=query, type="track", limit=1)

                    if results["tracks"]["items"]:
                        track = results["tracks"]["items"][0]
                        is_explicit = 1 if track.get("explicit", False) else 0

                        cursor.execute(
                            "UPDATE songs SET is_explicit = %s WHERE id = %s",
                            (is_explicit, song_id),
                        )

                        if is_explicit:
                            tagged_explicit += 1
                        else:
                            tagged_clean += 1
                    else:
                        not_found += 1

                except Exception as e:
                    errors += 1
                    if "429" in str(e):
                        # Rate limited - wait and retry

                        eventlet.sleep(5)
                        continue

                # Commit every 50 songs
                if (i + 1) % 50 == 0:
                    conn.commit()

                # Progress update every 10 songs
                if i % 10 == 0:
                    progress_tracker.update_progress(
                        operation_id,
                        i,
                        f"Processing {i}/{total}...",
                    )
                    safe_emit(
                        "explicit_progress",
                        {
                            "operation_id": operation_id,
                            "current": i,
                            "total": total,
                            "message": f"Processing... ({tagged_explicit} explicit, {tagged_clean} clean, {not_found} not found)",
                            "status": "running",
                        },
                    )

                # Small delay to avoid Spotify rate limits

                eventlet.sleep(0.1)

            # Final commit
            conn.commit()

            msg = f"Done! {tagged_explicit} explicit, {tagged_clean} clean, {not_found} not found, {errors} errors"
            progress_tracker.complete_operation(operation_id, msg)
            safe_emit(
                "explicit_progress",
                {
                    "operation_id": operation_id,
                    "current": total,
                    "total": total,
                    "message": msg,
                    "status": "complete",
                },
            )

        except Exception as e:
            progress_tracker.fail_operation(operation_id, str(e))
            safe_emit(
                "explicit_progress",
                {
                    "operation_id": operation_id,
                    "current": 0,
                    "total": 0,
                    "message": f"Error: {str(e)}",
                    "status": "error",
                },
            )
        finally:
            if conn:
                conn.close()

    thread = threading.Thread(target=run_enrichment)
    thread.daemon = True
    thread.start()

    return jsonify(
        {"message": "Explicit enrichment started", "operation_id": operation_id}
    )


@api.route("/api/download-artwork", methods=["POST"])
def download_artwork():
    """Download artwork from MusicBrainz for all albums"""
    from app.artwork_downloader import ArtworkDownloader

    # Generate unique operation ID
    operation_id = f"artwork_{uuid.uuid4().hex[:8]}"

    def run_download():
        """Run download in background thread"""
        db = get_db()
        downloader = ArtworkDownloader(db, progress_tracker, operation_id)
        downloader.download_all_artwork()

    # Start download in background thread
    thread = threading.Thread(target=run_download)
    thread.daemon = True
    thread.start()

    # Return immediately with operation ID
    return jsonify(
        {"message": "Artwork download started", "operation_id": operation_id}
    )


@api.route("/api/stats", methods=["GET"])
def get_stats():
    """Get library statistics"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    cursor.execute("SELECT COUNT(*) as count FROM artists")
    artist_count = cursor.fetchone()["count"]

    cursor.execute("SELECT COUNT(*) as count FROM albums")
    album_count = cursor.fetchone()["count"]

    cursor.execute("SELECT COUNT(*) as count FROM songs")
    song_count = cursor.fetchone()["count"]

    cursor.execute("SELECT SUM(duration) as total FROM songs")
    total_duration = cursor.fetchone()["total"] or 0

    conn.close()

    return jsonify(
        {
            "artists": artist_count,
            "albums": album_count,
            "songs": song_count,
            "total_duration": total_duration,
            "total_duration_formatted": f"{total_duration // 3600}h {(total_duration % 3600) // 60}m",
        }
    )


# =============================================================================
# GENRES (MusicBrainz backfill — genre_fetcher.py)
# =============================================================================

@api.route("/api/genres/fetch", methods=["POST"])
def fetch_genres():
    """Backfill album/artist genres from MusicBrainz in the background.
    Body: {scope: all|albums|artists|fallback, only_missing: true}"""
    from app.genre_fetcher import GenreFetcher

    data = request.get_json() or {}
    scope = data.get("scope", "all")
    only_missing = data.get("only_missing", True)
    operation_id = f"genres_{uuid.uuid4().hex[:8]}"
    progress_tracker.start_operation(operation_id, 0, "genre fetch")

    def run():
        db = get_db()
        GenreFetcher(db, progress_tracker, operation_id).run(scope, only_missing)

    thread = threading.Thread(target=run)
    thread.daemon = True
    thread.start()
    return jsonify({"message": "Genre fetch started", "operation_id": operation_id})


@api.route("/api/genres/summary", methods=["GET"])
def genres_summary():
    """Coverage plus the genre vocabulary with album counts."""
    db = get_db()
    conn = db.get_connection()
    try:
        cursor = db.get_cursor(conn)
        cursor.execute(
            "SELECT count(*) AS albums, "
            "count(*) FILTER (WHERE genres_fetched_at IS NOT NULL) AS fetched, "
            "count(*) FILTER (WHERE genres IS NOT NULL AND array_length(genres,1) > 0) AS with_genres "
            "FROM albums"
        )
        cov = dict(cursor.fetchone())
        cursor.execute(
            "SELECT count(*) AS artists, "
            "count(*) FILTER (WHERE genres IS NOT NULL AND array_length(genres,1) > 0) AS with_genres "
            "FROM artists"
        )
        cov["artists"] = dict(cursor.fetchone())
        cursor.execute(
            "SELECT g AS genre, count(*) AS albums FROM albums, unnest(genres) AS g "
            "GROUP BY g ORDER BY albums DESC, g"
        )
        genres = [dict(r) for r in cursor.fetchall()]
        return jsonify({"coverage": cov, "genres": genres})
    finally:
        conn.close()


@api.route("/api/albums-without-artwork", methods=["GET"])
def get_albums_without_artwork():
    """Get albums that don't have artwork, optionally filtered by folder path"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    folder_path = request.args.get("folder_path")

    try:
        if folder_path:
            # Get albums that have songs in this folder AND don't have artwork
            cursor.execute(
                """
                SELECT DISTINCT albums.id, albums.title, artists.name as artist_name
                FROM albums
                JOIN artists ON albums.artist_id = artists.id
                JOIN songs ON songs.album_id = albums.id
                WHERE (albums.artwork_path IS NULL OR albums.artwork_path = '')
                AND songs.file_path LIKE %s
                ORDER BY albums.id DESC
            """,
                (f"{folder_path}%",),
            )
        else:
            cursor.execute(
                """
                SELECT albums.id, albums.title, artists.name as artist_name
                FROM albums
                JOIN artists ON albums.artist_id = artists.id
                WHERE albums.artwork_path IS NULL OR albums.artwork_path = ''
                ORDER BY albums.id DESC
                LIMIT 20
            """
            )
        albums = [dict(row) for row in cursor.fetchall()]
        return jsonify({"albums": albums})
    finally:
        conn.close()


def _send_image(path, mimetype):
    """Image responses revalidate on every load. The cast receiver and the
    phone hit the same URL per album/artist forever, so a changed cover
    stayed stale until the TV's browser felt like refetching. max_age=0 +
    conditional gives a cheap 304 when nothing changed."""
    resp = send_file(path, mimetype=mimetype, max_age=0, conditional=True)
    resp.headers["Cache-Control"] = "no-cache"
    return resp


def _cast_refresh(album_id=None, artist_id=None):
    """Tell any headless cast showing this album/artist to repaint."""
    try:
        from app.cast_sender import refresh_artwork
        n = refresh_artwork(album_id=album_id, artist_id=artist_id)
        if n:
            print(f"📺 cast artwork refresh sent to {n} session(s)")
    except Exception as e:
        print(f"📺 cast artwork refresh skipped: {e}")


@api.route("/api/artwork/<int:album_id>", methods=["GET"])
def get_artwork(album_id):
    """Get album artwork. Use ?size=thumb for 300px thumbnail, default returns full res."""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    cursor.execute("SELECT artwork_path FROM albums WHERE id = %s", (album_id,))
    row = cursor.fetchone()
    conn.close()

    # Return default placeholder if no artwork
    default_placeholder = os.path.join(APP_BASE_DIR, "static", "default_album.png")

    if not row or not row["artwork_path"]:
        if os.path.exists(default_placeholder):
            return _send_image(default_placeholder, mimetype="image/png")
        return jsonify({"error": "Artwork not found"}), 404

    # Use absolute path - handle both path formats in DB
    db_path = row["artwork_path"]
    if db_path.startswith("artwork/"):
        artwork_path = os.path.join(APP_BASE_DIR, db_path)
    else:
        artwork_path = os.path.join(APP_BASE_DIR, "artwork", db_path)

    if not os.path.exists(artwork_path):
        if os.path.exists(default_placeholder):
            return _send_image(default_placeholder, mimetype="image/png")
        return jsonify({"error": "Artwork file not found"}), 404

    # Serve thumbnail if requested (for lists/grids)
    size = request.args.get("size", "")
    if size == "thumb":
        from PIL import Image
        from io import BytesIO
        thumb_cache_dir = os.path.join(APP_BASE_DIR, "artwork", "thumbs")
        os.makedirs(thumb_cache_dir, exist_ok=True)
        thumb_filename = f"thumb_{os.path.basename(artwork_path)}"
        thumb_path = os.path.join(thumb_cache_dir, thumb_filename)

        # Generate thumbnail if it doesn't exist or is older than the original
        if not os.path.exists(thumb_path) or os.path.getmtime(thumb_path) < os.path.getmtime(artwork_path):
            img = Image.open(artwork_path)
            img.thumbnail((300, 300), Image.Resampling.LANCZOS)
            img.save(thumb_path, "JPEG", quality=80)

        return _send_image(thumb_path, mimetype="image/jpeg")

    return _send_image(artwork_path, mimetype="image/jpeg")


@api.route("/api/artist-image/<int:artist_id>", methods=["GET"])
def get_artist_image(artist_id):
    """Get artist image"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    cursor.execute("SELECT image_path FROM artists WHERE id = %s", (artist_id,))
    row = cursor.fetchone()
    conn.close()

    if not row or not row["image_path"]:
        return jsonify({"error": "Artist image not found"}), 404

    # Use absolute path
    image_path = os.path.join(APP_BASE_DIR, "artist_images", row["image_path"])

    if not os.path.exists(image_path):
        return jsonify({"error": "Image file not found"}), 404

    return _send_image(image_path, mimetype="image/jpeg")


@api.route("/api/artist/<int:artist_id>/download-image", methods=["POST"])
def download_single_artist_image(artist_id):
    """Download image for a specific artist from Fanart.tv"""
    try:
        db = get_db()
        conn = db.get_connection()
        cursor = db.get_cursor(conn)
        cursor.execute(
            "SELECT name, image_path FROM artists WHERE id = %s", (artist_id,)
        )
        artist = cursor.fetchone()
        conn.close()

        if not artist:
            return jsonify({"error": "Artist not found"}), 404

        artist_name = artist["name"]

        # Download image
        from app.artist_image_downloader import ArtistImageDownloader

        downloader = ArtistImageDownloader(db)
        image_path = downloader.download_artist_image(artist_id, artist_name)

        if image_path:
            _cast_refresh(artist_id=artist_id)
            return jsonify(
                {
                    "success": True,
                    "message": f"Downloaded image for {artist_name}",
                    "image_path": image_path,
                }
            )
        else:
            return (
                jsonify(
                    {
                        "success": False,
                        "message": f"Could not find image for {artist_name}",
                    }
                ),
                404,
            )

    except Exception as e:
        return _error_response(e)


@api.route("/api/playlist-artwork/<int:playlist_id>", methods=["GET"])
def get_playlist_artwork(playlist_id):
    """Get artwork for a playlist (first song's album artwork)"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Get the first song's album that has artwork
        cursor.execute(
            """
            SELECT a.artwork_path, a.id as album_id
            FROM playlist_songs ps
            JOIN songs s ON ps.song_id = s.id
            JOIN albums a ON s.album_id = a.id
            WHERE ps.playlist_id = %s AND a.artwork_path IS NOT NULL
            ORDER BY ps.position
            LIMIT 1
        """,
            (playlist_id,),
        )

        row = cursor.fetchone()
        if not row or not row["artwork_path"]:
            return jsonify({"error": "No artwork found"}), 404

        artwork_path = os.path.join(APP_BASE_DIR, "artwork", row["artwork_path"])

        if os.path.exists(artwork_path):
            return send_file(artwork_path, mimetype="image/jpeg")

        return jsonify({"error": "Artwork file not found"}), 404
    finally:
        conn.close()


@api.route("/api/artists/repair-images", methods=["POST"])
def repair_artist_images():
    """Artists whose image_path points at a file that no longer exists show
    blank forever (75 of them on 2026-09-12). Clear those paths and refetch
    in the background."""
    from app.artist_image_downloader import ArtistImageDownloader

    db = get_db()
    conn = db.get_connection()
    try:
        cursor = db.get_cursor(conn)
        cursor.execute("SELECT id, name, image_path FROM artists WHERE image_path IS NOT NULL AND image_path <> ''")
        rows = cursor.fetchall()
        dangling = [
            r for r in rows
            if not os.path.exists(os.path.join(APP_BASE_DIR, "artist_images", r["image_path"]))
        ]
        if dangling:
            cursor.execute(
                "UPDATE artists SET image_path = NULL WHERE id = ANY(%s)",
                ([r["id"] for r in dangling],),
            )
            conn.commit()
    finally:
        conn.close()

    operation_id = f"artist_repair_{uuid.uuid4().hex[:8]}"

    def run():
        d = ArtistImageDownloader(get_db(), progress_tracker, operation_id)
        for i, r in enumerate(dangling, 1):
            d.download_artist_image(r["id"], r["name"])
            progress_tracker.update_progress(operation_id, i, f"{r['name']}")
        progress_tracker.complete_operation(operation_id, f"Refetched {len(dangling)} artist images")

    if dangling:
        progress_tracker.start_operation(operation_id, len(dangling), "artist image repair")
        t = threading.Thread(target=run)
        t.daemon = True
        t.start()
    return jsonify({"dangling": len(dangling), "operation_id": operation_id if dangling else None,
                    "artists": [r["name"] for r in dangling]})


@api.route("/api/download-artist-images", methods=["POST"])
def download_artist_images():
    """Download artist images from Fanart.tv"""
    from app.artist_image_downloader import ArtistImageDownloader

    # Generate unique operation ID
    operation_id = f"artists_{uuid.uuid4().hex[:8]}"

    def run_download():
        """Run download in background thread"""
        db = get_db()
        downloader = ArtistImageDownloader(db, progress_tracker, operation_id)
        downloader.download_all_images()

    # Start download in background thread
    thread = threading.Thread(target=run_download)
    thread.daemon = True
    thread.start()

    # Return immediately with operation ID
    return jsonify(
        {"message": "Artist image download started", "operation_id": operation_id}
    )


@api.route("/api/progress/<operation_id>", methods=["GET"])
def stream_progress(operation_id):
    """Stream progress updates using Server-Sent Events"""

    def generate():
        """Generator function for SSE"""
        while True:
            progress = progress_tracker.get_progress(operation_id)

            if progress is None:
                # Operation doesn't exist yet, wait
                time.sleep(0.5)
                continue

            # Send progress update
            yield f"data: {json.dumps(progress)}\n\n"

            # If operation is complete or failed, send one more update and close
            if progress["status"] in ["complete", "failed"]:
                time.sleep(0.5)  # Give client time to receive final update
                break

            time.sleep(0.5)  # Update every 500ms

    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@api.route("/api/waveform/<int:song_id>", methods=["GET"])
def get_waveform(song_id):
    """Get waveform data for a song"""
    from app.waveform import WaveformGenerator

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    cursor.execute("SELECT file_path FROM songs WHERE id = %s", (song_id,))
    song = cursor.fetchone()
    conn.close()

    if not song:
        return jsonify({"error": "Song not found"}), 404

    # The app fetches a song's waveform right when it focuses/loads it — before
    # the play or cast request. Use that as a cue to warm the audio file off the
    # NAS in the background, so the upcoming stream open is instant (no 7s cold
    # open stalling the cast).
    eventlet.spawn_n(_prewarm_file, song_id)

    waveform_gen = WaveformGenerator()
    result = waveform_gen.generate_waveform(ensure_windows_path(song["file_path"]), song_id)

    # generate_waveform returns dict with 'status' and 'waveform' keys
    if isinstance(result, dict):
        return jsonify(result)
    else:
        # Legacy fallback: plain list
        return jsonify({"status": "ready", "waveform": result})


@api.route("/api/generate-waveforms", methods=["POST"])
def generate_all_waveforms():
    """Bulk generate waveform data for all songs missing cached waveforms"""

    from app.waveform import WaveformGenerator

    operation_id = f"waveform_{uuid.uuid4().hex[:8]}"

    def run_generation():
        try:
            waveform_gen = WaveformGenerator()
            cache_dir = waveform_gen.cache_dir

            db = get_db()
            conn = db.get_connection()
            cursor = db.get_cursor(conn)

            cursor.execute("SELECT id, file_path FROM songs ORDER BY id")
            all_songs = cursor.fetchall()
            conn.close()

            # Filter to only songs without cached waveforms

            songs = [
                s
                for s in all_songs
                if not os.path.exists(os.path.join(cache_dir, f"{s['id']}.json"))
            ]
            total = len(songs)

            if total == 0:
                safe_emit(
                    "waveform_progress",
                    {
                        "operation_id": operation_id,
                        "current": 0,
                        "total": 0,
                        "message": "All songs already have waveforms cached",
                        "status": "complete",
                    },
                )
                return

            progress_tracker.start_operation(operation_id, total, "waveform_generation")

            safe_emit(
                "waveform_progress",
                {
                    "operation_id": operation_id,
                    "current": 0,
                    "total": total,
                    "message": f"Starting waveform generation for {total} songs...",
                    "status": "running",
                },
            )

            generated = 0
            errors = 0

            for i, song in enumerate(songs):
                if progress_tracker.is_cancelled(operation_id):
                    progress_tracker.fail_operation(operation_id, "Cancelled by user")
                    safe_emit(
                        "waveform_progress",
                        {
                            "operation_id": operation_id,
                            "current": i,
                            "total": total,
                            "message": "Cancelled by user",
                            "status": "cancelled",
                        },
                    )
                    return

                try:
                    # Run in real OS thread — librosa is CPU-bound
                    eventlet.tpool.execute(waveform_gen._generate_and_cache, song["file_path"], song["id"])
                    generated += 1
                except Exception as e:
                    errors += 1
                    print(f"⚠️ Waveform error for song {song['id']}: {e}")

                if (i + 1) % 10 == 0 or i == total - 1:
                    progress_tracker.update_progress(
                        operation_id, i + 1, f"Processing {i+1}/{total}..."
                    )
                    safe_emit(
                        "waveform_progress",
                        {
                            "operation_id": operation_id,
                            "current": i + 1,
                            "total": total,
                            "message": f"Generated {generated}, errors {errors} ({i+1}/{total})",
                            "status": "running",
                        },
                    )

                # Small yield to let other requests breathe

                eventlet.sleep(0.1)

            msg = f"Done! {generated} generated, {errors} errors out of {total} songs"
            progress_tracker.complete_operation(operation_id, msg)
            safe_emit(
                "waveform_progress",
                {
                    "operation_id": operation_id,
                    "current": total,
                    "total": total,
                    "message": msg,
                    "status": "complete",
                },
            )

        except Exception as e:
            print(f"❌ Waveform generation error: {e}")
            progress_tracker.fail_operation(operation_id, str(e))
            safe_emit(
                "waveform_progress",
                {
                    "operation_id": operation_id,
                    "current": 0,
                    "total": 0,
                    "message": f"Error: {e}",
                    "status": "error",
                },
            )

    thread = threading.Thread(target=run_generation, daemon=True)
    thread.start()

    return jsonify(
        {"message": "Waveform generation started", "operation_id": operation_id}
    )


@api.route("/api/cancel/<operation_id>", methods=["POST"])
def cancel_operation(operation_id):
    """Cancel a running operation"""
    progress_tracker.cancel_operation(operation_id)
    return jsonify({"message": "Operation cancelled", "operation_id": operation_id})


# ========================
# Analytics Endpoints
# ========================


@api.route("/api/track-play", methods=["POST"])
def track_play():
    """Track when a song starts playing"""
    from app.analytics import Analytics

    data = request.get_json()
    song_id = data.get("song_id")

    if not song_id:
        return jsonify({"error": "song_id is required"}), 400

    analytics = Analytics()
    result = analytics.track_play_start(song_id)

    if result["success"]:
        # Last.fm "now playing" notification (fire and forget)
        try:
            from app.lastfm import LastFM

            lastfm = LastFM()
            if lastfm.is_enabled():
                db = get_db()
                conn = db.get_connection()
                cursor = db.get_cursor(conn)
                cursor.execute(
                    """SELECT songs.title, artists.name as artist_name,
                              albums.title as album_title, songs.duration,
                              artists.exclude_from_scrobble as artist_excluded,
                              albums.exclude_from_scrobble as album_excluded
                       FROM songs
                       JOIN artists ON songs.artist_id = artists.id
                       JOIN albums ON songs.album_id = albums.id
                       WHERE songs.id = %s""",
                    (song_id,),
                )
                song_info = cursor.fetchone()
                conn.close()
                if (
                    song_info
                    and not song_info["artist_excluded"]
                    and not song_info["album_excluded"]
                ):
                    eventlet.spawn_n(
                        lastfm.update_now_playing,
                        song_info["artist_name"],
                        song_info["title"],
                        song_info["album_title"],
                        song_info["duration"],
                    )
        except Exception:
            pass  # Never let Last.fm errors break play tracking

        return jsonify(result)
    else:
        return jsonify(result), 500


@api.route("/api/spotify/import/cancel", methods=["POST"])
def cancel_spotify_import():
    """Cancel an in-progress Spotify import"""
    cancel_import()
    print("🛑 Import cancellation requested")
    return jsonify({"success": True, "message": "Cancellation requested"})


@api.route("/api/track-complete", methods=["POST"])
def track_complete():
    """Track when a song completes or reaches a certain percentage"""
    from app.analytics import Analytics

    data = request.get_json()
    song_id = data.get("song_id")
    completion_percentage = data.get("completion_percentage", 100)

    if not song_id:
        return jsonify({"error": "song_id is required"}), 400

    analytics = Analytics()
    result = analytics.track_play_complete(song_id, completion_percentage)

    if result["success"]:
        # Last.fm scrobble (fire and forget) — requires 50%+ completion per Last.fm rules
        if completion_percentage >= 50:
            try:
                from app.lastfm import LastFM

                lastfm = LastFM()
                if lastfm.is_enabled():
                    db = get_db()
                    conn = db.get_connection()
                    cursor = db.get_cursor(conn)
                    cursor.execute(
                        """SELECT songs.title, artists.name as artist_name,
                                  albums.title as album_title, songs.duration,
                                  artists.exclude_from_scrobble as artist_excluded,
                                  albums.exclude_from_scrobble as album_excluded
                           FROM songs
                           JOIN artists ON songs.artist_id = artists.id
                           JOIN albums ON songs.album_id = albums.id
                           WHERE songs.id = %s""",
                        (song_id,),
                    )
                    song_info = cursor.fetchone()
                    conn.close()
                    if (
                        song_info
                        and not song_info["artist_excluded"]
                        and not song_info["album_excluded"]
                    ):
                        eventlet.spawn_n(
                            lastfm.scrobble,
                            song_info["artist_name"],
                            song_info["title"],
                            song_info["album_title"],
                            song_info["duration"],
                        )
            except Exception:
                pass  # Never let Last.fm errors break play tracking

        return jsonify(result)
    else:
        return jsonify(result), 500


@api.route("/api/track-skip", methods=["POST"])
def track_skip():
    """Track when a song is skipped"""
    from app.analytics import Analytics

    data = request.get_json()
    song_id = data.get("song_id")

    if not song_id:
        return jsonify({"error": "song_id is required"}), 400

    analytics = Analytics()
    result = analytics.track_skip(song_id)

    if result["success"]:
        return jsonify(result)
    else:
        return jsonify(result), 500


@api.route("/api/recently-played", methods=["GET"])
def get_recently_played():
    """Get recently played songs"""
    from app.analytics import Analytics

    limit = request.args.get("limit", 50, type=int)

    analytics = Analytics()
    songs = analytics.get_recently_played(limit)

    # Add all artists for each song
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    for song in songs:
        cursor.execute(
            """
            SELECT artists.id, artists.name 
            FROM song_artists 
            JOIN artists ON song_artists.artist_id = artists.id 
            WHERE song_artists.song_id = %s
            ORDER BY song_artists.position
            """,
            (song["id"],),
        )
        artist_list = [
            {"id": row["id"], "name": row["name"]} for row in cursor.fetchall()
        ]
        song["artists"] = (
            artist_list
            if artist_list
            else [{"id": song["artist_id"], "name": song["artist_name"]}]
        )

    conn.close()

    return jsonify(songs)


@api.route("/api/song/<int:song_id>", methods=["GET"])
def get_song(song_id):
    """Get song details including file path"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    cursor.execute(
        """
        SELECT songs.id, songs.title, songs.artist_id, songs.album_id, songs.track_number, 
               songs.disc_number, songs.duration, songs.file_path, songs.file_size, songs.bitrate,
               songs.is_explicit, songs.is_hdcd, songs.audio_codec, songs.audio_channels, songs.is_atmos,
               songs.spectral_cutoff_hz, songs.transcode_suspect,
               artists.name as artist_name, albums.title as album_title
        FROM songs
        JOIN artists ON songs.artist_id = artists.id
        JOIN albums ON songs.album_id = albums.id
        WHERE songs.id = %s
        """,
        (song_id,),
    )

    row = cursor.fetchone()
    if not row:
        conn.close()
        return jsonify({"error": "Song not found"}), 404

    song = dict(row)

    # Add all artists for this song
    cursor.execute(
        """
        SELECT artists.id, artists.name 
        FROM song_artists 
        JOIN artists ON song_artists.artist_id = artists.id 
        WHERE song_artists.song_id = %s
        ORDER BY song_artists.position
        """,
        (song_id,),
    )
    artists = [{"id": row["id"], "name": row["name"]} for row in cursor.fetchall()]
    song["artists"] = (
        artists if artists else [{"id": song["artist_id"], "name": song["artist_name"]}]
    )

    conn.close()
    return jsonify(song)


@api.route("/api/songs/<int:song_id>/chapters", methods=["GET"])
def get_song_chapters(song_id):
    """Return chapters for a song (primarily podcast episodes).

    If chapters aren't cached yet and the song is a podcast, synchronously
    fetches them via ID3 parsing. Cheap on subsequent calls — just hits
    the song_chapters table.

    Query ?force_refresh=1 re-parses even if cached (for debugging /
    when a feed's chapters file has been updated).
    """
    force = request.args.get("force_refresh") == "1"
    db = get_db()

    if force:
        conn = db.get_connection()
        cursor = db.get_cursor(conn)
        try:
            cursor.execute("DELETE FROM song_chapters WHERE song_id = %s", (song_id,))
            conn.commit()
        finally:
            conn.close()

    # Prime the cache if empty — synchronous so the caller gets real data
    # on first request. Bounded by the ID3 fetch timeout (~20s).
    try:
        from app.chapters import ensure_chapters_for_song
        ensure_chapters_for_song(db, song_id)
    except Exception as e:
        print(f"[chapters api] Song {song_id}: prime failed: {e}")

    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute(
            """
            SELECT order_index, start_time_seconds, end_time_seconds,
                   title, image_url, link_url, is_skippable, source
              FROM song_chapters
             WHERE song_id = %s
             ORDER BY order_index
            """,
            (song_id,),
        )
        chapters = [dict(r) for r in cursor.fetchall()]
    finally:
        conn.close()

    return jsonify({
        "song_id": song_id,
        "count": len(chapters),
        "chapters": chapters,
    })


@api.route("/api/songs/batch", methods=["POST"])
def get_songs_batch():
    """Get multiple songs by IDs in a single request"""
    data = request.get_json()
    song_ids = data.get("ids", [])

    if not song_ids:
        return jsonify([])

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        placeholders = ",".join(["%s"] * len(song_ids))
        cursor.execute(
            f"""
            SELECT s.id, s.title, s.artist_id, s.album_id, s.track_number,
                   s.disc_number, s.duration, s.file_path, s.file_size, s.bitrate,
                   s.file_format, s.is_explicit, s.is_hdcd, s.audio_codec, s.audio_channels, s.is_atmos,
                   ar.name AS artist_name, al.title AS album_title
            FROM songs s
            JOIN artists ar ON s.artist_id = ar.id
            JOIN albums al ON s.album_id = al.id
            WHERE s.id IN ({placeholders})
            """,
            tuple(song_ids),
        )
        rows = cursor.fetchall()
        song_map = {row["id"]: dict(row) for row in rows}

        # Return in the same order as requested
        songs = [song_map[sid] for sid in song_ids if sid in song_map]

        # Add artists for each song
        for song in songs:
            cursor.execute(
                """
                SELECT artists.id, artists.name
                FROM song_artists
                JOIN artists ON song_artists.artist_id = artists.id
                WHERE song_artists.song_id = %s
                ORDER BY song_artists.position
                """,
                (song["id"],),
            )
            artists = [{"id": r["id"], "name": r["name"]} for r in cursor.fetchall()]
            song["artists"] = (
                artists if artists else [{"id": song["artist_id"], "name": song["artist_name"]}]
            )

        return jsonify(songs)
    finally:
        conn.close()


@api.route("/api/song/<int:song_id>", methods=["DELETE"])
def delete_song(song_id):
    """Delete song from database (file remains on disk)"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Get song details for response and exclusion
        cursor.execute(
            """
            SELECT songs.title, songs.file_path, artists.name as artist_name, albums.title as album_title
            FROM songs
            JOIN artists ON songs.artist_id = artists.id
            JOIN albums ON songs.album_id = albums.id
            WHERE songs.id = %s
            """,
            (song_id,),
        )
        song = cursor.fetchone()
        if not song:
            conn.close()
            return jsonify({"error": "Song not found"}), 404

        song_title = song["title"]
        file_path = song["file_path"]
        artist_name = song["artist_name"]
        album_title = song["album_title"]

        # Add to excluded_paths so it won't be re-imported
        cursor.execute(
            """
            INSERT INTO excluded_paths (file_path, original_title, original_artist, original_album)
            VALUES (%s, %s, %s, %s)
            ON CONFLICT DO NOTHING
            """,
            (file_path, song_title, artist_name, album_title),
        )

        # Delete from song_artists table first (foreign key constraint)
        cursor.execute("DELETE FROM song_artists WHERE song_id = %s", (song_id,))

        # Convert playlist songs to unavailable instead of deleting
        cursor.execute(
            """
            UPDATE playlist_songs 
            SET song_id = NULL,
                spotify_track_name = %s,
                spotify_artist = %s,
                spotify_album = %s
            WHERE song_id = %s
            """,
            (song_title, artist_name, album_title, song_id),
        )

        # Delete from favorites
        cursor.execute(
            "DELETE FROM favorites WHERE item_type = 'song' AND item_id = %s",
            (song_id,),
        )

        # Delete from analytics
        cursor.execute("DELETE FROM play_history WHERE song_id = %s", (song_id,))

        # Delete the song itself
        cursor.execute("DELETE FROM songs WHERE id = %s", (song_id,))

        conn.commit()
        conn.close()

        return jsonify(
            {"success": True, "message": f"Deleted '{song_title}' from database"}
        )

    except Exception as e:
        conn.rollback()
        conn.close()
        return _error_response(e)


@api.route("/api/album/<int:album_id>", methods=["DELETE"])
def delete_album(album_id):
    """Delete album and all its songs from database, optionally delete files from disk"""
    delete_files = request.args.get("delete_files", "false").lower() == "true"
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Get album title and artist for response
        cursor.execute(
            """
            SELECT albums.title, artists.name as artist_name
            FROM albums
            JOIN artists ON albums.artist_id = artists.id
            WHERE albums.id = %s
            """,
            (album_id,),
        )
        album = cursor.fetchone()
        if not album:
            conn.close()
            return jsonify({"error": "Album not found"}), 404

        album_title = album["title"]
        artist_name = album["artist_name"]

        # Get all songs from this album (need file_path for exclusion)
        cursor.execute(
            "SELECT id, title, file_path FROM songs WHERE album_id = %s", (album_id,)
        )
        songs = cursor.fetchall()
        song_ids = [row["id"] for row in songs]

        # Add all song file paths to excluded_paths
        for song in songs:
            cursor.execute(
                """
                INSERT INTO excluded_paths (file_path, original_title, original_artist, original_album)
                VALUES (%s, %s, %s, %s)
                """,
                (song["file_path"], song["title"], artist_name, album_title),
            )

        if song_ids:
            placeholders = ",".join(["%s"] * len(song_ids))

            # Delete from song_artists table
            cursor.execute(
                f"DELETE FROM song_artists WHERE song_id IN ({placeholders})", song_ids
            )

            # Convert playlist songs to unavailable instead of deleting
            for song in songs:
                cursor.execute(
                    """
                    UPDATE playlist_songs
                    SET song_id = NULL,
                        spotify_track_name = %s,
                        spotify_artist = %s,
                        spotify_album = %s
                    WHERE song_id = %s
                    """,
                    (song["title"], artist_name, album_title, song["id"]),
                )

            # Delete from favorites
            cursor.execute(
                f"DELETE FROM favorites WHERE item_type = 'song' AND item_id IN ({placeholders})",
                song_ids,
            )

            # Delete from analytics
            cursor.execute(
                f"DELETE FROM play_history WHERE song_id IN ({placeholders})", song_ids
            )

            # Delete from song_analysis
            cursor.execute(
                f"DELETE FROM song_analysis WHERE song_id IN ({placeholders})", song_ids
            )

            # Delete from spotify_plays
            cursor.execute(
                f"DELETE FROM spotify_plays WHERE matched_song_id IN ({placeholders})",
                song_ids,
            )

            # Clear playback_state references
            cursor.execute(
                f"UPDATE playback_state SET current_song_id = NULL WHERE current_song_id IN ({placeholders})",
                song_ids,
            )

            # Delete all songs
            cursor.execute(f"DELETE FROM songs WHERE id IN ({placeholders})", song_ids)

        # Delete from favorites (album itself)
        cursor.execute(
            "DELETE FROM favorites WHERE item_type = 'album' AND item_id = %s",
            (album_id,),
        )

        # Delete the album itself
        cursor.execute("DELETE FROM albums WHERE id = %s", (album_id,))

        conn.commit()
        conn.close()

    except Exception as e:
        conn.rollback()
        conn.close()
        return _error_response(e)

    # File deletion runs AFTER the DB commit and outside the try-except.
    # If file ops fail at this point, we end up with orphan files
    # (recoverable from disk or via a library re-scan) — far better than
    # orphan DB records pointing at deleted files, which was the failure
    # mode of the previous ordering (the 2026-05-22 Sammy Hagar incident,
    # where rmtree of a phantom album's folder ran before the DB rollback,
    # destroying audio belonging to a different album_id).
    if delete_files:
        import os
        import shutil

        folders_to_check = set()
        for song in songs:
            try:
                if os.path.exists(song["file_path"]):
                    os.remove(song["file_path"])
                    folders_to_check.add(os.path.dirname(song["file_path"]))
            except Exception as file_err:
                print(
                    f"Warning: Could not delete file {song['file_path']}: {file_err}"
                )

        # SAFETY CHECK on folder rmtree — never remove folder if other audio
        # files remain (they belong to a different album_id sharing this
        # physical directory; same incident note above).
        for folder in folders_to_check:
            try:
                if not os.path.exists(folder):
                    continue
                remaining_audio = [
                    f for f in os.listdir(folder)
                    if os.path.splitext(f)[1].lower() in Config.SUPPORTED_FORMATS
                ]
                if remaining_audio:
                    sample = remaining_audio[:3]
                    suffix = "..." if len(remaining_audio) > 3 else ""
                    print(
                        f"⚠️ Keeping folder {folder} — {len(remaining_audio)} "
                        f"audio file(s) remain that belong to other DB records: "
                        f"{sample}{suffix}"
                    )
                    continue
                shutil.rmtree(folder)
            except Exception as folder_err:
                print(f"Warning: Could not delete folder {folder}: {folder_err}")

    return jsonify(
        {
            "success": True,
            "message": f"Deleted album '{album_title}' and {len(song_ids)} songs from database",
        }
    )


@api.route("/api/artist/<int:artist_id>", methods=["DELETE"])
def delete_artist(artist_id):
    """Delete artist and all their albums/songs from database, optionally delete files from disk"""
    delete_files = request.args.get("delete_files", "false").lower() == "true"
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Get artist name for response
        cursor.execute("SELECT name FROM artists WHERE id = %s", (artist_id,))
        artist = cursor.fetchone()
        if not artist:
            conn.close()
            return jsonify({"error": "Artist not found"}), 404

        artist_name = artist["name"]

        # Get all albums by this artist
        cursor.execute(
            "SELECT id, title FROM albums WHERE artist_id = %s", (artist_id,)
        )
        albums = cursor.fetchall()
        album_ids = [row["id"] for row in albums]
        album_titles = {row["id"]: row["title"] for row in albums}

        # Get all songs by this artist (with album_id for exclusion)
        cursor.execute(
            "SELECT id, title, file_path, album_id FROM songs WHERE artist_id = %s",
            (artist_id,),
        )
        songs = cursor.fetchall()
        song_ids = [row["id"] for row in songs]

        # Add all song file paths to excluded_paths
        for song in songs:
            album_title = album_titles.get(song["album_id"], "Unknown Album")
            cursor.execute(
                """
                INSERT INTO excluded_paths (file_path, original_title, original_artist, original_album)
                VALUES (%s, %s, %s, %s)
                """,
                (song["file_path"], song["title"], artist_name, album_title),
            )

        if song_ids:
            placeholders = ",".join(["%s"] * len(song_ids))

            # Delete from song_artists table
            cursor.execute(
                f"DELETE FROM song_artists WHERE song_id IN ({placeholders})", song_ids
            )

            # Convert playlist songs to unavailable instead of deleting
            for song in songs:
                album_title = album_titles.get(song["album_id"], "Unknown Album")
                cursor.execute(
                    """
                    UPDATE playlist_songs 
                    SET song_id = NULL,
                        spotify_track_name = %s,
                        spotify_artist = %s,
                        spotify_album = %s
                    WHERE song_id = %s
                    """,
                    (song["title"], artist_name, album_title, song["id"]),
                )

            # Delete from favorites (songs)
            cursor.execute(
                f"DELETE FROM favorites WHERE item_type = 'song' AND item_id IN ({placeholders})",
                song_ids,
            )

            # Delete from analytics
            cursor.execute(
                f"DELETE FROM play_history WHERE song_id IN ({placeholders})", song_ids
            )

            # Delete from song_analysis
            cursor.execute(
                f"DELETE FROM song_analysis WHERE song_id IN ({placeholders})", song_ids
            )

            # Delete from spotify_plays
            cursor.execute(
                f"DELETE FROM spotify_plays WHERE matched_song_id IN ({placeholders})",
                song_ids,
            )

            # Clear playback_state references
            cursor.execute(
                f"UPDATE playback_state SET current_song_id = NULL WHERE current_song_id IN ({placeholders})",
                song_ids,
            )

            # Delete all songs
            cursor.execute(f"DELETE FROM songs WHERE id IN ({placeholders})", song_ids)

        if album_ids:
            placeholders = ",".join(["%s"] * len(album_ids))

            # Delete from favorites (albums)
            cursor.execute(
                f"DELETE FROM favorites WHERE item_type = 'album' AND item_id IN ({placeholders})",
                album_ids,
            )

            # Delete all albums
            cursor.execute(
                f"DELETE FROM albums WHERE id IN ({placeholders})", album_ids
            )

        # Delete from favorites (artist itself)
        cursor.execute(
            "DELETE FROM favorites WHERE item_type = 'artist' AND item_id = %s",
            (artist_id,),
        )

        # Delete the artist itself
        cursor.execute("DELETE FROM artists WHERE id = %s", (artist_id,))

        conn.commit()
        conn.close()

    except Exception as e:
        conn.rollback()
        conn.close()
        return _error_response(e)

    # File deletion runs AFTER the DB commit and outside the try-except.
    # If file ops fail at this point, we end up with orphan files
    # (recoverable from disk or via a library re-scan) — far better than
    # orphan DB records pointing at deleted files. See delete_album above
    # for the same rule and the 2026-05-22 incident that motivated it.
    if delete_files:
        import os
        import shutil

        folders_to_check = set()
        for song in songs:
            try:
                if os.path.exists(song["file_path"]):
                    os.remove(song["file_path"])
                    folders_to_check.add(os.path.dirname(song["file_path"]))
            except Exception as file_err:
                print(
                    f"Warning: Could not delete file {song['file_path']}: {file_err}"
                )

        # SAFETY CHECK on folder rmtree — never remove folder if other audio
        # files remain (they belong to a different album_id sharing this
        # physical directory; same incident note above).
        for folder in folders_to_check:
            try:
                if not os.path.exists(folder):
                    continue
                remaining_audio = [
                    f for f in os.listdir(folder)
                    if os.path.splitext(f)[1].lower() in Config.SUPPORTED_FORMATS
                ]
                if remaining_audio:
                    sample = remaining_audio[:3]
                    suffix = "..." if len(remaining_audio) > 3 else ""
                    print(
                        f"⚠️ Keeping folder {folder} — {len(remaining_audio)} "
                        f"audio file(s) remain that belong to other DB records: "
                        f"{sample}{suffix}"
                    )
                    continue
                shutil.rmtree(folder)
                # Also try removing the parent (artist folder) if now empty
                parent = os.path.dirname(folder)
                if os.path.exists(parent) and not os.listdir(parent):
                    os.rmdir(parent)
            except Exception as folder_err:
                print(f"Warning: Could not delete folder {folder}: {folder_err}")

    return jsonify(
        {
            "success": True,
            "message": f"Deleted artist '{artist_name}', {len(album_ids)} albums, and {len(song_ids)} songs from database",
        }
    )


@api.route("/api/artist/<int:artist_id>/top-tracks", methods=["GET"])
def get_artist_top_tracks(artist_id):
    """Get top played tracks for an artist"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        cursor.execute(
            """
            SELECT songs.id, songs.title, songs.duration, songs.file_path, songs.is_explicit, songs.is_hdcd, songs.audio_codec, songs.audio_channels, songs.is_atmos,
                   COUNT(play_history.id) as play_count,
                   albums.id as album_id, albums.title as album_title, albums.artwork_path
            FROM songs
            JOIN albums ON songs.album_id = albums.id
            JOIN play_history ON play_history.song_id = songs.id
            WHERE songs.artist_id = %s
            GROUP BY songs.id, songs.title, songs.duration, songs.file_path, songs.is_explicit, songs.is_hdcd, songs.audio_codec, songs.audio_channels, songs.is_atmos, albums.id, albums.title, albums.artwork_path
            ORDER BY play_count DESC
            LIMIT 5
        """,
            (artist_id,),
        )

        tracks = [dict(row) for row in cursor.fetchall()]
        return jsonify({"tracks": tracks})
    finally:
        conn.close()


@api.route("/api/artist/<int:artist_id>/spotify-top-tracks", methods=["GET"])
def get_artist_spotify_top_tracks(artist_id):
    """Get top tracks with real play counts from Spotify's Pathfinder API.

    DB connections are released before and between external HTTP calls
    (MusicBrainz + Spotify). Holding a pooled conn across these 10s+
    requests would drain the pool when many clients hit artist pages
    concurrently.
    """
    db = get_db()

    # Step 1: quick DB read for artist info, then release.
    conn = db.get_connection()
    try:
        cursor = db.get_cursor(conn)
        cursor.execute("SELECT name, mbid FROM artists WHERE id = %s", (artist_id,))
        artist = cursor.fetchone()
        if not artist:
            return jsonify({"error": "Artist not found"}), 404
        artist_name = artist["name"]
        artist_mbid = artist.get("mbid")
    finally:
        conn.close()

    try:
        # Step 2: external HTTP (MusicBrainz + Spotify) — no DB conn held.
        spotify_artist_id = None

        if artist_mbid:
            try:
                import requests as mb_requests

                mb_url = f"https://musicbrainz.org/ws/2/artist/{artist_mbid}?inc=url-rels&fmt=json"
                mb_resp = mb_requests.get(
                    mb_url, headers={"User-Agent": "NASRadio/1.0"}, timeout=25
                )
                if mb_resp.status_code == 200:
                    mb_data = mb_resp.json()
                    for rel in mb_data.get("relations", []):
                        if (
                            rel.get("type") == "streaming music"
                            or rel.get("type") == "free streaming"
                        ):
                            url = rel.get("url", {}).get("resource", "")
                            if "open.spotify.com/artist/" in url:
                                spotify_artist_id = url.split("/artist/")[-1].split(
                                    "?"
                                )[0]
                                print(
                                    f"🟢 Found Spotify ID via MusicBrainz MBID: {spotify_artist_id}"
                                )
                                break
            except Exception as e:
                print(
                    f"🟡 MusicBrainz MBID lookup failed, falling back to name search: {e}"
                )

        if not spotify_artist_id:
            try:
                discovery = SpotifyDiscovery()
                results = discovery.sp.search(
                    q=f'artist:"{artist_name}"', type="artist", limit=5
                )
                for sp_artist in results.get("artists", {}).get("items", []):
                    if sp_artist["name"].lower() == artist_name.lower():
                        spotify_artist_id = sp_artist["id"]
                        break
            except Exception as e:
                print(f"🟡 Spotify name search fallback failed: {e}")

        if not spotify_artist_id:
            return jsonify({"error": "Artist not found on Spotify", "tracks": []}), 404

        config = Config()
        playcount_client = SpotifyPlayCount(config.SPOTIFY_SP_DC)
        # Catch Spotify Pathfinder 5xx (their service blipping)
        # explicitly. Returning a 503 + warning is more honest than a
        # 500 + full traceback in our log — it's not our outage.
        try:
            result = playcount_client.get_artist_play_counts(spotify_artist_id)
        except mb_requests.exceptions.HTTPError as e:
            status = getattr(e.response, "status_code", 0) if e.response is not None else 0
            if status >= 500 and status < 600:
                print(
                    f"🟡 Spotify Pathfinder {status} for artist "
                    f"{spotify_artist_id} — Spotify is having a moment"
                )
                return jsonify({
                    "error": "Spotify service is temporarily unavailable, please try again later",
                    "tracks": [],
                }), 503
            raise

        if not result.get("success"):
            return jsonify({"error": "Failed to fetch play counts", "tracks": []}), 500

        # Step 3: fetch local song rows for matching, then release.
        tracks = result["tracks"]
        local_songs = []
        if tracks:
            conn = db.get_connection()
            try:
                cursor = db.get_cursor(conn)
                cursor.execute("""
                    SELECT s.id, s.title, s.album_id, a.title as album_title, a.artwork_path,
                           s.duration, s.track_number, s.disc_number, s.file_path, s.file_size,
                           s.bitrate, s.artist_id
                    FROM songs s
                    JOIN albums a ON s.album_id = a.id
                    WHERE s.artist_id = %s
                """, (artist_id,))
                local_songs = cursor.fetchall()

                cursor.execute("""
                    SELECT s.id, s.title, s.album_id, a.title as album_title, a.artwork_path,
                           s.duration, s.track_number, s.disc_number, s.file_path, s.file_size,
                           s.bitrate, s.artist_id
                    FROM songs s
                    JOIN albums a ON s.album_id = a.id
                    JOIN song_artists sa ON sa.song_id = s.id
                    WHERE sa.artist_id = %s
                """, (artist_id,))
                local_songs.extend(cursor.fetchall())
            finally:
                conn.close()

        if tracks:

            # Build lookup: normalized title -> song info
            from app.utils import normalize_text_for_search
            import re as _re

            def _strip_suffixes(title):
                """Strip common Spotify suffixes like (Remastered), - 2015 Remaster, etc."""
                # Parenthesized suffixes: (Remastered), (2015 Remaster), (Deluxe), etc.
                title = _re.sub(
                    r'\s*\((?:Remastered|Remaster|Deluxe|Bonus Track|'
                    r'\d{4}\s*Remaster(?:ed)?|Anniversary Edition|'
                    r'Special Edition|Expanded Edition|'
                    r'Single Version|Album Version|Radio Edit)\)',
                    '', title, flags=_re.IGNORECASE
                )
                # Dash suffixes: " - 2015 Remaster", " - Remastered 2021", " - Live", etc.
                title = _re.sub(
                    r'\s*-\s*(?:\d{4}\s*)?Remaster(?:ed)?(?:\s*\d{4})?$',
                    '', title, flags=_re.IGNORECASE
                )
                return title.strip()

            # Build lookup: normalized title -> list of all matching songs
            from collections import defaultdict
            local_lookup = defaultdict(list)
            seen_ids = set()
            for song in local_songs:
                if song["id"] in seen_ids:
                    continue
                seen_ids.add(song["id"])
                key = normalize_text_for_search(song["title"])
                local_lookup[key].append(song)
                stripped_key = normalize_text_for_search(_strip_suffixes(song["title"]))
                if stripped_key != key:
                    local_lookup[stripped_key].append(song)

            # Count songs per album to help identify compilations/bootlegs
            album_song_counts = {}
            for song in local_songs:
                aid = song["album_id"]
                album_song_counts[aid] = album_song_counts.get(aid, 0) + 1

            def _pick_best_match(candidates, spotify_album_name=""):
                """Prefer studio albums over live/compilations/bootlegs."""
                if len(candidates) == 1:
                    return candidates[0]

                live_patterns = _re.compile(
                    r'\b(live|concert|tour|bootleg|unplugged|acoustic live|'
                    r'in concert|on stage)\b|@ ', _re.IGNORECASE
                )
                compilation_patterns = _re.compile(
                    r'\b(greatest hits|best of|collection|anthology|'
                    r'essential|definitive|complete|chronicle|'
                    r'instrumentals|vocals|outtakes|demos?)\b', _re.IGNORECASE
                )
                # Year-only or city-year bootleg patterns: "Charlotte 2007", "1998"
                bootleg_patterns = _re.compile(
                    r'^[A-Z][a-z]+ \d{4}$|^Unchained'
                )

                def _score(song):
                    album = song["album_title"] or ""
                    score = 0
                    # Penalize live albums heavily
                    if live_patterns.search(album):
                        score -= 20
                    # Penalize compilations
                    if compilation_patterns.search(album):
                        score -= 15
                    # Penalize bootleg-style names
                    if bootleg_patterns.search(album):
                        score -= 20
                    # Penalize huge albums (likely compilations/box sets)
                    track_count = album_song_counts.get(song["album_id"], 0)
                    if track_count > 25:
                        score -= 10
                    # Slight bonus for normal-sized albums (studio album range)
                    elif 6 <= track_count <= 16:
                        score += 5
                    # Bonus if album name matches Spotify's album
                    if spotify_album_name:
                        sp_album_norm = normalize_text_for_search(spotify_album_name)
                        local_album_norm = normalize_text_for_search(album)
                        if sp_album_norm == local_album_norm:
                            score += 30
                        elif sp_album_norm in local_album_norm or local_album_norm in sp_album_norm:
                            score += 15
                    return score

                return max(candidates, key=_score)

            # Match each Spotify track to a local song
            for track in tracks:
                spotify_title = track.get("name", "")
                spotify_album = track.get("album_name", "")
                # Try exact normalized match first
                key = normalize_text_for_search(spotify_title)
                candidates = local_lookup.get(key, [])
                # Try with suffixes stripped
                if not candidates:
                    stripped = normalize_text_for_search(_strip_suffixes(spotify_title))
                    candidates = local_lookup.get(stripped, [])
                match = _pick_best_match(candidates, spotify_album) if candidates else None
                if match:
                    track["local_id"] = match["id"]
                    track["album_id"] = match["album_id"]
                    track["artwork_path"] = match["artwork_path"]
                    track["album_title"] = match["album_title"]
                    track["duration"] = match["duration"]
                    track["track_number"] = match["track_number"]
                    track["disc_number"] = match["disc_number"]
                    track["file_path"] = match["file_path"]
                    track["file_size"] = match["file_size"]
                    track["bitrate"] = match["bitrate"]
                    track["artist_id"] = match["artist_id"]
                    track["local_title"] = match["title"]

        # Return tracks with play counts
        return jsonify(
            {
                "tracks": tracks,
                "monthly_listeners": result.get("monthly_listeners"),
                "follower_count": result.get("follower_count"),
            }
        )

    except Exception as e:
        print(f"🔴 Spotify play count error: {e}")
        traceback.print_exc()
        return _error_response(e)


@api.route("/api/artist/<int:artist_id>/image-search", methods=["GET"])
def search_artist_images(artist_id):
    """Search multiple sources for artist images"""
    import requests as img_requests

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        cursor.execute("SELECT name, mbid FROM artists WHERE id = %s", (artist_id,))
        artist = cursor.fetchone()
        if not artist:
            return jsonify({"error": "Artist not found"}), 404

        artist_name = artist["name"]
        artist_mbid = artist.get("mbid")
    finally:
        conn.close()

    def _do_image_search():
        """Run all external API calls in a real thread."""
        options = []
        mbid = artist_mbid
        resolved_name = artist_name  # May differ if found via alias (e.g. "The Chicks" for "Dixie Chicks")

        # If no stored MBID, look up via MusicBrainz (handles aliases like Dixie Chicks → The Chicks)
        if not mbid:
            try:
                mb_search = img_requests.get(
                    "https://musicbrainz.org/ws/2/artist/",
                    params={"query": f'{artist_name}', "fmt": "json", "limit": 5},
                    headers={"User-Agent": "NASRadio/1.0"},
                    timeout=25,
                )
                if mb_search.status_code == 200:
                    mb_artists = mb_search.json().get("artists", [])
                    for mb_artist in mb_artists:
                        # Check exact name match or alias match
                        if mb_artist["name"].lower() == artist_name.lower():
                            mbid = mb_artist["id"]
                            resolved_name = mb_artist["name"]
                            break
                        for alias in mb_artist.get("aliases", []):
                            if alias.get("name", "").lower() == artist_name.lower():
                                mbid = mb_artist["id"]
                                resolved_name = mb_artist["name"]
                                break
                        if mbid:
                            break
                    if mbid:
                        print(f"Found MBID via MusicBrainz: {mbid} (resolved: {resolved_name})")
            except Exception as e:
                print(f"MusicBrainz alias lookup failed: {e}")

        # Source 1: Fanart.tv (via MBID)
        if mbid:
            try:
                fanart_url = f"https://webservice.fanart.tv/v3/music/{mbid}"
                fanart_resp = img_requests.get(
                    fanart_url,
                    headers={"api-key": Config.FANART_API_KEY},
                    timeout=10,
                )
                if fanart_resp.status_code == 200:
                    fanart_data = fanart_resp.json()
                    for thumb in fanart_data.get("artistthumb", []):
                        options.append(
                            {
                                "url": thumb["url"],
                                "source": "Fanart.tv",
                                "type": "Thumbnail",
                            }
                        )
                    for bg in fanart_data.get("artistbackground", []):
                        options.append(
                            {
                                "url": bg["url"],
                                "source": "Fanart.tv",
                                "type": "Background",
                            }
                        )
            except Exception as e:
                print(f"🟡 Fanart.tv search failed: {e}")

        # Source 2: Spotify (via artist search)
        try:
            discovery = SpotifyDiscovery()

            # Try MBID lookup first
            spotify_artist_id = None
            if mbid:
                try:
                    mb_url = f"https://musicbrainz.org/ws/2/artist/{mbid}?inc=url-rels&fmt=json"
                    mb_resp = img_requests.get(
                        mb_url,
                        headers={"User-Agent": "NASRadio/1.0"},
                        timeout=25,
                    )
                    if mb_resp.status_code == 200:
                        mb_data = mb_resp.json()
                        for rel in mb_data.get("relations", []):
                            if rel.get("type") in ("streaming music", "free streaming"):
                                url = rel.get("url", {}).get("resource", "")
                                if "open.spotify.com/artist/" in url:
                                    spotify_artist_id = url.split("/artist/")[-1].split(
                                        "?"
                                    )[0]
                                    break
                except Exception:
                    pass

            # Fallback to name search (try resolved name first, then original)
            if not spotify_artist_id:
                names_to_try = [resolved_name]
                if resolved_name.lower() != artist_name.lower():
                    names_to_try.append(artist_name)
                for search_name in names_to_try:
                    results = discovery.sp.search(
                        q=f'artist:"{search_name}"', type="artist", limit=5
                    )
                    for sp_artist in results.get("artists", {}).get("items", []):
                        if sp_artist["name"].lower() == search_name.lower():
                            spotify_artist_id = sp_artist["id"]
                            break
                    if spotify_artist_id:
                        break

            if spotify_artist_id:
                sp_artist = discovery.sp.artist(spotify_artist_id)
                images = sp_artist.get("images", [])
                if images:
                    # Only keep the largest Spotify image
                    largest = max(images, key=lambda i: i.get("width", 0) * i.get("height", 0))
                    options.append(
                        {
                            "url": largest["url"],
                            "source": "Spotify",
                            "type": f"{largest.get('width', '?')}x{largest.get('height', '?')}",
                        }
                    )
        except Exception as e:
            print(f"Spotify image search failed: {e}")

        # Source 3: Last.fm (skip — they deprecated artist images, only returns placeholders now)

        return options

    try:
        # Run all external API calls in a real OS thread
        options = eventlet.tpool.execute(_do_image_search)

        return jsonify(
            {
                "artist_id": artist_id,
                "artist_name": artist_name,
                "options": options,
            }
        )

    except Exception as e:
        print(f"🔴 Artist image search error: {e}")
        traceback.print_exc()
        return _error_response(e)


@api.route("/api/artist/<int:artist_id>/set-image", methods=["POST"])
def set_artist_image(artist_id):
    """Download and save a selected artist image"""
    import requests as img_requests
    from PIL import Image
    from io import BytesIO

    data = request.get_json()
    image_url = data.get("url")

    if not image_url:
        return jsonify({"error": "No image URL provided"}), 400

    def _download_and_save():
        """Download and process image in a real thread (PIL is CPU-bound)."""
        resp = img_requests.get(image_url, timeout=15)
        if resp.status_code != 200:
            return None

        img = Image.open(BytesIO(resp.content))
        if img.mode in ("RGBA", "LA", "P"):
            img = img.convert("RGB")

        img.thumbnail((1200, 1200), Image.Resampling.LANCZOS)

        image_filename = f"artist_{artist_id}.jpg"
        image_path = os.path.join("artist_images", image_filename)
        os.makedirs("artist_images", exist_ok=True)
        img.save(image_path, "JPEG", quality=95)
        return image_filename

    try:
        image_filename = eventlet.tpool.execute(_download_and_save)
        if not image_filename:
            return jsonify({"error": "Failed to download image"}), 500

        # Update database
        db = get_db()
        conn = db.get_connection()
        cursor = db.get_cursor(conn)
        try:
            cursor.execute(
                "UPDATE artists SET image_path = %s, image_source = %s WHERE id = %s",
                (image_filename, f"manual:{image_url}"[:500], artist_id),
            )
            conn.commit()
        finally:
            conn.close()

        _cast_refresh(artist_id=artist_id)
        return jsonify({"success": True, "image_path": image_filename})

    except Exception as e:
        print(f"🔴 Set artist image error: {e}")
        traceback.print_exc()
        return _error_response(e)


@api.route("/api/artist/<int:artist_id>/upload-image", methods=["POST"])
def upload_artist_image(artist_id):
    """Upload a custom artist image"""
    from PIL import Image
    from io import BytesIO

    if "file" not in request.files:
        return jsonify({"error": "No file provided"}), 400

    file = request.files["file"]
    if not file.filename:
        return jsonify({"error": "No filename"}), 400

    image_data = file.read()

    def _process_and_save():
        img = Image.open(BytesIO(image_data))
        if img.mode in ("RGBA", "LA", "P"):
            img = img.convert("RGB")
        # Keep original resolution for artist uploads
        image_filename = f"artist_{artist_id}.jpg"
        image_path = os.path.join("artist_images", image_filename)
        os.makedirs("artist_images", exist_ok=True)
        img.save(image_path, "JPEG", quality=95)
        return image_filename

    try:
        image_filename = eventlet.tpool.execute(_process_and_save)

        db = get_db()
        conn = db.get_connection()
        cursor = db.get_cursor(conn)
        try:
            cursor.execute(
                "UPDATE artists SET image_path = %s, image_source = %s WHERE id = %s",
                (image_filename, "upload", artist_id),
            )
            conn.commit()
        finally:
            conn.close()

        _cast_refresh(artist_id=artist_id)
        return jsonify({"success": True, "image_path": image_filename})

    except Exception as e:
        print(f"🔴 Upload artist image error: {e}")
        traceback.print_exc()
        return _error_response(e)


@api.route("/api/artist/<int:artist_id>/lastfm-top-tracks", methods=["GET"])
def get_artist_lastfm_top_tracks(artist_id):
    """Get top tracks from Last.fm and check local availability"""

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Get artist name and MBID for disambiguation
        cursor.execute("SELECT name, mbid FROM artists WHERE id = %s", (artist_id,))
        artist = cursor.fetchone()
        if not artist:
            return jsonify({"error": "Artist not found"}), 404

        artist_name = artist["name"]
        artist_mbid = artist.get("mbid")

        # Call Last.fm API - use MBID if available for disambiguation
        lastfm_api_key = Config.LASTFM_API_KEY

        lastfm_params = {
            "method": "artist.gettoptracks",
            "api_key": lastfm_api_key,
            "format": "json",
            "limit": 10,
        }
        if artist_mbid:
            lastfm_params["mbid"] = artist_mbid
        else:
            lastfm_params["artist"] = artist_name

        response = mb_requests.get(
            "http://ws.audioscrobbler.com/2.0/",
            params=lastfm_params,
            timeout=10,
        )

        if response.status_code != 200:
            print(f"🔴 Last.fm API error: status={response.status_code}")
            return jsonify({"tracks": [], "error": "Last.fm API error"})

        data = response.json()
        print(
            f"🎵 Last.fm response for '{artist_name}': {len(data.get('toptracks', {}).get('track', []))} tracks"
        )

        if "error" in data:
            print(f"🔴 Last.fm error: {data.get('message', 'Unknown')}")
            return jsonify(
                {"tracks": [], "error": data.get("message", "Unknown error")}
            )

        # Check if Last.fm returned the correct artist by comparing MBIDs
        top_tracks = data.get("toptracks", {}).get("track", [])
        if artist_mbid and top_tracks:
            returned_mbid = top_tracks[0].get("artist", {}).get("mbid", "")
            if returned_mbid and returned_mbid != artist_mbid:
                print(
                    f"⚠️ Last.fm MBID mismatch for '{artist_name}': expected {artist_mbid}, got {returned_mbid} — wrong artist, skipping"
                )
                conn.close()
                return jsonify(
                    {
                        "tracks": [],
                        "note": "Last.fm returned a different artist with the same name",
                    }
                )

        tracks = []
        seen_titles = set()

        for track in top_tracks:
            if len(tracks) >= 10:
                break

            track_name = track.get("name", "")

            # Normalize title for deduplication (remove remaster/remix info)

            normalized = re.sub(
                r"\s*[-–]\s*(19|20)\d{2}\s*(Remaster|Remix|Version).*$",
                "",
                track_name,
                flags=re.IGNORECASE,
            )
            normalized = re.sub(
                r"\s*\((19|20)\d{2}\s*(Remaster|Remix|Version).*\)$",
                "",
                normalized,
                flags=re.IGNORECASE,
            )
            normalized = normalized.lower().strip()

            if normalized in seen_titles:
                continue
            seen_titles.add(normalized)
            playcount = track.get("playcount", 0)
            mbid = track.get("mbid", "")

            # Normalize for matching (handle smart quotes/apostrophes)
            def normalize_title(t):
                return (
                    t.lower()
                    .replace("'", "'")
                    .replace("'", "'")
                    .replace("`", "'")
                    .replace("'", "'")
                )

            track_name_normalized = normalize_title(track_name)

            # Check if we have this song locally - use LIKE for fuzzy matching
            # Replace smart apostrophes in search term for SQL
            sql_track_name = track_name.replace("'", "_").replace("'", "_")

            cursor.execute(
                """
                SELECT songs.id, songs.title, songs.file_path, songs.duration, albums.id as album_id, albums.title as album_title, albums.artwork_path, albums.year
                FROM songs
                JOIN albums ON songs.album_id = albums.id
                WHERE songs.artist_id = %s AND LOWER(songs.title) LIKE LOWER(%s)
                ORDER BY 
                    CASE WHEN albums.artwork_path IS NOT NULL THEN 0 ELSE 1 END,
                    CASE 
                        WHEN LOWER(albums.title) LIKE '%%live%%' THEN 3
                        WHEN LOWER(albums.title) LIKE '%%concert%%' THEN 3
                        WHEN LOWER(albums.title) LIKE '%%tour%%' THEN 3
                        WHEN LOWER(albums.title) LIKE '%%bootleg%%' THEN 3
                        WHEN LOWER(albums.title) LIKE '%%unchained%%' THEN 3
                        WHEN LOWER(albums.title) LIKE '%%monster%%' THEN 3
                        WHEN LOWER(albums.title) LIKE '%% 19__' THEN 3
                        WHEN LOWER(albums.title) LIKE '%% 20__' THEN 3
                        WHEN LOWER(albums.title) LIKE '%%/@%%' THEN 3
                        WHEN LOWER(albums.title) LIKE '%%@ %%' THEN 3
                        WHEN LOWER(albums.title) LIKE '%%outtake%%' THEN 3
                        WHEN LOWER(albums.title) LIKE '%%demo%%' THEN 3
                        WHEN LOWER(albums.title) LIKE '%%best of%%' THEN 2
                        WHEN LOWER(albums.title) LIKE '%%greatest hits%%' THEN 2
                        WHEN LOWER(albums.title) LIKE '%%compilation%%' THEN 2
                        WHEN LOWER(albums.title) LIKE '%%collection%%' THEN 2
                        WHEN LOWER(albums.title) LIKE '%%anthology%%' THEN 2
                        ELSE 1
                    END,
                    albums.year ASC NULLS LAST
                LIMIT 1
            """,
                (artist_id, sql_track_name),
            )

            local_song = cursor.fetchone()

            tracks.append(
                {
                    "title": track_name,
                    "playcount": int(playcount),
                    "mbid": mbid,
                    "local_id": local_song["id"] if local_song else None,
                    "album_id": local_song["album_id"] if local_song else None,
                    "album_title": local_song["album_title"] if local_song else None,
                    "artwork_path": local_song["artwork_path"] if local_song else None,
                    "file_path": local_song["file_path"] if local_song else None,
                    "duration": local_song["duration"] if local_song else 0,
                }
            )

        print(f"🎵 Returning {len(tracks)} tracks for '{artist_name}'", flush=True)
        return jsonify({"tracks": tracks, "artist_name": artist_name})

    except mb_requests.exceptions.Timeout:
        print(f"🔴 Last.fm timeout", flush=True)
        return jsonify({"tracks": [], "error": "Last.fm timeout"})
    except Exception as e:
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/artist/<int:artist_id>/discography", methods=["GET"])
def get_artist_discography(artist_id):
    """Every MusicBrainz release group for the artist, tabbed by type, with
    the ones in the library marked. Cached in mb_release_groups; the first
    call for an artist (or ?refresh=1) kicks a background fetch and answers
    status="fetching" until it lands. See app/discography.py."""
    from app.discography import build_discography

    refresh = request.args.get("refresh") in ("1", "true", "yes")
    try:
        payload = build_discography(get_db(), artist_id, refresh=refresh)
    except Exception as e:
        return _error_response(e)
    if payload is None:
        return jsonify({"error": "Artist not found"}), 404
    return jsonify(payload)


@api.route("/api/imports/upload", methods=["POST"])
def upload_import_files():
    """Land files picked in the app into the NASRadio downloads folder so
    the normal import route can take them from there. Multipart: `folder`
    (new subfolder name) plus one or more `files`. Returns the same shape
    as an /api/imports/pending entry so the app can open it directly."""
    folder = (request.form.get("folder") or "").strip()
    files = request.files.getlist("files")
    if not folder or not files:
        return jsonify({"error": "folder and at least one file required"}), 400

    safe = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", folder).strip(" .")[:150] or "import"
    base = Config.DOWNLOADS_NASRADIO
    dest = os.path.join(base, safe)
    n = 2
    while os.path.exists(dest):
        dest = os.path.join(base, f"{safe} ({n})")
        n += 1
    os.makedirs(dest, exist_ok=True)

    saved, total = [], 0
    for f in files:
        name = os.path.basename(f.filename or "")
        name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", name).strip() or "track"
        target = os.path.join(dest, name)
        f.save(target)
        size = os.path.getsize(target)
        saved.append({"name": name, "size": size})
        total += size

    print(f"📥 Upload import: {len(saved)} files, {format_size(total)} -> {dest}", flush=True)
    return jsonify(
        {
            "success": True,
            "path": dest,
            "folder_name": os.path.basename(dest),
            "source": "nasradio",
            "audio_file_count": len(saved),
            "total_size": total,
            "size_formatted": format_size(total),
            "has_cue": any(x["name"].lower().endswith(".cue") for x in saved),
            "cue_files": [os.path.join(dest, x["name"]) for x in saved if x["name"].lower().endswith(".cue")],
            "needs_cue_split": False,
            "multi_disc_info": {"is_multi_disc": False},
            "files": saved,
        }
    )

@api.route("/api/album/<int:album_id>/renumber-disc", methods=["POST"])
def renumber_disc_tracks(album_id):
    """Renumber all tracks in a disc sequentially"""
    data = request.get_json()
    disc_number = data.get("disc_number")
    start_number = data.get("start_number", 1)

    if disc_number is None:
        return jsonify({"error": "disc_number is required"}), 400

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Get all songs in this disc, ordered by current track number
        cursor.execute(
            """
            SELECT id, track_number 
            FROM songs 
            WHERE album_id = %s AND disc_number = %s 
            ORDER BY track_number
            """,
            (album_id, disc_number),
        )
        songs = cursor.fetchall()

        if not songs:
            conn.close()
            return jsonify({"error": "No songs found in this disc"}), 404

        # Renumber each song sequentially
        new_track_number = start_number
        for song in songs:
            cursor.execute(
                "UPDATE songs SET track_number = %s WHERE id = %s",
                (new_track_number, song["id"]),
            )
            new_track_number += 1

        conn.commit()
        conn.close()

        return jsonify(
            {
                "success": True,
                "message": f"Renumbered {len(songs)} tracks in disc {disc_number} starting from {start_number}",
            }
        )

    except Exception as e:
        conn.rollback()
        conn.close()
        return _error_response(e)


@api.route("/api/most-played", methods=["GET"])
def get_most_played():
    """Get most played songs"""
    from app.analytics import Analytics

    limit = request.args.get("limit", 50, type=int)

    analytics = Analytics()
    songs = analytics.get_most_played(limit)

    # Add all artists for each song
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    for song in songs:
        cursor.execute(
            """
            SELECT artists.id, artists.name 
            FROM song_artists 
            JOIN artists ON song_artists.artist_id = artists.id 
            WHERE song_artists.song_id = %s
            ORDER BY song_artists.position
            """,
            (song["id"],),
        )
        artist_list = [
            {"id": row["id"], "name": row["name"]} for row in cursor.fetchall()
        ]
        song["artists"] = (
            artist_list
            if artist_list
            else [{"id": song["artist_id"], "name": song["artist_name"]}]
        )

    conn.close()

    return jsonify(songs)


@api.route("/api/analytics-stats", methods=["GET"])
def get_analytics_stats():
    """Get overall analytics statistics"""
    from app.analytics import Analytics

    analytics = Analytics()
    stats = analytics.get_analytics_stats()

    return jsonify(stats)


# ========================
# Favorites Endpoints
# ========================


@api.route("/api/favorites/add", methods=["POST"])
def add_favorite():
    """Add an item to favorites"""
    from app.favorites import Favorites

    data = request.get_json()
    item_type = data.get("item_type")
    item_id = data.get("item_id")

    if not item_type or not item_id:
        return jsonify({"error": "item_type and item_id are required"}), 400

    if item_type not in ["song", "album", "artist", "station"]:
        return jsonify({"error": "item_type must be 'song', 'album', 'artist', or 'station'"}), 400

    favorites = Favorites()
    result = favorites.add_favorite(item_type, item_id)

    if result["success"]:
        return jsonify(result)
    else:
        return jsonify(result), 500


@api.route("/api/favorites/remove", methods=["POST"])
def remove_favorite():
    """Remove an item from favorites"""
    from app.favorites import Favorites

    data = request.get_json()
    item_type = data.get("item_type")
    item_id = data.get("item_id")

    if not item_type or not item_id:
        return jsonify({"error": "item_type and item_id are required"}), 400

    favorites = Favorites()
    result = favorites.remove_favorite(item_type, item_id)

    if result["success"]:
        return jsonify(result)
    else:
        return jsonify(result), 500


@api.route("/api/favorites/check", methods=["GET"])
def check_favorite():
    """Check if an item is favorited"""
    from app.favorites import Favorites

    item_type = request.args.get("item_type")
    item_id = request.args.get("item_id", type=int)

    if not item_type or not item_id:
        return jsonify({"error": "item_type and item_id are required"}), 400

    favorites = Favorites()
    is_favorited = favorites.is_favorite(item_type, item_id)

    return jsonify({"is_favorite": is_favorited})


@api.route("/api/favorites/check-batch", methods=["POST"])
def check_favorite_batch():
    """Check favorite status for many items in a single request.

    Body: {"item_type": "song", "ids": [1, 2, 3, ...]}
    Returns: {"favorites": {1: true, 2: false, ...}}

    Exists to fix the per-song HTTP storm — a list of 50 songs used to
    fire 50 individual /favorites/check requests in parallel, each
    grabbing a DB connection. This endpoint does the whole thing in
    one connection + one query with WHERE item_id = ANY(%s). When the
    frontend FavoriteButton is rewired to pre-fetch from this endpoint
    at list-load time, the per-song HTTP calls go away entirely.
    """
    data = request.get_json(silent=True) or {}
    item_type = data.get("item_type")
    ids = data.get("ids") or []

    if not item_type:
        return jsonify({"error": "item_type is required"}), 400
    if not isinstance(ids, list):
        return jsonify({"error": "ids must be a list"}), 400
    if not ids:
        return jsonify({"favorites": {}})

    # Coerce + cap. The cap protects against accidental megaqueries.
    try:
        clean_ids = [int(i) for i in ids][:500]
    except (TypeError, ValueError):
        return jsonify({"error": "ids must be integers"}), 400

    db = get_db()
    conn = db.get_connection()
    cur = db.get_cursor(conn)
    try:
        cur.execute(
            "SELECT item_id FROM favorites "
            "WHERE user_id = %s AND item_type = %s AND item_id = ANY(%s)",
            (auth.current_user_id(), item_type, clean_ids),
        )
        favorited = {row["item_id"] for row in cur.fetchall()}
    finally:
        conn.close()

    return jsonify({
        "favorites": {str(i): (i in favorited) for i in clean_ids}
    })


@api.route("/api/favorites/songs", methods=["GET"])
def get_favorite_songs():
    """Get all favorite songs"""
    from app.favorites import Favorites

    favorites = Favorites()
    songs = favorites.get_favorite_songs()

    # Add all artists for each song
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    for song in songs:
        cursor.execute(
            """
            SELECT artists.id, artists.name 
            FROM song_artists 
            JOIN artists ON song_artists.artist_id = artists.id 
            WHERE song_artists.song_id = %s
            ORDER BY song_artists.position
            """,
            (song["id"],),
        )
        artist_list = [
            {"id": row["id"], "name": row["name"]} for row in cursor.fetchall()
        ]
        song["artists"] = (
            artist_list
            if artist_list
            else [{"id": song["artist_id"], "name": song["artist_name"]}]
        )

    conn.close()

    return jsonify(songs)


@api.route("/api/favorites/albums", methods=["GET"])
def get_favorite_albums():
    """Get all favorite albums"""
    from app.favorites import Favorites

    favorites = Favorites()
    albums = favorites.get_favorite_albums()

    return jsonify(albums)


@api.route("/api/favorites/artists", methods=["GET"])
def get_favorite_artists():
    """Get all favorite artists"""
    from app.favorites import Favorites

    favorites = Favorites()
    artists = favorites.get_favorite_artists()

    return jsonify(artists)


@api.route("/api/favorites/station-status", methods=["GET"])
def station_favorite_status():
    """Favorite status for a station by stream URL.

    Station Songs carry synthetic NEGATIVE ids in the app (saved: -dbId,
    radio-browser: -urlHash — a collision-avoidance design), so the id-based
    /favorites/check can never match a station. The stream URL is a station's
    one stable identity; returns the real station id so the client can
    unfavorite without a lookup.
    """
    url = (request.args.get("url") or "").strip()
    if not url:
        return jsonify({"error": "url is required"}), 400

    db = get_db()
    conn = db.get_connection()
    cur = db.get_cursor(conn)
    try:
        cur.execute(
            "SELECT s.id FROM stations s "
            "JOIN favorites f ON f.item_id = s.id "
            "AND f.item_type = 'station' AND f.user_id = %s "
            "WHERE s.url = %s",
            (auth.current_user_id(), url),
        )
        row = cur.fetchone()
        return jsonify({
            "is_favorite": row is not None,
            "station_id": row["id"] if row else None,
        })
    finally:
        conn.close()


@api.route("/api/favorites/stations", methods=["GET"])
def get_favorite_stations():
    """Get all favorite stations (live internet radio)"""
    from app.favorites import Favorites

    favorites = Favorites()
    stations = favorites.get_favorite_stations()

    return jsonify(stations)


@api.route("/api/favorites/counts", methods=["GET"])
def get_favorites_counts():
    """Get count of favorites by type"""
    from app.favorites import Favorites

    favorites = Favorites()
    counts = favorites.get_favorites_count()

    return jsonify(counts)


# ========================
# Last.fm Scrobbling
# ========================


@api.route("/api/lastfm/status", methods=["GET"])
def lastfm_status():
    """Get Last.fm connection status"""
    from app.lastfm import LastFM

    lastfm = LastFM()
    creds = lastfm._get_credentials()
    return jsonify(
        {
            "configured": bool(creds.get("api_key")),
            "authenticated": bool(creds.get("session_key")),
            "username": creds.get("username"),
            "enabled": creds.get("enabled", "true") == "true",
        }
    )


@api.route("/api/lastfm/stats", methods=["GET"])
def lastfm_stats():
    """Profile totals + top artists/tracks (by period) + recent scrobbles for
    the in-app Last.fm screen. Query: ?period=7day|1month|3month|6month|12month|overall"""
    from app.lastfm import LastFM

    period = request.args.get("period", "overall")
    lastfm = LastFM()
    # get_stats fans the Last.fm calls out as green threads itself — calling it
    # directly (NOT via tpool) keeps it on the cooperative event loop so a slow
    # Last.fm response can't starve the native thread pool used by streaming/SMB.
    result = lastfm.get_stats(period)
    if not result.get("success"):
        return jsonify(result), 400
    return jsonify(result)


@api.route("/api/lastfm/configure", methods=["POST"])
def lastfm_configure():
    """Store Last.fm API key and secret"""
    data = request.get_json()
    api_key = data.get("api_key")
    api_secret = data.get("api_secret")

    if not api_key or not api_secret:
        return jsonify({"error": "api_key and api_secret required"}), 400

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        for key, value in [
            ("api_key", api_key),
            ("api_secret", api_secret),
            ("enabled", "true"),
        ]:
            cursor.execute(
                """INSERT INTO lastfm_config (key, value) VALUES (%s, %s)
                   ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value""",
                (key, value),
            )
        conn.commit()
        return jsonify({"success": True})
    finally:
        conn.close()


@api.route("/api/lastfm/auth-url", methods=["GET"])
def lastfm_auth_url():
    """Get Last.fm auth URL for user to approve"""
    from app.lastfm import LastFM

    lastfm = LastFM()
    url = lastfm.get_auth_url()
    if url:
        return jsonify({"url": url})
    return jsonify({"error": "API key not configured"}), 400


@api.route("/api/lastfm/callback", methods=["POST"])
def lastfm_callback():
    """Complete Last.fm auth — exchanges stored pending token for session key"""
    from app.lastfm import LastFM

    lastfm = LastFM()
    result = lastfm.complete_auth()
    if result.get("success"):
        return jsonify(result)
    return jsonify(result), 400


@api.route("/api/lastfm/toggle", methods=["POST"])
def lastfm_toggle():
    """Enable/disable scrobbling"""
    data = request.get_json()
    enabled = data.get("enabled", True)

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute(
            """INSERT INTO lastfm_config (key, value) VALUES ('enabled', %s)
               ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value""",
            ("true" if enabled else "false",),
        )
        conn.commit()
        return jsonify({"success": True, "enabled": enabled})
    finally:
        conn.close()


@api.route("/api/lastfm/disconnect", methods=["POST"])
def lastfm_disconnect():
    """Remove Last.fm session (disconnect account)"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute(
            "DELETE FROM lastfm_config WHERE key IN ('session_key', 'username', 'pending_token')"
        )
        conn.commit()
        return jsonify({"success": True})
    finally:
        conn.close()


# ========================
# Artwork Search Endpoints
# ========================


@api.route("/api/artwork/search/<int:album_id>", methods=["GET"])
def search_artwork(album_id):
    """Search for artwork options for an album"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    # Get album info including MBID
    cursor.execute(
        """
        SELECT albums.title, albums.mbid, artists.name as artist_name
        FROM albums
        JOIN artists ON albums.artist_id = artists.id
        WHERE albums.id = %s
        """,
        (album_id,),
    )
    album = cursor.fetchone()

    # A YouTube source URL from any of this album's songs lets us offer the
    # video thumbnail as an artwork candidate — the only option the picker has
    # for rips MusicBrainz/Cover Art Archive don't know about.
    yt_source_url = None
    if album:
        cursor.execute(
            """SELECT source_url FROM songs
               WHERE album_id = %s AND source_url IS NOT NULL
                 AND (source_url LIKE %s OR source_url LIKE %s)
               LIMIT 1""",
            (album_id, "%youtube.com%", "%youtu.be%"),
        )
        yt_row = cursor.fetchone()
        yt_source_url = yt_row["source_url"] if yt_row else None
    conn.close()

    if not album:
        return jsonify({"error": "Album not found"}), 404

    def _do_artwork_search():
        """Run MusicBrainz search in a real thread so it doesn't block the event loop."""
        searcher = ArtworkSearch()
        results = []

        # If we have a stored MBID, try that first for an exact match
        if album.get("mbid"):
            mbid_result = searcher.get_artwork_by_mbid(album["mbid"])
            if mbid_result and mbid_result.get("is_single"):
                mbid_result["confidence"] = 100
                mbid_result["match_source"] = "mbid"
                results.append(mbid_result)
            elif mbid_result and mbid_result.get("releases"):
                for r in mbid_result["releases"]:
                    r["match_source"] = "mbid"
                    results.append(r)

        # Also search by name for additional options
        name_results = searcher.search_musicbrainz(album["artist_name"], album["title"], limit=5)
        existing_ids = {r.get("release_id") for r in results}
        for r in name_results:
            if r.get("release_id") not in existing_ids:
                results.append(r)

        # Sort all results: digital first, US first, then confidence
        def _sort_key(result):
            fmt = (result.get("format") or "").lower()
            country_date = result.get("country_date") or ""
            is_digital = 1 if "digital" in fmt else 0
            is_us = 1 if "US" in country_date else 0
            is_xe = 1 if "XE" in country_date else 0
            return (is_digital, is_us, is_xe, result.get("confidence", 0))

        results.sort(key=_sort_key, reverse=True)

        # Extra candidates from non-MusicBrainz sources, appended after the
        # sorted MB results. Each uses a "url:<image url>" sentinel as its
        # release_id so /api/artwork/select downloads it directly.
        if yt_source_url:
            m = re.search(
                r"(?:v=|youtu\.be/|/watch\?v=)([A-Za-z0-9_-]{11})", yt_source_url
            )
            if m:
                thumb = searcher.best_youtube_thumbnail(m.group(1))
                if thumb:
                    results.append({
                        "release_id": "url:" + thumb,
                        "title": "YouTube thumbnail",
                        "artist": album["artist_name"],
                        "year": None,
                        "format": "YouTube",
                        "country_date": None,
                        "confidence": 60,
                        "quality_score": 0,
                        "artwork_url": thumb,
                    })

        spotify_cover = searcher.search_spotify_cover(
            album["artist_name"], album["title"]
        )
        if spotify_cover:
            results.append({
                "release_id": "url:" + spotify_cover,
                "title": "Spotify cover",
                "artist": album["artist_name"],
                "year": None,
                "format": "Spotify",
                "country_date": None,
                "confidence": 70,
                "quality_score": 0,
                "artwork_url": spotify_cover,
            })

        return results

    # Run the blocking MusicBrainz search in a real OS thread
    results = eventlet.tpool.execute(_do_artwork_search)

    return jsonify(
        {
            "album_id": album_id,
            "album_title": album["title"],
            "artist_name": album["artist_name"],
            "options": results,
        }
    )


@api.route("/api/artwork/select", methods=["POST"])
def select_artwork():
    """Save selected artwork for an album"""
    data = request.get_json()
    album_id = data.get("album_id")
    release_id = data.get("release_id")

    if not album_id or not release_id:
        return jsonify({"error": "album_id and release_id are required"}), 400

    # Download and save the artwork (blocking HTTP — run in real thread).
    # A "url:<image url>" release_id is a direct-image candidate (YouTube
    # thumbnail / Spotify cover), not a Cover Art Archive release id.
    searcher = ArtworkSearch()
    if isinstance(release_id, str) and release_id.startswith("url:"):
        artwork_filename = eventlet.tpool.execute(
            searcher.download_and_save_from_url, release_id[4:], album_id
        )
    else:
        artwork_filename = eventlet.tpool.execute(
            searcher.download_and_save_artwork, release_id, album_id
        )

    if not artwork_filename:
        return jsonify({"error": "Failed to download artwork"}), 500

    # Update database with artwork path and mark as verified
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        cursor.execute(
            "UPDATE albums SET artwork_path = %s, artwork_verified = 1 WHERE id = %s",
            (artwork_filename, album_id),
        )
        conn.commit()
        conn.close()
        _cast_refresh(album_id=album_id)

        return jsonify(
            {
                "success": True,
                "message": "Artwork saved and verified",
                "artwork_path": artwork_filename,
            }
        )

    except Exception as e:
        conn.close()
        return _error_response(e)


@api.route("/api/artwork/upgrade-all", methods=["POST"])
def upgrade_all_artwork():
    """Re-download all album artwork at full resolution using stored MBIDs"""
    from app.artwork_search import ArtworkSearch

    db = get_db()
    operation_id = f"artwork_upgrade_{int(time.time())}"

    def _download_one(url, headers):
        """Download a single image in a real thread (blocking HTTP)."""
        import requests as dl_requests
        resp = dl_requests.get(url, headers=headers, timeout=15)
        return resp.status_code, resp.content if resp.status_code == 200 else None

    def _process_image(image_data, artwork_path):
        """Process and save image in a real thread (CPU-bound PIL)."""
        from PIL import Image
        from io import BytesIO

        new_img = Image.open(BytesIO(image_data))
        new_pixels = new_img.size[0] * new_img.size[1]
        new_size = (new_img.size[0], new_img.size[1])

        # Check if existing image is higher resolution
        if os.path.exists(artwork_path):
            try:
                existing_img = Image.open(artwork_path)
                existing_pixels = existing_img.size[0] * existing_img.size[1]
                existing_size = (existing_img.size[0], existing_img.size[1])
                existing_img.close()
                if existing_pixels >= new_pixels:
                    return "skipped", existing_size, new_size
            except Exception:
                pass

        if new_img.mode in ("RGBA", "LA", "P"):
            new_img = new_img.convert("RGB")
        new_img.save(artwork_path, "JPEG", quality=95)
        return "saved", new_size, new_size

    def _run_upgrade():
        conn = db.get_connection()
        cursor = db.get_cursor(conn)

        try:
            cursor.execute("""
                SELECT id, title, mbid, artwork_path
                FROM albums
                WHERE mbid IS NOT NULL
                AND artwork_path IS NOT NULL AND artwork_path != ''
                ORDER BY id
            """)
            albums = cursor.fetchall()
            total = len(albums)
            upgraded = 0
            failed = 0
            skipped = 0

            print(f"Starting artwork upgrade for {total} albums with MBIDs...")
            progress_tracker.start_operation(operation_id, total, "artwork_upgrade")

            safe_emit("artwork_upgrade_progress", {
                "operation_id": operation_id,
                "current": 0, "total": total,
                "message": f"Found {total} albums to upgrade",
                "status": "running", "upgraded": 0, "failed": 0, "skipped": 0,
            })

            searcher = ArtworkSearch()

            for idx, album in enumerate(albums, 1):
                if progress_tracker.is_cancelled(operation_id):
                    print("Artwork upgrade cancelled by user")
                    safe_emit("artwork_upgrade_progress", {
                        "operation_id": operation_id,
                        "current": idx, "total": total,
                        "message": f"Cancelled. Upgraded {upgraded}, skipped {skipped}, failed {failed}",
                        "status": "cancelled",
                        "upgraded": upgraded, "failed": failed, "skipped": skipped,
                    })
                    return

                album_id = album["id"]
                album_title = album["title"]
                mbid = album["mbid"]

                urls_to_try = [
                    f"https://coverartarchive.org/release-group/{mbid}/front",
                    f"https://coverartarchive.org/release/{mbid}/front",
                ]

                success = False
                for url in urls_to_try:
                    try:
                        status_code, image_data = eventlet.tpool.execute(
                            _download_one, url, searcher.headers
                        )
                        if status_code == 200 and image_data:
                            artwork_filename = f"album_{album_id}.jpg"
                            artwork_path = os.path.join(searcher.artwork_dir, artwork_filename)

                            result, existing_sz, new_sz = eventlet.tpool.execute(
                                _process_image, image_data, artwork_path
                            )

                            if result == "skipped":
                                skipped += 1
                                success = True
                                print(f"  [{idx}/{total}] Skipped {album_title} (existing {existing_sz[0]}x{existing_sz[1]} >= new {new_sz[0]}x{new_sz[1]})")
                                break
                            else:
                                upgraded += 1
                                success = True
                                print(f"  [{idx}/{total}] Upgraded {album_title} ({new_sz[0]}x{new_sz[1]})")
                                break
                        elif status_code == 404:
                            continue
                    except Exception as e:
                        print(f"  [{idx}/{total}] Warning {album_title}: {e}")
                        continue

                if not success:
                    failed += 1
                    print(f"  [{idx}/{total}] Failed {album_title}: no artwork found")

                # Rate limit
                eventlet.sleep(1.5)

                # Emit progress on every album
                safe_emit("artwork_upgrade_progress", {
                    "operation_id": operation_id,
                    "current": idx, "total": total,
                    "message": f"{album_title}",
                    "status": "running",
                    "upgraded": upgraded, "failed": failed, "skipped": skipped,
                })
                progress_tracker.update_progress(operation_id, idx, f"Processing: {album_title}")

            progress_tracker.complete_operation(
                operation_id,
                f"Artwork upgrade complete! Upgraded {upgraded}, skipped {skipped}, failed {failed}",
            )
            safe_emit("artwork_upgrade_progress", {
                "operation_id": operation_id,
                "current": total, "total": total,
                "message": f"Complete! Upgraded {upgraded}, skipped {skipped}, failed {failed}",
                "status": "complete",
                "upgraded": upgraded, "failed": failed, "skipped": skipped,
            })

            print(f"Artwork upgrade complete! Upgraded: {upgraded}, Skipped: {skipped}, Failed: {failed}")

        except Exception as e:
            print(f"Artwork upgrade error: {e}")
            traceback.print_exc()
        finally:
            conn.close()

    eventlet.spawn_n(_run_upgrade)

    return jsonify({
        "message": "Artwork upgrade started",
        "operation_id": operation_id,
    })


@api.route("/api/artwork/mbid/<release_id>", methods=["GET"])
def get_artwork_by_mbid(release_id):
    """Get artwork info for a specific MusicBrainz release ID"""
    searcher = ArtworkSearch()
    result = eventlet.tpool.execute(searcher.get_artwork_by_mbid, release_id)

    if result:
        return jsonify(result)
    else:
        return jsonify({"error": "Release not found or no artwork available"}), 404


@api.route("/api/artwork/upload/<int:album_id>", methods=["POST"])
def upload_artwork(album_id):
    """Upload custom artwork for an album"""
    if "file" not in request.files:
        return jsonify({"error": "No file provided"}), 400

    file = request.files["file"]

    if file.filename == "":
        return jsonify({"error": "No file selected"}), 400

    # Read file data
    image_data = file.read()

    # Save the artwork
    searcher = ArtworkSearch()
    artwork_filename = searcher.save_uploaded_artwork(album_id, image_data)

    if not artwork_filename:
        return jsonify({"error": "Failed to save artwork"}), 500

    # Update database with artwork path and mark as verified
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        cursor.execute(
            "UPDATE albums SET artwork_path = %s, artwork_verified = 1 WHERE id = %s",
            (artwork_filename, album_id),
        )
        conn.commit()
        conn.close()
        _cast_refresh(album_id=album_id)

        return jsonify(
            {
                "success": True,
                "message": "Artwork uploaded and verified",
                "artwork_path": artwork_filename,
            }
        )
    except Exception as e:
        conn.close()
        return _error_response(e)


# ========================
# Metadata Editing Endpoints
# ========================


@api.route("/api/edit/artist/<int:artist_id>", methods=["PUT"])
def edit_artist(artist_id):
    """Edit artist name"""
    data = request.get_json()
    new_name = data.get("name")

    if not new_name:
        return jsonify({"error": "name is required"}), 400

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Check if new name already exists (and it's not the same artist)
        cursor.execute(
            "SELECT id FROM artists WHERE name = %s AND id != %s", (new_name, artist_id)
        )
        existing = cursor.fetchone()
        if existing:
            return jsonify({"error": "An artist with this name already exists"}), 400

        # Update artist name
        cursor.execute(
            "UPDATE artists SET name = %s WHERE id = %s", (new_name, artist_id)
        )
        conn.commit()

        return jsonify({"success": True, "message": "Artist name updated"})
    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


# =============================================================================
# PROWLARR / TRANSMISSION ROUTES
# =============================================================================


@api.route("/api/prowlarr/indexers", methods=["GET"])
def get_prowlarr_indexers():
    """Get list of configured Prowlarr indexers"""
    from app.prowlarr import ProwlarrClient

    client = ProwlarrClient()
    result = client.get_indexers()
    if result["success"]:
        return jsonify(result)
    return jsonify(result), 500


@api.route("/api/prowlarr/search", methods=["GET"])
def search_prowlarr():
    """Search Prowlarr indexers for releases.

    Query params:
        query: Search string (required)
        indexers: Comma-separated indexer IDs (overrides default)
        deep: "true" to include slow indexers (RuTracker, etc.)
        all: "true" to search ALL enabled indexers (no filtering)
    """
    from app.prowlarr import ProwlarrClient

    query = request.args.get("query", "").strip()
    if not query:
        return jsonify({"error": "Query parameter required"}), 400

    client = ProwlarrClient()

    # Determine which indexers to search. Fast/deep tiers are resolved by
    # indexer NAME at request time (see ProwlarrClient) so re-adding an indexer
    # in Prowlarr can't silently break the tiers by renumbering IDs.
    indexer_ids = request.args.get("indexers")
    explicit_indexers = bool(indexer_ids)
    is_deep_request = (
        request.args.get("all", "").lower() == "true"
        or request.args.get("deep_only", "").lower() == "true"
        or request.args.get("deep", "").lower() == "true"
    )
    try:
        if explicit_indexers:
            # Explicit indexer list overrides everything
            indexer_ids = [int(i) for i in indexer_ids.split(",")]
        elif request.args.get("all", "").lower() == "true":
            # Search all enabled indexers (no filter)
            indexer_ids = None
        elif request.args.get("deep_only", "").lower() == "true":
            # Only slow/deep indexers (RuTracker, etc.) — for appending to fast results
            indexer_ids = client.deep_indexer_ids()
        elif request.args.get("deep", "").lower() == "true":
            # Fast + deep indexers combined
            indexer_ids = client.fast_indexer_ids() + client.deep_indexer_ids()
        else:
            # Default: fast indexers only (~1-2 seconds vs 60+ with all)
            indexer_ids = client.fast_indexer_ids()
    except Exception as e:
        return jsonify({"success": False,
                        "error": f"Could not resolve Prowlarr indexers: {e}"}), 502

    # Hide Knaben results sourced from RuTracker in the default (fast)
    # mode — those download attempts always fail while RuTracker's
    # origin is down. The deep modes pass this through so the user
    # can still opt in via "Also search RuTracker."
    filter_rutracker = not (is_deep_request or explicit_indexers)
    # Prowlarr search makes blocking HTTP requests — run in real thread
    result = eventlet.tpool.execute(
        client.search, query, indexer_ids, None, filter_rutracker
    )

    if result["success"]:
        return jsonify(result)
    return jsonify(result), 500


@api.route("/api/transmission/add", methods=["POST"])
def add_to_transmission():
    """Add a torrent to Transmission"""
    from app.prowlarr import TransmissionClient

    data = request.get_json()
    if not data or not data.get("url"):
        return jsonify({"error": "URL required"}), 400

    try:
        client = TransmissionClient()
        result = client.add_torrent(
            url=data["url"], download_dir=data.get("download_dir")
        )

        if result["success"]:
            return jsonify(result)
        # Log the failure detail so it's visible in combined.log —
        # previously these returned success=False silently and the
        # frontend showed a generic error with no way to diagnose.
        print(
            f"❌ Transmission add failed (url={data['url']!r}): "
            f"{result.get('error', 'no error message')}"
        )
        return jsonify(result), 500
    except Exception as e:
        print(f"❌ Transmission add error: {e}")
        traceback.print_exc()
        return _error_response(e)


@api.route("/api/transmission/probe", methods=["POST"])
def probe_transmission_swarm():
    """Scrape a torrent's trackers directly and report real seeder counts.

    Indexer seeder counts are stale scrapes; this asks the trackers now.
    The app calls it before adding so a dead torrent gets an "add anyway?"
    instead of sitting in the list forever looking alive.
    """
    from app.prowlarr import TransmissionClient

    data = request.get_json()
    if not data or not data.get("url"):
        return jsonify({"error": "URL required"}), 400

    try:
        result = TransmissionClient().probe_swarm(data["url"])
        if result["success"]:
            return jsonify(result)
        return jsonify(result), 502
    except Exception as e:
        print(f"❌ Swarm probe error: {e}")
        traceback.print_exc()
        return _error_response(e)


@api.route("/api/transmission/torrents", methods=["GET"])
def get_transmission_torrents():
    """Get list of torrents from Transmission"""
    from app.prowlarr import TransmissionClient

    client = TransmissionClient()
    result = client.get_torrents()

    if result["success"]:
        return jsonify(result)
    return jsonify(result), 500


@api.route("/api/transmission/stop/<int:torrent_id>", methods=["POST"])
def stop_transmission_torrent(torrent_id):
    """Stop a specific torrent"""
    from app.prowlarr import TransmissionClient

    client = TransmissionClient()
    result = client.stop_torrent(torrent_id)

    if result["success"]:
        return jsonify(result)
    return jsonify(result), 500


@api.route("/api/transmission/remove/<int:torrent_id>", methods=["DELETE"])
def remove_transmission_torrent(torrent_id):
    """Remove a torrent"""
    from app.prowlarr import TransmissionClient

    delete_data = request.args.get("delete_data", "false").lower() == "true"

    client = TransmissionClient()
    result = client.remove_torrent(torrent_id, delete_data=delete_data)

    if result["success"]:
        return jsonify(result)
    return jsonify(result), 500


@api.route("/api/transmission/stop-old-seeders", methods=["POST"])
@auth.require_admin
def stop_old_seeders():
    """Stop torrents that have been seeding too long"""
    from app.prowlarr import TransmissionClient

    data = request.get_json() or {}
    max_minutes = data.get("max_seed_minutes", 30)

    client = TransmissionClient()
    result = client.stop_old_seeders(max_seed_minutes=max_minutes)

    if result["success"]:
        return jsonify(result)
    return jsonify(result), 500


@api.route("/api/transmission/clear-completed", methods=["POST"])
@auth.require_admin
def clear_completed_torrents():
    """Remove all completed and stopped torrents from Transmission"""
    from app.prowlarr import TransmissionClient

    data = request.get_json() or {}
    delete_data = data.get("delete_data", False)

    client = TransmissionClient()
    result = client.clear_completed(delete_data=delete_data)
    return jsonify(result)


# =============================================================================
# YOUTUBE DOWNLOAD ROUTES
# =============================================================================


@api.route("/api/youtube/yt-dlp-version", methods=["GET"])
def get_ytdlp_version():
    """Check installed yt-dlp version and whether an update is available"""
    import subprocess as sp

    def _check_version():
        # Get installed version
        try:
            result = sp.run(
                ["yt-dlp", "--version"], capture_output=True, text=True, timeout=10
            )
            installed = result.stdout.strip() if result.returncode == 0 else None
        except Exception:
            installed = None

        # Check for available update
        latest = None
        update_available = False
        try:
            import requests as ver_requests

            resp = ver_requests.get(
                "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest",
                timeout=10,
            )
            if resp.status_code == 200:
                tag = resp.json().get("tag_name", "")
                latest = tag
                if installed and latest and installed != latest:
                    update_available = True
        except Exception:
            pass

        return {
            "installed": installed,
            "latest": latest,
            "update_available": update_available,
        }

    try:
        result = eventlet.tpool.execute(_check_version)
        return jsonify(result)
    except Exception as e:
        return _error_response(e)


@api.route("/api/youtube/yt-dlp-update", methods=["POST"])
def update_ytdlp():
    """Update yt-dlp to the latest version"""
    import subprocess as sp
    import sys

    def _do_update():
        # yt-dlp on this box is a pip console-script (C:\ytdl\yt-dlp.exe)
        # pinned to the backend venv's interpreter — NOT a standalone build,
        # so `yt-dlp -U` refuses. And a bare `pip` resolves to global Python,
        # a different env than the one the app actually runs yt-dlp from.
        # sys.executable is the venv python (Flask runs under it), which owns
        # the same yt-dlp the version check and downloader invoke.
        result = sp.run(
            [sys.executable, "-m", "pip", "install", "--upgrade", "yt-dlp"],
            capture_output=True,
            text=True,
            timeout=120,
        )
        return {
            "success": result.returncode == 0,
            "output": result.stdout,
            "error": result.stderr if result.returncode != 0 else None,
        }

    try:
        result = eventlet.tpool.execute(_do_update)
        if result["success"]:
            # Get new version after update
            try:
                ver_result = sp.run(
                    ["yt-dlp", "--version"], capture_output=True, text=True, timeout=10
                )
                result["new_version"] = ver_result.stdout.strip()
            except Exception:
                pass
        return jsonify(result)
    except Exception as e:
        return _error_response(e)


@api.route("/api/youtube/validate", methods=["POST"])
def validate_youtube_url():
    """Validate a YouTube URL and identify if it's a video or playlist"""
    from app.youtube_download import YouTubeDownloader

    data = request.get_json()
    url = data.get("url", "").strip()

    if not url:
        return jsonify({"error": "URL required"}), 400

    downloader = YouTubeDownloader()
    result = downloader.validate_url(url)

    return jsonify(result)


@api.route("/api/youtube/info", methods=["POST"])
def get_youtube_info():
    """Get metadata for a YouTube video without downloading"""
    from app.youtube_download import YouTubeDownloader

    data = request.get_json()
    url = data.get("url", "").strip()

    if not url:
        return jsonify({"error": "URL required"}), 400

    downloader = YouTubeDownloader()
    result = eventlet.tpool.execute(downloader.get_video_info, url)

    if result["success"]:
        return jsonify(result)
    return jsonify(result), 500


@api.route("/api/youtube/playlist-info", methods=["POST"])
def get_youtube_playlist_info():
    """Get metadata for all videos in a YouTube playlist"""
    from app.youtube_download import YouTubeDownloader

    data = request.get_json()
    url = data.get("url", "").strip()

    if not url:
        return jsonify({"error": "URL required"}), 400

    downloader = YouTubeDownloader()
    result = eventlet.tpool.execute(downloader.get_playlist_info, url)

    if result["success"]:
        return jsonify(result)
    return jsonify(result), 500


@api.route("/api/youtube/search-albums", methods=["POST"])
def youtube_search_albums():
    """Playlist-only YouTube search so the album hunt happens in the app."""
    from app.youtube_curate import search_albums

    data = request.get_json() or {}
    query = (data.get("query") or "").strip()
    if not query:
        return jsonify({"error": "query required"}), 400
    result = search_albums(query)
    return jsonify(result), (200 if result.get("success") else 502)


@api.route("/api/youtube/curate-playlist", methods=["POST"])
def youtube_curate_playlist():
    """Expand a playlist, grade every video against the MusicBrainz track
    lengths, and auto-find clean replacements for the suspects."""
    from app.youtube_curate import curate_playlist, DEFAULT_TOLERANCE

    data = request.get_json() or {}
    url = (data.get("url") or "").strip()
    if not url:
        return jsonify({"error": "URL required"}), 400
    try:
        tolerance = int(data.get("tolerance") or DEFAULT_TOLERANCE)
    except (TypeError, ValueError):
        tolerance = DEFAULT_TOLERANCE
    result = curate_playlist(
        url,
        artist=(data.get("artist") or "").strip() or None,
        album=(data.get("album") or "").strip() or None,
        tolerance=tolerance,
        auto_replace=data.get("auto_replace", True),
    )
    return jsonify(result), (200 if result.get("success") else 502)


@api.route("/api/youtube/find-clean", methods=["POST"])
def youtube_find_clean():
    """Replacement candidates for one track (the 'see alternatives' sheet)."""
    from app.youtube_curate import find_clean

    data = request.get_json() or {}
    artist = (data.get("artist") or "").strip()
    title = (data.get("title") or "").strip()
    if not title:
        return jsonify({"error": "title required"}), 400
    result = find_clean(
        artist, title,
        target_duration=data.get("target_duration"),
        exclude_id=data.get("exclude_id"),
    )
    return jsonify(result), (200 if result.get("success") else 502)


@api.route("/api/youtube/preview-chapters", methods=["POST"])
def preview_youtube_chapters():
    """
    Preview a YouTube video as a chapter-split album. Returns the video
    header (title/channel/duration/thumbnail) plus a chapter list, sourced
    either from real YouTube chapter markers (native) or parsed out of the
    description's timestamp tracklist (parsed). If neither finds anything,
    chapter_source='none' and the caller can fall back to single-track import.
    """
    from app.youtube_download import YouTubeDownloader
    from app.youtube_chapters import parse_chapters_from_description

    data = request.get_json()
    url = data.get("url", "").strip()

    if not url:
        return jsonify({"error": "URL required"}), 400

    downloader = YouTubeDownloader()
    result = eventlet.tpool.execute(downloader.get_video_info, url)

    if not result.get("success"):
        return jsonify(result), 500

    info = result["info"]

    # Prefer real chapter markers when YouTube already has them parsed.
    chapters = info.get("chapters") or []
    chapter_source = "native" if chapters else "none"

    # Fall back to the description-timestamp parser for OST uploads YouTube
    # missed (most of them — its parser is strict).
    if not chapters:
        parsed = parse_chapters_from_description(
            info.get("description", ""),
            info.get("duration"),
        )
        if parsed:
            chapters = parsed
            chapter_source = "parsed"

    return jsonify({
        "success": True,
        "warnings": result.get("warnings", []),
        "header": {
            "id": info.get("id"),
            "title": info.get("title"),
            "channel": info.get("channel"),
            "uploader": info.get("uploader"),
            "duration": info.get("duration"),
            "thumbnail": info.get("thumbnail"),
            "upload_date": info.get("upload_date"),
        },
        "chapter_source": chapter_source,
        "chapters": chapters,
    })


@api.route("/api/youtube/download", methods=["POST"])
def download_youtube_video():
    """Download audio from a YouTube video"""
    from app.youtube_download import YouTubeDownloader

    data = request.get_json()
    url = data.get("url", "").strip()

    if not url:
        return jsonify({"error": "URL required"}), 400

    operation_id = data.get("operation_id") or str(uuid.uuid4())
    downloader = YouTubeDownloader()
    result = downloader.download_video(url, operation_id=operation_id)

    if result["success"]:
        return jsonify(result)
    return jsonify(result), 500


@api.route("/api/youtube/download-playlist", methods=["POST"])
def download_youtube_playlist():
    """Download all audio from a YouTube playlist"""
    from app.youtube_download import YouTubeDownloader

    data = request.get_json()
    url = data.get("url", "").strip()

    if not url:
        return jsonify({"error": "URL required"}), 400

    operation_id = data.get("operation_id") or str(uuid.uuid4())
    downloader = YouTubeDownloader()
    result = downloader.download_playlist(url, operation_id=operation_id)

    if result["success"]:
        return jsonify(result)
    return jsonify(result), 500


@api.route("/api/youtube/cancel", methods=["POST"])
def cancel_youtube_download():
    """Cancel an active YouTube download"""
    from app.youtube_download import cancel_download

    data = request.get_json()
    operation_id = data.get("operation_id")

    if not operation_id:
        return jsonify({"error": "operation_id required"}), 400

    cancelled = cancel_download(operation_id)

    if cancelled:
        return jsonify({"success": True, "message": "Download cancelled"})
    return (
        jsonify({"success": False, "error": "No active download found with that ID"}),
        404,
    )


@api.route("/api/youtube/active-jobs", methods=["GET"])
def list_active_youtube_jobs():
    """List currently-tracked YouTube download jobs.

    Returns running jobs plus recently-finished ones (within the
    retire grace window — ~30s by default). Used by the YouTube
    screen on open so the user can rejoin a download/import they
    navigated away from instead of the screen looking idle while a
    real subprocess is still chewing through their playlist.
    """
    from app.youtube_download import list_active_jobs
    jobs = list_active_jobs()
    return jsonify({"jobs": jobs, "count": len(jobs)})


@api.route("/api/youtube/tag", methods=["POST"])
def tag_youtube_download():
    """Apply metadata tags to a downloaded file"""
    from app.youtube_download import YouTubeDownloader

    data = request.get_json()
    filename = data.get("filename")
    tags = data.get("tags", {})

    if not filename:
        return jsonify({"error": "filename required"}), 400

    downloader = YouTubeDownloader()
    file_path = os.path.join(downloader.staging_dir, filename)

    if not os.path.exists(file_path):
        return jsonify({"error": "File not found in staging"}), 404

    result = downloader.apply_tags(file_path, tags)

    if result["success"]:
        return jsonify({"success": True, "message": "Tags applied successfully"})
    return jsonify(result), 500


@api.route("/api/youtube/import", methods=["POST"])
def import_youtube_download():
    """Import a tagged file from staging into the music library"""
    import shutil
    from app.youtube_download import YouTubeDownloader
    from app.scanner import MusicScanner

    data = request.get_json()
    filename = data.get("filename")
    artist_name = data.get("artist_name", "").strip()
    album_name = data.get("album_name", "").strip()
    target_album_id = data.get("album_id")  # Optional: import to existing album

    if not filename:
        return jsonify({"error": "filename is required"}), 400

    # If no album_id, require artist_name and album_name (original behavior)
    if not target_album_id and (not artist_name or not album_name):
        return jsonify({"error": "filename, artist_name, and album_name required (or provide album_id)"}), 400

    downloader = YouTubeDownloader()
    file_path = os.path.join(downloader.staging_dir, filename)

    if not os.path.exists(file_path):
        return jsonify({"error": "File not found in staging"}), 404

    # Determine destination based on whether we're importing to an existing album
    if target_album_id:
        # Import to existing album — find the album's actual directory from DB
        db = get_db()
        conn = db.get_connection()
        try:
            cursor = db.get_cursor(conn)
            cursor.execute(
                "SELECT file_path FROM songs WHERE album_id = %s LIMIT 1",
                (target_album_id,),
            )
            song_row = cursor.fetchone()
            if not song_row:
                return jsonify({"error": f"No songs found for album {target_album_id}"}), 404

            dest_dir = os.path.dirname(song_row["file_path"])
            if not os.path.isdir(dest_dir):
                return jsonify({"error": f"Album directory not found: {dest_dir}"}), 404

            # Move file to the album's directory
            dest_filename = os.path.basename(file_path)
            dest_path = os.path.join(dest_dir, dest_filename)

            # Handle filename collisions
            if os.path.exists(dest_path):
                base, ext = os.path.splitext(dest_filename)
                counter = 1
                while os.path.exists(dest_path):
                    dest_path = os.path.join(dest_dir, f"{base}_{counter}{ext}")
                    counter += 1

            shutil.move(file_path, dest_path)
            result = {
                "success": True,
                "file_path": dest_path,
                "artist_folder": os.path.basename(os.path.dirname(dest_dir)),
                "album_folder": os.path.basename(dest_dir),
            }
            print(f"📂 Imported to existing album dir: {dest_dir}")
        finally:
            conn.close()
    else:
        # Original behavior — create artist/album folder structure
        result = downloader.import_to_library(file_path, artist_name, album_name)

    if not result["success"]:
        return jsonify(result), 500

    # Scan the imported file into the database
    try:
        db = get_db()
        scanner = MusicScanner(db)
        scanner.process_audio_file(result["file_path"])

        # When importing to an Existing Album, force the song's album_id to
        # the user-chosen target. Scanner assigns album_id from the file's
        # tags, which creates a phantom duplicate album when the song's
        # tags don't match the target album's identity (e.g., a compilation
        # track tagged with the original-release artist instead of the
        # compilation's primary artist — see the 2026-05-22 Sammy Hagar /
        # Montrose / Essential Red Collection incident).
        #
        # We preserve the song's tagged artist_id (so per-track artists show
        # correctly in compilations and the song appears under the right
        # artist's discography) but force album_id to the target. If the
        # phantom album+artist were created fresh by this scan and end up
        # empty after the reassignment, clean them up so the DB doesn't
        # accumulate orphan records every time someone imports a compilation
        # track to an existing album.
        if target_album_id:
            phantom_conn = db.get_connection()
            try:
                pc = db.get_cursor(phantom_conn)
                pc.execute(
                    "SELECT id, album_id, artist_id FROM songs WHERE file_path = %s",
                    (result["file_path"],),
                )
                song_row = pc.fetchone()
                if song_row and song_row["album_id"] != target_album_id:
                    phantom_album_id = song_row["album_id"]
                    phantom_artist_id = song_row["artist_id"]

                    # Reassign the song to the target album
                    pc.execute(
                        "UPDATE songs SET album_id = %s WHERE id = %s",
                        (target_album_id, song_row["id"]),
                    )
                    print(
                        f"📂 Forced song {song_row['id']} into target album "
                        f"{target_album_id} (scanner had assigned "
                        f"{phantom_album_id} based on file tags)"
                    )

                    # If the phantom album now has no songs, it was just
                    # created by this scan and is safe to remove. Clear any
                    # album-level favorites first to keep FK constraints
                    # happy.
                    pc.execute(
                        "SELECT COUNT(*) AS c FROM songs WHERE album_id = %s",
                        (phantom_album_id,),
                    )
                    if pc.fetchone()["c"] == 0:
                        pc.execute(
                            "DELETE FROM favorites WHERE item_type = 'album' AND item_id = %s",
                            (phantom_album_id,),
                        )
                        pc.execute(
                            "DELETE FROM albums WHERE id = %s",
                            (phantom_album_id,),
                        )
                        print(f"📂 Removed empty phantom album {phantom_album_id}")

                        # If the phantom artist now has no albums AND no
                        # songs anywhere, remove it too. Scanner only
                        # creates new artists when no existing match is
                        # found, so an empty one is safely an artifact of
                        # this import.
                        pc.execute(
                            "SELECT COUNT(*) AS c FROM albums WHERE artist_id = %s",
                            (phantom_artist_id,),
                        )
                        artist_albums = pc.fetchone()["c"]
                        pc.execute(
                            "SELECT COUNT(*) AS c FROM songs WHERE artist_id = %s",
                            (phantom_artist_id,),
                        )
                        artist_songs = pc.fetchone()["c"]
                        if artist_albums == 0 and artist_songs == 0:
                            pc.execute(
                                "DELETE FROM favorites WHERE item_type = 'artist' AND item_id = %s",
                                (phantom_artist_id,),
                            )
                            pc.execute(
                                "DELETE FROM artists WHERE id = %s",
                                (phantom_artist_id,),
                            )
                            print(
                                f"📂 Removed empty phantom artist {phantom_artist_id}"
                            )
                phantom_conn.commit()
            except Exception as phantom_err:
                phantom_conn.rollback()
                print(f"⚠️ Phantom-album reassignment failed: {phantom_err}")
            finally:
                phantom_conn.close()

        # Get the album ID for the imported file
        album_id = None
        conn = db.get_connection()
        try:
            cursor = db.get_cursor(conn)
            cursor.execute(
                """
                SELECT a.id FROM albums a
                JOIN songs s ON s.album_id = a.id
                WHERE s.file_path = %s
                """,
                (result["file_path"],),
            )
            row = cursor.fetchone()
            if row:
                album_id = row["id"]
        finally:
            conn.close()

        # Trigger transcoding for the imported song (desktop preferred, local fallback)
        try:
            song_id = None
            conn2 = db.get_connection()
            try:
                cursor2 = db.get_cursor(conn2)
                cursor2.execute("SELECT id, is_hdcd FROM songs WHERE file_path = %s", (result["file_path"],))
                song_row = cursor2.fetchone()
                if song_row:
                    song_id = song_row["id"]
            finally:
                conn2.close()

            if song_id:
                from app.transcode import check_transcode_service
                if check_transcode_service():
                    _trigger_desktop_transcode(song_id, result["file_path"])
                else:
                    # Local fallback: transcode in background
                    is_hdcd = song_row.get("is_hdcd") == 1 if song_row else False
                    eventlet.spawn_n(_transcode_to_cache, result["file_path"], song_id, "high", is_hdcd)
                    print(f"Queued local transcode for imported song {song_id}")
        except Exception as e:
            print(f"Could not trigger transcoding for imported song: {e}")

        # Trigger Essentia audio analysis for the imported song
        try:
            from app.audio_analysis import check_essentia_service, start_analysis_background
            if check_essentia_service():
                start_analysis_background(config.DATABASE_URL)
                print(f"Triggered Essentia analysis for imported song")
        except Exception as e:
            print(f"Could not trigger analysis for imported song: {e}")

        return jsonify(
            {
                "success": True,
                "message": f"Imported to {result['artist_folder']}/{result['album_folder']}",
                "file_path": result["file_path"],
                "songs_added": scanner.songs_added,
                "albums_added": scanner.albums_added,
                "artists_added": scanner.artists_added,
                "album_id": album_id,
            }
        )
    except Exception as e:
        return _error_response(e)


@api.route("/api/youtube/import-as-album", methods=["POST"])
def import_youtube_as_album():
    """
    Download a YouTube video and split it into tracks by chapter, importing
    as one album.

    Request body:
      {
        "url": "https://youtu.be/<id>",
        "chapters": [
          {"order_index": 0, "start_seconds": 0, "end_seconds": 333,
           "title": "Track 1", "skip": false},
          ...
        ],
        "album": {"title": "...", "artist": "...", "year": 1996},
        "operation_id": "1234567890"
      }

    Response: {success, album_id, artist_id, songs_added, song_ids[]} on
    success; {success: false, error} on failure.
    """
    from app.youtube_download import YouTubeDownloader

    data = request.get_json() or {}
    url = (data.get("url") or "").strip()
    chapters = data.get("chapters") or []
    album_meta = data.get("album") or {}
    operation_id = data.get("operation_id")
    # Optional: pin imported songs to an existing album instead of creating
    # one. When set, album.title/artist are still required for the
    # chapter-tagging step but the DB rows + folder location come from the
    # existing album.
    target_album_id = data.get("album_id")

    if not url:
        return jsonify({"success": False, "error": "URL required"}), 400
    if not chapters:
        return jsonify({"success": False, "error": "At least one chapter required"}), 400
    if not (album_meta.get("title") and album_meta.get("artist")):
        return jsonify({"success": False, "error": "Album title and artist required"}), 400

    db = get_db()
    downloader = YouTubeDownloader()
    result = downloader.import_video_as_album(
        url=url,
        chapters=chapters,
        album_meta=album_meta,
        db=db,
        operation_id=operation_id,
        target_album_id=target_album_id,
    )

    status = 200 if result.get("success") else 500
    return jsonify(result), status


@api.route("/api/youtube/staging", methods=["GET"])
def get_youtube_staging():
    """Get list of files in YouTube staging folder"""
    from app.youtube_download import YouTubeDownloader

    downloader = YouTubeDownloader()
    result = downloader.get_staged_files()

    if result["success"]:
        return jsonify(result)
    return jsonify(result), 500


@api.route("/api/youtube/staging/<filename>", methods=["DELETE"])
def delete_youtube_staging_file(filename):
    """Delete a file from YouTube staging"""
    from app.youtube_download import YouTubeDownloader

    downloader = YouTubeDownloader()
    result = downloader.delete_staged_file(filename)

    if result["success"]:
        return jsonify(result)
    return jsonify(result), 500


@api.route("/api/youtube/staging/clear", methods=["DELETE"])
def clear_youtube_staging():
    """Clear all files from YouTube staging"""
    from app.youtube_download import YouTubeDownloader

    downloader = YouTubeDownloader()
    result = downloader.clear_staging()

    if result["success"]:
        return jsonify(result)
    return jsonify(result), 500


@api.route("/api/library/check-exists", methods=["POST"])
def check_library_exists():
    """Check if albums exist in the library based on search terms"""

    data = request.get_json()
    if not data or not data.get("queries"):
        return jsonify({"error": "queries array required"}), 400

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    results = {}

    try:
        for query in data["queries"]:
            clean = query.lower()
            clean = re.sub(r"\(.*?\)|\[.*?\]", "", clean)
            clean = re.sub(
                r"\b(flac|mp3|dsd|wav|alac|aac|ogg|ape|opus|m4a|320|v0|24.?bit|16.?bit|44\.1|48|96|192|128|lossless|vinyl|remaster|remastered|deluxe|edition|tracks|image|cue|hard\s*rock|rock|pop|metal|jazz|pbthal|web|webrip|bdrip|dts|lp|ep|cd\d*|disc\d*)\b",
                "",
                clean,
                flags=re.IGNORECASE,
            )
            clean = re.sub(r"\b(kbps|khz|hz)\b", "", clean, flags=re.IGNORECASE)
            clean = re.sub(r"\d{4}", "", clean)
            # Strip stray 1-3 digit numbers (bitrates, sample rates,
            # track counts) left over after the format-word pass.
            # Four-digit years already handled above.
            clean = re.sub(r"\b\d{1,3}\b", "", clean)
            clean = re.sub(r"[_\-\.\,]", " ", clean)
            clean = " ".join(clean.split())

            words = [w for w in clean.split() if len(w) > 2]
            if not words:
                results[query] = {"in_library": False}
                continue

            conditions = []
            params = []
            for word in words[:6]:
                conditions.append("LOWER(a.title || ' ' || ar.name) LIKE %s")
                params.append(f"%{word}%")

            where_clause = " AND ".join(conditions)

            cursor.execute(
                f"""
                SELECT a.id, a.title, ar.name as artist_name
                FROM albums a
                JOIN artists ar ON a.artist_id = ar.id
                WHERE {where_clause}
                LIMIT 1
            """,
                params,
            )

            match = cursor.fetchone()
            if match:
                # Get quality of existing album so the UI can show
                # what's already in the library. We can't compute a
                # "pending" quality here (we only have a search
                # string, not a real folder) — leave those keys out.
                cursor.execute(
                    """
                    SELECT file_format, file_path FROM songs
                    WHERE album_id = %s LIMIT 1
                """,
                    (match["id"],),
                )
                existing_song = cursor.fetchone()
                existing_quality = (
                    _get_quality_score(existing_song["file_format"])
                    if existing_song
                    else 0
                )
                existing_format = (
                    existing_song["file_format"] if existing_song else "Unknown"
                )

                # Spatial profile of the library copy, so the UI can tell
                # "you own this album" apart from "you own THIS MIX of
                # this album" (stereo rip vs a surround/Atmos release).
                cursor.execute(
                    """
                    SELECT COALESCE(MAX(audio_channels), 2) AS max_channels,
                           COALESCE(MAX(is_atmos), 0) AS has_atmos
                    FROM songs WHERE album_id = %s
                """,
                    (match["id"],),
                )
                spatial = cursor.fetchone()

                results[query] = {
                    "in_library": True,
                    "album_id": match["id"],
                    "album_title": match["title"],
                    "artist_name": match["artist_name"],
                    "existing_format": existing_format,
                    "existing_quality": existing_quality,
                    "library_max_channels": spatial["max_channels"],
                    "library_is_atmos": bool(spatial["has_atmos"]),
                }
            else:
                results[query] = {"in_library": False}

        return jsonify({"success": True, "results": results})

    except Exception as e:
        return _error_response(e)
    finally:
        conn.close()


# =============================================================================
# IMPORT QUEUE ROUTES
# =============================================================================


def analyze_cue_file(cue_path, folder_path=None):
    """Analyze a single CUE file and return its properties"""

    if folder_path is None:
        folder_path = os.path.dirname(cue_path)

    result = {
        "cue_file": cue_path,
        "cue_name": os.path.basename(cue_path),
        "audio_file_ref": None,  # What the CUE references
        "audio_file_exists": False,  # Whether that file exists
        "audio_file_path": None,  # Full path if it exists
        "track_count": 0,
        "has_isrc": False,
        "album_title": None,
        "album_performer": None,
    }

    try:
        content = None
        for encoding in ["utf-8", "latin-1", "cp1252", "shift-jis"]:
            try:
                with open(cue_path, "r", encoding=encoding) as f:
                    content = f.read()
                break
            except UnicodeDecodeError:
                continue

        if content is None:
            return result

        # Extract FILE reference
        file_match = re.search(
            r'^FILE\s+"([^"]+)"', content, re.MULTILINE | re.IGNORECASE
        )
        if file_match:
            result["audio_file_ref"] = file_match.group(1)
            # Check if the referenced file exists
            potential_path = os.path.join(folder_path, file_match.group(1))
            if os.path.exists(potential_path):
                result["audio_file_exists"] = True
                result["audio_file_path"] = potential_path

        # Count tracks
        result["track_count"] = len(
            re.findall(r"^\s*TRACK\s+\d+", content, re.MULTILINE | re.IGNORECASE)
        )

        # Check for ISRC codes
        result["has_isrc"] = bool(
            re.search(r"^\s*ISRC\s+", content, re.MULTILINE | re.IGNORECASE)
        )

        # Extract album info
        title_match = re.search(
            r'^TITLE\s+"([^"]+)"', content, re.MULTILINE | re.IGNORECASE
        )
        if title_match:
            result["album_title"] = title_match.group(1)

        performer_match = re.search(
            r'^PERFORMER\s+"([^"]+)"', content, re.MULTILINE | re.IGNORECASE
        )
        if performer_match:
            result["album_performer"] = performer_match.group(1)

    except Exception:
        pass

    # THIRD: Handle multiple CUE files for a single disc (variants like with/without ISRC)
    # This happens when we have multiple CUE files but none have disc numbers
    if len(cue_files) > 1:
        cue_dirs = set(os.path.dirname(cue_path) for cue_path in cue_files)

        # Only if CUE files are in the same directory
        if len(cue_dirs) == 1:
            cue_variants = []
            for cue_path in cue_files:
                cue_info = analyze_cue_file(cue_path, folder_path)
                cue_variants.append(cue_info)

            # Sort: valid audio first, then by whether it has ISRC, then by name
            cue_variants.sort(
                key=lambda x: (
                    not x["audio_file_exists"],  # Valid audio first
                    not x["has_isrc"],  # ISRC second (if both valid)
                    x["cue_name"],  # Alphabetical as tiebreaker
                )
            )

            result["cue_variants"] = cue_variants
            # Auto-select the best one (first after sorting = valid audio preferred)
            valid_cues = [c for c in cue_variants if c["audio_file_exists"]]
            if valid_cues:
                result["selected_cue"] = valid_cues[0]["cue_file"]
            elif cue_variants:
                result["selected_cue"] = cue_variants[0]["cue_file"]

    # Also analyze single CUE file
    elif len(cue_files) == 1:
        cue_info = analyze_cue_file(cue_files[0], folder_path)
        result["cue_variants"] = [cue_info]
        result["selected_cue"] = cue_files[0]

    return result


def analyze_multi_disc_structure(folder_path, cue_files, audio_files):
    """Analyze folder structure to detect multi-disc albums"""

    result = {"is_multi_disc": False, "disc_type": "single", "discs": []}

    # Pattern to detect disc indicators in filenames/folders
    # Matches patterns like: (CD1), [Disc 2], -D3-, _Side A_, etc.
    disc_pattern = re.compile(
        r"[\(\[\s\-_](CD|Disc|Disk|D|Side)\s*(\d+|[AB])[\)\]\s\-_\.]", re.IGNORECASE
    )
    # Also match disc number at end of filename (before extension): "Album Disc2.cue"
    disc_pattern_end = re.compile(r"(CD|Disc|Disk|D|Side)\s*(\d+|[AB])$", re.IGNORECASE)

    # FIRST: Check for subfolders with disc names (CD1/, Disc 1/, etc.)
    # This takes priority because CUE files in subfolders shouldn't be treated as cue_pairs
    try:
        subdirs = [
            d
            for d in os.listdir(folder_path)
            if os.path.isdir(os.path.join(folder_path, d))
        ]
        disc_subdirs = []

        for subdir in subdirs:
            match = disc_pattern.search(subdir) or re.match(
                r"^(CD|Disc|Disk|D|Side)\s*(\d+|[AB])(?:\s|$|-|_)",
                subdir,
                re.IGNORECASE,
            )
            if match:
                subdir_path = os.path.join(folder_path, subdir)

                # Count audio files in subdir
                audio_count = 0
                has_cue = False
                cue_file_path = None
                for f in os.listdir(subdir_path):
                    ext = os.path.splitext(f)[1].lower()
                    if ext in [".flac", ".mp3", ".m4a", ".wav", ".ogg", ".ape", ".wv"]:
                        audio_count += 1
                    if ext == ".cue":
                        has_cue = True
                        cue_file_path = os.path.join(subdir_path, f)

                disc_id = match.group(2) if match.lastindex >= 2 else match.group(1)
                if disc_id.upper() == "A":
                    disc_num = 1
                    disc_name = "Side A"
                elif disc_id.upper() == "B":
                    disc_num = 2
                    disc_name = "Side B"
                else:
                    disc_num = int(disc_id) if disc_id.isdigit() else None
                    disc_name = subdir

                disc_subdirs.append(
                    {
                        "disc_number": disc_num,
                        "disc_name": disc_name,
                        "subdir": subdir,
                        "path": subdir_path,
                        "track_count": audio_count,
                        "has_cue": has_cue,
                        "cue_file": cue_file_path,
                    }
                )

        if len(disc_subdirs) > 1:
            disc_subdirs.sort(key=lambda x: x["disc_number"] or 99)
            result["is_multi_disc"] = True
            result["disc_type"] = "subfolders"
            result["discs"] = disc_subdirs
            return result

    except Exception:
        pass

    # SECOND: Check for multiple CUE files in the SAME directory (like CD1.cue, CD2.cue)
    # Only applies if we didn't detect disc subfolders above
    if len(cue_files) > 1:
        # Check if all CUE files are in the same directory
        cue_dirs = set(os.path.dirname(cue_path) for cue_path in cue_files)

        # Only process as cue_pairs if CUE files are in the same directory
        if len(cue_dirs) == 1:
            cue_discs = []
            for cue_path in cue_files:
                cue_name = os.path.basename(cue_path)
                cue_name_no_ext = os.path.splitext(cue_name)[0]

                # Try multiple patterns to extract disc number
                match = disc_pattern.search(cue_name) or disc_pattern_end.search(
                    cue_name_no_ext
                )

                disc_info = {
                    "cue_file": cue_path,
                    "audio_file": None,
                    "disc_number": None,
                    "disc_name": None,
                    "track_count": 0,
                }

                if match:
                    disc_type_str = match.group(1).upper()
                    disc_id = match.group(2)

                    # Convert Side A/B to 1/2
                    if disc_id.upper() == "A":
                        disc_info["disc_number"] = 1
                        disc_info["disc_name"] = "Side A"
                    elif disc_id.upper() == "B":
                        disc_info["disc_number"] = 2
                        disc_info["disc_name"] = "Side B"
                    else:
                        disc_info["disc_number"] = int(disc_id)
                        disc_info["disc_name"] = f"{disc_type_str}{disc_id}"

                # Find matching audio file (same base name or referenced in CUE)
                cue_dir = os.path.dirname(cue_path)

                # Try to find audio file with same base name
                for ext in [".flac", ".ape", ".wav", ".wv", ".aiff", ".aif"]:
                    potential_audio = os.path.join(cue_dir, cue_name_no_ext + ext)
                    if os.path.exists(potential_audio):
                        disc_info["audio_file"] = potential_audio
                        break

                # Parse CUE to count tracks
                try:
                    for encoding in ["utf-8", "latin-1", "cp1252", "shift-jis"]:
                        try:
                            with open(cue_path, "r", encoding=encoding) as f:
                                content = f.read()
                                disc_info["track_count"] = len(
                                    re.findall(
                                        r"^\s*TRACK\s+\d+",
                                        content,
                                        re.MULTILINE | re.IGNORECASE,
                                    )
                                )
                            break
                        except UnicodeDecodeError:
                            continue
                except Exception:
                    pass

                cue_discs.append(disc_info)

            # Sort by disc number
            cue_discs.sort(key=lambda x: x["disc_number"] or 99)

            if len(cue_discs) > 1:
                # Only treat as multi-disc if at least one CUE has a detectable disc number
                # Otherwise it's just multiple CUE variants for the same disc
                has_disc_numbers = any(d["disc_number"] is not None for d in cue_discs)
                if has_disc_numbers:
                    has_splittable = any(d["audio_file"] is not None for d in cue_discs)
                    result["is_multi_disc"] = True
                    result["disc_type"] = "cue_pairs"
                    result["discs"] = cue_discs
                    result["has_splittable_audio"] = has_splittable
                    return result

    return result


@api.route("/api/imports/pending", methods=["GET"])
def get_pending_imports():
    """Get list of folders in downloads ready for import"""

    from pathlib import Path

    downloads_path = Config.DOWNLOADS_NASRADIO
    lidarr_path = Config.DOWNLOADS_LIDARR

    pending = []

    # Scan nasradio folder
    if os.path.exists(downloads_path):
        for item in os.listdir(downloads_path):
            item_path = os.path.join(downloads_path, item)
            if os.path.isdir(item_path):
                # Get folder info
                audio_files = []
                cue_files = []
                flac_files = []
                total_size = 0
                for root, dirs, files in os.walk(item_path):
                    for f in files:
                        file_path = os.path.join(root, f)
                        ext = os.path.splitext(f)[1].lower()
                        if ext in [
                            ".flac",
                            ".mp3",
                            ".m4a",
                            ".wav",
                            ".ogg",
                            ".opus",
                            ".aac",
                            ".wma",
                            ".ape",
                            ".wv",
                            ".aiff",
                            ".aif",
                            ".dsf",
                            ".dff",
                            ".mpc",
                        ]:
                            audio_files.append(f)
                            if ext in [
                                ".flac",
                                ".ape",
                                ".wav",
                                ".wv",
                                ".aiff",
                                ".aif",
                                ".dsf",
                                ".dff",
                            ]:
                                flac_files.append(file_path)
                        if ext == ".cue":
                            cue_files.append(file_path)
                        total_size += os.path.getsize(file_path)

                # Analyze multi-disc structure
                multi_disc_info = analyze_multi_disc_structure(
                    item_path, cue_files, audio_files
                )

                # Detect CUE splitting needs
                # needs_cue_split if: has CUE files AND audio count matches CUE count (not yet split)
                if (
                    multi_disc_info["is_multi_disc"]
                    and multi_disc_info["disc_type"] == "cue_pairs"
                ):
                    needs_cue_split = True
                else:
                    needs_cue_split = len(cue_files) > 0 and len(audio_files) <= len(
                        cue_files
                    )

                if audio_files:  # Only include folders with audio files
                    pending.append(
                        {
                            "path": item_path,
                            "folder_name": item,
                            "source": "nasradio",
                            "audio_file_count": len(audio_files),
                            "total_size": total_size,
                            "size_formatted": format_size(total_size),
                            "has_cue": len(cue_files) > 0,
                            "cue_files": cue_files,
                            "needs_cue_split": needs_cue_split,
                            "multi_disc_info": multi_disc_info,
                        }
                    )

    # Scan lidarr folder too
    if os.path.exists(lidarr_path):
        for item in os.listdir(lidarr_path):
            item_path = os.path.join(lidarr_path, item)
            if os.path.isdir(item_path):
                audio_files = []
                cue_files = []
                flac_files = []
                total_size = 0
                for root, dirs, files in os.walk(item_path):
                    for f in files:
                        file_path = os.path.join(root, f)
                        ext = os.path.splitext(f)[1].lower()
                        if ext in [
                            ".flac",
                            ".mp3",
                            ".m4a",
                            ".wav",
                            ".ogg",
                            ".opus",
                            ".aac",
                            ".wma",
                            ".ape",
                            ".wv",
                            ".aiff",
                            ".aif",
                            ".dsf",
                            ".dff",
                            ".mpc",
                        ]:
                            audio_files.append(f)
                            if ext in [
                                ".flac",
                                ".ape",
                                ".wav",
                                ".wv",
                                ".aiff",
                                ".aif",
                                ".dsf",
                                ".dff",
                            ]:
                                flac_files.append(file_path)
                        if ext == ".cue":
                            cue_files.append(file_path)
                        total_size += os.path.getsize(file_path)

                # Analyze multi-disc structure
                multi_disc_info = analyze_multi_disc_structure(
                    item_path, cue_files, audio_files
                )

                # Detect CUE splitting needs
                if (
                    multi_disc_info["is_multi_disc"]
                    and multi_disc_info["disc_type"] == "cue_pairs"
                ):
                    needs_cue_split = True
                else:
                    needs_cue_split = len(cue_files) > 0 and len(audio_files) <= len(
                        cue_files
                    )

                if audio_files:
                    pending.append(
                        {
                            "path": item_path,
                            "folder_name": item,
                            "source": "lidarr",
                            "audio_file_count": len(audio_files),
                            "total_size": total_size,
                            "size_formatted": format_size(total_size),
                            "has_cue": len(cue_files) > 0,
                            "cue_files": cue_files,
                            "needs_cue_split": needs_cue_split,
                            "multi_disc_info": multi_disc_info,
                        }
                    )

    # Sort by folder name
    pending.sort(key=lambda x: x["folder_name"].lower())

    return jsonify({"success": True, "pending_count": len(pending), "pending": pending})


def format_size(size_bytes):
    """Format bytes to human-readable size"""
    if size_bytes == 0:
        return "0 B"
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if size_bytes < 1024:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} PB"


@api.route("/api/imports/parse-folder", methods=["POST"])
def parse_folder_name():
    """Parse a folder name to extract artist and album info"""

    data = request.get_json()
    folder_name = data.get("folder_name", "")

    # Common patterns:
    # "Artist - Album (Year) [Format]"
    # "Artist - Album [Format]"
    # "Artist - Album (Year)"
    # "Artist - Album"

    # Remove common suffixes
    clean = folder_name
    clean = re.sub(r"\[.*?\]", "", clean)  # Remove [FLAC], [MP3], etc.
    clean = re.sub(r"\((?:19|20)\d{2}\)", "", clean)  # Remove (Year)
    clean = re.sub(r"\(\d+[- ]?\d*\)", "", clean)  # Remove (24-96), (24-192), etc
    clean = clean.strip(" -")

    # Try to split by " - "
    if " - " in clean:
        parts = clean.split(" - ", 1)
        artist = parts[0].strip()
        album = parts[1].strip()
    else:
        # Can't determine, return folder name as album
        artist = ""
        album = clean.strip()

    # Extract year if present
    year_match = re.search(r"\(?(19|20)(\d{2})\)?", folder_name)
    year = int(year_match.group(1) + year_match.group(2)) if year_match else None

    return jsonify(
        {
            "success": True,
            "parsed": {
                "artist": artist,
                "album": album,
                "year": year,
                "original": folder_name,
            },
        }
    )


@api.route("/api/edit/album/<int:album_id>", methods=["PUT"])
def edit_album(album_id):
    """Edit album title - or merge into existing album if name matches"""
    data = request.get_json()
    new_title = data.get("title")

    if not new_title:
        return jsonify({"error": "title is required"}), 400

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Get current album info
        cursor.execute(
            "SELECT id, title, artist_id FROM albums WHERE id = %s", (album_id,)
        )
        album = cursor.fetchone()
        if not album:
            return jsonify({"error": "Album not found"}), 404

        artist_id = album["artist_id"]

        # Check if an album with the new title already exists for this artist
        cursor.execute(
            "SELECT id FROM albums WHERE title = %s AND artist_id = %s AND id != %s",
            (new_title, artist_id, album_id),
        )
        existing_album = cursor.fetchone()

        if existing_album:
            # MERGE: Move all songs from current album to existing album
            target_album_id = existing_album["id"]

            # Get max track number in target album to avoid conflicts
            cursor.execute(
                "SELECT MAX(track_number) as max_track FROM songs WHERE album_id = %s",
                (target_album_id,),
            )
            max_track = cursor.fetchone()["max_track"] or 0

            # Move songs to target album, incrementing track numbers
            cursor.execute(
                """
                UPDATE songs 
                SET album_id = %s, track_number = track_number + %s
                WHERE album_id = %s
                """,
                (target_album_id, max_track, album_id),
            )
            songs_moved = cursor.rowcount

            # Delete the now-empty source album
            cursor.execute("DELETE FROM albums WHERE id = %s", (album_id,))

            conn.commit()
            return jsonify(
                {
                    "success": True,
                    "message": f"Merged {songs_moved} songs into existing album '{new_title}'",
                    "merged_into_album_id": target_album_id,
                }
            )
        else:
            # Simple rename - no existing album with that name
            cursor.execute(
                "UPDATE albums SET title = %s WHERE id = %s", (new_title, album_id)
            )
            conn.commit()
            return jsonify({"success": True, "message": "Album title updated"})

    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/edit/album/<int:album_id>/year", methods=["PUT"])
def edit_album_year(album_id):
    """Edit album year"""
    data = request.get_json()
    new_year = data.get("year")

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Check album exists
        cursor.execute("SELECT id FROM albums WHERE id = %s", (album_id,))
        if not cursor.fetchone():
            conn.close()
            return jsonify({"error": "Album not found"}), 404

        # Update year (can be None to clear it)
        cursor.execute(
            "UPDATE albums SET year = %s WHERE id = %s",
            (new_year, album_id),
        )
        conn.commit()
        return jsonify({"success": True, "message": "Album year updated"})

    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/edit/merge-artists", methods=["POST"])
def merge_artists():
    """Merge artists into one canonical artist, carrying over everything that
    points at them.

    Hardened 2026-09-20. The old version re-pointed albums, songs and credits
    in three blunt UPDATEs, which (a) violated UNIQUE(song_id, artist_id) on
    song_artists whenever two of the merged artists were credited on the same
    song — exactly the "Joan Jett" + "The Blackhearts" case — and rolled the
    whole merge back, and (b) ignored favorites, upcoming releases, album
    groups and the Last.fm cache, and threw away a source's image/MBID even
    when the target had none.
    """
    data = request.get_json(silent=True) or {}
    try:
        target = int(data.get("target_artist_id"))
        sources = sorted({int(x) for x in (data.get("source_artist_ids") or [])})
    except (TypeError, ValueError):
        return jsonify({"error": "target_artist_id and source_artist_ids must be artist ids"}), 400
    if target in sources:
        return jsonify({"error": "the target artist can't also be one of the sources"}), 400
    if not sources:
        return jsonify({"error": "target_artist_id and source_artist_ids are required"}), 400

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    images_dir = os.path.join(APP_BASE_DIR, "artist_images")
    orphan_images = []

    try:
        cursor.execute(
            "SELECT id, name, mbid, image_path, image_source FROM artists WHERE id = ANY(%s)",
            ([target] + sources,),
        )
        rows = {r["id"]: dict(r) for r in cursor.fetchall()}
        missing = [i for i in [target] + sources if i not in rows]
        if missing:
            return jsonify({"error": f"no such artist id(s): {missing}"}), 404
        tgt = rows[target]
        moved = {}

        # Albums follow — but idx_albums_unique forbids two albums with the
        # same title under one artist, so a source album whose title the
        # target (or an earlier source) already uses would abort the whole
        # merge. Folding them automatically is risky (the same record ripped
        # twice would double every track), so rename the newcomer, move it
        # intact, and report the pair for the album-merge screen.
        cursor.execute("SELECT id, title FROM albums WHERE artist_id = %s", (target,))
        taken = {(r["title"] or "").lower(): r["id"] for r in cursor.fetchall()}
        cursor.execute(
            "SELECT id, title, artist_id FROM albums WHERE artist_id = ANY(%s) ORDER BY id",
            (sources,),
        )
        renamed_albums = []
        for al in cursor.fetchall():
            title = al["title"] or ""
            key = title.lower()
            if key in taken:
                base = f"{title} (from {rows[al['artist_id']]['name']})"
                new_title, n = base, 2
                while new_title.lower() in taken:
                    new_title, n = f"{base} {n}", n + 1
                cursor.execute("UPDATE albums SET title = %s WHERE id = %s", (new_title, al["id"]))
                renamed_albums.append({"album_id": al["id"], "was": title, "now": new_title,
                                       "same_title_as_album_id": taken[key]})
                key = new_title.lower()
            taken[key] = al["id"]
        cursor.execute("UPDATE albums SET artist_id = %s WHERE artist_id = ANY(%s)", (target, sources))
        moved["albums"] = cursor.rowcount
        cursor.execute("UPDATE songs SET artist_id = %s WHERE artist_id = ANY(%s)", (target, sources))
        moved["songs"] = cursor.rowcount

        # Credits: a song may credit several of the merged artists (and maybe
        # the target already). Move exactly ONE credit per song that doesn't
        # credit the target yet, drop the rest, then renumber so the song's
        # main artist is position 1.
        cursor.execute("SELECT DISTINCT song_id FROM song_artists WHERE artist_id = ANY(%s)", (sources,))
        affected = [r["song_id"] for r in cursor.fetchall()]
        cursor.execute(
            """UPDATE song_artists SET artist_id = %s WHERE id IN (
                   SELECT DISTINCT ON (song_id) id FROM song_artists
                    WHERE artist_id = ANY(%s)
                      AND song_id NOT IN (SELECT song_id FROM song_artists WHERE artist_id = %s)
                    ORDER BY song_id, position, id)""",
            (target, sources, target),
        )
        moved["credits"] = cursor.rowcount
        cursor.execute("DELETE FROM song_artists WHERE artist_id = ANY(%s)", (sources,))
        moved["duplicate_credits_dropped"] = cursor.rowcount
        if affected:
            cursor.execute(
                """UPDATE song_artists sa SET position = r.rn FROM (
                       SELECT sa2.id, ROW_NUMBER() OVER (
                                  PARTITION BY sa2.song_id
                                  ORDER BY (sa2.artist_id = s.artist_id) DESC, sa2.position, sa2.id) AS rn
                         FROM song_artists sa2 JOIN songs s ON s.id = sa2.song_id
                        WHERE sa2.song_id = ANY(%s)) r
                    WHERE r.id = sa.id AND sa.position IS DISTINCT FROM r.rn""",
                (affected,),
            )

        # Aliases: copy distinct ones, then remember every merged NAME as an
        # alias so a future import tagged with the old spelling lands here.
        cursor.execute(
            """INSERT INTO artist_aliases (artist_id, alias, source)
                   SELECT DISTINCT ON (alias) %s, alias, source FROM artist_aliases
                    WHERE artist_id = ANY(%s) ORDER BY alias, id
               ON CONFLICT (artist_id, alias) DO NOTHING""",
            (target, sources),
        )
        for sid in sources:
            old_name = (rows[sid]["name"] or "").strip()
            if old_name and old_name.lower() != (tgt["name"] or "").strip().lower():
                cursor.execute(
                    "INSERT INTO artist_aliases (artist_id, alias, source) VALUES (%s, %s, 'merge') "
                    "ON CONFLICT (artist_id, alias) DO NOTHING",
                    (target, old_name),
                )
        cursor.execute("DELETE FROM artist_aliases WHERE artist_id = ANY(%s)", (sources,))

        # Favorites: UNIQUE(user_id, item_type, item_id) — one per user.
        cursor.execute(
            """UPDATE favorites SET item_id = %s WHERE id IN (
                   SELECT DISTINCT ON (user_id) id FROM favorites
                    WHERE item_type = 'artist' AND item_id = ANY(%s)
                      AND user_id NOT IN (SELECT user_id FROM favorites
                                           WHERE item_type = 'artist' AND item_id = %s)
                    ORDER BY user_id, created_at, id)""",
            (target, sources, target),
        )
        moved["favorites"] = cursor.rowcount
        cursor.execute("DELETE FROM favorites WHERE item_type = 'artist' AND item_id = ANY(%s)", (sources,))

        # Upcoming releases: UNIQUE(artist_id, release_title) — one per title.
        cursor.execute(
            """UPDATE upcoming_releases SET artist_id = %s, artist_name = %s WHERE id IN (
                   SELECT DISTINCT ON (release_title) id FROM upcoming_releases
                    WHERE artist_id = ANY(%s)
                      AND release_title NOT IN (SELECT release_title FROM upcoming_releases WHERE artist_id = %s)
                    ORDER BY release_title, id)""",
            (target, tgt["name"], sources, target),
        )
        moved["upcoming_releases"] = cursor.rowcount
        cursor.execute("DELETE FROM upcoming_releases WHERE artist_id = ANY(%s)", (sources,))

        # Album groups would be cascade-deleted with their artist; keep them.
        cursor.execute("UPDATE album_groups SET artist_id = %s WHERE artist_id = ANY(%s)", (target, sources))
        moved["album_groups"] = cursor.rowcount
        # Pure caches for the sources (the target's refresh on their own).
        cursor.execute("DELETE FROM lastfm_top_tracks WHERE artist_id = ANY(%s)", (sources,))

        # Best of both: inherit a MusicBrainz id and an image the target lacks.
        inherited = {}
        if not tgt.get("mbid"):
            donor = next((rows[i] for i in sources if rows[i].get("mbid")), None)
            if donor:
                cursor.execute("UPDATE artists SET mbid = %s WHERE id = %s", (donor["mbid"], target))
                inherited["mbid_from"] = donor["name"]
        tgt_has_image = bool(tgt.get("image_path")) and os.path.exists(
            os.path.join(images_dir, tgt["image_path"]))
        for sid in sources:
            ipath = rows[sid].get("image_path")
            if not ipath:
                continue
            full = os.path.join(images_dir, ipath)
            if not os.path.exists(full):
                continue
            if not tgt_has_image:
                new_name = f"artist_{target}{os.path.splitext(ipath)[1] or '.jpg'}"
                try:
                    os.replace(full, os.path.join(images_dir, new_name))
                    cursor.execute(
                        "UPDATE artists SET image_path = %s, image_source = %s WHERE id = %s",
                        (new_name, rows[sid].get("image_source"), target),
                    )
                    tgt_has_image = True
                    inherited["image_from"] = rows[sid]["name"]
                    continue
                except OSError as e:
                    print(f"⚠️ merge-artists: could not adopt image {ipath}: {e}")
            orphan_images.append(full)

        cursor.execute(
            "UPDATE artists SET album_count = (SELECT COUNT(*) FROM albums WHERE artist_id = %s), "
            "song_count = (SELECT COUNT(*) FROM songs WHERE artist_id = %s) WHERE id = %s",
            (target, target, target),
        )
        # mb_release_groups / mb_discography_status rows of the sources cascade.
        cursor.execute("DELETE FROM artists WHERE id = ANY(%s)", (sources,))

        conn.commit()
    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()

    # Only after the commit: files of the rows that are gone.
    for full in orphan_images:
        try:
            os.remove(full)
        except OSError:
            pass

    print(f"🔀 Merged artists {sources} into {target} ({tgt['name']}): {moved}, inherited {inherited}")
    return jsonify(
        {
            "success": True,
            "message": f"Merged {len(sources)} artists",
            "target_artist_id": target,
            "moved": moved,
            "inherited": inherited,
            # Same-titled albums were renamed rather than folded together;
            # merge each pair deliberately in the album-merge screen.
            "renamed_albums": renamed_albums,
        }
    )


@api.route("/api/edit/find-similar-artists", methods=["GET"])
def find_similar_artists():
    """Find artists with similar names for merging suggestions"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    cursor.execute(
        "SELECT id, name, album_count, song_count FROM artists ORDER BY name"
    )
    all_artists = [dict(row) for row in cursor.fetchall()]
    conn.close()

    # Group artists by normalized name (lowercase, no punctuation)

    groups = {}
    for artist in all_artists:
        # Normalize: lowercase, remove &/and/the, remove punctuation, strip spaces
        normalized = re.sub(r"[^\w\s]", "", artist["name"].lower())
        # Remove "the" from beginning
        if normalized.startswith("the "):
            normalized = normalized[4:]
        # Remove trailing numbers like (01), (02), (1), (2), etc.
        normalized = re.sub(r"\s*\d+\s*$", "", normalized)
        normalized = normalized.replace(" and ", " ").replace("  ", " ").strip()

        if normalized not in groups:
            groups[normalized] = []
        groups[normalized].append(artist)

    # Only return groups with 2+ artists (potential duplicates)
    suggestions = [group for group in groups.values() if len(group) > 1]

    return jsonify({"suggestions": suggestions})


@api.route("/api/artists/search", methods=["GET"])
def search_artists():
    """Search artists by name"""
    query = request.args.get("q", "")

    if not query or len(query) < 2:
        return jsonify([])

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    normalized_query = re.sub(r"[^a-z0-9 ]", "", query.lower())
    strip_punct = "regexp_replace(LOWER({}), '[^a-z0-9 ]', '', 'g')"

    search_pattern = f"%{normalized_query}%"
    cursor.execute(
        f"""SELECT id, name FROM artists
            WHERE {strip_punct.format('name')} LIKE %s
               OR similarity({strip_punct.format('name')}, %s) > 0.3
            ORDER BY
                CASE WHEN {strip_punct.format('name')} LIKE %s THEN 0 ELSE 1 END,
                name
            LIMIT 20""",
        (search_pattern, normalized_query, search_pattern),
    )
    artists = [dict(row) for row in cursor.fetchall()]
    conn.close()

    return jsonify(artists)


@api.route("/api/merge-albums", methods=["POST"])
def merge_albums():
    """Merge multiple albums into one canonical album"""
    data = request.get_json()
    target_album_id = data.get("target_album_id")  # The one to keep
    source_album_ids = data.get("source_album_ids")  # The ones to merge into target
    disc_numbers = data.get("disc_numbers", {})  # album_id -> disc_number mapping
    disc_names = data.get("disc_names", {})  # disc_number -> disc_name mapping
    new_album_name = data.get("new_album_name")  # New name for merged album
    album_artist_id = data.get(
        "album_artist_id"
    )  # Artist ID to set for merged album (None = keep target's artist)
    update_song_artists = data.get(
        "update_song_artists", False
    )  # Also update track artists

    if not target_album_id or not source_album_ids:
        return (
            jsonify({"error": "target_album_id and source_album_ids are required"}),
            400,
        )

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Handle special "various_artists" string - get or create Various Artists
        if album_artist_id == "various_artists":
            cursor.execute("SELECT id FROM artists WHERE name = 'Various Artists'")
            row = cursor.fetchone()
            if row:
                album_artist_id = row["id"]
            else:
                cursor.execute(
                    "INSERT INTO artists (name, song_count, album_count) VALUES ('Various Artists', 0, 0) RETURNING id"
                )
                album_artist_id = cursor.fetchone()["id"]

        # Update disc numbers for each album's songs
        for album_id_str, disc_num in disc_numbers.items():
            album_id = int(album_id_str)
            cursor.execute(
                "UPDATE songs SET disc_number = %s WHERE album_id = %s",
                (disc_num, album_id),
            )

        # Update target album name if provided
        if new_album_name:
            cursor.execute(
                "UPDATE albums SET title = %s WHERE id = %s",
                (new_album_name, target_album_id),
            )

        # Update album artist if specified
        if album_artist_id:
            cursor.execute(
                "UPDATE albums SET artist_id = %s WHERE id = %s",
                (album_artist_id, target_album_id),
            )

        # Update all songs from source albums to target album
        placeholders = ",".join(["%s"] * len(source_album_ids))
        cursor.execute(
            f"UPDATE songs SET album_id = %s WHERE album_id IN ({placeholders})",
            [target_album_id] + source_album_ids,
        )

        # Optionally update all song artists to match the album artist
        if update_song_artists and album_artist_id:
            # Get the actual artist ID (resolve various_artists if needed)
            actual_artist_id = album_artist_id

            # Get all song IDs in the merged album
            cursor.execute(
                "SELECT id FROM songs WHERE album_id = %s", (target_album_id,)
            )
            song_ids = [row["id"] for row in cursor.fetchall()]

            if song_ids:
                song_placeholders = ",".join(["%s"] * len(song_ids))

                # Update songs.artist_id
                cursor.execute(
                    f"UPDATE songs SET artist_id = %s WHERE id IN ({song_placeholders})",
                    [actual_artist_id] + song_ids,
                )

                # Update song_artists - remove existing entries and add new one
                cursor.execute(
                    f"DELETE FROM song_artists WHERE song_id IN ({song_placeholders})",
                    song_ids,
                )

                # Add new artist as primary for each song
                for song_id in song_ids:
                    cursor.execute(
                        "INSERT INTO song_artists (song_id, artist_id, position) VALUES (%s, %s, 0)",
                        (song_id, actual_artist_id),
                    )

        # Recalculate song count for target album
        cursor.execute(
            "UPDATE albums SET song_count = (SELECT COUNT(*) FROM songs WHERE album_id = %s) WHERE id = %s",
            (target_album_id, target_album_id),
        )

        # Delete the source albums (now empty)
        cursor.execute(
            f"DELETE FROM albums WHERE id IN ({placeholders})", source_album_ids
        )

        # Save disc names if provided
        if disc_names:
            # Clear existing disc names for this album
            cursor.execute(
                "DELETE FROM disc_names WHERE album_id = %s", (target_album_id,)
            )
            # Insert new disc names
            for disc_num_str, disc_name in disc_names.items():
                disc_num = int(disc_num_str)
                cursor.execute(
                    "INSERT INTO disc_names (album_id, disc_number, disc_name) VALUES (%s, %s, %s)",
                    (target_album_id, disc_num, disc_name),
                )

        # Clean up orphaned artists (artists with no songs or albums)
        cursor.execute(
            """
            UPDATE artists SET 
                album_count = (SELECT COUNT(*) FROM albums WHERE artist_id = artists.id),
                song_count = (SELECT COUNT(*) FROM songs WHERE artist_id = artists.id)
            """
        )

        conn.commit()

        return jsonify(
            {"success": True, "message": f"Merged {len(source_album_ids)} albums"}
        )
    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/split-box-set/<int:album_id>", methods=["POST"])
def split_box_set(album_id):
    """Split a box set back into individual albums"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Get the box set album
        cursor.execute(
            "SELECT * FROM albums WHERE id = %s",
            (album_id,),
        )
        box_set = cursor.fetchone()
        if not box_set:
            return jsonify({"error": "Album not found"}), 404

        # Get disc names
        cursor.execute(
            "SELECT disc_number, disc_name FROM disc_names WHERE album_id = %s ORDER BY disc_number",
            (album_id,),
        )
        disc_names = {row["disc_number"]: row["disc_name"] for row in cursor.fetchall()}

        if not disc_names:
            return (
                jsonify({"error": "This album is not a box set (no disc names found)"}),
                400,
            )

        created_albums = []

        # For each disc, create a new album (except disc 1 which stays as the original)
        for disc_number, disc_name in disc_names.items():
            if disc_number == 1:
                # Rename the original album to disc 1's name
                cursor.execute(
                    "UPDATE albums SET title = %s WHERE id = %s",
                    (disc_name, album_id),
                )
                # Reset disc numbers for disc 1 songs
                cursor.execute(
                    "UPDATE songs SET disc_number = 1 WHERE album_id = %s AND disc_number = 1",
                    (album_id,),
                )
                created_albums.append({"id": album_id, "title": disc_name, "disc": 1})
            else:
                # Create new album for this disc
                cursor.execute(
                    """INSERT INTO albums (title, artist_id, year, song_count, artwork_path, created_at)
                       VALUES (%s, %s, %s, 0, %s, NOW()) RETURNING id""",
                    (
                        disc_name,
                        box_set["artist_id"],
                        box_set["year"],
                        box_set["artwork_path"],
                    ),
                )
                new_album_id = cursor.fetchone()["id"]

                # Move songs from this disc to the new album
                cursor.execute(
                    "UPDATE songs SET album_id = %s, disc_number = 1 WHERE album_id = %s AND disc_number = %s",
                    (new_album_id, album_id, disc_number),
                )

                # Update song count
                cursor.execute(
                    "UPDATE albums SET song_count = (SELECT COUNT(*) FROM songs WHERE album_id = %s) WHERE id = %s",
                    (new_album_id, new_album_id),
                )

                created_albums.append(
                    {"id": new_album_id, "title": disc_name, "disc": disc_number}
                )

        # Update song count for original album
        cursor.execute(
            "UPDATE albums SET song_count = (SELECT COUNT(*) FROM songs WHERE album_id = %s) WHERE id = %s",
            (album_id, album_id),
        )

        # Update artist album/song counts
        cursor.execute(
            """
            UPDATE artists SET 
                album_count = (SELECT COUNT(*) FROM albums WHERE artist_id = artists.id),
                song_count = (SELECT COUNT(*) FROM songs WHERE artist_id = artists.id)
            """
        )

        # Delete disc names
        cursor.execute("DELETE FROM disc_names WHERE album_id = %s", (album_id,))

        conn.commit()

        return jsonify(
            {
                "success": True,
                "message": f"Split box set into {len(created_albums)} albums",
                "albums": created_albums,
            }
        )

    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/find-duplicate-albums", methods=["GET"])
def find_duplicate_albums():
    """Find duplicate albums (same title, same artist - with normalization)"""

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    # Get all albums with their info
    cursor.execute(
        """
        SELECT 
            albums.id, albums.title, albums.artist_id, albums.year, 
            albums.song_count, albums.created_at, albums.artwork_path,
            artists.name as artist_name,
            (SELECT file_path FROM songs WHERE album_id = albums.id LIMIT 1) as sample_path
        FROM albums
        JOIN artists ON albums.artist_id = artists.id
        ORDER BY artists.name, albums.title
        """
    )

    all_albums = [dict(row) for row in cursor.fetchall()]

    # Get songs for all albums with quality info
    cursor.execute(
        """
        SELECT id, title, album_id, track_number, disc_number, file_path, bitrate
        FROM songs
        ORDER BY album_id, disc_number, track_number
        """
    )
    all_songs = cursor.fetchall()

    # Group songs by album_id and calculate quality summary
    songs_by_album = {}
    quality_by_album = {}
    for song in all_songs:
        album_id = song["album_id"]
        if album_id not in songs_by_album:
            songs_by_album[album_id] = []
            quality_by_album[album_id] = {"formats": set(), "bitrates": []}

        songs_by_album[album_id].append(
            {
                "id": song["id"],
                "title": song["title"],
                "track_number": song["track_number"],
                "disc_number": song["disc_number"],
            }
        )

        # Extract format from file path
        if song["file_path"]:
            ext = (
                song["file_path"].rsplit(".", 1)[-1].upper()
                if "." in song["file_path"]
                else "Unknown"
            )
            quality_by_album[album_id]["formats"].add(ext)

        if song["bitrate"]:
            quality_by_album[album_id]["bitrates"].append(song["bitrate"])

    # Get not-duplicate pairs
    cursor.execute("SELECT album_id_1, album_id_2 FROM not_duplicate_albums")
    not_dup_pairs = set()
    for row in cursor.fetchall():
        not_dup_pairs.add((row["album_id_1"], row["album_id_2"]))

    conn.close()

    def normalize_title(title):
        """Normalize title for comparison - strips edition/remaster/version info but preserves volume numbers"""
        if not title:
            return ""
        # Lowercase
        t = title.lower().strip()

        # Normalize unicode characters
        t = t.replace("'", "'").replace("'", "'")  # Smart quotes to regular
        t = t.replace(""", '"').replace(""", '"')
        t = t.replace("–", "-").replace("—", "-")  # En/em dash to hyphen
        t = t.replace("…", "...")

        # IMPORTANT: Normalize volume indicators BEFORE removing them
        # Convert "Vol. 2", "Volume 2", ", Vol 2" etc to a standard format we KEEP
        t = re.sub(r",?\s*vol(?:ume)?\.?\s*(\d+)", r" vol \1", t, flags=re.IGNORECASE)

        # Also preserve numbered sequels: "2", "II", "III" at end of title
        # These are NOT duplicates - they're different albums in a series

        # Remove bracketed info: [Deluxe], [Explicit], [Clean], etc.
        t = re.sub(r"\s*\[[^\]]*\]", "", t)

        # Remove parenthetical edition info: (Deluxe), (Remastered), (20th Anniversary Edition), etc.
        # But NOT volume numbers like (Vol. 2)
        t = re.sub(
            r"\s*\([^)]*(?:edition|remaster|deluxe|version|anniversary|expanded|bonus|special|limited|disc|cd|explicit|clean|mono|stereo|remix|japanese)[^)]*\)",
            "",
            t,
            flags=re.IGNORECASE,
        )

        # Remove year in parentheses at end: (2020), (1984)
        t = re.sub(r"\s*\(\d{4}\)\s*$", "", t)

        # Remove standalone parenthetical discs (but NOT volumes): (Disc 1), (CD 2)
        t = re.sub(r"\s*\((?:disc|cd|disk)\s*\d+\)", "", t, flags=re.IGNORECASE)

        # Remove non-parenthetical edition info
        t = re.sub(
            r"\s*-?\s*\d*\s*(?:th|st|nd|rd)?\s*anniversary\s*(?:edition)?\s*$",
            "",
            t,
            flags=re.IGNORECASE,
        )
        t = re.sub(
            r"\s*-?\s*(?:deluxe|remastered|remaster|expanded|special|limited|platinum|gold|silver|diamond|super)\s*(?:edition|version)?\s*$",
            "",
            t,
            flags=re.IGNORECASE,
        )
        t = re.sub(
            r"\s*-?\s*\d{4}\s*(?:cd\s*)?(?:version|remaster|edition)\s*$",
            "",
            t,
            flags=re.IGNORECASE,
        )
        t = re.sub(
            r"\s*-?\s*(?:explicit|clean)\s*(?:version)?\s*$", "", t, flags=re.IGNORECASE
        )

        # Remove disc indicators at end (but NOT volume - those are different albums)
        t = re.sub(r"\s*-?\s*(?:disc|disk|cd)\s*\d+\s*$", "", t, flags=re.IGNORECASE)

        # Remove region indicators
        t = re.sub(
            r"\s*\((?:uk|us|usa|japan|jp|eu|europe|international|import)\)\s*$",
            "",
            t,
            flags=re.IGNORECASE,
        )

        # Normalize "and" / "&"
        t = t.replace(" & ", " and ")

        # Normalize whitespace
        t = re.sub(r"\s+", " ", t).strip()

        # Remove trailing punctuation
        t = t.strip(".,!?-_:")

        return t

    # Group albums by artist_id + normalized title
    groups = {}
    for album in all_albums:
        normalized = normalize_title(album["title"])
        key = f"{album['artist_id']}|{normalized}"
        if key not in groups:
            groups[key] = []
        groups[key].append(album)

    # Filter to only groups with duplicates, excluding marked not-duplicates
    result = []
    for key, albums in groups.items():
        if len(albums) > 1:
            # Check if all pairs in this group are marked as not duplicates
            dominated_pairs = set()
            for i, a1 in enumerate(albums):
                for a2 in albums[i + 1 :]:
                    id1 = min(a1["id"], a2["id"])
                    id2 = max(a1["id"], a2["id"])
                    if (id1, id2) in not_dup_pairs:
                        dominated_pairs.add((id1, id2))

            # Count total possible pairs
            total_pairs = len(albums) * (len(albums) - 1) // 2

            # Skip this group if all pairs are marked as not duplicates
            if len(dominated_pairs) == total_pairs:
                continue

            # Add songs and quality info to each album
            for album in albums:
                album["songs"] = songs_by_album.get(album["id"], [])
                quality = quality_by_album.get(
                    album["id"], {"formats": set(), "bitrates": []}
                )
                album["formats"] = list(quality["formats"])
                album["avg_bitrate"] = (
                    int(sum(quality["bitrates"]) / len(quality["bitrates"]))
                    if quality["bitrates"]
                    else None
                )

            result.append(
                {
                    "title": albums[0]["title"],
                    "artist_name": albums[0]["artist_name"],
                    "album_count": len(albums),
                    "albums": sorted(albums, key=lambda x: x["created_at"]),
                }
            )

    # Sort by artist name, then title
    result.sort(key=lambda x: (x["artist_name"].lower(), x["title"].lower()))

    return jsonify(
        {
            "success": True,
            "duplicate_count": len(result),
            "total_duplicate_albums": sum(g["album_count"] for g in result),
            "duplicates": result,
        }
    )


@api.route("/api/cleanup-empty-albums", methods=["GET"])
def list_empty_albums():
    """List all albums with 0 songs (orphaned records)"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    cursor.execute(
        """
        SELECT albums.id, albums.title, albums.year, albums.created_at,
               artists.name as artist_name
        FROM albums
        JOIN artists ON albums.artist_id = artists.id
        WHERE albums.song_count = 0
        ORDER BY artists.name, albums.title
        """
    )

    empty_albums = [dict(row) for row in cursor.fetchall()]
    conn.close()

    return jsonify(
        {"success": True, "count": len(empty_albums), "albums": empty_albums}
    )


@api.route("/api/cleanup-empty-albums", methods=["DELETE"])
def delete_empty_albums():
    """Delete albums with no songs actually referencing them.

    Was using `WHERE song_count = 0` — but the `songs_count` column on
    albums isn't updated atomically when songs are deleted, so it goes
    stale. The 4 orphan albums simpson1045 hit on 2026-06-01 (incl. Sonic Mania
    OST Selected Edition) all had non-zero stored song_count even though
    no songs existed. Switched to an actual NOT EXISTS check against
    the songs table, which is what "empty" really means.

    Also clears favorites referencing the about-to-be-deleted album rows
    so they don't dangle.
    """
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Find the genuinely empty album ids using a join check, not
        # the stale stored counter.
        cursor.execute(
            """
            SELECT a.id FROM albums a
            LEFT JOIN songs s ON s.album_id = a.id
            GROUP BY a.id
            HAVING COUNT(s.id) = 0
            """
        )
        empty_ids = [row["id"] for row in cursor.fetchall()]

        if empty_ids:
            cursor.execute(
                "DELETE FROM favorites WHERE item_type = 'album' AND item_id = ANY(%s)",
                (empty_ids,),
            )
            cursor.execute(
                "DELETE FROM albums WHERE id = ANY(%s)",
                (empty_ids,),
            )

        # Also clean up any orphaned artists (no albums, no songs)
        cursor.execute(
            """
            DELETE FROM artists
            WHERE id NOT IN (SELECT DISTINCT artist_id FROM albums)
            AND id NOT IN (SELECT DISTINCT artist_id FROM songs)
            """
        )
        orphaned_artists = cursor.rowcount

        conn.commit()
        conn.close()

        return jsonify(
            {
                "success": True,
                "deleted_albums": len(empty_ids),
                "deleted_orphaned_artists": orphaned_artists,
            }
        )

    except Exception as e:
        conn.rollback()
        conn.close()
        return _error_response(e)


@api.route("/api/not-duplicate-albums", methods=["POST"])
def mark_not_duplicates():
    """Mark a group of albums as not duplicates of each other"""
    data = request.get_json()
    album_ids = data.get("album_ids", [])

    if len(album_ids) < 2:
        return jsonify({"error": "Need at least 2 album IDs"}), 400

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Create pairs from all albums in the group
        pairs_added = 0
        for i in range(len(album_ids)):
            for j in range(i + 1, len(album_ids)):
                id1 = min(album_ids[i], album_ids[j])
                id2 = max(album_ids[i], album_ids[j])
                try:
                    cursor.execute(
                        "INSERT INTO not_duplicate_albums (album_id_1, album_id_2) VALUES (%s, %s)",
                        (id1, id2),
                    )
                    pairs_added += 1
                except Exception:
                    pass  # Already exists

        conn.commit()
        return jsonify({"success": True, "pairs_added": pairs_added})
    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/find-similar-albums", methods=["GET"])
def find_similar_albums():
    """Find albums with similar names for merging suggestions (e.g., CD 1/CD 2 splits, compilation albums split by artist)"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    # Get albums with a sample file path to check folder location
    cursor.execute(
        """
        SELECT albums.id, albums.title, albums.artist_id, albums.year, albums.song_count,
               artists.name as artist_name,
               (SELECT file_path FROM songs WHERE album_id = albums.id LIMIT 1) as sample_path
        FROM albums
        JOIN artists ON albums.artist_id = artists.id
        ORDER BY albums.title, artists.name
        """
    )
    all_albums = [dict(row) for row in cursor.fetchall()]

    # Get not-duplicate pairs
    cursor.execute("SELECT album_id_1, album_id_2 FROM not_duplicate_albums")
    not_dup_pairs = set()
    for row in cursor.fetchall():
        not_dup_pairs.add((row["album_id_1"], row["album_id_2"]))

    conn.close()

    title_groups = {}
    for album in all_albums:
        # Normalize: lowercase, remove disc/cd indicators, remove punctuation
        normalized = album["title"].lower()

        # Remove disc/CD indicators (handles CD-01, CD 01, [CD-01], etc.)
        normalized = re.sub(
            r"\s*[\(\[]?\s*(cd|disc|disk)[\s\-]*\d+\s*[\)\]]?",
            "",
            normalized,
            flags=re.IGNORECASE,
        )

        # Remove bracketed info: [Deluxe], [Explicit], etc.
        normalized = re.sub(r"\s*\[[^\]]*\]", "", normalized)

        # Remove parenthetical edition info: (Deluxe), (Deluxe Version), (Remastered), etc.
        normalized = re.sub(
            r"\s*\([^)]*(?:deluxe|remaster|remastered|edition|expanded|bonus|anniversary|special|limited|version|explicit|clean)[^)]*\)",
            "",
            normalized,
            flags=re.IGNORECASE,
        )

        # Remove non-parenthetical edition suffixes
        normalized = re.sub(
            r"\s*-?\s*(?:deluxe|remastered|remaster|expanded|special|limited)(?:\s+(?:edition|version))?\s*$",
            "",
            normalized,
            flags=re.IGNORECASE,
        )

        # Remove trailing standalone numbers
        normalized = re.sub(r"\s+\d+$", "", normalized)

        # Remove punctuation and clean whitespace
        normalized = re.sub(r"[^\w\s]", "", normalized)
        normalized = re.sub(r"\s+", " ", normalized).strip()

        # Get parent folder from sample path (e.g., "\\server\share\Artist\Album" -> "\\server\share\Artist")
        parent_folder = ""
        if album.get("sample_path"):
            parent_folder = os.path.dirname(album["sample_path"])
            # If parent folder looks like a disc folder (CD 01, Disc 2, etc.), go up one more level
            folder_name = os.path.basename(parent_folder).lower()
            if re.match(r"^(cd|disc|disk)\s*\d+$", folder_name):
                parent_folder = os.path.dirname(parent_folder)

        # Group by normalized title + parent folder
        folder_key = f"{normalized}|{parent_folder}"
        if folder_key not in title_groups:
            title_groups[folder_key] = []
        title_groups[folder_key].append(album)

        # Also group by artist + normalized title (catches split albums in different folders)
        artist_key = f"artist_{album['artist_id']}|{normalized}"
        if artist_key not in title_groups:
            title_groups[artist_key] = []
        # Only add if not already in this group
        if album not in title_groups[artist_key]:
            title_groups[artist_key].append(album)

    # Only return groups with 2+ albums (potential duplicates)
    suggestions = []
    for group in title_groups.values():
        if len(group) > 1:
            # Check if all pairs in this group are marked as not duplicates
            dominated_pairs = 0
            total_pairs = len(group) * (len(group) - 1) // 2
            for i, a1 in enumerate(group):
                for a2 in group[i + 1 :]:
                    id1 = min(a1["id"], a2["id"])
                    id2 = max(a1["id"], a2["id"])
                    if (id1, id2) in not_dup_pairs:
                        dominated_pairs += 1

            # Skip this group if all pairs are marked as not duplicates
            if dominated_pairs == total_pairs:
                continue

            unique_artists = set(album["artist_id"] for album in group)
            is_multi_artist = len(unique_artists) > 1

            for album in group:
                album["is_multi_artist_group"] = is_multi_artist

            suggestions.append(group)

    return jsonify(suggestions)


@api.route("/api/edit/song/<int:song_id>", methods=["PUT"])
def edit_song(song_id):
    """Edit song metadata (title, track_number, disc_number, artist_id)"""
    data = request.get_json()
    new_title = data.get("title")
    track_number = data.get("track_number")
    disc_number = data.get("disc_number")
    artist_id = data.get("artist_id")

    # At least one field must be provided
    if (
        new_title is None
        and track_number is None
        and disc_number is None
        and artist_id is None
    ):
        return (
            jsonify(
                {
                    "error": "At least one of title, track_number, disc_number, or artist_id is required"
                }
            ),
            400,
        )

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Check if song exists
        cursor.execute("SELECT id, title FROM songs WHERE id = %s", (song_id,))
        song = cursor.fetchone()
        if not song:
            return jsonify({"error": "Song not found"}), 404

        # Resolve special artist_id values
        if artist_id is not None:
            if artist_id == "various_artists":
                cursor.execute("SELECT id FROM artists WHERE name = 'Various Artists'")
                row = cursor.fetchone()
                if row:
                    artist_id = row["id"]
                else:
                    cursor.execute(
                        "INSERT INTO artists (name, song_count, album_count) VALUES ('Various Artists', 0, 0) RETURNING id"
                    )
                    artist_id = cursor.fetchone()["id"]
            elif isinstance(artist_id, str) and artist_id.startswith("new:"):
                artist_name = artist_id[4:]
                if not artist_name:
                    return jsonify({"error": "Artist name cannot be empty"}), 400
                cursor.execute(
                    "SELECT id FROM artists WHERE LOWER(name) = LOWER(%s)",
                    (artist_name,),
                )
                existing = cursor.fetchone()
                if existing:
                    artist_id = existing["id"]
                else:
                    cursor.execute(
                        "INSERT INTO artists (name, song_count, album_count) VALUES (%s, 0, 0) RETURNING id",
                        (artist_name,),
                    )
                    artist_id = cursor.fetchone()["id"]

        # Build dynamic update query
        updates = []
        params = []

        if new_title is not None:
            updates.append("title = %s")
            params.append(new_title)
        if track_number is not None:
            updates.append("track_number = %s")
            params.append(track_number)
        if disc_number is not None:
            updates.append("disc_number = %s")
            params.append(disc_number)
        if artist_id is not None:
            updates.append("artist_id = %s")
            params.append(artist_id)

        params.append(song_id)

        cursor.execute(f"UPDATE songs SET {', '.join(updates)} WHERE id = %s", params)

        # Also update song_artists table if artist changed
        if artist_id is not None:
            # Remove old primary artist and add new one
            cursor.execute(
                "DELETE FROM song_artists WHERE song_id = %s",
                (song_id,),
            )
            cursor.execute(
                "INSERT INTO song_artists (song_id, artist_id) VALUES (%s, %s) ON CONFLICT DO NOTHING",
                (song_id, artist_id),
            )

        conn.commit()

        return jsonify({"success": True, "message": "Song updated"})
    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/edit/songs/artist", methods=["PUT"])
def edit_songs_artist():
    """Bulk update artist for multiple songs"""
    data = request.get_json()
    song_ids = data.get("song_ids", [])
    artist_id = data.get("artist_id")

    if not song_ids:
        return jsonify({"error": "song_ids is required"}), 400
    if not artist_id:
        return jsonify({"error": "artist_id is required"}), 400

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Resolve special artist_id values
        if artist_id == "various_artists":
            cursor.execute("SELECT id FROM artists WHERE name = 'Various Artists'")
            row = cursor.fetchone()
            if row:
                artist_id = row["id"]
            else:
                cursor.execute(
                    "INSERT INTO artists (name, song_count, album_count) VALUES ('Various Artists', 0, 0) RETURNING id"
                )
                artist_id = cursor.fetchone()["id"]
        elif isinstance(artist_id, str) and artist_id.startswith("new:"):
            artist_name = artist_id[4:]
            if not artist_name:
                return jsonify({"error": "Artist name cannot be empty"}), 400
            cursor.execute(
                "SELECT id FROM artists WHERE LOWER(name) = LOWER(%s)", (artist_name,)
            )
            existing = cursor.fetchone()
            if existing:
                artist_id = existing["id"]
            else:
                cursor.execute(
                    "INSERT INTO artists (name, song_count, album_count) VALUES (%s, 0, 0) RETURNING id",
                    (artist_name,),
                )
                artist_id = cursor.fetchone()["id"]

        # Update songs table
        placeholders = ",".join(["%s"] * len(song_ids))
        cursor.execute(
            f"UPDATE songs SET artist_id = %s WHERE id IN ({placeholders})",
            [artist_id] + song_ids,
        )
        updated = cursor.rowcount

        # Update song_artists table - remove old entries and add new
        cursor.execute(
            f"DELETE FROM song_artists WHERE song_id IN ({placeholders})",
            song_ids,
        )
        for song_id in song_ids:
            cursor.execute(
                "INSERT INTO song_artists (song_id, artist_id) VALUES (%s, %s) ON CONFLICT DO NOTHING",
                (song_id, artist_id),
            )

        conn.commit()
        return jsonify({"success": True, "message": f"Updated {updated} songs"})
    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/edit/strip-album-version/<int:album_id>", methods=["POST"])
def strip_album_version(album_id):
    """Strip (Album Version) from all songs in an album"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Find all songs in this album with "(Album Version)"
        cursor.execute(
            "SELECT id, title FROM songs WHERE album_id = %s AND (title LIKE '%%Album Version%%' OR title LIKE '%%Original Album Version%%')",
            (album_id,),
        )
        songs = cursor.fetchall()

        if not songs:
            return jsonify(
                {
                    "success": True,
                    "message": "No songs with (Album Version) found",
                    "count": 0,
                }
            )

        # Strip (Album Version) from each song
        updated_count = 0
        for song in songs:
            new_title = (
                song["title"]
                .replace(" (Original Album Version)", "")
                .replace("(Original Album Version)", "")
                .replace(" (Album Version)", "")
                .replace("(Album Version)", "")
                .strip()
            )
            cursor.execute(
                "UPDATE songs SET title = %s WHERE id = %s", (new_title, song["id"])
            )
            updated_count += 1

        conn.commit()

        return jsonify(
            {
                "success": True,
                "message": f"Stripped (Album Version) from {updated_count} songs",
                "count": updated_count,
            }
        )
    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


# ========================
# Playlist Endpoints
# ========================


@api.route("/api/playlists", methods=["GET"])
def get_playlists():
    """Get all playlists for the user"""
    playlists_manager = Playlists()
    playlists = playlists_manager.get_playlists()
    return jsonify(playlists)


@api.route("/api/playlist/<int:playlist_id>/played", methods=["POST"])
def mark_playlist_played(playlist_id):
    """Mark a playlist as recently played"""

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        cursor.execute(
            "UPDATE playlists SET last_played_at = %s WHERE id = %s AND user_id = %s",
            (datetime.now().isoformat(), playlist_id, auth.current_user_id()),
        )
        conn.commit()
        return jsonify({"success": True})
    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/playlist/<int:playlist_id>/pin", methods=["POST"])
def toggle_playlist_pin(playlist_id):
    """Toggle playlist pinned status"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        cursor.execute(
            "SELECT pinned FROM playlists WHERE id = %s AND user_id = %s",
            (playlist_id, auth.current_user_id()),
        )
        row = cursor.fetchone()
        if not row:
            return jsonify({"error": "Playlist not found"}), 404

        new_pinned = 0 if row["pinned"] else 1
        cursor.execute(
            "UPDATE playlists SET pinned = %s WHERE id = %s AND user_id = %s",
            (new_pinned, playlist_id, auth.current_user_id()),
        )
        conn.commit()
        safe_emit("playlist_updated", {"action": "pinned", "playlist_id": playlist_id})
        return jsonify({"success": True, "pinned": new_pinned == 1})
    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


# ── Stations: live internet radio (Icecast/Shoutcast direct streams) ──────
# Direct passthrough: the app plays station.url itself (no backend relay).
# Plain authed CRUD — the before_request gate covers these (full token).
@api.route("/api/stations", methods=["GET"])
def list_stations():
    """List active radio stations, featured first."""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute(
            "SELECT id, name, url, genre, description, homepage, favicon, source, "
            "sort_order, COALESCE(play_count, 0) AS play_count "
            "FROM stations WHERE is_active = 1 "
            "ORDER BY (source = 'featured') DESC, sort_order, name"
        )
        return jsonify([dict(r) for r in cursor.fetchall()])
    except Exception as e:
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/stations/<int:station_id>/now-playing", methods=["GET"])
def station_now_playing(station_id):
    """Current track (title/artist/artwork) for a live station, fetched
    out-of-band from the broadcaster (Nightride SSE / SomaFM JSON / generic
    Icecast / in-band ICY). Cached ~15s server-side. All-null fields mean the
    stream exposes nothing usable — the app then just shows the station name.

    NOTE: the app negates station ids to build Song ids, so it calls this
    with the ORIGINAL positive station id (i.e. -song.id).
    """
    from app.station_metadata import get_station_now_playing

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute(
            "SELECT url, homepage FROM stations WHERE id = %s", (station_id,)
        )
        row = cursor.fetchone()
        if not row:
            return jsonify({"error": "station not found"}), 404
        # Blocking network I/O — MUST go through tpool so the eventlet hub
        # keeps serving audio/other requests while we wait on the broadcaster.
        result = eventlet.tpool.execute(
            get_station_now_playing, row["url"], row["homepage"]
        )
        return jsonify(result)
    except Exception as e:
        return _error_response(e)
    finally:
        conn.close()


# Enriched history cached per station so the app's polling doesn't re-run the
# library matching every request (the upstream fetch has its own 30s cache).
_STATION_HISTORY_CACHE = {}    # station_id -> (fetched_at_monotonic, payload)
_STATION_HISTORY_TTL = 30.0


def _match_library_song(cursor, artist, title):
    """Best-effort match of an external 'artist + title' (e.g. a station
    history row) against the local library, using the SAME normalization +
    trigram + artist_aliases smarts as the music search. Returns a song id or
    None. External artist strings like 'A & B feat. C' are split and each
    performer tried against primary and collab artists."""
    from app.utils import normalize_text_for_search, parse_artists

    nt = normalize_text_for_search(title or "")
    if not nt:
        return None
    strip = "regexp_replace(LOWER({}), '[^a-z0-9 ]', '', 'g')"
    names = parse_artists(artist or "")
    for name in (names or [])[:3]:
        na = normalize_text_for_search(name)
        if not na:
            continue
        cursor.execute(
            f"""SELECT s.id,
                       similarity({strip.format('s.title')}, %s) AS title_sim
                FROM songs s
                JOIN artists a ON a.id = s.artist_id
                WHERE s.source_type = 'local'
                  AND similarity({strip.format('s.title')}, %s) > 0.5
                  AND ({strip.format('a.name')} = %s
                       OR similarity({strip.format('a.name')}, %s) > 0.45
                       OR EXISTS (SELECT 1 FROM artist_aliases aa
                                  WHERE aa.artist_id = a.id
                                    AND {strip.format('aa.alias')} = %s)
                       OR EXISTS (SELECT 1 FROM song_artists sa
                                  JOIN artists ca ON ca.id = sa.artist_id
                                  WHERE sa.song_id = s.id
                                    AND ({strip.format('ca.name')} = %s
                                         OR similarity({strip.format('ca.name')}, %s) > 0.45)))
                ORDER BY title_sim DESC
                LIMIT 1""",
            (nt, nt, na, na, na, na, na),
        )
        row = cursor.fetchone()
        if row:
            return row["id"]
    return None


def _fetch_and_enrich_station_history(stream_url, homepage):
    """Runs INSIDE a tpool thread: fetch the broadcaster's history, then
    fuzzy-match every row against the library. The matching is ~30 trigram
    queries (100-200ms each) — several seconds total — which would stall the
    eventlet hub if run on the request greenlet, so it lives here with the
    blocking network fetch. Uses its own pooled connection because the
    request's cursor must not cross threads."""
    from app.station_metadata import get_station_recently_played

    raw = get_station_recently_played(stream_url, homepage)
    if not raw:
        return []
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        # Copy rows before enriching — the raw list is shared via the
        # station_metadata cache and must stay unmodified.
        tracks = []
        for t in raw:
            t = dict(t)
            t["song_id"] = _match_library_song(
                cursor, t.get("artist"), t.get("title")
            )
            tracks.append(t)
        return tracks
    finally:
        conn.close()


@api.route("/api/stations/<int:station_id>/recently-played", methods=["GET"])
def station_recently_played(station_id):
    """Play history for a live station (newest first), fetched out-of-band
    from broadcasters that publish it (Nightride via lissen.to, SomaFM).
    Stations without a history source return an empty list.

    Each row is enriched with 'song_id' when the track fuzzy-matches the
    local library, so the app can offer instant playback; null song_id means
    "not in library" (the app offers Prowlarr/YouTube search instead).

    NOTE: like now-playing, the app calls this with the ORIGINAL positive
    station id (i.e. -song.id).
    """
    now = time.monotonic()
    hit = _STATION_HISTORY_CACHE.get(station_id)
    if hit and (now - hit[0]) < _STATION_HISTORY_TTL:
        return jsonify(hit[1])

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute(
            "SELECT url, homepage FROM stations WHERE id = %s", (station_id,)
        )
        row = cursor.fetchone()
        if not row:
            return jsonify({"error": "station not found"}), 404
    finally:
        conn.close()
    try:
        # Blocking network I/O + seconds of trigram matching — MUST go
        # through tpool so the eventlet hub keeps serving audio/other
        # requests while this works.
        tracks = eventlet.tpool.execute(
            _fetch_and_enrich_station_history, row["url"], row["homepage"]
        )
        payload = {"tracks": tracks}
        _STATION_HISTORY_CACHE[station_id] = (now, payload)
        return jsonify(payload)
    except Exception as e:
        return _error_response(e)


@api.route("/api/stations", methods=["POST"])
def create_station():
    """Add a user station (or re-activate / update one matched by URL)."""
    data = request.get_json() or {}
    name = (data.get("name") or "").strip()
    url = (data.get("url") or "").strip()
    if not name or not url:
        return jsonify({"error": "name and url are required"}), 400
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute(
            "INSERT INTO stations (name, url, genre, description, homepage, favicon, source) "
            "VALUES (%s, %s, %s, %s, %s, %s, 'user') "
            "ON CONFLICT (url) DO UPDATE SET name = EXCLUDED.name, genre = EXCLUDED.genre, "
            "description = EXCLUDED.description, is_active = 1 "
            "RETURNING id, name, url, genre, description, homepage, favicon, source, sort_order",
            (name, url, data.get("genre"), data.get("description"),
             data.get("homepage"), data.get("favicon")),
        )
        row = cursor.fetchone()
        conn.commit()
        return jsonify(dict(row))
    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


_RADIO_BROWSER_SERVERS = (
    "https://de1.api.radio-browser.info",
    "https://de2.api.radio-browser.info",
    "https://nl1.api.radio-browser.info",
)

# sort key -> (radio-browser order field, reverse?)
_RB_SORT = {
    "popular": ("clickcount", True),
    "trending": ("clicktrend", True),
    "votes": ("votes", True),
    "bitrate": ("bitrate", True),
    "name": ("name", False),
}


def _normalize_rb_station(s):
    """A radio-browser station dict -> our station shape, with the metadata that
    actually distinguishes stations (tags, bitrate, country, listeners, votes)."""
    url = (s.get("url_resolved") or s.get("url") or "").strip()
    raw_tags = [t.strip() for t in (s.get("tags") or "").split(",") if t.strip()]
    genre = raw_tags[0].title() if raw_tags else (s.get("codec") or "Radio")
    return {
        "id": None,
        "uuid": s.get("stationuuid"),
        "name": (s.get("name") or "Unknown").strip(),
        "url": url,
        "genre": genre,
        "tags": ", ".join(t.title() for t in raw_tags[:4]),
        "description": (s.get("country") or "").strip(),
        "favicon": (s.get("favicon") or "").strip(),
        "homepage": (s.get("homepage") or "").strip(),
        "bitrate": s.get("bitrate") or 0,
        "codec": (s.get("codec") or "").upper(),
        "country": (s.get("country") or "").strip(),
        "countrycode": (s.get("countrycode") or "").strip(),
        "votes": s.get("votes") or 0,
        "clickcount": s.get("clickcount") or 0,
        "clicktrend": s.get("clicktrend") or 0,
        "source": "radio-browser",
    }


# Liveness cache for stream probes: url -> (alive, checked_at). The
# radio-browser directory is littered with dead duplicate entries (same
# station name, different host:port) that its European checker can still
# reach — or last reached long ago. What matters is whether the stream
# answers from OUR network. Probes are cheap (a ranged GET, headers only)
# and cached for an hour so repeat searches don't re-probe.
_stream_probe_cache = {}
_STREAM_PROBE_TTL = 3600.0


def _probe_stream_alive(url):
    """One cheap ranged GET against the stream URL; True iff it answers.

    Old Shoutcast v1 servers reply with a raw 'ICY 200 OK' status line
    that urllib3 rejects as malformed HTTP — that IS a live stream, so a
    failure mentioning ICY counts as alive."""
    now = time.time()
    hit = _stream_probe_cache.get(url)
    if hit and (now - hit[1]) < _STREAM_PROBE_TTL:
        return hit[0]
    alive = False
    try:
        r = mb_requests.get(
            url,
            stream=True,
            timeout=2.5,
            headers={
                "User-Agent": "NASRadio/1.4",
                "Icy-MetaData": "0",
                "Range": "bytes=0-255",
            },
        )
        alive = r.status_code in (200, 206)
        r.close()
    except Exception as e:
        alive = "ICY" in str(e)
    _stream_probe_cache[url] = (alive, now)
    return alive


def _expand_station_query(q):
    """Resolve nicknames via the SAME artist_aliases table + trigram the music
    search uses, so a station search for 'vh' also searches radio-browser for
    'Van Halen'. Returns [original, ...resolved artist names]."""
    from app.utils import normalize_text_for_search
    terms = [q]
    nq = normalize_text_for_search(q)
    if not nq:
        return terms
    strip = "regexp_replace(LOWER({}), '[^a-z0-9 ]', '', 'g')"
    conn = None
    try:
        db = get_db()
        conn = db.get_connection()
        cur = db.get_cursor(conn)
        cur.execute(
            f"""SELECT DISTINCT a.name FROM artists a
                WHERE EXISTS (SELECT 1 FROM artist_aliases aa
                              WHERE aa.artist_id = a.id
                                AND {strip.format('aa.alias')} = %s)
                   OR similarity({strip.format('a.name')}, %s) > 0.6
                ORDER BY a.name LIMIT 2""",
            (nq, nq),
        )
        for row in cur.fetchall():
            nm = (row.get("name") or "").strip()
            if nm and normalize_text_for_search(nm) != nq and nm not in terms:
                terms.append(nm)
    except Exception as e:
        print(f"⚠️ [stations] alias expand failed: {e}")
    finally:
        if conn:
            conn.close()
    return terms[:3]


def _local_station_matches(q):
    """Fuzzy-match the user's own/featured stations (trigram + ILIKE)."""
    conn = None
    out = []
    try:
        db = get_db()
        conn = db.get_connection()
        cur = db.get_cursor(conn)
        cur.execute(
            """SELECT id, name, url, genre, description, homepage, favicon, source,
                      sort_order, COALESCE(play_count, 0) AS play_count
               FROM stations
               WHERE is_active = 1
                 AND (name ILIKE %s OR genre ILIKE %s
                      OR similarity(LOWER(name), LOWER(%s)) > 0.3)
               ORDER BY play_count DESC, name LIMIT 10""",
            (f"%{q}%", f"%{q}%", q),
        )
        out = [dict(r) for r in cur.fetchall()]
    except Exception as e:
        print(f"⚠️ [stations] local match failed: {e}")
    finally:
        if conn:
            conn.close()
    return out


# ─── Station relay: shared ring buffer + burst-on-connect ───────────
# Why not a dumb pass-through proxy: the cast receiver's Chrome refuses
# to start playing a live stream until it has banked a fat cushion of
# audio. Stations that send a big backlog burst on connect (SomaFM,
# Nightride) start in seconds; stations that trickle at exactly 1×
# realtime (Radio Art: 6+ min to start at 96kbps; Radio Caprice: ~2 min
# at 320kbps — both measured 2026-08-13) crawl or never start. So the
# backend plays Icecast itself: ONE upstream connection per station
# feeds a ring of the last ~60s, and every listener gets the ring
# dumped instantly (burst) before joining the live flow. First listener
# on a cold relay waits for a ~20s pre-buffer — a one-time cost, far
# better than 6 minutes — and everyone after that starts instantly.

_RELAY_RING_SECONDS = 60       # backlog kept/burst to new listeners
_RELAY_PREBUFFER_SECONDS = 20  # audio-seconds before first serve
_RELAY_PREBUFFER_MAX_WAIT = 25 # wall-clock cap on the pre-buffer wait
_RELAY_IDLE_SHUTDOWN = 600     # keep upstream warm 10 min after last listener
_RELAY_CHUNK = 4096

_station_relays = {}


class _StationRelay:
    def __init__(self, url):
        self.url = url
        self.ring = []            # list of chunks (greenlets never preempt mid-op)
        self.ring_bytes = 0
        self.bitrate_kbps = 128   # refined from icy-br when present
        self.ring_max = 128 * 1024 * _RELAY_RING_SECONDS // 8
        self.listeners = set()    # LightQueue per listener
        self.content_type = "audio/mpeg"
        self.alive = True
        self.started = False      # first upstream bytes seen
        self.last_listener_at = time.time()
        eventlet.spawn_n(self._pump)

    def _pump(self):
        upstream = None
        try:
            upstream = mb_requests.get(
                self.url, stream=True, timeout=15,
                headers={"User-Agent": "NASRadio/1.4", "Icy-MetaData": "0"},
            )
            if upstream.status_code not in (200, 206):
                print(f"📻 [relay] {self.url}: upstream HTTP {upstream.status_code}")
                return
            self.content_type = upstream.headers.get("Content-Type", "audio/mpeg")
            try:
                self.bitrate_kbps = int(
                    (upstream.headers.get("icy-br") or "128").split(",")[0])
            except Exception:
                pass
            self.ring_max = max(
                256 * 1024,
                self.bitrate_kbps * 1024 // 8 * _RELAY_RING_SECONDS)
            print(f"📻 [relay] {self.url}: pumping "
                  f"(type={self.content_type}, ~{self.bitrate_kbps}kbps)")
            for chunk in upstream.iter_content(chunk_size=_RELAY_CHUNK):
                if not chunk:
                    continue
                self.started = True
                self.ring.append(chunk)
                self.ring_bytes += len(chunk)
                while self.ring_bytes > self.ring_max:
                    self.ring_bytes -= len(self.ring.pop(0))
                for q in list(self.listeners):
                    try:
                        q.put_nowait(chunk)
                    except Exception:
                        # Listener fell hopelessly behind — cut them loose;
                        # their generator ends and the client reconnects
                        # (getting a fresh burst).
                        self.listeners.discard(q)
                if not self.listeners and (
                        time.time() - self.last_listener_at
                        > _RELAY_IDLE_SHUTDOWN):
                    print(f"📻 [relay] {self.url}: idle — shutting down")
                    break
        except Exception as e:
            print(f"📻 [relay] {self.url}: pump died: {e}")
        finally:
            self.alive = False
            if upstream is not None:
                try:
                    upstream.close()
                except Exception:
                    pass
            for q in list(self.listeners):
                try:
                    q.put_nowait(None)  # end-of-stream sentinel
                except Exception:
                    pass
            self.listeners.clear()


def _get_station_relay(url):
    relay = _station_relays.get(url)
    if relay is None or not relay.alive:
        relay = _StationRelay(url)
        _station_relays[url] = relay
    return relay


@api.route("/api/station-proxy", methods=["GET"])
def station_proxy():
    """Station relay for casting (see _StationRelay above).

    Solves two distinct TV problems at once: (1) http-only stations are
    mixed content on the HTTPS receiver page — the relay serves them
    over our HTTPS; (2) burst-less stations never satisfy the receiver
    Chrome's start-up buffer — the relay's ring provides the burst.
    Media-scoped ?token= accepted (auth.MEDIA_PATH_PREFIXES).
    """
    import ipaddress
    import socket as _socket
    from urllib.parse import urlparse as _urlparse
    from eventlet.queue import LightQueue

    url = (request.args.get("url") or "").strip()
    if not (url.startswith("http://") or url.startswith("https://")):
        return jsonify({"error": "http(s) url required"}), 400
    # SSRF guard: external radio servers only, never our own network.
    try:
        host = _urlparse(url).hostname or ""
        addr = ipaddress.ip_address(_socket.gethostbyname(host))
        if addr.is_private or addr.is_loopback or addr.is_link_local:
            return jsonify({"error": "private hosts not allowed"}), 400
    except Exception:
        return jsonify({"error": "unresolvable host"}), 400

    relay = _get_station_relay(url)
    relay.last_listener_at = time.time()

    # Pre-buffer gate: wait for enough banked audio to constitute a real
    # burst (or the wall-clock cap, or the ring already being warm).
    target_bytes = relay.bitrate_kbps * 1024 // 8 * _RELAY_PREBUFFER_SECONDS
    deadline = time.time() + _RELAY_PREBUFFER_MAX_WAIT
    while (relay.alive and relay.ring_bytes < target_bytes
           and time.time() < deadline):
        eventlet.sleep(0.2)
        target_bytes = relay.bitrate_kbps * 1024 // 8 * _RELAY_PREBUFFER_SECONDS
    if not relay.alive and not relay.started:
        return jsonify({"error": "station upstream unreachable"}), 502

    q = LightQueue(maxsize=512)

    def generate():
        # Snapshot-then-register: a chunk arriving in the gap is missed
        # (sub-second gap) — preferable to the duplicate a
        # register-then-snapshot order would produce.
        burst = list(relay.ring)
        relay.listeners.add(q)
        relay.last_listener_at = time.time()
        try:
            for chunk in burst:
                yield chunk
            while True:
                chunk = q.get()
                if chunk is None:
                    break
                yield chunk
        finally:
            relay.listeners.discard(q)
            relay.last_listener_at = time.time()

    burst_kb = relay.ring_bytes // 1024
    print(f"📻 [relay] listener joined {url} (burst={burst_kb}KB, "
          f"listeners={len(relay.listeners) + 1})")
    resp = Response(stream_with_context(generate()),
                    content_type=relay.content_type)
    resp.headers["Cache-Control"] = "no-cache"
    # Tell NPM's nginx not to buffer this response — latency matters.
    resp.headers["X-Accel-Buffering"] = "no"
    return resp


@api.route("/api/stations/search", methods=["GET"])
def search_stations():
    """Search radio-browser.info (names + tags) plus the user's own stations,
    with nickname/alias expansion ('vh' -> 'Van Halen') matching the music
    search. Normalized to our station shape (playable + saveable). requests is
    greened by eventlet and timeout-bounded, so it never wedges the hub."""
    q = (request.args.get("q") or "").strip()
    if len(q) < 2:
        return jsonify([])
    order_field, order_rev = _RB_SORT.get(
        (request.args.get("sort") or "popular").lower(), _RB_SORT["popular"])

    # Your own/featured stations always lead; radio-browser matches follow.
    local = _local_station_matches(q)
    local_urls = {(s.get("url") or "").strip() for s in local}

    terms = _expand_station_query(q)
    expansions = terms[1:]
    # Search resolved aliases FIRST (a 'vh' search should lead with Van Halen,
    # not 'KHVH'); skip the raw substring search when it's a tiny abbreviation
    # that already resolved to a name — its substring matches are just noise.
    plan = [(e, ("name",)) for e in expansions]
    if not (expansions and len(q) <= 3):
        plan.append((q, ("name", "tag")))

    headers = {"User-Agent": "NASRadio/1.4"}
    rb = {}  # url -> station
    rb_ok = False
    for server in _RADIO_BROWSER_SERVERS:
        try:
            for term, modes in plan:
                for mode in modes:
                    params = {
                        mode: term, "limit": 40, "hidebroken": "true",
                        "order": order_field, "reverse": str(order_rev).lower(),
                    }
                    r = mb_requests.get(
                        f"{server}/json/stations/search",
                        params=params, headers=headers, timeout=7,
                    )
                    if r.status_code != 200:
                        continue
                    rb_ok = True
                    for s in r.json():
                        st = _normalize_rb_station(s)
                        u = st["url"]
                        if u and u not in rb and u not in local_urls:
                            rb[u] = st
            if rb_ok:
                break
        except Exception as e:
            print(f"⚠️ [stations] radio-browser {server} search failed: {e}")
            continue

    rb_list = list(rb.values())
    if order_field == "name":
        rb_list.sort(key=lambda s: s["name"].lower())
    else:
        rb_list.sort(key=lambda s: s.get(order_field) or 0, reverse=True)

    # Drop dead streams BEFORE they reach the user (simpson1045 tapped a
    # top-ranked Radio Caprice entry whose server was stone dead from
    # here despite radio-browser's hidebroken flag). GreenPool → ~40
    # concurrent probes cost one 2.5s timeout of wall-clock worst case,
    # and the 1h cache makes repeat searches free. Cap the candidate list
    # first so a pathological merge can't open unbounded sockets (the
    # eventlet hub's select() dies near 512 fds — see fd-limit incident).
    rb_list = rb_list[:60]
    if rb_list:
        pool = eventlet.GreenPool(min(len(rb_list), 40))
        alive_flags = list(
            pool.imap(lambda s: _probe_stream_alive(s["url"]), rb_list))
        dropped = sum(1 for a in alive_flags if not a)
        if dropped:
            print(
                f"📻 [stations] search '{q}': dropped {dropped}/"
                f"{len(rb_list)} dead streams")
        rb_list = [s for s, a in zip(rb_list, alive_flags) if a]

    # Flag which results the user already has saved (by URL), so the app shows a
    # "saved" check even when the saved station didn't match the raw query.
    saved_urls = set()
    db = get_db()
    sconn = db.get_connection()
    try:
        scur = db.get_cursor(sconn)
        scur.execute("SELECT url FROM stations WHERE is_active = 1")
        saved_urls = {(r.get("url") or "").strip() for r in scur.fetchall()}
    except Exception:
        pass
    finally:
        sconn.close()
    for s in local:
        s["saved"] = True
    for s in rb_list:
        s["saved"] = s["url"] in saved_urls

    result = (local + rb_list)[:40]
    if result or rb_ok:
        return jsonify(result)
    return jsonify({"error": "Search unavailable"}), 503


@api.route("/api/stations/<int:station_id>/played", methods=["POST"])
def station_played(station_id):
    """Bump a station's play_count — drives the 'most listened' carousel."""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute(
            "UPDATE stations SET play_count = COALESCE(play_count, 0) + 1, "
            "last_played_at = CURRENT_TIMESTAMP WHERE id = %s",
            (station_id,),
        )
        conn.commit()
        return jsonify({"success": True})
    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/stations/<int:station_id>", methods=["DELETE"])
def delete_station(station_id):
    """Remove a station."""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute("DELETE FROM stations WHERE id = %s", (station_id,))
        conn.commit()
        return jsonify({"success": True})
    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/playlist/<int:playlist_id>", methods=["GET"])
def get_playlist(playlist_id):
    """Get a single playlist with all its songs"""
    playlists_manager = Playlists()
    playlist = playlists_manager.get_playlist(playlist_id)

    if playlist is None:
        return jsonify({"error": "Playlist not found"}), 404

    return jsonify(playlist)


@api.route("/api/playlist", methods=["POST"])
def create_playlist():
    """Create a new playlist"""
    playlists_manager = Playlists()
    data = request.get_json()

    name = data.get("name")
    description = data.get("description")

    if not name:
        return jsonify({"error": "name is required"}), 400

    result = playlists_manager.create_playlist(name, description)

    if result["success"]:
        safe_emit(
            "playlist_updated",
            {"action": "created", "playlist_id": result.get("playlist_id")},
        )
        return jsonify(result)
    else:
        return jsonify(result), 500


@api.route("/api/playlist/<int:playlist_id>", methods=["PUT"])
def update_playlist(playlist_id):
    """Update playlist name and/or description"""
    playlists_manager = Playlists()
    data = request.get_json()

    name = data.get("name")
    description = data.get("description")

    result = playlists_manager.update_playlist(playlist_id, name, description)

    if result["success"]:
        safe_emit("playlist_updated", {"action": "updated", "playlist_id": playlist_id})
        return jsonify(result)
    else:
        return jsonify(result), 500


@api.route("/api/playlist/<int:playlist_id>", methods=["DELETE"])
def delete_playlist(playlist_id):
    """Delete a playlist"""
    playlists_manager = Playlists()
    result = playlists_manager.delete_playlist(playlist_id)

    if result["success"]:
        safe_emit("playlist_updated", {"action": "deleted", "playlist_id": playlist_id})
        return jsonify(result)
    else:
        return jsonify(result), 500


@api.route("/api/playlist/<int:playlist_id>/add-episode", methods=["POST"])
def add_podcast_episode_to_playlist(playlist_id):
    """Add a podcast episode to a playlist.

    Thin wrapper over add_song so the frontend can pass an rss_episodes.id
    (what every podcast screen has on hand) without first resolving it to
    the mirrored songs row. Since Phase 1 every episode has a
    corresponding `songs` row with source_type='podcast'; we do the
    lookup server-side and delegate to the normal playlist-add logic.
    """
    playlists_manager = Playlists()
    data = request.get_json() or {}
    episode_id = data.get("episode_id")
    position = data.get("position")

    if not episode_id:
        return jsonify({"error": "episode_id is required"}), 400

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute(
            "SELECT id FROM songs WHERE podcast_episode_id = %s LIMIT 1",
            (episode_id,),
        )
        row = cursor.fetchone()
        if not row:
            return jsonify({
                "error": "Episode not yet mirrored to songs — refresh the feed or run migrate_podcasts_to_songs.py",
            }), 404
        song_id = row["id"]
    finally:
        conn.close()

    result = playlists_manager.add_song(playlist_id, song_id, position)
    if result.get("success"):
        safe_emit("playlist_updated", {"action": "episode_added", "playlist_id": playlist_id})
        return jsonify(result)
    return jsonify(result), 500


@api.route("/api/playlist/<int:playlist_id>/add", methods=["POST"])
def add_song_to_playlist(playlist_id):
    """Add a song to a playlist"""
    playlists_manager = Playlists()
    data = request.get_json()

    song_id = data.get("song_id")
    position = data.get("position")  # Optional: insert at specific position

    if not song_id:
        return jsonify({"error": "song_id is required"}), 400

    result = playlists_manager.add_song(playlist_id, song_id, position)

    if result["success"]:
        safe_emit(
            "playlist_updated", {"action": "song_added", "playlist_id": playlist_id}
        )
        return jsonify(result)
    else:
        return jsonify(result), 400


@api.route("/api/playlist/<int:playlist_id>/link", methods=["POST"])
def link_playlist_song(playlist_id):
    """Link an unmatched playlist entry to a song in the library"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    data = request.get_json()
    spotify_track_id = data.get("spotify_track_id")
    song_id = data.get("song_id")

    if not spotify_track_id or not song_id:
        return jsonify({"error": "spotify_track_id and song_id are required"}), 400

    try:
        # Update the playlist entry to link it to the local song — only if the
        # playlist belongs to the current user.
        cursor.execute(
            """
            UPDATE playlist_songs
            SET song_id = %s, manually_fixed = TRUE
            WHERE playlist_id = %s AND spotify_track_id = %s
              AND playlist_id IN (SELECT id FROM playlists WHERE user_id = %s)
            """,
            (song_id, playlist_id, spotify_track_id, auth.current_user_id()),
        )

        if cursor.rowcount == 0:
            conn.close()
            return jsonify({"error": "Playlist entry not found"}), 404

        conn.commit()
        conn.close()

        return jsonify({"success": True, "message": "Song linked successfully"})
    except Exception as e:
        conn.close()
        return _error_response(e)


@api.route("/api/playlist/<int:playlist_id>/remove", methods=["POST"])
def remove_song_from_playlist(playlist_id):
    """Remove a song from a playlist"""
    playlists_manager = Playlists()
    data = request.get_json()

    song_id = data.get("song_id")

    if not song_id:
        return jsonify({"error": "song_id is required"}), 400

    result = playlists_manager.remove_song(playlist_id, song_id)

    if result["success"]:
        safe_emit(
            "playlist_updated", {"action": "song_removed", "playlist_id": playlist_id}
        )
        return jsonify(result)
    else:
        return jsonify(result), 400


@api.route("/api/playlist/<int:playlist_id>/reorder", methods=["POST"])
def reorder_playlist_song(playlist_id):
    """Reorder a song within a playlist"""
    playlists_manager = Playlists()
    data = request.get_json()

    song_id = data.get("song_id")
    new_position = data.get("new_position")

    if not song_id or new_position is None:
        return jsonify({"error": "song_id and new_position are required"}), 400

    result = playlists_manager.reorder_songs(playlist_id, song_id, new_position)

    if result["success"]:
        return jsonify(result)
    else:
        return jsonify(result), 400


@api.route("/api/playlist/<int:playlist_id>/add-songs", methods=["POST"])
def add_songs_to_playlist(playlist_id):
    """Add multiple songs to a playlist at once"""
    playlists_manager = Playlists()
    data = request.get_json()

    song_ids = data.get("song_ids", [])
    position = data.get("position")  # Optional: insert at specific position

    if not song_ids:
        return jsonify({"error": "song_ids is required"}), 400

    result = playlists_manager.add_songs(playlist_id, song_ids, position)

    if result["success"]:
        safe_emit(
            "playlist_updated", {"action": "songs_added", "playlist_id": playlist_id}
        )
        return jsonify(result)
    else:
        return jsonify(result), 400


@api.route("/api/playlist/<int:playlist_id>/bulk-reorder", methods=["POST"])
def bulk_reorder_playlist_songs(playlist_id):
    """Move multiple songs to a new position in a playlist"""
    playlists_manager = Playlists()
    data = request.get_json()

    song_ids = data.get("song_ids", [])
    new_position = data.get("new_position")

    if not song_ids or new_position is None:
        return jsonify({"error": "song_ids and new_position are required"}), 400

    result = playlists_manager.bulk_reorder_songs(playlist_id, song_ids, new_position)

    if result["success"]:
        return jsonify(result)
    else:
        return jsonify(result), 400


# ========================
# Spotify Import Endpoint
# ========================


@api.route("/api/spotify/import", methods=["POST"])
def import_spotify_playlist():
    """Import a playlist from Spotify"""
    data = request.get_json()
    playlist_url = data.get("playlist_url")
    create_playlist = data.get("create_playlist", True)
    existing_playlist_id = data.get("existing_playlist_id")  # NEW
    skip_existing = data.get("skip_existing", False)  # NEW

    if not playlist_url:
        return jsonify({"error": "playlist_url is required"}), 400

    importer = SpotifyImporter()
    result = importer.import_playlist(
        playlist_url,
        create_playlist,
        existing_playlist_id=existing_playlist_id,
        skip_existing=skip_existing,
    )

    if result["success"]:
        return jsonify(result)
    else:
        return jsonify(result), 500


@api.route("/api/playlist/import-m3u8", methods=["POST"])
def import_m3u8_playlist():
    """Import a playlist from an uploaded .m3u8 file.

    Accepts either a multipart file upload (field name 'file') or a JSON body
    with a 'content' string. Matches tracks against the library the same way the
    Spotify import does; unmatched tracks become missing entries.
    """
    from app.m3u8_import import M3U8Importer

    content = None
    filename = None

    if request.files.get("file"):
        upload = request.files["file"]
        filename = upload.filename
        content = upload.read().decode("utf-8", errors="replace")
        create_playlist = request.form.get("create_playlist", "true").lower() != "false"
        existing_playlist_id = request.form.get("existing_playlist_id")
        existing_playlist_id = int(existing_playlist_id) if existing_playlist_id else None
        skip_existing = request.form.get("skip_existing", "false").lower() == "true"
    else:
        data = request.get_json(silent=True) or {}
        content = data.get("content")
        filename = data.get("filename")
        create_playlist = data.get("create_playlist", True)
        existing_playlist_id = data.get("existing_playlist_id")
        skip_existing = data.get("skip_existing", False)

    if not content:
        return jsonify({"error": "No playlist content provided"}), 400

    importer = M3U8Importer()
    result = importer.import_m3u8(
        content,
        filename=filename,
        create_local_playlist=create_playlist,
        existing_playlist_id=existing_playlist_id,
        skip_existing=skip_existing,
    )

    if result["success"]:
        return jsonify(result)
    else:
        return jsonify(result), 500


@api.route("/api/musicbrainz/track-releases", methods=["GET"])
def musicbrainz_track_releases():
    """List the albums (release-groups) a track appears on, each tagged with a
    category (Studio Album / Compilation / Live / ...), for the missing-track
    album picker. Lets the user choose which release to search Prowlarr for."""
    from app.m3u8_import import M3U8Importer

    artist = request.args.get("artist", "").strip()
    track = request.args.get("track", "").strip()
    if not artist or not track:
        return jsonify({"error": "artist and track are required"}), 400

    importer = M3U8Importer()
    # MusicBrainz call is blocking HTTP — run off the eventlet hub
    candidates = eventlet.tpool.execute(
        importer.list_track_release_groups, track, artist
    )
    return jsonify({"success": True, "candidates": candidates})


# ========================
# Playback State Endpoints
# ========================


@api.route("/api/playback-state/<device_id>", methods=["GET"])
def get_playback_state(device_id):
    """Get playback state for a device"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        cursor.execute(
            "SELECT * FROM playback_state WHERE device_id = %s", (device_id,)
        )
        state = cursor.fetchone()

        if not state:
            return jsonify({"exists": False})

        return jsonify(
            {
                "exists": True,
                "device_id": state["device_id"],
                "device_name": state["device_name"],
                "current_song_id": state["current_song_id"],
                "position_ms": state["position_ms"],
                "queue_json": state["queue_json"],
                "original_queue_json": state["original_queue_json"] or "[]",
                "queue_index": state["queue_index"],
                "shuffle_mode": state["shuffle_mode"],
                "repeat_mode": state["repeat_mode"],
                "volume": state["volume"],
                "is_playing": state["is_playing"],
                "is_active": state["is_active"],
                "updated_at": state["updated_at"],
                # Source context — "Playing from simpson1045's Mix" survives
                # across Resume-from-device.
                "source_type": state.get("source_type"),
                "source_id": state.get("source_id"),
                "source_name": state.get("source_name"),
            }
        )
    finally:
        conn.close()


@api.route("/api/playback-state/<device_id>", methods=["PUT"])
def save_playback_state(device_id):
    """Save/update playback state for a device"""
    data = request.get_json()

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Check if device exists
        cursor.execute(
            "SELECT id FROM playback_state WHERE device_id = %s", (device_id,)
        )
        exists = cursor.fetchone()

        if exists:
            # Update existing
            cursor.execute(
                """
                UPDATE playback_state SET
                    device_name = COALESCE(%s, device_name),
                    current_song_id = %s,
                    position_ms = %s,
                    queue_json = %s,
                    original_queue_json = %s,
                    queue_index = %s,
                    shuffle_mode = %s,
                    repeat_mode = %s,
                    volume = %s,
                    is_playing = %s,
                    is_active = %s,
                    source_type = %s,
                    source_id = %s,
                    source_name = %s,
                    updated_at = CURRENT_TIMESTAMP
                WHERE device_id = %s
                """,
                (
                    data.get("device_name"),
                    data.get("current_song_id"),
                    data.get("position_ms", 0),
                    data.get("queue_json", "[]"),
                    data.get("original_queue_json", "[]"),
                    data.get("queue_index", 0),
                    data.get("shuffle_mode", 0),
                    data.get("repeat_mode", 0),
                    data.get("volume", 1.0),
                    data.get("is_playing", 0),
                    data.get("is_active", 0),
                    data.get("source_type"),
                    data.get("source_id"),
                    data.get("source_name"),
                    device_id,
                ),
            )
        else:
            # Insert new
            cursor.execute(
                """
                INSERT INTO playback_state (
                    device_id, device_name, current_song_id, position_ms,
                    queue_json, original_queue_json, queue_index, shuffle_mode, repeat_mode,
                    volume, is_playing, is_active,
                    source_type, source_id, source_name
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                """,
                (
                    device_id,
                    data.get("device_name", "Unknown Device"),
                    data.get("current_song_id"),
                    data.get("position_ms", 0),
                    data.get("queue_json", "[]"),
                    data.get("original_queue_json", "[]"),
                    data.get("queue_index", 0),
                    data.get("shuffle_mode", 0),
                    data.get("repeat_mode", 0),
                    data.get("volume", 1.0),
                    data.get("is_playing", 0),
                    data.get("is_active", 0),
                    data.get("source_type"),
                    data.get("source_id"),
                    data.get("source_name"),
                ),
            )

        conn.commit()

        # Broadcast state change to other devices
        safe_emit("playback_state_changed", {
            "device_id": device_id,
            "device_name": data.get("device_name"),
            "current_song_id": data.get("current_song_id"),
            "position_ms": data.get("position_ms", 0),
            "is_playing": data.get("is_playing", 0),
            "is_active": data.get("is_active", 0),
        })

        return jsonify({"success": True})
    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/devices", methods=["GET"])
def get_devices():
    """Get all registered devices with enriched playback info"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        cursor.execute(
            """
            SELECT ps.device_id, ps.device_name, ps.is_playing, ps.is_active,
                   ps.updated_at, ps.current_song_id, ps.position_ms, ps.queue_index,
                   ps.volume, ps.shuffle_mode, ps.repeat_mode,
                   ps.group_id, ps.group_role, ps.controlled_by,
                   s.title AS song_title, s.duration AS song_duration,
                   s.file_format, s.is_hdcd, s.audio_codec, s.audio_channels, s.is_atmos,
                   ar.name AS artist_name, al.id AS album_id, al.title AS album_title
            FROM playback_state ps
            LEFT JOIN songs s ON ps.current_song_id = s.id
            LEFT JOIN albums al ON s.album_id = al.id
            LEFT JOIN artists ar ON s.artist_id = ar.id
            ORDER BY ps.updated_at DESC
            """
        )
        devices = [dict(row) for row in cursor.fetchall()]

        # Tag each device with whether it currently has a LIVE device-sync
        # socket connection. The list above is pure DB history (every device
        # that ever reported state), which is why stale/offline devices linger.
        # Remote control only works against live devices, so the UI needs to
        # know which is which — and a recency hint for sorting/cleanup.
        from app.device_sync import connected_devices
        live_ids = set(connected_devices.keys())
        for d in devices:
            d["connected"] = d["device_id"] in live_ids
        # Live devices first, then most-recently-seen.
        devices.sort(key=lambda d: (not d["connected"], ), reverse=False)

        return jsonify(devices)
    finally:
        conn.close()


@api.route("/api/devices/<device_id>", methods=["DELETE"])
def delete_device(device_id):
    """Remove a device from the devices list"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        cursor.execute(
            "DELETE FROM playback_state WHERE device_id = %s", (device_id,)
        )
        conn.commit()
        if cursor.rowcount > 0:
            return jsonify({"success": True, "message": "Device removed"})
        else:
            return jsonify({"error": "Device not found"}), 404
    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


# ========================
# Lyrics Endpoints
# ========================


@api.route("/api/lyrics/<int:song_id>", methods=["GET"])
def get_lyrics(song_id):
    """Get lyrics for a song, fetching from LRCLIB if not cached.

    The DB connection is released before the LRCLIB HTTP call and
    reacquired only for the INSERT. Holding a pooled conn across a
    10s external request would drain the pool under rapid song
    changes (e.g. Chromecast flipping tracks).
    """
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        cursor.execute(
            "SELECT synced_lyrics, plain_lyrics, source FROM lyrics WHERE song_id = %s",
            (song_id,),
        )
        cached = cursor.fetchone()

        if cached:
            return jsonify(
                {
                    "success": True,
                    "synced_lyrics": cached["synced_lyrics"],
                    "plain_lyrics": cached["plain_lyrics"],
                    "source": cached["source"],
                    "cached": True,
                }
            )

        cursor.execute(
            """
            SELECT songs.title, artists.name as artist_name, songs.duration
            FROM songs
            JOIN artists ON songs.artist_id = artists.id
            WHERE songs.id = %s
            """,
            (song_id,),
        )
        song = cursor.fetchone()

        if not song:
            return jsonify({"success": False, "error": "Song not found"}), 404

        artist_name = song["artist_name"]
        track_title = song["title"]
        duration = song["duration"]
    finally:
        conn.close()
        conn = None

    try:
        response = mb_requests.get(
            "https://lrclib.net/api/get",
            params={
                "artist_name": artist_name,
                "track_name": track_title,
                "duration": duration,
            },
            headers={
                "User-Agent": "NASRadio/1.0 (https://github.com/simpson1045/nasradio)"
            },
            timeout=10,
        )
    except mb_requests.exceptions.Timeout:
        return jsonify({"success": False, "error": "LRCLIB timeout"})
    except mb_requests.exceptions.RequestException as e:
        return _error_response(e)

    if response.status_code != 200:
        return jsonify({"success": False, "error": "No lyrics found"})

    data = response.json()
    synced = data.get("syncedLyrics")
    plain = data.get("plainLyrics")

    if not (synced or plain):
        return jsonify({"success": False, "error": "No lyrics found"})

    conn = db.get_connection()
    try:
        cursor = db.get_cursor(conn)
        cursor.execute(
            """
            INSERT INTO lyrics (song_id, synced_lyrics, plain_lyrics, source)
            VALUES (%s, %s, %s, 'lrclib')
            """,
            (song_id, synced, plain),
        )
        conn.commit()
    finally:
        conn.close()

    return jsonify(
        {
            "success": True,
            "synced_lyrics": synced,
            "plain_lyrics": plain,
            "source": "lrclib",
            "cached": False,
        }
    )


@api.route("/api/recently-added", methods=["GET"])
def get_recently_added():
    """Get music albums added in the last 30 days.

    Podcast-feed albums are filtered out — they show up in the podcast
    section instead. A music album qualifies here if it has at least
    one local song.
    """
    days = request.args.get("days", 30, type=int)
    limit = request.args.get("limit", 50, type=int)

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        cursor.execute(
            """
            SELECT albums.*, artists.name as artist_name,
                   COUNT(songs.id) as song_count
            FROM albums
            JOIN artists ON albums.artist_id = artists.id
            LEFT JOIN songs ON songs.album_id = albums.id
            WHERE albums.created_at >= CURRENT_TIMESTAMP - INTERVAL '%s days'
              AND EXISTS (
                  SELECT 1 FROM songs s2
                  WHERE s2.album_id = albums.id
                    AND s2.source_type = 'local'
              )
            GROUP BY albums.id, artists.name
            ORDER BY albums.created_at DESC
            LIMIT %s
            """,
            (days, limit),
        )
        albums = [dict(row) for row in cursor.fetchall()]

        return jsonify({"albums": albums, "count": len(albums), "days": days})
    finally:
        conn.close()


@api.route("/api/song/<int:song_id>/stats", methods=["GET"])
def get_song_stats(song_id):
    """Get detailed stats for a song"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Get song details
        cursor.execute(
            """
            SELECT songs.*, albums.title as album_title, artists.name as artist_name
            FROM songs
            JOIN albums ON songs.album_id = albums.id
            JOIN artists ON songs.artist_id = artists.id
            WHERE songs.id = %s
            """,
            (song_id,),
        )
        song = cursor.fetchone()
        if not song:
            return jsonify({"error": "Song not found"}), 404

        # Get play count
        cursor.execute(
            "SELECT COUNT(*) as play_count FROM play_history WHERE song_id = %s",
            (song_id,),
        )
        play_count = cursor.fetchone()["play_count"]

        # Get last played
        cursor.execute(
            "SELECT played_at FROM play_history WHERE song_id = %s ORDER BY played_at DESC LIMIT 1",
            (song_id,),
        )
        last_played_row = cursor.fetchone()
        last_played = last_played_row["played_at"] if last_played_row else None

        # Get first played
        cursor.execute(
            "SELECT played_at FROM play_history WHERE song_id = %s ORDER BY played_at ASC LIMIT 1",
            (song_id,),
        )
        first_played_row = cursor.fetchone()
        first_played = first_played_row["played_at"] if first_played_row else None

        return jsonify(
            {
                "id": song["id"],
                "title": song["title"],
                "artist_name": song["artist_name"],
                "album_title": song["album_title"],
                "track_number": song["track_number"],
                "disc_number": song["disc_number"],
                "duration": song["duration"],
                "file_path": song["file_path"],
                "file_size": song["file_size"],
                "bitrate": song["bitrate"],
                "created_at": song["created_at"],
                "play_count": play_count,
                "last_played": last_played,
                "first_played": first_played,
            }
        )
    finally:
        conn.close()


# ========================
# Operations Status (Unified)
# ========================


@api.route("/api/operations/status", methods=["GET"])
def get_all_operations_status():
    """Get status of all long-running operations"""
    from app.operation_state import OperationState
    from app.audio_analysis import check_essentia_service, get_analysis_stats

    op_state = OperationState(config.DATABASE_URL)
    states = op_state.get_all_states()

    # Add extra info to audio_analysis
    states["audio_analysis"]["service_online"] = check_essentia_service()
    stats = get_analysis_stats(config.DATABASE_URL)
    states["audio_analysis"]["analyzed_songs"] = stats["analyzed_songs"]
    states["audio_analysis"]["total_songs"] = stats["total_songs"]
    states["audio_analysis"]["coverage_percent"] = stats["coverage_percent"]

    return jsonify(states)


# ========================
# Audio Analysis Endpoints
# ========================


@api.route("/api/analysis/status", methods=["GET"])
def get_analysis_status():
    """Get audio analysis status"""
    from app.audio_analysis import get_analysis_state

    state = get_analysis_state(config.DATABASE_URL)
    return jsonify(state)


@api.route("/api/analysis/start", methods=["POST"])
@auth.require_admin
def start_audio_analysis():
    """Start audio analysis.

    Always force-restarts Essentia first — kill any existing process
    (which may be hung even though /health timed out instead of
    refusing) and spawn a fresh one. Then start the batch. This is the
    behavior simpson1045 asked for after we found that the prior "check then
    start" path kept piling fresh batches onto a deadlocked Essentia,
    exhausting the DB connection pool and forcing manual recovery.

    Progress is already persisted to the DB row-by-row, so a kill +
    restart loses nothing — the next batch resumes from the last
    analyzed song.
    """
    from app.audio_analysis import start_analysis_background
    from app.service_restart import force_restart_essentia

    restart_result = force_restart_essentia()
    if not restart_result.get("success"):
        return jsonify({
            "success": False,
            "error": "Essentia restart failed: " + restart_result.get(
                "message", restart_result.get("error", "unknown")
            ),
            "restart_result": restart_result,
        }), 503

    data = request.get_json(silent=True) or {}
    force_reanalyze = data.get("force", False)

    result = start_analysis_background(config.DATABASE_URL, force_reanalyze)
    # Surface the restart info so the UI can show "service was restarted (killed
    # N stale processes)" in the response toast.
    result["restart_result"] = restart_result
    return jsonify(result)


@api.route("/api/analysis/cancel", methods=["POST"])
@auth.require_admin
def cancel_audio_analysis():
    """Cancel audio analysis"""
    from app.audio_analysis import cancel_analysis

    result = cancel_analysis(config.DATABASE_URL)
    return jsonify(result)


@api.route("/api/spectral/status", methods=["GET"])
def get_spectral_status():
    """Spectral transcode-scan state + coverage/suspect stats"""
    from app.spectral_analysis import get_spectral_state

    return jsonify(get_spectral_state(config.DATABASE_URL))


@api.route("/api/spectral/start", methods=["POST"])
def start_spectral_scan():
    """Start the library-wide spectral transcode scan (background).

    Resumable: only FLACs without spectral_analyzed_at are queued.
    Pass {"force": true} to rescan everything.
    """
    from app.spectral_analysis import start_spectral_background

    data = request.get_json(silent=True) or {}
    return jsonify(
        start_spectral_background(config.DATABASE_URL, data.get("force", False))
    )


@api.route("/api/spectral/cancel", methods=["POST"])
def cancel_spectral_scan():
    """Cancel a running spectral scan (takes effect at the next chunk)"""
    from app.spectral_analysis import cancel_spectral

    return jsonify(cancel_spectral(config.DATABASE_URL))


@api.route("/api/spectral/suspects", methods=["GET"])
def get_spectral_suspects():
    """All songs flagged as suspected transcodes, worst cutoff first"""
    from app.spectral_analysis import get_suspects

    return jsonify(get_suspects(config.DATABASE_URL))


@api.route("/api/essentia/start", methods=["POST"])
@auth.require_admin
def start_essentia_service():
    """Start the Essentia ML service (mounts NAS share in WSL2, launches
    Essentia, polls until it's healthy).

    Returns when the service is online or the timeout expires. The launcher
    bat is invoked detached so Essentia keeps running after this request
    returns. The mount step inside start.sh is idempotent — safe to call
    even if WSL2 already has the share mounted.
    """
    import subprocess
    import time
    import os
    from app.audio_analysis import check_essentia_service

    bat_path = os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
        "start_essentia.bat",
    )
    if not os.path.exists(bat_path):
        return jsonify({
            "success": False,
            "error": f"start_essentia.bat not found at {bat_path}",
        }), 500

    if check_essentia_service():
        return jsonify({
            "success": True,
            "message": "Essentia already online",
            "already_running": True,
        })

    # Spawn detached so Essentia survives this request.
    # CREATE_NEW_PROCESS_GROUP + DETACHED_PROCESS keeps it independent of Flask.
    # CREATE_NO_WINDOW suppresses the cmd/.bat console window that
    # would otherwise flash onscreen on every spawn (annoying on
    # cold-start when the watchdog also fires).
    DETACHED_PROCESS = 0x00000008
    CREATE_NEW_PROCESS_GROUP = 0x00000200
    CREATE_NO_WINDOW = 0x08000000
    try:
        subprocess.Popen(
            [bat_path, "--scheduled"],
            creationflags=DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            close_fds=True,
        )
    except Exception as e:
        return jsonify({
            "success": False,
            "error": f"Failed to spawn launcher: {e}",
        }), 500

    # Poll Essentia health for up to 90s (mount can take a few retries on
    # WSL2 cold start; ML model load adds ~10-20s).
    deadline = time.time() + 90
    while time.time() < deadline:
        if check_essentia_service():
            return jsonify({
                "success": True,
                "message": "Essentia online",
                "elapsed_seconds": int(90 - (deadline - time.time())),
            })
        time.sleep(2)

    return jsonify({
        "success": False,
        "error": (
            "Essentia did not come online within 90s. Check that the NAS "
            "share can be mounted in WSL2 (see ~/.nas-credentials)."
        ),
    }), 504


@api.route("/api/essentia/force-restart", methods=["POST"])
@auth.require_admin
def force_restart_essentia_route():
    """Kill any running WSL Essentia process and spawn a fresh instance.

    Unlike /api/essentia/start (which is a no-op when Essentia answers
    "alive"), this endpoint ALWAYS kills + restarts. Use when the
    existing Essentia is hung — it answers /health slowly or never,
    /api/essentia/start sees it "up" and refuses to restart, and the
    backend keeps firing analysis at a dead process.
    """
    from app.service_restart import force_restart_essentia
    result = force_restart_essentia()
    status = 200 if result.get("success") else 504
    return jsonify(result), status


@api.route("/api/transcode/force-restart-service", methods=["POST"])
@auth.require_admin
def force_restart_transcode_service_route():
    """Kill any running WSL transcode service and spawn a fresh instance.

    Distinct from /api/transcode/start (which kicks off the local-ffmpeg
    batch). This restarts the desktop transcode service in WSL on :5006.
    """
    from app.service_restart import force_restart_transcode_service
    result = force_restart_transcode_service()
    status = 200 if result.get("success") else 504
    return jsonify(result), status


@api.route("/api/analysis/song/<int:song_id>", methods=["GET"])
def get_song_analysis_route(song_id):
    """Get analysis for a specific song"""
    from app.audio_analysis import get_song_analysis

    analysis = get_song_analysis(config.DATABASE_URL, song_id)

    if not analysis:
        return jsonify({"error": "No analysis found for this song"}), 404

    return jsonify(analysis)


@api.route("/api/analysis/song/<int:song_id>", methods=["POST"])
def analyze_single_song(song_id):
    """Analyze a single song on demand"""
    from app.audio_analysis import analyze_song, store_analysis, check_essentia_service

    if not check_essentia_service():
        return (
            jsonify({"success": False, "error": "Essentia service is not available"}),
            503,
        )

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    cursor.execute("SELECT file_path, title FROM songs WHERE id = %s", (song_id,))
    row = cursor.fetchone()
    conn.close()

    if not row:
        return jsonify({"error": "Song not found"}), 404

    analysis = analyze_song(row["file_path"])

    if analysis and "error" not in analysis:
        store_analysis(config.DATABASE_URL, song_id, analysis)
        return jsonify(
            {
                "success": True,
                "song_id": song_id,
                "title": row["title"],
                "analysis": analysis,
            }
        )
    else:
        return (
            jsonify(
                {
                    "success": False,
                    "error": (
                        analysis.get("error", "Analysis failed")
                        if analysis
                        else "Analysis failed"
                    ),
                }
            ),
            500,
        )


# ========================
# Transcode Service
# ========================


@api.route("/api/transcode/status", methods=["GET"])
def get_transcode_status_route():
    """Get transcode status and batch progress."""
    # Count cached files
    music_lib = Config.MUSIC_LIBRARY_PATH
    cache_dir = os.path.join(music_lib, ".transcode_cache")
    cached_count = 0
    if os.path.exists(cache_dir):
        cached_count = len([f for f in os.listdir(cache_dir) if f.endswith(('.m4a', '.mp3'))])

    # Get total songs from DB
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    cursor.execute("SELECT COUNT(*) as count FROM songs")
    total_songs = cursor.fetchone()["count"]
    conn.close()

    elapsed = 0
    if _batch_transcode["started_at"] and _batch_transcode["running"]:
        elapsed = time.time() - _batch_transcode["started_at"]

    result = {
        "service_online": True,  # Always online — using local ffmpeg
        "cached_count": cached_count,
        "total_songs": total_songs,
        "status": "running" if _batch_transcode["running"] else "idle",
        "batch_total": _batch_transcode["total"],
        "batch_done": _batch_transcode["done"],
        "batch_failed": _batch_transcode["failed"],
        "batch_skipped": _batch_transcode["skipped"],
        "batch_workers": _batch_transcode["workers"],
        "elapsed_seconds": round(elapsed),
    }

    return jsonify(result)


# Batch transcode state (module-level so status endpoint can read it)
_batch_transcode = {
    "running": False,
    "cancel_requested": False,
    "total": 0,
    "done": 0,
    "failed": 0,
    "skipped": 0,
    "workers": 0,
    "started_at": None,
}


def _start_local_batch_transcode(quality="high", workers=4):
    """Start batch transcoding using local ffmpeg with parallel workers.
    Transcodes all lossless songs that don't already have a cached file.
    Returns a dict with success status and details.
    Can be called from the API route or automatically after scan.
    """
    if _batch_transcode["running"]:
        return {
            "success": False,
            "error": "Batch transcode already running",
            "progress": _batch_transcode,
        }

    workers = max(1, min(workers, 16))  # Clamp 1-16

    # Get all lossless songs from DB
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    cursor.execute("""
        SELECT id, file_path, is_hdcd
        FROM songs
        WHERE LOWER(SUBSTRING(file_path FROM '\\.([^.]+)$')) IN ('flac', 'wav', 'aiff', 'ape', 'wv')
        ORDER BY id
    """)
    all_songs = cursor.fetchall()
    conn.close()

    # Filter to only songs that need transcoding (no cache file yet)
    songs_to_transcode = []
    skipped = 0
    for song in all_songs:
        fmt, bitrate, cache_file, temp_file, transcode_mime = _get_transcode_paths(song["id"], quality)
        if os.path.exists(cache_file):
            skipped += 1
        else:
            songs_to_transcode.append(song)

    if not songs_to_transcode:
        return {
            "success": True,
            "message": f"All {skipped} lossless songs already cached!",
            "total": 0,
            "skipped": skipped,
        }

    # Reset state
    _batch_transcode.update({
        "running": True,
        "cancel_requested": False,
        "total": len(songs_to_transcode),
        "done": 0,
        "failed": 0,
        "skipped": skipped,
        "workers": workers,
        "started_at": time.time(),
    })

    def worker(song_queue):
        """Worker that pulls songs from the queue and transcodes them."""
        while not _batch_transcode["cancel_requested"]:
            try:
                song = song_queue.pop(0)
            except IndexError:
                break  # Queue empty
            is_hdcd = song.get("is_hdcd") == 1
            cache_file, mime = _transcode_to_cache(song["file_path"], song["id"], quality, is_hdcd=is_hdcd)
            if cache_file:
                _batch_transcode["done"] += 1
            else:
                _batch_transcode["failed"] += 1

        if _batch_transcode["cancel_requested"]:
            print(f"🛑 [batch-transcode] Worker exiting — cancel requested")

    def run_batch():
        """Spawn workers and wait for them all to finish."""
        song_queue = list(songs_to_transcode)  # Shared mutable list
        print(f"🚀 [batch-transcode] Starting {workers} workers for {len(song_queue)} songs (quality={quality})")

        threads = []
        for i in range(workers):
            t = eventlet.spawn(worker, song_queue)
            threads.append(t)

        for t in threads:
            t.wait()

        elapsed = time.time() - _batch_transcode["started_at"]
        done = _batch_transcode["done"]
        failed = _batch_transcode["failed"]
        cancelled = _batch_transcode["cancel_requested"]
        status = "cancelled" if cancelled else "complete"
        print(f"{'🛑' if cancelled else '✅'} [batch-transcode] {status}: {done} transcoded, {failed} failed in {elapsed:.0f}s")
        _batch_transcode["running"] = False

    eventlet.spawn_n(run_batch)

    return {
        "success": True,
        "message": f"Batch transcode started: {len(songs_to_transcode)} songs with {workers} workers",
        "total": len(songs_to_transcode),
        "skipped": skipped,
        "workers": workers,
        "quality": quality,
    }


@api.route("/api/transcode/start", methods=["POST"])
@auth.require_admin
def start_transcode_route():
    """Start batch transcoding using local ffmpeg with parallel workers.

    Always force-restart-style on entry: cancel any running batch, kill
    orphan ffmpeg.exe workers (identified by '.transcode_cache' in
    their command line so we don't touch on-demand stream transcodes),
    and reset the _batch_transcode state dict. Then start the new
    batch. This mirrors the Essentia force-restart behavior and
    eliminates the pile-on scenario where a stale 409 "already
    running" state blocked the user from kicking off a fresh batch.
    """
    from app.service_restart import kill_local_batch_ffmpeg

    cancel_was_running = _batch_transcode["running"]
    if cancel_was_running:
        _batch_transcode["cancel_requested"] = True

    killed = kill_local_batch_ffmpeg()

    # Reset state so the new batch starts clean. Workers reading old
    # state would see cancel_requested=True from the line above and
    # exit immediately, but we want a known-good start.
    _batch_transcode.update({
        "running": False,
        "cancel_requested": False,
        "total": 0,
        "done": 0,
        "failed": 0,
        "skipped": 0,
        "workers": 0,
        "started_at": None,
    })

    if cancel_was_running or killed > 0:
        # Give any in-flight subprocess.run() calls a moment to notice
        # their child died and unwind, otherwise the new batch can race
        # with workers still cleaning up.
        time.sleep(1)

    quality = request.json.get("quality", "high") if request.is_json else "high"
    workers = int(request.json.get("workers", 8)) if request.is_json else 8

    result = _start_local_batch_transcode(quality=quality, workers=workers)
    result["pre_start_cleanup"] = {
        "cancelled_previous_batch": cancel_was_running,
        "killed_orphan_ffmpeg": killed,
    }
    status_code = 409 if not result.get("success") and "already running" in result.get("error", "") else 200
    return jsonify(result), status_code


@api.route("/api/transcode/cancel", methods=["POST"])
@auth.require_admin
def cancel_transcode_route():
    """Cancel the running batch transcode."""
    if not _batch_transcode["running"]:
        return jsonify({"success": False, "error": "No batch transcode running"}), 400

    _batch_transcode["cancel_requested"] = True
    return jsonify({
        "success": True,
        "message": "Cancel requested — workers will stop after current song",
        "progress": _batch_transcode,
    })


# ========================
# Query by Audio Features
# ========================


@api.route("/api/songs/by-mood", methods=["GET"])
def get_songs_by_mood():
    """Get songs filtered by mood"""
    mood = request.args.get("mood")
    min_score = request.args.get("min_score", 0.7, type=float)
    limit = request.args.get("limit", 50, type=int)

    valid_moods = [
        "happy",
        "sad",
        "aggressive",
        "relaxed",
        "acoustic",
        "electronic",
        "danceability",
        "instrumental",
        "party",
        "tonal",
        "bright",
    ]

    if mood not in valid_moods:
        return jsonify({"error": f"Invalid mood. Valid: {valid_moods}"}), 400

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    column = f"mood_{mood}"
    cursor.execute(
        f"""
        SELECT s.id, s.title, s.duration, s.file_path,
               a.name as artist_name, al.title as album_title, al.artwork_path,
               sa.{column} as mood_score, sa.bpm, sa.musical_key, sa.musical_scale
        FROM songs s
        JOIN song_analysis sa ON s.id = sa.song_id
        JOIN artists a ON s.artist_id = a.id
        JOIN albums al ON s.album_id = al.id
        WHERE sa.{column} >= %s
        ORDER BY sa.{column} DESC
        LIMIT %s
    """,
        (min_score, limit),
    )

    songs = [dict(row) for row in cursor.fetchall()]
    conn.close()

    return jsonify(songs)


@api.route("/api/songs/by-bpm", methods=["GET"])
def get_songs_by_bpm():
    """Get songs in BPM range"""
    min_bpm = request.args.get("min", 0, type=float)
    max_bpm = request.args.get("max", 300, type=float)
    limit = request.args.get("limit", 50, type=int)

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    cursor.execute(
        """
        SELECT s.id, s.title, s.duration, s.file_path,
               a.name as artist_name, al.title as album_title, al.artwork_path,
               sa.bpm, sa.musical_key, sa.musical_scale, sa.mood_danceability
        FROM songs s
        JOIN song_analysis sa ON s.id = sa.song_id
        JOIN artists a ON s.artist_id = a.id
        JOIN albums al ON s.album_id = al.id
        WHERE sa.bpm BETWEEN %s AND %s
        ORDER BY sa.bpm
        LIMIT %s
    """,
        (min_bpm, max_bpm, limit),
    )

    songs = [dict(row) for row in cursor.fetchall()]
    conn.close()

    return jsonify(songs)


@api.route("/api/songs/by-key", methods=["GET"])
def get_songs_by_key():
    """Get songs in a specific key"""
    key = request.args.get("key")
    scale = request.args.get("scale")
    limit = request.args.get("limit", 50, type=int)

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    query = """
        SELECT s.id, s.title, s.duration, s.file_path,
               a.name as artist_name, al.title as album_title, al.artwork_path,
               sa.bpm, sa.musical_key, sa.musical_scale, sa.key_confidence
        FROM songs s
        JOIN song_analysis sa ON s.id = sa.song_id
        JOIN artists a ON s.artist_id = a.id
        JOIN albums al ON s.album_id = al.id
        WHERE 1=1
    """
    params = []

    if key:
        query += " AND sa.musical_key = %s"
        params.append(key)
    if scale:
        query += " AND sa.musical_scale = %s"
        params.append(scale)

    query += " ORDER BY sa.key_confidence DESC LIMIT %s"
    params.append(limit)

    cursor.execute(query, params)
    songs = [dict(row) for row in cursor.fetchall()]
    conn.close()

    return jsonify(songs)


# ========================
# Spotify History Endpoints
# ========================


@api.route("/api/spotify/stats", methods=["GET"])
def get_spotify_stats():
    """Get Spotify import statistics"""
    from app.spotify_history_import import get_import_stats

    stats = get_import_stats(config.DATABASE_URL)
    return jsonify(stats)


@api.route("/api/spotify/missing", methods=["GET"])
def get_missing_albums():
    """Get missing albums sorted by listen time"""
    page = request.args.get("page", 1, type=int)
    per_page = request.args.get("per_page", 20, type=int)
    offset = (page - 1) * per_page

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    # Get total count
    cursor.execute(
        """
        SELECT COUNT(DISTINCT artist_name || '|||' || COALESCE(album_name, ''))
        FROM spotify_plays
        WHERE matched_song_id IS NULL
        AND artist_name IS NOT NULL
    """
    )
    total = cursor.fetchone()["count"]

    # Get missing albums with stats
    cursor.execute(
        """
        SELECT 
            artist_name,
            album_name,
            COUNT(*) as play_count,
            SUM(ms_played) as total_ms,
            COUNT(DISTINCT track_name) as track_count
        FROM spotify_plays
        WHERE matched_song_id IS NULL
        AND artist_name IS NOT NULL
        GROUP BY artist_name, album_name
        ORDER BY total_ms DESC
        LIMIT %s OFFSET %s
    """,
        (per_page, offset),
    )

    albums = []
    for row in cursor.fetchall():
        total_ms = row["total_ms"] or 0
        hours = total_ms // 3600000
        minutes = (total_ms % 3600000) // 60000
        albums.append(
            {
                "artist": row["artist_name"],
                "album": row["album_name"] or "Unknown Album",
                "play_count": row["play_count"],
                "track_count": row["track_count"],
                "total_ms": total_ms,
                "listen_time": f"{hours}h {minutes}m" if hours else f"{minutes}m",
            }
        )

    conn.close()

    return jsonify(
        {
            "albums": albums,
            "total": total,
            "page": page,
            "per_page": per_page,
            "total_pages": (total + per_page - 1) // per_page,
        }
    )


@api.route("/api/spotify/link-album", methods=["POST"])
def link_spotify_album():
    """
    Manually link a Spotify album to a library album.
    """
    data = request.get_json()
    spotify_artist = data.get("spotify_artist")
    spotify_album = data.get("spotify_album")
    library_album_id = data.get("library_album_id")

    if not spotify_artist or not library_album_id:
        return jsonify({"success": False, "error": "Missing required fields"}), 400

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Get the library album's tracks
        cursor.execute(
            """
            SELECT s.id, s.title
            FROM songs s
            WHERE s.album_id = %s
        """,
            (library_album_id,),
        )
        library_tracks = {row["id"]: row for row in cursor.fetchall()}

        if not library_tracks:
            return (
                jsonify(
                    {"success": False, "error": "No tracks found in library album"}
                ),
                404,
            )

        # Build normalized lookup for library tracks
        from app.spotify_history_import import normalize_text

        library_lookup = {}
        for song_id, track_data in library_tracks.items():
            norm_title = normalize_text(track_data["title"])
            library_lookup[norm_title] = song_id

        # Get distinct tracks from Spotify plays for this album
        if spotify_album:
            cursor.execute(
                """
                SELECT DISTINCT track_name
                FROM spotify_plays
                WHERE artist_name = %s AND album_name = %s
                AND matched_song_id IS NULL
            """,
                (spotify_artist, spotify_album),
            )
        else:
            cursor.execute(
                """
                SELECT DISTINCT track_name
                FROM spotify_plays
                WHERE artist_name = %s AND album_name IS NULL
                AND matched_song_id IS NULL
            """,
                (spotify_artist,),
            )

        spotify_tracks = cursor.fetchall()
        matched_count = 0
        updated_plays = 0

        for row in spotify_tracks:
            track_name = row["track_name"]
            if not track_name:
                continue

            norm_track = normalize_text(track_name)
            song_id = library_lookup.get(norm_track)

            # If no exact match, try partial matching
            if not song_id:
                for lib_norm, lib_id in library_lookup.items():
                    if lib_norm in norm_track or norm_track in lib_norm:
                        song_id = lib_id
                        break

            if song_id:
                if spotify_album:
                    cursor.execute(
                        """
                        UPDATE spotify_plays
                        SET matched_song_id = %s, matched_at = CURRENT_TIMESTAMP
                        WHERE artist_name = %s AND album_name = %s AND track_name = %s
                        AND matched_song_id IS NULL
                    """,
                        (song_id, spotify_artist, spotify_album, track_name),
                    )
                else:
                    cursor.execute(
                        """
                        UPDATE spotify_plays
                        SET matched_song_id = %s, matched_at = CURRENT_TIMESTAMP
                        WHERE artist_name = %s AND album_name IS NULL AND track_name = %s
                        AND matched_song_id IS NULL
                    """,
                        (song_id, spotify_artist, track_name),
                    )

                updated_plays += cursor.rowcount
                matched_count += 1

        conn.commit()
        conn.close()

        return jsonify(
            {
                "success": True,
                "message": f"Linked {matched_count} tracks ({updated_plays} plays)",
                "matched_tracks": matched_count,
                "updated_plays": updated_plays,
            }
        )

    except Exception as e:
        conn.close()
        return _error_response(e)


@api.route("/api/spotify/dismiss-album", methods=["POST"])
def dismiss_spotify_album():
    """
    Dismiss a missing Spotify album (sets matched_song_id to -1).
    """
    data = request.get_json()
    spotify_artist = data.get("spotify_artist")
    spotify_album = data.get("spotify_album")

    if not spotify_artist:
        return jsonify({"success": False, "error": "Missing artist name"}), 400

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        if spotify_album:
            cursor.execute(
                """
                UPDATE spotify_plays
                SET matched_song_id = -1, matched_at = CURRENT_TIMESTAMP
                WHERE artist_name = %s AND album_name = %s
                AND matched_song_id IS NULL
            """,
                (spotify_artist, spotify_album),
            )
        else:
            cursor.execute(
                """
                UPDATE spotify_plays
                SET matched_song_id = -1, matched_at = CURRENT_TIMESTAMP
                WHERE artist_name = %s AND album_name IS NULL
                AND matched_song_id IS NULL
            """,
                (spotify_artist,),
            )

        updated = cursor.rowcount
        conn.commit()
        conn.close()

        return jsonify(
            {
                "success": True,
                "message": f"Dismissed album ({updated} plays hidden)",
                "updated_plays": updated,
            }
        )

    except Exception as e:
        conn.close()
        return _error_response(e)


@api.route("/api/spotify/history", methods=["GET"])
def get_spotify_history():
    """Get recent Spotify play history"""
    limit = request.args.get("limit", 50, type=int)
    year = request.args.get("year")

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    query = """
        SELECT 
            sp.ts, sp.track_name, sp.artist_name, sp.album_name,
            sp.ms_played, sp.matched_song_id,
            s.id as song_id, al.artwork_path
        FROM spotify_plays sp
        LEFT JOIN songs s ON sp.matched_song_id = s.id
        LEFT JOIN albums al ON s.album_id = al.id
        WHERE 1=1
    """
    params = []

    if year:
        query += " AND EXTRACT(YEAR FROM sp.ts) = %s"
        params.append(int(year))

    query += " ORDER BY sp.ts DESC LIMIT %s"
    params.append(limit)

    cursor.execute(query, params)

    plays = []
    for row in cursor.fetchall():
        ms = row["ms_played"] or 0
        minutes = ms // 60000
        seconds = (ms % 60000) // 1000
        plays.append(
            {
                "timestamp": row["ts"],
                "track": row["track_name"],
                "artist": row["artist_name"],
                "album": row["album_name"],
                "duration": f"{minutes}:{seconds:02d}",
                "matched": row["matched_song_id"] is not None,
                "song_id": row["song_id"],
                "artwork_path": row["artwork_path"],
            }
        )

    conn.close()

    return jsonify(plays)


@api.route("/api/imports/analyze-split", methods=["POST"])
def analyze_folder_for_split():
    """Analyze a folder to detect files that should be split into separate disc folders"""

    data = request.get_json()
    folder_path = data.get("path")

    if not folder_path:
        return jsonify({"error": "path is required"}), 400

    # Validate path is in allowed directories
    allowed_paths = Config.DOWNLOADS_ALLOWED
    if not any(folder_path.startswith(p) for p in allowed_paths):
        return jsonify({"error": "Invalid path"}), 400

    if not os.path.isdir(folder_path):
        return jsonify({"error": "Folder not found"}), 404

    # Patterns to detect disc numbers in filenames
    disc_patterns = [
        re.compile(r"(?:^|[\s\-_\.])(?:CD|Disc|D)[\s\-_]?(\d+)", re.IGNORECASE),
        re.compile(
            r"[\s\-_\.](\d+)[\s\-_\.]", re.IGNORECASE
        ),  # Just numbers between separators
    ]

    # Collect all files and try to detect which disc they belong to
    files_by_disc = {}  # disc_num -> list of files
    unmatched_files = []

    try:
        for item in os.listdir(folder_path):
            item_path = os.path.join(folder_path, item)
            if os.path.isfile(item_path):
                ext = os.path.splitext(item)[1].lower()
                # Only process audio and CUE files
                if ext not in [
                    ".flac",
                    ".mp3",
                    ".m4a",
                    ".wav",
                    ".ogg",
                    ".ape",
                    ".wv",
                    ".aiff",
                    ".aif",
                    ".cue",
                ]:
                    continue

                # Try to detect disc number
                disc_num = None
                for pattern in disc_patterns:
                    match = pattern.search(item)
                    if match:
                        disc_num = int(match.group(1))
                        break

                file_info = {
                    "name": item,
                    "path": item_path,
                    "extension": ext,
                    "size": os.path.getsize(item_path),
                }

                if disc_num is not None:
                    if disc_num not in files_by_disc:
                        files_by_disc[disc_num] = []
                    files_by_disc[disc_num].append(file_info)
                else:
                    unmatched_files.append(file_info)

        # Build proposed split structure
        proposed_folders = []
        for disc_num in sorted(files_by_disc.keys()):
            proposed_folders.append(
                {
                    "disc_number": disc_num,
                    "folder_name": f"CD{disc_num}",
                    "files": files_by_disc[disc_num],
                }
            )

        # Determine if split is recommended
        can_split = len(files_by_disc) > 1

        return jsonify(
            {
                "success": True,
                "can_split": can_split,
                "proposed_folders": proposed_folders,
                "unmatched_files": unmatched_files,
                "total_discs_detected": len(files_by_disc),
            }
        )

    except Exception as e:
        return _error_response(e)


@api.route("/api/imports/perform-split", methods=["POST"])
def perform_folder_split():
    """Move files into separate disc folders based on provided structure"""

    data = request.get_json()
    base_path = data.get("path")
    folders = data.get(
        "folders", []
    )  # List of {"folder_name": "CD1", "files": ["file1.flac", "file2.cue"]}

    if not base_path or not folders:
        return jsonify({"error": "path and folders are required"}), 400

    # Validate path is in allowed directories
    allowed_paths = Config.DOWNLOADS_ALLOWED
    if not any(base_path.startswith(p) for p in allowed_paths):
        return jsonify({"error": "Invalid path"}), 400

    if not os.path.isdir(base_path):
        return jsonify({"error": "Folder not found"}), 404

    results = []
    for folder in folders:
        folder_name = folder.get("folder_name")
        files = folder.get("files", [])

        if not folder_name or not files:
            continue

        # Create the new folder
        new_folder_path = os.path.join(base_path, folder_name)
        try:
            os.makedirs(new_folder_path, exist_ok=True)
        except Exception as e:
            results.append(
                {
                    "folder_name": folder_name,
                    "success": False,
                    "error": f"Failed to create folder: {e}",
                }
            )
            continue

        # Move files into the folder
        moved_count = 0
        for filename in files:
            src_path = os.path.join(base_path, filename)
            dst_path = os.path.join(new_folder_path, filename)

            if not os.path.exists(src_path):
                continue

            try:
                shutil.move(src_path, dst_path)
                moved_count += 1
            except Exception as e:
                results.append(
                    {
                        "folder_name": folder_name,
                        "file": filename,
                        "success": False,
                        "error": str(e),
                    }
                )

        results.append(
            {"folder_name": folder_name, "success": True, "files_moved": moved_count}
        )

    return jsonify({"success": True, "results": results})


@api.route("/api/imports/move-folder-up", methods=["POST"])
def move_folder_up():
    """Move a subfolder up one level with optional rename"""

    data = request.get_json()
    folder_path = data.get("folder_path")  # The folder to move
    new_name = data.get("new_name")  # Optional new name for the folder

    if not folder_path:
        return jsonify({"error": "folder_path is required"}), 400

    # Validate path is in allowed directories
    allowed_paths = Config.DOWNLOADS_ALLOWED
    if not any(folder_path.startswith(p) for p in allowed_paths):
        return jsonify({"error": "Invalid path"}), 400

    if not os.path.isdir(folder_path):
        return jsonify({"error": "Folder not found"}), 404

    try:
        # Get parent and grandparent paths
        parent_path = os.path.dirname(folder_path)
        grandparent_path = os.path.dirname(parent_path)

        # Don't allow moving out of the allowed directories
        if not any(grandparent_path.startswith(p) for p in allowed_paths):
            return (
                jsonify({"error": "Cannot move folder outside allowed directories"}),
                400,
            )

        # Determine destination name
        current_name = os.path.basename(folder_path)
        dest_name = new_name if new_name else current_name
        dest_path = os.path.join(grandparent_path, dest_name)

        # Check if destination already exists
        if os.path.exists(dest_path):
            return (
                jsonify(
                    {
                        "error": f"A folder named '{dest_name}' already exists in the parent directory"
                    }
                ),
                400,
            )

        # Move the folder
        shutil.move(folder_path, dest_path)

        return jsonify(
            {
                "success": True,
                "old_path": folder_path,
                "new_path": dest_path,
                "new_name": dest_name,
            }
        )

    except Exception as e:
        return _error_response(e)


@api.route("/api/imports/list-subfolders", methods=["POST"])
def list_import_subfolders():
    """List subfolders within an import folder"""

    data = request.get_json()
    base_path = data.get("path")

    if not base_path:
        return jsonify({"error": "path is required"}), 400

    # Validate path is in allowed directories
    allowed_paths = Config.DOWNLOADS_ALLOWED
    if not any(base_path.startswith(p) for p in allowed_paths):
        return jsonify({"error": "Invalid path"}), 400

    if not os.path.isdir(base_path):
        return jsonify({"error": "Folder not found"}), 404

    subfolders = []
    try:
        for item in os.listdir(base_path):
            item_path = os.path.join(base_path, item)
            if os.path.isdir(item_path):
                # Count audio files and check for CUE
                audio_count = 0
                has_cue = False
                for f in os.listdir(item_path):
                    ext = os.path.splitext(f)[1].lower()
                    if ext in [
                        ".flac",
                        ".mp3",
                        ".m4a",
                        ".wav",
                        ".ogg",
                        ".ape",
                        ".wv",
                        ".aiff",
                        ".aif",
                    ]:
                        audio_count += 1
                    if ext == ".cue":
                        has_cue = True

                subfolders.append(
                    {
                        "name": item,
                        "path": item_path,
                        "audio_count": audio_count,
                        "has_cue": has_cue,
                    }
                )

        # Sort by name
        subfolders.sort(key=lambda x: x["name"].lower())
    except Exception as e:
        return _error_response(e)

    return jsonify({"success": True, "subfolders": subfolders})


@api.route("/api/imports/rename-subfolders", methods=["POST"])
def rename_import_subfolders():
    """Rename subfolders within an import folder (for normalizing disc folders)"""

    data = request.get_json()
    base_path = data.get("path")
    renames = data.get(
        "renames", []
    )  # List of {"old_name": "CD1 Remastered", "new_name": "CD1"}

    if not base_path or not renames:
        return jsonify({"error": "path and renames are required"}), 400

    # Validate path is in allowed directories
    allowed_paths = Config.DOWNLOADS_ALLOWED
    if not any(base_path.startswith(p) for p in allowed_paths):
        return jsonify({"error": "Invalid path"}), 400

    if not os.path.isdir(base_path):
        return jsonify({"error": "Folder not found"}), 404

    results = []
    for rename in renames:
        old_name = rename.get("old_name")
        new_name = rename.get("new_name")

        if not old_name or not new_name:
            continue

        old_path = os.path.join(base_path, old_name)
        new_path = os.path.join(base_path, new_name)

        if not os.path.isdir(old_path):
            results.append(
                {"old_name": old_name, "success": False, "error": "Folder not found"}
            )
            continue

        if os.path.exists(new_path) and old_path != new_path:
            results.append(
                {
                    "old_name": old_name,
                    "success": False,
                    "error": "Target name already exists",
                }
            )
            continue

        try:
            os.rename(old_path, new_path)
            results.append(
                {"old_name": old_name, "new_name": new_name, "success": True}
            )
        except Exception as e:
            results.append({"old_name": old_name, "success": False, "error": str(e)})

    return jsonify({"success": True, "results": results})


@api.route("/api/imports/folder", methods=["DELETE"])
def delete_import_folder():
    """Delete a folder from the downloads directory"""

    data = request.get_json()
    folder_path = data.get("path")

    if not folder_path:
        return jsonify({"error": "path required"}), 400

    # Security check - only allow deleting from downloads folders
    if not any(folder_path.startswith(p) for p in Config.DOWNLOADS_ALLOWED):
        return jsonify({"error": "Can only delete from downloads folder"}), 403

    if not os.path.exists(folder_path):
        return jsonify({"error": "Folder not found"}), 404

    try:
        shutil.rmtree(folder_path)
        return jsonify(
            {"success": True, "message": f"Deleted {os.path.basename(folder_path)}"}
        )
    except Exception as e:
        return _error_response(e)


def _get_quality_score(file_format):
    """Return a quality score for comparison. Higher = better."""
    if not file_format:
        return 0
    fmt = file_format.upper()
    # Quality hierarchy
    if "DSD" in fmt:
        return 100
    if fmt in ["FLAC", "WAV", "ALAC"]:
        return 80  # Lossless
    if fmt in ["OGG", "OPUS"]:
        return 50  # Good lossy
    if fmt == "MP3":
        return 40
    if fmt in ["AAC", "M4A"]:
        return 35
    if fmt == "WMA":
        return 30
    return 20


def _get_folder_quality(folder_path):
    """Scan a folder and return the quality score and format of audio files."""

    audio_extensions = {
        ".flac": "FLAC",
        ".mp3": "MP3",
        ".m4a": "M4A",
        ".wav": "WAV",
        ".ogg": "OGG",
        ".opus": "OPUS",
        ".aac": "AAC",
        ".wma": "WMA",
        ".dsf": "DSD",
        ".dff": "DSD",
        ".alac": "ALAC",
        ".wv": "WavPack",
        ".ape": "APE",
        ".aiff": "AIFF",
    }

    best_quality = 0
    best_format = "Unknown"

    if not os.path.exists(folder_path):
        return 0, "Unknown"

    for root, dirs, files in os.walk(folder_path):
        for f in files:
            ext = os.path.splitext(f)[1].lower()
            if ext in audio_extensions:
                fmt = audio_extensions[ext]
                score = _get_quality_score(fmt)
                if score > best_quality:
                    best_quality = score
                    best_format = fmt

    return best_quality, best_format


@api.route("/api/imports/check-duplicates", methods=["POST"])
def check_import_duplicates():
    """Check which pending imports already exist in the library using audio file metadata"""

    from mutagen import File as MutagenFile

    data = request.get_json()
    folders = data.get("folders", [])

    if not folders:
        return jsonify({"error": "folders array required"}), 400

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    results = {}
    audio_extensions = [
        ".flac",
        ".mp3",
        ".m4a",
        ".wav",
        ".ogg",
        ".opus",
        ".aac",
        ".wma",
        ".wv",
        ".ape",
        ".aiff",
        ".dsf",
        ".dff",
    ]

    try:
        for folder in folders:
            folder_name = folder.get("folder_name", "")
            folder_path = folder.get("path", "")

            artist = None
            album = None
            # Channel count of the pending files (mutagen reads it for
            # free alongside the tags) — lets the duplicate check tell
            # a surround/Atmos release apart from the stereo album of
            # the same name already in the library.
            pending_channels = None

            # First, try to read tags from audio files
            if os.path.exists(folder_path):
                audio_files = []
                for root, dirs, files in os.walk(folder_path):
                    for f in files:
                        ext = os.path.splitext(f)[1].lower()
                        if ext in audio_extensions:
                            audio_files.append(os.path.join(root, f))

                # Read tags from first few files
                for audio_path in audio_files[:5]:
                    try:
                        audio = MutagenFile(audio_path, easy=True)
                        if audio is None:
                            continue

                        ch = getattr(getattr(audio, "info", None), "channels", None)
                        if ch:
                            pending_channels = max(pending_channels or 0, int(ch))

                        # Extract artist
                        if not artist:
                            if audio.get("albumartist"):
                                artist = audio.get("albumartist")[0]
                            elif audio.get("artist"):
                                artist = audio.get("artist")[0]

                        # Extract album
                        if not album and audio.get("album"):
                            album = audio.get("album")[0]

                        # If we have both, stop looking
                        if artist and album:
                            break

                    except Exception as e:
                        continue

                # mutagen can't read the channel count of Dolby
                # bitstreams in mp4 — ec-3 sample entries come back as
                # channels=2 — so confirm with ffprobe: real channel
                # count plus the profile string, which names Atmos
                # explicitly (same trick as scanner.detect_atmos).
                # One probe per pending folder, tpool-wrapped.
                if audio_files:
                    try:
                        r = eventlet.tpool.execute(
                            safe_subprocess_run,
                            ["ffprobe", "-v", "error", "-select_streams", "a:0",
                             "-show_entries", "stream=channels,profile",
                             "-of", "default=noprint_wrappers=1", audio_files[0]],
                            capture_output=True, text=True, timeout=30,
                        )
                        out = r.stdout or ""
                        m = re.search(r"channels=(\d+)", out)
                        if m:
                            pending_channels = max(pending_channels or 0, int(m.group(1)))
                        if "Atmos" in out:
                            pending_channels = max(pending_channels or 0, 6)
                    except Exception:
                        pass

            # Fall back to folder name parsing if tags didn't work
            if not artist or not album:
                clean = folder_name
                clean = re.sub(r"\[.*?\]", "", clean)
                clean = re.sub(r"\((?:19|20)\d{2}\)", "", clean)
                clean = re.sub(r"^(?:19|20)\d{2}[.\-_\s]+", "", clean)
                clean = clean.strip()

                if " - " in clean:
                    parts = clean.split(" - ", 1)
                    if not artist:
                        artist = parts[0].strip()
                    if not album:
                        album = parts[1].strip()
                elif not album:
                    album = clean

            # Check if exists in library
            if artist and album:
                # Try exact match first
                cursor.execute(
                    """
                    SELECT a.id, a.title, ar.name as artist_name
                    FROM albums a
                    JOIN artists ar ON a.artist_id = ar.id
                    WHERE LOWER(ar.name) = LOWER(%s) AND LOWER(a.title) = LOWER(%s)
                    """,
                    (artist, album),
                )
                match = cursor.fetchone()

                fuzzy_match = None
                # Fuzzy fallback ONLY if exact missed AND both strings are
                # substantial enough that LIKE %x% is informative. The old
                # fuzzy was LIKE %artist% AND LIKE %album% which false-
                # matched any short artist substring against unrelated
                # albums (e.g. "Foo" inside "Foofighters Live") and was
                # blocking legit re-imports — diagnosed 2026-06-01 with
                # the Sonic Mania OST re-import incident, where 4 orphan
                # album rows were ALSO contributing to the false-positive.
                # Minimum length 4 on both sides eliminates the most
                # egregious false matches without sacrificing real ones
                # like "X" vs "X (Deluxe Edition)".
                if not match and len(artist) >= 4 and len(album) >= 4:
                    cursor.execute(
                        """
                        SELECT a.id, a.title, ar.name as artist_name
                        FROM albums a
                        JOIN artists ar ON a.artist_id = ar.id
                        WHERE LOWER(ar.name) LIKE LOWER(%s) AND LOWER(a.title) LIKE LOWER(%s)
                        """,
                        (f"%{artist}%", f"%{album}%"),
                    )
                    fuzzy_match = cursor.fetchone()

                # Mix-aware veto: an album-name match is NOT a duplicate
                # when the pending files and the library copy are
                # different mixes (surround/Atmos vs stereo). Without
                # this, a downloaded Atmos release of an album owned in
                # stereo got a red "Delete duplicate" offer — one click
                # from binning the better copy (Thriller Atmos incident,
                # 2026-08-24). Compares actual pending channel count
                # against the library album's scan-time spatial profile.
                matched = match or fuzzy_match
                different_mix = False
                if matched and pending_channels:
                    cursor.execute(
                        """
                        SELECT COALESCE(MAX(audio_channels), 2) AS max_ch,
                               COALESCE(MAX(is_atmos), 0) AS has_atmos
                        FROM songs WHERE album_id = %s
                    """,
                        (matched["id"],),
                    )
                    sp = cursor.fetchone()
                    lib_surround = (sp["max_ch"] or 2) > 2 or bool(sp["has_atmos"])
                    different_mix = (pending_channels > 2) != lib_surround

                if matched and different_mix:
                    results[folder_path] = {
                        "in_library": False,
                        "match_type": "different_mix",
                        "album_id": matched["id"],
                        "album_title": matched["title"],
                        "artist_name": matched["artist_name"],
                    }
                elif match:
                    # Exact (case-insensitive) — caller should treat as a
                    # hard duplicate.
                    results[folder_path] = {
                        "in_library": True,
                        "match_type": "exact",
                        "album_id": match["id"],
                        "album_title": match["title"],
                        "artist_name": match["artist_name"],
                    }
                elif fuzzy_match:
                    # Fuzzy — surface as a soft warning, not a hard block.
                    # in_library still True for backward compat with the
                    # current UI; match_type lets a future UI render it
                    # as "possible duplicate, click to confirm".
                    results[folder_path] = {
                        "in_library": True,
                        "match_type": "fuzzy",
                        "album_id": fuzzy_match["id"],
                        "album_title": fuzzy_match["title"],
                        "artist_name": fuzzy_match["artist_name"],
                    }
                else:
                    results[folder_path] = {"in_library": False}
            else:
                results[folder_path] = {"in_library": False}

        return jsonify({"success": True, "results": results})

    except Exception as e:
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/imports/bulk-delete", methods=["POST"])
@auth.require_admin
def bulk_delete_import_folders():
    """Delete multiple folders from downloads"""

    data = request.get_json()
    paths = data.get("paths", [])

    if not paths:
        return jsonify({"error": "paths array required"}), 400

    deleted = 0
    errors = []

    for path in paths:
        if not any(path.startswith(p) for p in Config.DOWNLOADS_ALLOWED):
            errors.append(f"{path}: not in downloads folder")
            continue

        if not os.path.exists(path):
            errors.append(f"{path}: not found")
            continue

        try:
            shutil.rmtree(path)
            deleted += 1
        except Exception as e:
            errors.append(f"{path}: {str(e)}")

    return jsonify({"success": True, "deleted_count": deleted, "errors": errors})


@api.route("/api/musicbrainz/search", methods=["GET"])
def search_musicbrainz():
    """Search MusicBrainz for album and get MBID"""

    from urllib.parse import quote

    artist = request.args.get("artist")
    album = request.args.get("album")

    if not artist and not album:
        return jsonify({"error": "artist or album required"}), 400

    # MusicBrainz API requires user agent
    headers = {"User-Agent": "NASRadio/1.0 (https://github.com/simpson1045/NASRadio)"}

    # Clean up artist name for better matching
    # Remove parentheses, special chars, normalize spacing
    def clean_for_search(text):
        if not text:
            return ""
        # Replace special characters with regular equivalents
        text = text.replace("ə", "e").replace("ɛ", "e")
        # Remove parentheses content or just the parens
        text = re.sub(r"[\(\)\[\]]", "", text)
        # Remove special punctuation (keep & for artists like Y&T)
        text = re.sub(r"[!@#$%^*]", "", text)
        # Normalize spaces
        text = re.sub(r"\s+", " ", text).strip()
        return text

    clean_artist = clean_for_search(artist) if artist else ""
    clean_album = clean_for_search(album) if album else ""

    # Build a flexible query - don't use quotes for fuzzy matching
    query_parts = []
    if clean_artist:
        # Wrap in quotes if contains spaces (needed for "Y and T", etc.)
        if " " in clean_artist:
            query_parts.append(f'artist:"{clean_artist}"')
        else:
            query_parts.append(f"artist:{clean_artist}")
    if clean_album:
        if " " in clean_album:
            query_parts.append(f'releasegroup:"{clean_album}"')
        else:
            query_parts.append(f"releasegroup:{clean_album}")

    query = " AND ".join(query_parts)

    def _mb_release_group_search(q):
        encoded_query = quote(q)
        url = f"https://musicbrainz.org/ws/2/release-group?query={encoded_query}&limit=10&fmt=json"
        return mb_requests.get(url, headers=headers, timeout=25)

    try:
        response = _mb_release_group_search(query)

        if response.status_code == 200:
            data = response.json()
            release_groups = data.get("release-groups", [])

            # Fallback chain when the primary artist-AND-album query
            # returns nothing. Two common reasons for that:
            #   (a) the release-group's canonical artist credit differs
            #       from the local file's tag — e.g. Sonic Mania OST
            #       Selected Edition is tagged "SEGA Sound Team" on
            #       Spotify but MB's release-group is credited to "Tee
            #       Lopes" (the composer);
            #   (b) the local file's album title is actually the title
            #       of one specific RELEASE under a more-broadly-named
            #       release-group. The "Selected Edition" Sonic Mania
            #       release sits under a release-group titled just
            #       "Sonic Mania" — searching releasegroup:"Sonic Mania
            #       Original Sound Track Selected Edition" gets 0 hits
            #       even with no artist filter, but releasegroup:"Sonic
            #       Mania" returns the right group with 100 score.
            # Step 1: drop the artist constraint. Step 2: also strip
            # parenthetical edition info and OST/Soundtrack suffixes.
            # The sort_key below still ranks better-matching titles to
            # the top so the right entry surfaces.

            def _strip_edition_suffixes(s):
                t = re.sub(r"\s*\([^)]*\)", "", s)        # (Selected Edition), (Deluxe), etc.
                t = re.sub(r"\s*\[[^\]]*\]", "", t)        # [stuff]
                t = re.sub(
                    r"\s*\b(original\s+sound\s*track|original\s+soundtrack|soundtrack|ost)\b\s*",
                    " ",
                    t,
                    flags=re.IGNORECASE,
                )
                return re.sub(r"\s+", " ", t).strip()

            def _retry_album_only(album_term):
                if not album_term:
                    return []
                q = (
                    f'releasegroup:"{album_term}"'
                    if " " in album_term
                    else f"releasegroup:{album_term}"
                )
                r = _mb_release_group_search(q)
                if r.status_code == 200:
                    return r.json().get("release-groups", [])
                return []

            if not release_groups and clean_artist and clean_album:
                release_groups = _retry_album_only(clean_album)

            if not release_groups and clean_album:
                stripped = _strip_edition_suffixes(clean_album)
                if stripped and stripped.lower() != clean_album.lower():
                    release_groups = _retry_album_only(stripped)

            results = []
            for rg in release_groups:
                artist_credit = rg.get("artist-credit", [])
                artist_name = artist_credit[0]["name"] if artist_credit else "Unknown"

                # Get year from first-release-date
                first_release = rg.get("first-release-date", "")
                year = first_release[:4] if first_release else None

                results.append(
                    {
                        "mbid": rg.get("id"),
                        "title": rg.get("title"),
                        "artist": artist_name,
                        "year": year,
                        "type": rg.get("primary-type"),
                        "url": f"https://musicbrainz.org/release-group/{rg.get('id')}",
                        "cover_url": f"https://coverartarchive.org/release-group/{rg.get('id')}/front-250",
                    }
                )

            # Sort: Albums first, then EPs, then Singles
            # Also prioritize exact/closer title matches
            type_priority = {"Album": 0, "EP": 1, "Single": 2, None: 3}

            def sort_key(x):
                type_score = type_priority.get(x.get("type"), 99)
                title = (x.get("title") or "").lower()
                search_album = album.lower()

                # Exact match gets highest priority
                if title == search_album:
                    title_score = 0
                # Starts with search term
                elif title.startswith(search_album):
                    title_score = 1
                # Search term at start of title
                elif search_album.startswith(title):
                    title_score = 2
                # Length difference (shorter = closer match)
                else:
                    title_score = 3 + abs(len(title) - len(search_album))

                return (type_score, title_score)

            results.sort(key=sort_key)

            return jsonify(
                {
                    "query": {"artist": artist, "album": album},
                    "results": results,
                    "count": len(results),
                }
            )
        else:
            return (
                jsonify({"error": f"MusicBrainz returned {response.status_code}"}),
                502,
            )

    except Exception as e:
        return _error_response(e)


# ====================
# DISCOVERY ENDPOINTS
# ====================


@api.route("/api/discover/recommendations", methods=["GET"])
def get_discovery_recommendations():
    """
    Get music recommendations based on your library.
    Returns tracks with 30-second preview URLs.
    """
    limit = request.args.get("limit", 20, type=int)
    filter_owned = request.args.get("filter_owned", "true").lower() == "true"

    # Optional: specific seeds
    seed_artists = request.args.getlist("seed_artists")
    seed_tracks = request.args.getlist("seed_tracks")
    seed_genres = request.args.getlist("seed_genres")

    discovery = SpotifyDiscovery()
    result = discovery.get_recommendations(
        seed_artists=seed_artists if seed_artists else None,
        seed_tracks=seed_tracks if seed_tracks else None,
        seed_genres=seed_genres if seed_genres else None,
        limit=limit,
        filter_owned=filter_owned,
    )

    if result["success"]:
        return jsonify(result)
    else:
        return jsonify(result), 500


@api.route("/api/discover/similar-artists/<artist_name>", methods=["GET"])
def get_similar_artists(artist_name):
    """Get artists similar to a given artist"""
    limit = request.args.get("limit", 10, type=int)

    discovery = SpotifyDiscovery()
    result = discovery.get_similar_artists(artist_name=artist_name, limit=limit)

    if result["success"]:
        return jsonify(result)
    else:
        return jsonify(result), 500


@api.route("/api/discover/artist-top-tracks/<artist_name>", methods=["GET"])
def get_discover_artist_top_tracks(artist_name):
    """Get top tracks for an artist with preview URLs"""
    discovery = SpotifyDiscovery()
    result = discovery.get_artist_top_tracks(artist_name=artist_name)

    if result["success"]:
        return jsonify(result)
    else:
        return jsonify(result), 500


@api.route("/api/discover/search", methods=["GET"])
def search_spotify_discovery():
    """
    Search Spotify for tracks, artists, or albums.
    Returns preview URLs for tracks.
    """
    query = request.args.get("q")
    search_type = request.args.get("type", "track")  # track, artist, or album
    limit = request.args.get("limit", 20, type=int)

    if not query:
        return jsonify({"error": "Query parameter 'q' is required"}), 400

    if search_type not in ["track", "artist", "album"]:
        return jsonify({"error": "Type must be 'track', 'artist', or 'album'"}), 400

    discovery = SpotifyDiscovery()
    result = discovery.search_spotify(query=query, search_type=search_type, limit=limit)

    if result["success"]:
        return jsonify(result)
    else:
        return jsonify(result), 500


@api.route("/api/discover/genres", methods=["GET"])
def get_available_genres():
    """Get list of available genre seeds for recommendations"""
    discovery = SpotifyDiscovery()
    result = discovery.get_available_genre_seeds()

    if result["success"]:
        return jsonify(result)
    else:
        return jsonify(result), 500


@api.route("/api/discover/seeds", methods=["GET"])
def get_discovery_seeds():
    """
    Get the seed artists and tracks that would be used for recommendations
    based on your library's most played content.
    """
    discovery = SpotifyDiscovery()

    seed_artists = discovery.get_seed_artists_from_library(limit=5)
    seed_tracks = discovery.get_seed_tracks_from_library(limit=5)

    return jsonify(
        {
            "success": True,
            "seed_artists": seed_artists,
            "seed_tracks": seed_tracks,
        }
    )


# ============================================
# SPOTIFY PREVIEW ENDPOINT
# ============================================
# This uses the embed page workaround since Spotify
# deprecated preview_url in their API (Nov 2024)
# ============================================


def get_preview_from_embed(track_id):
    """
    Extract preview URL from Spotify's embed page.
    This is a workaround since Spotify deprecated preview_url in the API.
    """

    try:
        embed_url = f"https://open.spotify.com/embed/track/{track_id}"
        headers = {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        }

        response = mb_requests.get(embed_url, headers=headers, timeout=10)
        print(
            f"DEBUG: Embed page status: {response.status_code}, length: {len(response.text)}"
        )

        if response.status_code != 200:
            print(f"Embed page returned status {response.status_code}")
            return None

        html = response.text

        # Look for audioPreview URL pattern
        match = re.search(
            r'audioPreview":\{"url":"(https://p\.scdn\.co/mp3-preview/[^"]+)"', html
        )
        if match:
            return match.group(1)

        # Fallback: look for any mp3-preview URL
        match = re.search(r"(https://p\.scdn\.co/mp3-preview/[a-zA-Z0-9]+)", html)
        if match:
            return match.group(1)

        print("DEBUG: No preview URL found")
        return None

    except Exception as e:
        print(f"Error fetching embed page: {e}")
        return None


@api.route("/api/spotify/preview", methods=["GET"])
def get_spotify_preview():
    """
    Get Spotify preview URL for a track using embed page workaround.
    Query params: artist, track, album (optional)
    Returns: preview_url (30-sec MP3) or null if not available
    """

    artist = request.args.get("artist")
    track = request.args.get("track")
    album = request.args.get("album")

    if not artist or not track:
        return jsonify({"error": "artist and track are required"}), 400

    try:
        from spotipy.oauth2 import SpotifyClientCredentials
        import spotipy

        auth_manager = SpotifyClientCredentials(
            client_id=config.SPOTIFY_CLIENT_ID,
            client_secret=config.SPOTIFY_CLIENT_SECRET,
        )
        sp = spotipy.Spotify(auth_manager=auth_manager)

        # Build search query
        query = f'track:"{track}" artist:"{artist}"'
        if album:
            query += f' album:"{album}"'

        results = sp.search(q=query, type="track", limit=1)

        if not results["tracks"]["items"]:
            return jsonify({"success": False, "error": "Track not found on Spotify"})

        track_data = results["tracks"]["items"][0]
        track_id = track_data["id"]

        # Get artwork
        artwork_url = None
        if track_data["album"]["images"]:
            artwork_url = track_data["album"]["images"][0]["url"]

        # Try to get preview URL from embed page (workaround)
        preview_url = get_preview_from_embed(track_id)

        return jsonify(
            {
                "success": True,
                "track_id": track_id,
                "track_name": track_data["name"],
                "artist_name": track_data["artists"][0]["name"],
                "album_name": track_data["album"]["name"],
                "preview_url": preview_url,
                "duration_ms": track_data["duration_ms"],
                "artwork_url": artwork_url,
                "spotify_url": track_data["external_urls"].get("spotify"),
            }
        )

    except Exception as e:
        return _error_response(e)


@api.route("/api/spotify/preview-by-id/<track_id>", methods=["GET"])
def get_spotify_preview_by_id(track_id):
    """
    Get Spotify preview URL directly by track ID.
    Uses embed page workaround.
    """
    try:
        from spotipy.oauth2 import SpotifyClientCredentials
        import spotipy

        auth_manager = SpotifyClientCredentials(
            client_id=config.SPOTIFY_CLIENT_ID,
            client_secret=config.SPOTIFY_CLIENT_SECRET,
        )
        sp = spotipy.Spotify(auth_manager=auth_manager)

        # Get track info
        track_data = sp.track(track_id)

        # Get artwork
        artwork_url = None
        if track_data["album"]["images"]:
            artwork_url = track_data["album"]["images"][0]["url"]

        # Get preview URL from embed page (workaround)
        preview_url = get_preview_from_embed(track_id)

        return jsonify(
            {
                "success": True,
                "track_id": track_id,
                "track_name": track_data["name"],
                "artist_name": track_data["artists"][0]["name"],
                "album_name": track_data["album"]["name"],
                "preview_url": preview_url,
                "duration_ms": track_data["duration_ms"],
                "artwork_url": artwork_url,
                "spotify_url": track_data["external_urls"].get("spotify"),
            }
        )

    except Exception as e:
        return _error_response(e)


@api.route("/api/spotify/album-tracks", methods=["GET"])
def get_spotify_album_tracks():
    """
    Get all tracks from a Spotify album with preview URLs.
    Query params: artist, album
    Returns: list of tracks with preview_urls
    """
    artist = request.args.get("artist")
    album = request.args.get("album")

    if not artist or not album:
        return jsonify({"error": "artist and album are required"}), 400

    try:
        from spotipy.oauth2 import SpotifyClientCredentials
        import spotipy

        auth_manager = SpotifyClientCredentials(
            client_id=config.SPOTIFY_CLIENT_ID,
            client_secret=config.SPOTIFY_CLIENT_SECRET,
        )
        sp = spotipy.Spotify(auth_manager=auth_manager)

        # Search for the album - try exact match first, then broad search
        query = f'album:"{album}" artist:"{artist}"'
        results = sp.search(q=query, type="album", limit=1)

        if not results["albums"]["items"]:
            # Fallback: broader search without field filters
            query = f"{artist} {album}"
            results = sp.search(q=query, type="album", limit=5)
            # Try to find best match from broader results
            best_match = None
            album_lower = album.lower()
            for item in results["albums"]["items"]:
                if album_lower in item["name"].lower():
                    best_match = item
                    break
            if best_match:
                results["albums"]["items"] = [best_match]

        if not results["albums"]["items"]:
            return jsonify({"success": False, "error": "Album not found on Spotify"})

        album_data = results["albums"]["items"][0]
        album_id = album_data["id"]

        # Get album artwork
        artwork_url = None
        if album_data["images"]:
            artwork_url = album_data["images"][0]["url"]

        # Get all tracks from the album
        tracks_result = sp.album_tracks(album_id)

        tracks = []
        for track in tracks_result["items"]:
            # Get preview URL from embed page for each track
            preview_url = get_preview_from_embed(track["id"])

            tracks.append(
                {
                    "track_id": track["id"],
                    "track_name": track["name"],
                    "track_number": track["track_number"],
                    "disc_number": track["disc_number"],
                    "duration_ms": track["duration_ms"],
                    "preview_url": preview_url,
                    "artist_name": (
                        track["artists"][0]["name"] if track["artists"] else artist
                    ),
                }
            )

        return jsonify(
            {
                "success": True,
                "album_id": album_id,
                "album_name": album_data["name"],
                "artist_name": (
                    album_data["artists"][0]["name"]
                    if album_data["artists"]
                    else artist
                ),
                "artwork_url": artwork_url,
                "release_date": album_data.get("release_date"),
                "total_tracks": album_data.get("total_tracks"),
                "spotify_url": album_data["external_urls"].get("spotify"),
                "tracks": tracks,
            }
        )

    except Exception as e:
        return _error_response(e)


# ============================================
# LIDARR INTEGRATION
# ============================================


@api.route("/api/lidarr/search-artist", methods=["GET"])
def lidarr_search_artist():
    """Search for an artist in Lidarr's database"""

    artist_name = request.args.get("artist")
    if not artist_name:
        return jsonify({"error": "artist parameter required"}), 400

    try:
        response = mb_requests.get(
            f"{config.LIDARR_URL}/api/v1/artist/lookup",
            params={"term": artist_name},
            headers={"X-Api-Key": config.LIDARR_API_KEY},
            timeout=30,
        )

        if response.status_code == 200:
            results = response.json()
            return jsonify({"success": True, "results": results})
        else:
            return (
                jsonify(
                    {
                        "success": False,
                        "error": f"Lidarr returned {response.status_code}",
                    }
                ),
                response.status_code,
            )

    except Exception as e:
        return _error_response(e)


@api.route("/api/lidarr/search-album", methods=["GET"])
def lidarr_search_album():
    """Search for an album in Lidarr's database"""

    album_name = request.args.get("album")
    if not album_name:
        return jsonify({"error": "album parameter required"}), 400

    try:
        response = mb_requests.get(
            f"{config.LIDARR_URL}/api/v1/album/lookup",
            params={"term": album_name},
            headers={"X-Api-Key": config.LIDARR_API_KEY},
            timeout=30,
        )

        if response.status_code == 200:
            results = response.json()
            return jsonify({"success": True, "results": results})
        else:
            return (
                jsonify(
                    {
                        "success": False,
                        "error": f"Lidarr returned {response.status_code}",
                    }
                ),
                response.status_code,
            )

    except Exception as e:
        return _error_response(e)


@api.route("/api/lidarr/add-artist", methods=["POST"])
def lidarr_add_artist():
    """Add an artist to Lidarr"""

    data = request.get_json()
    foreign_artist_id = data.get("foreign_artist_id")  # MusicBrainz ID

    if not foreign_artist_id:
        return jsonify({"error": "foreign_artist_id required"}), 400

    try:
        # First, look up the artist to get full details
        lookup_response = mb_requests.get(
            f"{config.LIDARR_URL}/api/v1/artist/lookup",
            params={"term": f"lidarr:{foreign_artist_id}"},
            headers={"X-Api-Key": config.LIDARR_API_KEY},
            timeout=30,
        )

        if lookup_response.status_code != 200 or not lookup_response.json():
            return (
                jsonify({"success": False, "error": "Artist not found in MusicBrainz"}),
                404,
            )

        artist_data = lookup_response.json()[0]

        # Get root folder
        root_response = mb_requests.get(
            f"{config.LIDARR_URL}/api/v1/rootfolder",
            headers={"X-Api-Key": config.LIDARR_API_KEY},
            timeout=10,
        )

        if root_response.status_code != 200 or not root_response.json():
            return (
                jsonify(
                    {"success": False, "error": "No root folder configured in Lidarr"}
                ),
                500,
            )

        root_folder = root_response.json()[0]["path"]

        # Get quality profile
        quality_response = mb_requests.get(
            f"{config.LIDARR_URL}/api/v1/qualityprofile",
            headers={"X-Api-Key": config.LIDARR_API_KEY},
            timeout=10,
        )

        if quality_response.status_code != 200 or not quality_response.json():
            return (
                jsonify(
                    {
                        "success": False,
                        "error": "No quality profile configured in Lidarr",
                    }
                ),
                500,
            )

        quality_profile_id = quality_response.json()[0]["id"]

        # Get metadata profile
        metadata_response = mb_requests.get(
            f"{config.LIDARR_URL}/api/v1/metadataprofile",
            headers={"X-Api-Key": config.LIDARR_API_KEY},
            timeout=10,
        )

        if metadata_response.status_code != 200 or not metadata_response.json():
            return (
                jsonify(
                    {
                        "success": False,
                        "error": "No metadata profile configured in Lidarr",
                    }
                ),
                500,
            )

        metadata_profile_id = metadata_response.json()[0]["id"]

        # Add the artist
        add_data = {
            "foreignArtistId": artist_data["foreignArtistId"],
            "artistName": artist_data["artistName"],
            "qualityProfileId": quality_profile_id,
            "metadataProfileId": metadata_profile_id,
            "rootFolderPath": root_folder,
            "monitored": True,
            "addOptions": {
                "monitor": "none",  # Don't auto-monitor all albums
                "searchForMissingAlbums": False,
            },
        }

        add_response = mb_requests.post(
            f"{config.LIDARR_URL}/api/v1/artist",
            json=add_data,
            headers={"X-Api-Key": config.LIDARR_API_KEY},
            timeout=30,
        )

        if add_response.status_code in [200, 201]:
            return jsonify({"success": True, "artist": add_response.json()})
        elif (
            add_response.status_code == 400
            and "already been added" in add_response.text.lower()
        ):
            # Artist already exists, get their ID
            existing_response = mb_requests.get(
                f"{config.LIDARR_URL}/api/v1/artist",
                headers={"X-Api-Key": config.LIDARR_API_KEY},
                timeout=30,
            )
            if existing_response.status_code == 200:
                for artist in existing_response.json():
                    if artist["foreignArtistId"] == foreign_artist_id:
                        return jsonify(
                            {"success": True, "artist": artist, "already_existed": True}
                        )
            return (
                jsonify(
                    {
                        "success": False,
                        "error": "Artist already exists but couldn't retrieve",
                    }
                ),
                400,
            )
        else:
            return (
                jsonify(
                    {
                        "success": False,
                        "error": f"Failed to add artist: {add_response.text}",
                    }
                ),
                add_response.status_code,
            )

    except Exception as e:
        return _error_response(e)


@api.route("/api/lidarr/add-album", methods=["POST"])
def lidarr_add_album():
    """Add and monitor an album in Lidarr using MusicBrainz ID, then trigger search"""

    data = request.get_json()
    artist_name = data.get("artist")
    album_name = data.get("album")
    album_mbid = data.get("album_mbid")  # Release group MBID

    if not artist_name or not album_name:
        return jsonify({"error": "artist and album required"}), 400

    try:
        # Step 1: If no album MBID provided, search MusicBrainz first
        if not album_mbid:
            mb_headers = {
                "User-Agent": "NASRadio/1.0 (https://github.com/simpson1045/NASRadio)"
            }
            query = f'artist:"{artist_name}" AND releasegroup:"{album_name}"'
            mb_url = f"https://musicbrainz.org/ws/2/release-group?query={query}&limit=10&fmt=json"

            mb_response = mb_requests.get(mb_url, headers=mb_headers, timeout=25)
            if mb_response.status_code == 200:
                mb_data = mb_response.json()
                release_groups = mb_data.get("release-groups", [])
                if release_groups:
                    album_mbid = release_groups[0].get("id")

            if not album_mbid:
                return (
                    jsonify(
                        {
                            "success": False,
                            "error": "Could not find album in MusicBrainz",
                        }
                    ),
                    404,
                )

        # Step 2: Check if album already exists in Lidarr by searching all albums
        all_albums_response = mb_requests.get(
            f"{config.LIDARR_URL}/api/v1/album",
            headers={"X-Api-Key": config.LIDARR_API_KEY},
            timeout=30,
        )

        album_id = None
        artist_id = None
        if all_albums_response.status_code == 200:
            for album in all_albums_response.json():
                if album["foreignAlbumId"] == album_mbid:
                    album_id = album["id"]
                    artist_id = album["artistId"]
                    print(
                        f"DEBUG: Found existing album! album_id={album_id}, artist_id={artist_id}"
                    )
                    break

        # Step 3: If album not found, we need to add the artist first
        if album_id is None:

            # Look up album in Lidarr's database (not library)
            album_lookup = mb_requests.get(
                f"{config.LIDARR_URL}/api/v1/album/lookup",
                params={"term": f"mbid:{album_mbid}"},
                headers={"X-Api-Key": config.LIDARR_API_KEY},
                timeout=30,
            )

            if album_lookup.status_code != 200 or not album_lookup.json():
                return (
                    jsonify(
                        {
                            "success": False,
                            "error": "Album not found in Lidarr database",
                        }
                    ),
                    404,
                )

            album_data = album_lookup.json()[0]
            foreign_album_id = album_data["foreignAlbumId"]
            foreign_artist_id = album_data.get("artist", {}).get("foreignArtistId")

            print(
                f"DEBUG: Album lookup successful, foreign_artist_id={foreign_artist_id}"
            )

            # Check if artist exists
            artists_response = mb_requests.get(
                f"{config.LIDARR_URL}/api/v1/artist",
                headers={"X-Api-Key": config.LIDARR_API_KEY},
                timeout=30,
            )

            if artists_response.status_code == 200:
                for artist in artists_response.json():
                    if artist["foreignArtistId"] == foreign_artist_id:
                        artist_id = artist["id"]
                        break

            # Add artist if not exists
            if artist_id is None:

                # Get root folder, quality profile, metadata profile
                root_response = mb_requests.get(
                    f"{config.LIDARR_URL}/api/v1/rootfolder",
                    headers={"X-Api-Key": config.LIDARR_API_KEY},
                    timeout=10,
                )
                root_folder = (
                    root_response.json()[0]["path"]
                    if root_response.json()
                    else "/music"
                )

                quality_response = mb_requests.get(
                    f"{config.LIDARR_URL}/api/v1/qualityprofile",
                    headers={"X-Api-Key": config.LIDARR_API_KEY},
                    timeout=10,
                )
                quality_profile_id = (
                    quality_response.json()[0]["id"] if quality_response.json() else 1
                )

                metadata_response = mb_requests.get(
                    f"{config.LIDARR_URL}/api/v1/metadataprofile",
                    headers={"X-Api-Key": config.LIDARR_API_KEY},
                    timeout=10,
                )
                metadata_profile_id = (
                    metadata_response.json()[0]["id"] if metadata_response.json() else 1
                )

                # Look up artist
                artist_lookup = mb_requests.get(
                    f"{config.LIDARR_URL}/api/v1/artist/lookup",
                    params={"term": f"mbid:{foreign_artist_id}"},
                    headers={"X-Api-Key": config.LIDARR_API_KEY},
                    timeout=30,
                )

                if artist_lookup.status_code != 200 or not artist_lookup.json():
                    return (
                        jsonify(
                            {
                                "success": False,
                                "error": "Artist not found in Lidarr database",
                            }
                        ),
                        404,
                    )

                artist_data = artist_lookup.json()[0]

                add_artist_data = {
                    "foreignArtistId": artist_data["foreignArtistId"],
                    "artistName": artist_data["artistName"],
                    "qualityProfileId": quality_profile_id,
                    "metadataProfileId": metadata_profile_id,
                    "rootFolderPath": root_folder,
                    "monitored": False,
                    "addOptions": {
                        "monitor": "none",
                        "albumsToMonitor": [],
                        "searchForMissingAlbums": False,
                    },
                }

                add_artist_response = mb_requests.post(
                    f"{config.LIDARR_URL}/api/v1/artist",
                    json=add_artist_data,
                    headers={"X-Api-Key": config.LIDARR_API_KEY},
                    timeout=30,
                )

                if add_artist_response.status_code in [200, 201]:
                    artist_id = add_artist_response.json()["id"]
                else:
                    return (
                        jsonify(
                            {
                                "success": False,
                                "error": f"Failed to add artist: {add_artist_response.text}",
                            }
                        ),
                        500,
                    )

            # Now find the album (may need to wait for artist refresh)
            for attempt in range(15):
                time.sleep(5)

                albums_response = mb_requests.get(
                    f"{config.LIDARR_URL}/api/v1/album",
                    params={"artistId": artist_id},
                    headers={"X-Api-Key": config.LIDARR_API_KEY},
                    timeout=30,
                )

                if albums_response.status_code == 200:
                    for album in albums_response.json():
                        if album["foreignAlbumId"] == foreign_album_id:
                            album_id = album["id"]
                            break

                if album_id is not None:
                    break

            if album_id is None:
                return (
                    jsonify(
                        {
                            "success": False,
                            "error": "Album not found in Lidarr after adding artist. Try refreshing the artist in Lidarr.",
                        }
                    ),
                    404,
                )

        # Step 4: Monitor the album
        album_detail_response = mb_requests.get(
            f"{config.LIDARR_URL}/api/v1/album/{album_id}",
            headers={"X-Api-Key": config.LIDARR_API_KEY},
            timeout=10,
        )

        if album_detail_response.status_code == 200:
            album_detail = album_detail_response.json()
            album_detail["monitored"] = True

            mb_requests.put(
                f"{config.LIDARR_URL}/api/v1/album/{album_id}",
                json=album_detail,
                headers={"X-Api-Key": config.LIDARR_API_KEY},
                timeout=30,
            )

        # Step 5: Trigger album search
        search_response = mb_requests.post(
            f"{config.LIDARR_URL}/api/v1/command",
            json={"name": "AlbumSearch", "albumIds": [album_id]},
            headers={"X-Api-Key": config.LIDARR_API_KEY},
            timeout=30,
        )

        search_triggered = search_response.status_code in [200, 201]

        # Note: We don't wait for releases anymore - Lidarr searches asynchronously
        # and the release count check was unreliable due to timing issues

        return jsonify(
            {
                "success": True,
                "message": f"Added '{album_name}' by '{artist_name}' to Lidarr. Search triggered - check Lidarr for results.",
                "artist_id": artist_id,
                "album_id": album_id,
                "search_triggered": search_triggered,
            }
        )

    except Exception as e:

        traceback.print_exc()
        return _error_response(e)


@api.route("/api/lidarr/status", methods=["GET"])
def lidarr_status():
    """Check if Lidarr is reachable"""

    try:
        response = mb_requests.get(
            f"{config.LIDARR_URL}/api/v1/system/status",
            headers={"X-Api-Key": config.LIDARR_API_KEY},
            timeout=10,
        )

        if response.status_code == 200:
            return jsonify({"success": True, "status": response.json()})
        else:
            return (
                jsonify(
                    {
                        "success": False,
                        "error": f"Lidarr returned {response.status_code}",
                    }
                ),
                response.status_code,
            )

    except Exception as e:
        return _error_response(e)


@api.route("/api/missing-albums", methods=["GET"])
def get_aggregated_missing_albums():
    """Get all unique albums that are missing from imported Spotify playlists"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Get all unique album/artist combinations from unavailable playlist songs
        cursor.execute(
            """
            SELECT 
                spotify_album as album_name,
                spotify_artist as artist_name,
                COUNT(*) as track_count,
                STRING_AGG(DISTINCT spotify_track_name) as track_names,
                STRING_AGG(DISTINCT spotify_track_id) as spotify_track_ids,
                MIN(mbid) as mbid,
                STRING_AGG(DISTINCT playlist_id) as playlist_ids
            FROM playlist_songs
            WHERE song_id IS NULL
            AND spotify_album IS NOT NULL
            AND spotify_album != ''
            GROUP BY spotify_album, spotify_artist
            ORDER BY artist_name, album_name
            """
        )

        missing_albums = []
        for row in cursor.fetchall():
            album = dict(row)
            # Convert comma-separated playlist IDs to list
            album["playlist_ids"] = (
                [int(pid) for pid in album["playlist_ids"].split(",")]
                if album["playlist_ids"]
                else []
            )
            # Convert track names to list (limit to first 10 for display)
            track_names = (
                album["track_names"].split(",") if album["track_names"] else []
            )
            album["sample_tracks"] = track_names[:10]
            album["total_tracks"] = len(track_names)
            del album["track_names"]
            missing_albums.append(album)

        # Get playlist names for reference
        playlist_ids = set()
        for album in missing_albums:
            playlist_ids.update(album["playlist_ids"])

        playlist_names = {}
        if playlist_ids:
            placeholders = ",".join(["%s"] * len(playlist_ids))
            cursor.execute(
                f"SELECT id, name FROM playlists WHERE id IN ({placeholders})",
                list(playlist_ids),
            )
            playlist_names = {row["id"]: row["name"] for row in cursor.fetchall()}

        # Add playlist names to each album
        for album in missing_albums:
            album["playlists"] = [
                {"id": pid, "name": playlist_names.get(pid, "Unknown")}
                for pid in album["playlist_ids"]
            ]
            del album["playlist_ids"]

        # Summary stats
        total_albums = len(missing_albums)
        total_tracks = sum(album["track_count"] for album in missing_albums)
        unique_artists = len(set(album["artist_name"] for album in missing_albums))

        return jsonify(
            {
                "success": True,
                "missing_albums": missing_albums,
                "stats": {
                    "total_albums": total_albums,
                    "total_tracks": total_tracks,
                    "unique_artists": unique_artists,
                },
            }
        )

    except Exception as e:

        traceback.print_exc()
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/playlists/relink-missing", methods=["POST"])
def relink_missing_playlist_songs():
    """Re-scan all missing playlist songs and try to link them to library tracks"""
    from app.spotify_import import SpotifyImporter

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Get all missing playlist songs in the current user's playlists
        cursor.execute(
            """
            SELECT id, playlist_id, spotify_track_name, spotify_artist, spotify_album
            FROM playlist_songs
            WHERE song_id IS NULL
            AND spotify_track_name IS NOT NULL
            AND playlist_id IN (SELECT id FROM playlists WHERE user_id = %s)
            """,
            (auth.current_user_id(),),
        )

        missing_songs = cursor.fetchall()
        print(f"🔍 Found {len(missing_songs)} missing playlist songs to check")

        # Use the SpotifyImporter's matching logic
        importer = SpotifyImporter()

        linked_count = 0
        linked_details = []

        for row in missing_songs:
            track_name = row["spotify_track_name"]
            # Split artist string into list (might be "Artist1, Artist2")
            artist_names = (
                [a.strip() for a in row["spotify_artist"].split(",")]
                if row["spotify_artist"]
                else []
            )

            # Try to find a match in the library
            local_song = importer.search_song_in_library(track_name, artist_names)

            if local_song:
                # Found a match! Update the playlist_songs entry
                cursor.execute(
                    "UPDATE playlist_songs SET song_id = %s WHERE id = %s",
                    (local_song["id"], row["id"]),
                )
                linked_count += 1
                linked_details.append(
                    {
                        "playlist_id": row["playlist_id"],
                        "spotify_track": track_name,
                        "spotify_artist": row["spotify_artist"],
                        "matched_title": local_song["title"],
                        "matched_artist": local_song["artist_name"],
                    }
                )
                print(
                    f"  ✅ Linked: '{track_name}' -> '{local_song['title']}' by {local_song['artist_name']}"
                )

        conn.commit()

        # Update playlist song counts
        if linked_count > 0:
            # Get affected playlist IDs
            affected_playlists = set(d["playlist_id"] for d in linked_details)
            for playlist_id in affected_playlists:
                # Recalculate song count and duration
                cursor.execute(
                    """
                    UPDATE playlists SET 
                        song_count = (SELECT COUNT(*) FROM playlist_songs WHERE playlist_id = %s AND song_id IS NOT NULL),
                        total_duration = (SELECT COALESCE(SUM(songs.duration), 0) 
                                         FROM playlist_songs 
                                         JOIN songs ON playlist_songs.song_id = songs.id 
                                         WHERE playlist_songs.playlist_id = %s)
                    WHERE id = %s
                    """,
                    (playlist_id, playlist_id, playlist_id),
                )
            conn.commit()

        print(
            f"🎉 Relink complete! Linked {linked_count} of {len(missing_songs)} missing songs"
        )

        return jsonify(
            {
                "success": True,
                "checked": len(missing_songs),
                "linked": linked_count,
                "details": linked_details[
                    :50
                ],  # Limit details to first 50 for response size
            }
        )

    except Exception as e:

        traceback.print_exc()
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/library/search-song", methods=["GET"])
def search_library_song():
    """Search library for a song by title and optionally artist/album"""

    title = request.args.get("title", "")
    artist = request.args.get("artist", "")
    album = request.args.get("album", "")
    limit = request.args.get("limit", 20, type=int)

    if not title:
        return jsonify({"error": "title is required"}), 400

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Strip punctuation helper — same approach as main /api/search
        strip_punct = "regexp_replace(LOWER({}), '[^a-z0-9 ]', '', 'g')"

        # Normalize the search title: lowercase and strip punctuation
        normalized_title = re.sub(r"[^a-z0-9 ]", "", title.lower())
        search_title = f"%{normalized_title}%"

        # Build strict WHERE clause (punctuation-stripped LIKE match)
        strict_where = f"{strip_punct.format('s.title')} LIKE %s"
        strict_params = [search_title]

        # Build fuzzy WHERE clause (trigram similarity for typo tolerance)
        fuzzy_where = f"similarity({strip_punct.format('s.title')}, %s) > 0.3"
        fuzzy_params = [normalized_title]

        # Optional artist/album filters (applied to both strict and fuzzy)
        extra_filters = ""
        extra_params = []
        if artist:
            normalized_artist = re.sub(r"[^a-z0-9 ]", "", artist.lower())
            extra_filters += f" AND {strip_punct.format('a.name')} LIKE %s"
            extra_params.append(f"%{normalized_artist}%")

        if album:
            normalized_album = re.sub(r"[^a-z0-9 ]", "", album.lower())
            extra_filters += f" AND {strip_punct.format('al.title')} LIKE %s"
            extra_params.append(f"%{normalized_album}%")

        # Also search across artist name for better ranking
        artist_where = f"{strip_punct.format('a.name')} LIKE %s"
        normalized_artist_search = re.sub(r"[^a-z0-9 ]", "", (artist or title).lower())
        artist_search_param = f"%{normalized_artist_search}%"

        # Combined query: strict matches first, then fuzzy fallback
        # Ranking: exact title+artist > exact title > partial title+artist > partial > fuzzy
        query = f"""
            SELECT s.id, s.title, s.duration, s.file_path,
                   a.id as artist_id, a.name as artist_name,
                   al.id as album_id, al.title as album_title, al.artwork_path
            FROM songs s
            JOIN artists a ON s.artist_id = a.id
            JOIN albums al ON s.album_id = al.id
            WHERE (({strict_where}) OR ({fuzzy_where}) OR ({artist_where})){extra_filters}
            ORDER BY
                CASE WHEN LOWER(s.title) = LOWER(%s) AND {strip_punct.format('a.name')} LIKE %s THEN 0
                     WHEN LOWER(s.title) = LOWER(%s) THEN 1
                     WHEN {strip_punct.format('s.title')} LIKE %s AND {strip_punct.format('a.name')} LIKE %s THEN 2
                     WHEN {strip_punct.format('s.title')} LIKE %s THEN 3
                     ELSE 4 END,
                similarity({strip_punct.format('s.title')}, %s) DESC
            LIMIT %s
        """
        params = (strict_params + fuzzy_params + [artist_search_param] + extra_params +
                  [title, artist_search_param, title, search_title, artist_search_param, search_title, normalized_title, limit])

        cursor.execute(query, params)

        songs = [dict(row) for row in cursor.fetchall()]

        return jsonify({"success": True, "songs": songs, "count": len(songs)})

    except Exception as e:
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/playlist-song/link", methods=["POST"])
def link_playlist_song_to_library():
    """Manually link a missing playlist song to a library song"""
    data = request.get_json()

    # Can link by either playlist_song_id or by spotify track info
    spotify_artist = data.get("spotify_artist")
    spotify_album = data.get("spotify_album")
    spotify_track = data.get("spotify_track")
    library_song_id = data.get("library_song_id")

    if not library_song_id:
        return jsonify({"error": "library_song_id is required"}), 400

    if not spotify_artist or not spotify_track:
        return jsonify({"error": "spotify_artist and spotify_track are required"}), 400

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Find the playlist_songs entries that match
        if spotify_album:
            cursor.execute(
                """
                SELECT id, playlist_id FROM playlist_songs
                WHERE spotify_artist = %s AND spotify_album = %s AND spotify_track_name = %s
                AND song_id IS NULL
                AND playlist_id IN (SELECT id FROM playlists WHERE user_id = %s)
                """,
                (spotify_artist, spotify_album, spotify_track, auth.current_user_id()),
            )
        else:
            cursor.execute(
                """
                SELECT id, playlist_id FROM playlist_songs
                WHERE spotify_artist = %s AND spotify_track_name = %s
                AND song_id IS NULL
                AND playlist_id IN (SELECT id FROM playlists WHERE user_id = %s)
                """,
                (spotify_artist, spotify_track, auth.current_user_id()),
            )

        entries = cursor.fetchall()

        if not entries:
            return (
                jsonify(
                    {"success": False, "error": "No matching playlist entries found"}
                ),
                404,
            )

        # Update all matching entries
        updated_count = 0
        affected_playlists = set()

        for entry in entries:
            cursor.execute(
                "UPDATE playlist_songs SET song_id = %s, manually_fixed = TRUE WHERE id = %s",
                (library_song_id, entry["id"]),
            )
            updated_count += cursor.rowcount
            affected_playlists.add(entry["playlist_id"])

        # Update playlist stats
        for playlist_id in affected_playlists:
            cursor.execute(
                """
                UPDATE playlists SET 
                    song_count = (SELECT COUNT(*) FROM playlist_songs WHERE playlist_id = %s AND song_id IS NOT NULL),
                    total_duration = (SELECT COALESCE(SUM(songs.duration), 0) 
                                     FROM playlist_songs 
                                     JOIN songs ON playlist_songs.song_id = songs.id 
                                     WHERE playlist_songs.playlist_id = %s)
                WHERE id = %s
                """,
                (playlist_id, playlist_id, playlist_id),
            )

        conn.commit()

        # Get the library song info for the response
        cursor.execute(
            "SELECT title, (SELECT name FROM artists WHERE id = songs.artist_id) as artist_name FROM songs WHERE id = %s",
            (library_song_id,),
        )
        song_info = cursor.fetchone()

        return jsonify(
            {
                "success": True,
                "message": f"Linked '{spotify_track}' to '{song_info['title']}' by {song_info['artist_name']}",
                "updated_entries": updated_count,
                "affected_playlists": len(affected_playlists),
            }
        )

    except Exception as e:

        traceback.print_exc()
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/edit/album/<int:album_id>/artist", methods=["PUT"])
def edit_album_artist(album_id):
    """Change an album's artist"""
    data = request.get_json()
    new_artist_id = data.get("artist_id")
    update_song_artists = data.get("update_song_artists", False)

    if not new_artist_id:
        return jsonify({"error": "artist_id is required"}), 400

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Handle "various_artists" string
        if new_artist_id == "various_artists":
            cursor.execute("SELECT id FROM artists WHERE name = 'Various Artists'")
            row = cursor.fetchone()
            if row:
                new_artist_id = row["id"]
            else:
                cursor.execute(
                    "INSERT INTO artists (name, song_count, album_count) VALUES ('Various Artists', 0, 0) RETURNING id"
                )
                new_artist_id = cursor.fetchone()["id"]

        # Handle "new:ArtistName" format - create new artist
        elif isinstance(new_artist_id, str) and new_artist_id.startswith("new:"):
            artist_name = new_artist_id[4:]  # Remove "new:" prefix
            if not artist_name:
                return jsonify({"error": "Artist name cannot be empty"}), 400

            # Check if artist already exists (case-insensitive)
            cursor.execute(
                "SELECT id FROM artists WHERE LOWER(name) = LOWER(%s)", (artist_name,)
            )
            existing = cursor.fetchone()
            if existing:
                new_artist_id = existing["id"]
            else:
                cursor.execute(
                    "INSERT INTO artists (name, song_count, album_count) VALUES (%s, 0, 0) RETURNING id",
                    (artist_name,),
                )
                new_artist_id = cursor.fetchone()["id"]

        # Verify artist exists
        cursor.execute("SELECT id, name FROM artists WHERE id = %s", (new_artist_id,))
        artist = cursor.fetchone()
        if not artist:
            return jsonify({"error": "Artist not found"}), 404

        # Update album
        cursor.execute(
            "UPDATE albums SET artist_id = %s WHERE id = %s", (new_artist_id, album_id)
        )

        # Optionally update all song artists in this album
        if update_song_artists:
            # Get all song IDs in this album
            cursor.execute("SELECT id FROM songs WHERE album_id = %s", (album_id,))
            song_ids = [row["id"] for row in cursor.fetchall()]

            if song_ids:
                placeholders = ",".join(["%s"] * len(song_ids))

                # Update songs.artist_id
                cursor.execute(
                    f"UPDATE songs SET artist_id = %s WHERE id IN ({placeholders})",
                    [new_artist_id] + song_ids,
                )

                # Update song_artists - remove existing entries and add new one
                cursor.execute(
                    f"DELETE FROM song_artists WHERE song_id IN ({placeholders})",
                    song_ids,
                )

                # Add new artist as primary for each song
                for song_id in song_ids:
                    cursor.execute(
                        "INSERT INTO song_artists (song_id, artist_id, position) VALUES (%s, %s, 0)",
                        (song_id, new_artist_id),
                    )

        # Update artist counts
        cursor.execute(
            """
            UPDATE artists SET 
                album_count = (SELECT COUNT(*) FROM albums WHERE artist_id = artists.id),
                song_count = (SELECT COUNT(*) FROM songs WHERE artist_id = artists.id)
        """
        )

        conn.commit()
        return jsonify(
            {"success": True, "message": f"Album artist changed to {artist['name']}"}
        )
    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/excluded-paths", methods=["GET"])
def get_excluded_paths():
    """Get all excluded file paths (manually deleted items)"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        cursor.execute(
            """
            SELECT id, file_path, original_title, original_artist, original_album, excluded_at
            FROM excluded_paths
            ORDER BY excluded_at DESC
            """
        )
        excluded = [dict(row) for row in cursor.fetchall()]
        return jsonify(excluded)
    finally:
        conn.close()


@api.route("/api/excluded-paths/<int:exclusion_id>", methods=["DELETE"])
def restore_excluded_path(exclusion_id):
    """Remove a path from exclusions (allows re-import on next scan)"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Get the path info for response
        cursor.execute(
            "SELECT file_path, original_title FROM excluded_paths WHERE id = %s",
            (exclusion_id,),
        )
        excluded = cursor.fetchone()
        if not excluded:
            conn.close()
            return jsonify({"error": "Exclusion not found"}), 404

        file_path = excluded["file_path"]
        title = excluded["original_title"] or file_path

        # Remove from exclusions
        cursor.execute("DELETE FROM excluded_paths WHERE id = %s", (exclusion_id,))
        conn.commit()

        return jsonify(
            {
                "success": True,
                "message": f"Restored '{title}' - will be imported on next scan",
            }
        )
    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/excluded-paths/clear", methods=["DELETE"])
def clear_all_exclusions():
    """Clear all exclusions (allows all files to be re-imported)"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        cursor.execute("SELECT COUNT(*) as count FROM excluded_paths")
        count = cursor.fetchone()["count"]

        cursor.execute("DELETE FROM excluded_paths")
        conn.commit()

        return jsonify(
            {
                "success": True,
                "message": f"Cleared {count} exclusions - all files can be re-imported",
            }
        )
    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/imports/import", methods=["POST"])
def import_album():
    """Import a downloaded album into the library"""

    from mutagen import File as MutagenFile

    data = request.get_json()
    source_path = data.get("source_path")
    artist_name = data.get("artist_name", "").strip()
    album_title = data.get("album_title", "").strip()
    year = data.get("year")
    artist_mbid = data.get("artist_mbid")
    album_mbid = data.get("album_mbid")
    selected_files = data.get("selected_files")
    # Album editions (spec §3): attach this import as a new edition of
    # an existing album — the "album exists but lacks this mix" path.
    attach_to_album_id = data.get("attach_to_album_id")
    edition_label = (data.get("edition_label") or "").strip() or None

    print(f"DEBUG IMPORT START: artist={artist_name}, album={album_title}, year={year}")
    print(f"DEBUG IMPORT: source_path={source_path}")
    print(f"DEBUG IMPORT: selected_files={selected_files}")

    if not source_path or not artist_name or not album_title:
        print("DEBUG IMPORT: Missing required fields")
        return (
            jsonify({"error": "source_path, artist_name, and album_title required"}),
            400,
        )

    if not os.path.exists(source_path):
        print(f"DEBUG IMPORT: Source path does not exist: {source_path}")
        return jsonify({"error": "Source folder not found"}), 404

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # 1. Find or create artist
        print(f"DEBUG: Looking up artist: {artist_name}")
        cursor.execute(
            "SELECT id FROM artists WHERE LOWER(name) = LOWER(%s)", (artist_name,)
        )
        artist_row = cursor.fetchone()

        if artist_row:
            artist_id = artist_row["id"]
            print(f"DEBUG: Found existing artist_id={artist_id}")

            # Update artist mbid if we have one and they don't
            if artist_mbid:
                cursor.execute(
                    "UPDATE artists SET mbid = %s WHERE id = %s AND mbid IS NULL",
                    (artist_mbid, artist_id),
                )

            # Check if album already exists for this artist
            cursor.execute(
                "SELECT id, title FROM albums WHERE artist_id = %s AND LOWER(title) = LOWER(%s)",
                (artist_id, album_title),
            )
            existing_album = cursor.fetchone()
            if existing_album:
                print(f"DEBUG: Album already exists! ID={existing_album['id']}")
                return (
                    jsonify(
                        {
                            "error": f"Album '{existing_album['title']}' already exists for this artist",
                            "existing_album_id": existing_album["id"],
                        }
                    ),
                    400,
                )
        else:
            # Create new artist
            print(f"DEBUG: Creating new artist: {artist_name}")
            cursor.execute(
                "INSERT INTO artists (name, mbid) VALUES (%s, %s) RETURNING id",
                (artist_name, artist_mbid),
            )
            artist_id = cursor.fetchone()["id"]
            print(f"DEBUG: Created artist_id={artist_id}")

        # 2. Build destination path
        safe_artist = "".join(
            c for c in artist_name if c.isalnum() or c in " -_'"
        ).strip()
        safe_album = "".join(
            c for c in album_title if c.isalnum() or c in " -_'"
        ).strip()

        if year:
            dest_folder = f"{safe_artist}/{safe_album} ({year})"
        else:
            dest_folder = f"{safe_artist}/{safe_album}"

        dest_path = os.path.join(config.MUSIC_LIBRARY_PATH, dest_folder)
        print(f"DEBUG: dest_path={dest_path}")

        # Check if album folder already exists
        if os.path.exists(dest_path):
            print(f"DEBUG: Dest folder already exists!")
            return (
                jsonify({"error": f"Album folder already exists: {dest_folder}"}),
                400,
            )

        # === PRE-FLIGHT SOURCE VALIDATION ===
        # Verify every audio file in the source is actually a readable
        # audio file BEFORE we create any DB rows or copy any bytes. This
        # catches the torrent-client-pre-allocated-zero-files pattern (the
        # 2026-05-30 Brian May incident: Transmission reported the torrent
        # 100% complete but every .flac in /complete was 90+ MB of pure
        # nulls because the last seeder hadn't actually delivered any
        # pieces yet — the file was sparse-allocated at full size with no
        # data). Without this check, those files copy successfully (since
        # shutil just streams whatever bytes are there), mutagen then
        # throws on every one, and the loop's exception fallback inserts
        # a garbage song row per file with duration=0 and no track number
        # — leaving simpson1045 with a "successfully imported" album full of
        # unplayable junk that needed manual cleanup.
        _preflight_audio_exts = {
            ".flac", ".mp3", ".m4a", ".wav", ".ogg", ".opus",
            ".aac", ".wma", ".wv", ".ape", ".aiff", ".dsf", ".dff",
        }
        if selected_files:
            _preflight_files = [
                f for f in selected_files
                if os.path.exists(f)
                and os.path.splitext(f)[1].lower() in _preflight_audio_exts
            ]
        else:
            _preflight_files = []
            for _r, _ds, _fs in os.walk(source_path):
                for _fn in _fs:
                    if os.path.splitext(_fn)[1].lower() in _preflight_audio_exts:
                        _preflight_files.append(os.path.join(_r, _fn))

        if not _preflight_files:
            return jsonify({
                "error": "No audio files found in source folder. "
                         "Nothing was copied.",
            }), 400

        _validation_errors = []
        for _src in _preflight_files:
            _base = os.path.basename(_src)
            try:
                _size = os.path.getsize(_src)
            except OSError as _e:
                _validation_errors.append((_base, f"can't stat file: {_e}"))
                continue
            if _size == 0:
                _validation_errors.append((_base, "0 bytes (empty file)"))
                continue
            try:
                _audio = MutagenFile(_src, easy=True)
            except Exception as _e:
                # FLACNoHeaderError / MP4StreamInfoError / etc., including
                # the all-zeros-but-right-size case from torrent pre-alloc.
                _msg = str(_e).split(":")[-1].strip()[:90] or "unreadable"
                _validation_errors.append((_base, _msg))
                continue
            if _audio is None:
                _validation_errors.append((_base, "not a recognized audio format"))
                continue
            if not _audio.info or getattr(_audio.info, "length", 0) == 0:
                _validation_errors.append((_base, "no audio data (0-second length)"))
                continue

        if _validation_errors:
            _lines = [f"  • {f}: {r}" for f, r in _validation_errors[:10]]
            if len(_validation_errors) > 10:
                _lines.append(f"  • ...and {len(_validation_errors) - 10} more")
            _msg = (
                f"Pre-flight validation failed: "
                f"{len(_validation_errors)} of {len(_preflight_files)} source "
                f"audio file(s) are corrupted or incomplete:\n"
                + "\n".join(_lines)
                + "\n\nNothing was copied or imported. The torrent may not have "
                  "finished downloading — check that all source files play "
                  "correctly first."
            )
            print(f"DEBUG IMPORT: pre-flight validation FAILED:\n{_msg}")
            return jsonify({
                "error": _msg,
                "validation_failed": True,
                "failed_count": len(_validation_errors),
                "total_count": len(_preflight_files),
            }), 400

        print(f"DEBUG IMPORT: pre-flight validation OK ({len(_preflight_files)} files)")

        # 3. Create album in database
        print(f"DEBUG: Creating album in database")
        cursor.execute(
            """INSERT INTO albums (title, artist_id, year, mbid, folder_path) 
               VALUES (%s, %s, %s, %s, %s) RETURNING id""",
            (album_title, artist_id, year, album_mbid, dest_path),
        )
        album_id = cursor.fetchone()["id"]
        print(f"DEBUG: Created album_id={album_id}")

        # Attach as edition (spec §3): join (or create) the anchor
        # album's group. The group inherits the anchor's base title
        # (any trailing "(...)" edition suffix stripped) and its
        # release-group mbid.
        if attach_to_album_id:
            cursor.execute(
                "SELECT id, title, artist_id, group_id, mbid FROM albums "
                "WHERE id = %s",
                (attach_to_album_id,),
            )
            anchor = cursor.fetchone()
            if anchor:
                group_id = anchor["group_id"]
                if not group_id:
                    base_title = re.sub(
                        r"\s*\([^)]*\)\s*$", "", anchor["title"]
                    ).strip() or anchor["title"]
                    cursor.execute(
                        "INSERT INTO album_groups (title, artist_id, mbid) "
                        "VALUES (%s, %s, %s) RETURNING id",
                        (base_title, anchor["artist_id"], anchor["mbid"]),
                    )
                    group_id = cursor.fetchone()["id"]
                    cursor.execute(
                        "UPDATE albums SET group_id = %s WHERE id = %s",
                        (group_id, anchor["id"]),
                    )
                cursor.execute(
                    "UPDATE albums SET group_id = %s, edition_label = %s "
                    "WHERE id = %s",
                    (group_id, edition_label, album_id),
                )
                print(
                    f"DEBUG: album {album_id} attached as edition "
                    f"'{edition_label}' of group {group_id}"
                )

        # 4. Move files to destination
        os.makedirs(dest_path, exist_ok=True)
        print(f"DEBUG: Created destination folder")

        audio_extensions = {
            ".flac",
            ".mp3",
            ".m4a",
            ".wav",
            ".ogg",
            ".opus",
            ".aac",
            ".wma",
            ".wv",
            ".ape",
            ".aiff",
            ".dsf",
            ".dff",
        }
        image_extensions = {".jpg", ".jpeg", ".png", ".gif", ".bmp"}

        # Check for CUE files - only skip if single-file album
        cue_source_files = set()
        for root, dirs, files in os.walk(source_path):
            for filename in files:
                if filename.lower().endswith(".cue"):
                    cue_path = os.path.join(root, filename)
                    try:
                        with open(
                            cue_path, "r", encoding="utf-8", errors="ignore"
                        ) as f:
                            cue_files_in_this_cue = []
                            for line in f:
                                line = line.strip()
                                if line.upper().startswith("FILE "):

                                    match = re.search(
                                        r'FILE\s+"([^"]+)"', line, re.IGNORECASE
                                    )
                                    if match:
                                        cue_files_in_this_cue.append(
                                            match.group(1).lower()
                                        )

                            if len(cue_files_in_this_cue) == 1:
                                cue_source_files.add(cue_files_in_this_cue[0])
                                print(
                                    f"DEBUG: Will skip single-file CUE source: {cue_files_in_this_cue[0]}"
                                )
                    except Exception as e:
                        print(f"DEBUG: Error reading CUE file {cue_path}: {e}")

        tracks_added = 0

        # Build list of files to process
        if selected_files:
            files_to_process = [f for f in selected_files if os.path.exists(f)]
            print(f"DEBUG: Selected files mode, {len(files_to_process)} files")
        else:
            files_to_process = []
            for root, dirs, files in os.walk(source_path):
                for filename in files:
                    files_to_process.append(os.path.join(root, filename))
            print(f"DEBUG: Walk mode, {len(files_to_process)} files found")

        print(f"DEBUG: Starting file processing loop")
        print(f"DEBUG: audio_extensions={audio_extensions}")
        print(f"DEBUG: cue_source_files={cue_source_files}")

        # Count total audio files for progress
        total_audio_files = sum(
            1
            for f in files_to_process
            if os.path.splitext(f)[1].lower() in audio_extensions
            and os.path.basename(f).lower() not in cue_source_files
        )
        current_track = 0

        safe_emit(
            "import_progress",
            {
                "status": "starting",
                "current": 0,
                "total": total_audio_files,
                "message": f"Importing {total_audio_files} tracks to {album_title}",
            },
        )

        for src_file in files_to_process:
            filename = os.path.basename(src_file)

            # Skip files referenced by CUE sheets
            if filename.lower() in cue_source_files:
                print(f"DEBUG: Skipping CUE source file: {filename}")
                continue

            ext = os.path.splitext(filename)[1].lower()

            # Copy audio files and images
            if ext in audio_extensions or ext in image_extensions:
                dest_file = os.path.join(dest_path, filename)

                # Handle duplicates
                counter = 1
                base, extension = os.path.splitext(filename)
                while os.path.exists(dest_file):
                    dest_file = os.path.join(dest_path, f"{base}_{counter}{extension}")
                    counter += 1

                try:
                    shutil.copy2(src_file, dest_file)
                except Exception as copy_err:
                    print(f"DEBUG ERROR: Failed to copy {src_file}: {copy_err}")
                    traceback.print_exc()
                    continue

                # Add audio files to database
                if ext in audio_extensions:
                    try:
                        # Read metadata from the SOURCE file, not the
                        # destination. Mutagen reads on the destination
                        # (which is on a remote SMB share) have been
                        # observed to return incomplete `audio.info` —
                        # tags read fine but `audio.info.length` is 0,
                        # OR mutagen throws entirely — on files that
                        # are genuinely valid and play correctly later.
                        # The source is what the pre-flight already
                        # validated, so re-reading the same path here
                        # is reliable. Past damage from this: every
                        # all-songs-duration-0 album in simpson1045's library
                        # (Maniac, Goldmine, Hendrix, Depeche, etc. —
                        # see the 2026-05-30 audit).
                        audio = MutagenFile(src_file, easy=True)
                        print(
                            f"DEBUG DB: {filename} - audio={audio}, type={type(audio)}"
                        )

                        if audio:
                            # Get title - prefer tag, fallback to filename
                            if audio.get("title"):
                                title = audio.get("title")[0]
                            else:
                                title, parsed_track_num = extract_title_from_filename(
                                    filename, artist_name, album_title
                                )

                            current_track += 1
                            safe_emit(
                                "import_progress",
                                {
                                    "status": "importing",
                                    "current": current_track,
                                    "total": total_audio_files,
                                    "track_name": title,
                                    "message": f"Track {current_track}/{total_audio_files}: {title}",
                                },
                            )

                            # Get track number from tag, fallback to parsed from filename
                            track_num = 0
                            if audio.get("tracknumber"):
                                try:
                                    track_num = int(
                                        audio.get("tracknumber", ["0"])[0].split("/")[0]
                                    )
                                except Exception:
                                    pass
                            if (
                                track_num == 0
                                and "parsed_track_num" in dir()
                                and parsed_track_num > 0
                            ):
                                track_num = parsed_track_num
                            disc_num = 1
                            # First check folder path for disc indicators
                            folder_disc_match = re.search(
                                r"(?:disc|cd|disk)\s*(\d+)", src_file, re.IGNORECASE
                            )
                            if folder_disc_match:
                                disc_num = int(folder_disc_match.group(1))
                            elif audio.get("discnumber"):
                                try:
                                    disc_num = int(
                                        audio.get("discnumber", ["1"])[0].split("/")[0]
                                    )
                                except Exception:
                                    pass
                            duration = int(audio.info.length) if audio.info else 0

                            print(
                                f"DEBUG DB INSERT: title={title}, track={track_num}, disc={disc_num}, duration={duration}"
                            )
                            file_size = (
                                os.path.getsize(dest_file)
                                if os.path.exists(dest_file)
                                else 0
                            )
                            bitrate = (
                                audio.info.bitrate
                                if audio.info and hasattr(audio.info, "bitrate")
                                else 0
                            )
                            cursor.execute(
                                """INSERT INTO songs (title, artist_id, album_id, track_number, disc_number, duration, file_path, file_size, bitrate)
                                       VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)""",
                                (
                                    title,
                                    artist_id,
                                    album_id,
                                    track_num,
                                    disc_num,
                                    duration,
                                    dest_file,
                                    file_size,
                                    bitrate,
                                ),
                            )
                            tracks_added += 1
                            print(f"DEBUG: tracks_added now = {tracks_added}")
                        else:
                            # Mutagen returned None — file isn't a recognized
                            # audio format. With pre-flight validation in
                            # place this should be effectively unreachable
                            # (pre-flight would have aborted the import).
                            # Log it and SKIP — don't insert a row with
                            # placeholder values. That's what produced years
                            # of garbage albums (Maniac, Goldmine, etc.)
                            # before the 2026-05-30 audit.
                            print(
                                f"DEBUG DB: audio is None for {filename} — "
                                f"SKIPPING (pre-flight should have caught this; "
                                f"copied file may have been corrupted in transit)"
                            )
                            try:
                                if os.path.exists(dest_file):
                                    os.remove(dest_file)
                            except Exception as cleanup_err:
                                print(f"DEBUG: cleanup of dest_file failed: {cleanup_err}")
                    except Exception as e:
                        # Mutagen threw — same reasoning. Pre-flight should
                        # have caught the bad file; if we got here something
                        # changed between pre-flight and now (rare race).
                        # Log + skip rather than insert a row with the raw
                        # filename as a title and duration=0.
                        print(f"DEBUG DB ERROR: Exception for {filename}: {e} — SKIPPING")
                        traceback.print_exc()
                        try:
                            if os.path.exists(dest_file):
                                os.remove(dest_file)
                        except Exception as cleanup_err:
                            print(f"DEBUG: cleanup of dest_file failed: {cleanup_err}")

        print(f"DEBUG: File loop complete. tracks_added = {tracks_added}")

        # 5. Check if any tracks were added
        if tracks_added == 0:
            print("DEBUG: No tracks added! Rolling back...")
            conn.rollback()
            if os.path.exists(dest_path):
                shutil.rmtree(dest_path)
            return (
                jsonify(
                    {"success": False, "error": "No audio files found in source folder"}
                ),
                400,
            )

        # 6. Update album song count
        cursor.execute(
            "UPDATE albums SET song_count = %s WHERE id = %s",
            (tracks_added, album_id),
        )

        # 7. Update artist album/song counts
        cursor.execute(
            """
            UPDATE artists SET 
                album_count = (SELECT COUNT(*) FROM albums WHERE artist_id = artists.id),
                song_count = (SELECT COUNT(*) FROM songs WHERE artist_id = artists.id)
            WHERE id = %s
        """,
            (artist_id,),
        )

        # 8. Delete source folder or selected files
        if selected_files:
            for file_path in selected_files:
                try:
                    if os.path.exists(file_path):
                        os.remove(file_path)
                except Exception as e:
                    print(f"DEBUG: Error deleting {file_path}: {e}")
            remaining_audio = False
            for root, dirs, files in os.walk(source_path):
                for f in files:
                    if os.path.splitext(f)[1].lower() in audio_extensions:
                        remaining_audio = True
                        break
                if remaining_audio:
                    break
            if not remaining_audio:
                shutil.rmtree(source_path)
        else:
            shutil.rmtree(source_path)

        # 9. Collect local images that were copied to destination
        local_images = []
        cover_priority_names = ["cover", "folder", "front", "album", "artwork"]

        for filename in os.listdir(dest_path):
            ext = os.path.splitext(filename)[1].lower()
            if ext in image_extensions:
                name_lower = os.path.splitext(filename)[0].lower()
                priority = 99
                for i, priority_name in enumerate(cover_priority_names):
                    if priority_name in name_lower:
                        priority = i
                        break

                file_path = os.path.join(dest_path, filename)
                file_size = os.path.getsize(file_path)

                local_images.append(
                    {
                        "filename": filename,
                        "size": file_size,
                        "size_formatted": format_size(file_size),
                        "priority": priority,
                    }
                )

        local_images.sort(key=lambda x: (x["priority"], -x["size"]))
        print(f"DEBUG: Found {len(local_images)} local images")

        conn.commit()
        print(f"DEBUG: COMMIT successful! Returning success response")

        return jsonify(
            {
                "success": True,
                "message": f"Imported {tracks_added} tracks",
                "album_id": album_id,
                "artist_id": artist_id,
                "destination": dest_path,
                "local_images": local_images,
            }
        )

    except Exception as e:
        print(f"DEBUG EXCEPTION: {e}")
        traceback.print_exc()
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/imports/parse-cue", methods=["POST"])
def parse_cue_file():
    """Parse a CUE file and return track information"""

    data = request.get_json()
    folder_path = data.get("path")
    specific_cue_file = data.get("cue_file")  # Optional: specific CUE file path

    if not folder_path:
        return jsonify({"error": "path required"}), 400

    # Use specific CUE file if provided, otherwise find one
    cue_file = None
    flac_file = None

    if specific_cue_file and os.path.exists(specific_cue_file):
        cue_file = specific_cue_file
    else:
        for root, dirs, files in os.walk(folder_path):
            for f in files:
                if f.lower().endswith(".cue"):
                    cue_file = os.path.join(root, f)
                if f.lower().endswith(".flac") and flac_file is None:
                    flac_file = os.path.join(root, f)

    if not cue_file:
        return jsonify({"success": False, "error": "No CUE file found in folder"}), 404

    # Parse CUE file
    try:
        # Try different encodings
        content = None
        for encoding in ["utf-8", "latin-1", "cp1252", "shift-jis"]:
            try:
                with open(cue_file, "r", encoding=encoding) as f:
                    content = f.read()
                break
            except UnicodeDecodeError:
                continue

        if content is None:
            return (
                jsonify({"success": False, "error": "Could not decode CUE file"}),
                400,
            )

        tracks = []
        current_track = None
        album_performer = None
        album_title = None
        source_file = None

        for line in content.split("\n"):
            line = line.strip()

            # Get source file
            if line.upper().startswith("FILE "):
                match = re.search(r'FILE\s+"([^"]+)"', line, re.IGNORECASE)
                if match:
                    source_file = match.group(1)

            # Get album performer
            elif line.upper().startswith("PERFORMER ") and current_track is None:
                match = re.search(r'PERFORMER\s+"([^"]+)"', line, re.IGNORECASE)
                if match:
                    album_performer = match.group(1)

            # Get album title
            elif line.upper().startswith("TITLE ") and current_track is None:
                match = re.search(r'TITLE\s+"([^"]+)"', line, re.IGNORECASE)
                if match:
                    album_title = match.group(1)

            # New track
            elif line.upper().startswith("TRACK "):
                match = re.search(r"TRACK\s+(\d+)", line, re.IGNORECASE)
                if match:
                    if current_track:
                        tracks.append(current_track)
                    current_track = {
                        "number": int(match.group(1)),
                        "title": None,
                        "performer": album_performer,  # Default to album performer
                        "start_time": None,
                        "start_seconds": None,
                    }

            # Track title
            elif line.upper().startswith("TITLE ") and current_track:
                match = re.search(r'TITLE\s+"([^"]+)"', line, re.IGNORECASE)
                if match:
                    current_track["title"] = match.group(1)

            # Track performer (override album performer)
            elif line.upper().startswith("PERFORMER ") and current_track:
                match = re.search(r'PERFORMER\s+"([^"]+)"', line, re.IGNORECASE)
                if match:
                    current_track["performer"] = match.group(1)

            # Index (start time)
            elif line.upper().startswith("INDEX 01"):
                # Try MM:SS:FF format first (with frames)
                match = re.search(
                    r"INDEX\s+01\s+(\d+):(\d+):(\d+)", line, re.IGNORECASE
                )
                if match and current_track:
                    mins = int(match.group(1))
                    secs = int(match.group(2))
                    frames = int(match.group(3))
                    # Convert to seconds (75 frames per second in CUE)
                    total_seconds = mins * 60 + secs + frames / 75
                    current_track["start_time"] = f"{mins}:{secs:02d}"
                    current_track["start_seconds"] = total_seconds
                else:
                    # Try MM:SS format (no frames)
                    match = re.search(
                        r"INDEX\s+01\s+(\d+):(\d+)(?:\s|$)", line, re.IGNORECASE
                    )
                    if match and current_track:
                        mins = int(match.group(1))
                        secs = int(match.group(2))
                        total_seconds = mins * 60 + secs
                        current_track["start_time"] = f"{mins}:{secs:02d}"
                        current_track["start_seconds"] = total_seconds

        # Don't forget last track
        if current_track:
            tracks.append(current_track)

        # Calculate durations (difference between start times)
        for i in range(len(tracks)):
            if i < len(tracks) - 1:
                # Duration is next track's start minus this track's start
                next_start = tracks[i + 1]["start_seconds"]
                this_start = tracks[i]["start_seconds"]
                if next_start and this_start:
                    tracks[i]["duration"] = int(next_start - this_start)
            else:
                # Last track - we don't know duration without reading the audio file
                tracks[i]["duration"] = None

        return jsonify(
            {
                "success": True,
                "cue_file": cue_file,
                "source_file": source_file,
                "album_title": album_title,
                "album_performer": album_performer,
                "track_count": len(tracks),
                "tracks": tracks,
            }
        )

    except Exception as e:
        return _error_response(e)


# CUE split cancellation
_cue_split_cancelled = False
_cue_split_pid = None


@api.route("/api/imports/cancel-cue-split", methods=["POST"])
def cancel_cue_split():
    """Cancel an in-progress CUE split operation"""
    global _cue_split_cancelled, _cue_split_pid
    _cue_split_cancelled = True
    # Kill the running ffmpeg process immediately
    if _cue_split_pid:
        import signal
        try:
            os.kill(_cue_split_pid, signal.SIGTERM)
        except (OSError, ProcessLookupError):
            pass
        _cue_split_pid = None
    return jsonify({"success": True, "message": "Cancel requested"})


@api.route("/api/imports/split-cue", methods=["POST"])
def split_cue_file():
    """Split audio files using CUE sheets into individual tracks (supports multi-disc)"""
    global _cue_split_cancelled
    _cue_split_cancelled = False

    data = request.get_json()
    folder_path = data.get("path")

    if not folder_path:
        return jsonify({"error": "path required"}), 400

    audio_extensions = [".flac", ".ape", ".wav", ".wv", ".aiff", ".aif", ".dsf", ".dff"]

    # Find ALL CUE files and their associated audio files
    cue_audio_pairs = []
    disc_pattern = re.compile(
        r"[\(\[\s\-_](CD|Disc|Disk|D|Side)\s*(\d+|[AB])[\)\]\s\-_]", re.IGNORECASE
    )

    for root, dirs, files in os.walk(folder_path):
        for f in files:
            if f.lower().endswith(".cue"):
                cue_path = os.path.join(root, f)
                cue_dir = os.path.dirname(cue_path)
                cue_base = os.path.splitext(f)[0]

                # Detect disc number from filename OR folder name
                disc_number = 1
                match = disc_pattern.search(f)

                # If not found in filename, check folder name (for CD1/, Disc 2/ style folders)
                if not match:
                    folder_name = os.path.basename(root)
                    match = disc_pattern.search(folder_name)
                    # Also try simple patterns like "CD1" or "Disc2"
                    if not match:
                        match = re.match(
                            r"^(CD|Disc|Disk|D|Side)\s*(\d+|[AB])$",
                            folder_name,
                            re.IGNORECASE,
                        )

                if match:
                    disc_id = match.group(2)
                    if disc_id.upper() == "A":
                        disc_number = 1
                    elif disc_id.upper() == "B":
                        disc_number = 2
                    else:
                        disc_number = int(disc_id)

                # Find matching audio file
                audio_file = None

                # First try to parse CUE to find referenced file
                try:
                    for encoding in ["utf-8", "latin-1", "cp1252", "shift-jis"]:
                        try:
                            with open(cue_path, "r", encoding=encoding) as cf:
                                for line in cf:
                                    if line.strip().upper().startswith("FILE "):
                                        file_match = re.search(
                                            r'FILE\s+"([^"]+)"', line, re.IGNORECASE
                                        )
                                        if file_match:
                                            ref_file = file_match.group(1)
                                            ref_path = os.path.join(cue_dir, ref_file)
                                            if os.path.exists(ref_path):
                                                audio_file = ref_path
                                            else:
                                                # Try same base name with different extensions
                                                ref_base = os.path.splitext(ref_file)[0]
                                                for ext in audio_extensions:
                                                    alt_path = os.path.join(
                                                        cue_dir, ref_base + ext
                                                    )
                                                    if os.path.exists(alt_path):
                                                        audio_file = alt_path
                                                        break
                                        break
                            break
                        except UnicodeDecodeError:
                            continue
                except Exception:
                    pass

                # Fallback: try same base name as CUE
                if not audio_file:
                    for ext in audio_extensions:
                        potential = os.path.join(cue_dir, cue_base + ext)
                        if os.path.exists(potential):
                            audio_file = potential
                            break

                if audio_file:
                    cue_audio_pairs.append(
                        {
                            "cue_file": cue_path,
                            "audio_file": audio_file,
                            "disc_number": disc_number,
                        }
                    )

    if not cue_audio_pairs:
        return (
            jsonify(
                {"success": False, "error": "No CUE files with matching audio found"}
            ),
            404,
        )

    # Sort by disc number
    cue_audio_pairs.sort(key=lambda x: x["disc_number"])

    # Determine total discs
    total_discs = len(cue_audio_pairs)
    is_multi_disc = total_discs > 1

    # Count total tracks across all discs for progress
    total_tracks_all_discs = 0
    for pair in cue_audio_pairs:
        try:
            for encoding in ["utf-8", "latin-1", "cp1252", "shift-jis"]:
                try:
                    with open(pair["cue_file"], "r", encoding=encoding) as f:
                        content = f.read()
                        pair["track_count"] = len(
                            re.findall(
                                r"^\s*TRACK\s+\d+",
                                content,
                                re.MULTILINE | re.IGNORECASE,
                            )
                        )
                        total_tracks_all_discs += pair["track_count"]
                    break
                except UnicodeDecodeError:
                    continue
        except Exception:
            pair["track_count"] = 0

    safe_emit(
        "cue_split_progress",
        {
            "status": "starting",
            "current": 0,
            "total": total_tracks_all_discs,
            "message": f"Found {total_discs} disc(s) with {total_tracks_all_discs} total tracks",
            "disc_count": total_discs,
        },
    )

    all_created_files = []
    total_tracks_created = 0
    global_track_index = 0
    files_to_cleanup = []

    try:
        for pair in cue_audio_pairs:
            cue_file = pair["cue_file"]
            source_audio = pair["audio_file"]
            disc_number = pair["disc_number"]

            print(f"Processing Disc {disc_number}: {os.path.basename(cue_file)}")

            # Parse CUE file
            content = None
            for encoding in ["utf-8", "latin-1", "cp1252", "shift-jis"]:
                try:
                    with open(cue_file, "r", encoding=encoding) as f:
                        content = f.read()
                    break
                except UnicodeDecodeError:
                    continue

            if content is None:
                print(f"Could not decode CUE file: {cue_file}")
                continue

            tracks = []
            current_track = None
            album_performer = None
            album_title = None

            for line in content.split("\n"):
                line = line.strip()

                if line.upper().startswith("PERFORMER ") and current_track is None:
                    match = re.search(r'PERFORMER\s+"([^"]+)"', line, re.IGNORECASE)
                    if match:
                        album_performer = match.group(1)

                elif line.upper().startswith("TITLE ") and current_track is None:
                    match = re.search(r'TITLE\s+"([^"]+)"', line, re.IGNORECASE)
                    if match:
                        album_title = match.group(1)

                elif line.upper().startswith("TRACK "):
                    match = re.search(r"TRACK\s+(\d+)", line, re.IGNORECASE)
                    if match:
                        if current_track:
                            tracks.append(current_track)
                        current_track = {
                            "number": int(match.group(1)),
                            "title": None,
                            "performer": album_performer,
                            "start_seconds": None,
                        }

                elif line.upper().startswith("TITLE ") and current_track:
                    match = re.search(r'TITLE\s+"([^"]+)"', line, re.IGNORECASE)
                    if match:
                        current_track["title"] = match.group(1)

                elif line.upper().startswith("PERFORMER ") and current_track:
                    match = re.search(r'PERFORMER\s+"([^"]+)"', line, re.IGNORECASE)
                    if match:
                        current_track["performer"] = match.group(1)

                elif line.upper().startswith("INDEX 01"):
                    match = re.search(
                        r"INDEX\s+01\s+(\d+):(\d+):(\d+)", line, re.IGNORECASE
                    )
                    if match and current_track:
                        mins = int(match.group(1))
                        secs = int(match.group(2))
                        frames = int(match.group(3))
                        total_seconds = mins * 60 + secs + frames / 75
                        current_track["start_seconds"] = total_seconds

            if current_track:
                tracks.append(current_track)

            if not tracks:
                print(f"No tracks found in CUE file: {cue_file}")
                continue

            # Check if source needs conversion
            source_ext = os.path.splitext(source_audio)[1].lower()
            temp_flac = None
            working_audio = source_audio

            if source_ext in [".ape", ".wv", ".tta"]:
                temp_flac = os.path.join(
                    folder_path, f"_temp_converted_disc{disc_number}.flac"
                )
                print(f"Converting {source_ext.upper()} to FLAC for disc {disc_number}")

                safe_emit(
                    "cue_split_progress",
                    {
                        "status": "converting",
                        "current": global_track_index,
                        "total": total_tracks_all_discs,
                        "message": f"Disc {disc_number}: Converting {source_ext.upper()} to FLAC...",
                        "disc_number": disc_number,
                    },
                )

                convert_cmd = [
                    "ffmpeg",
                    "-y",
                    "-i",
                    source_audio,
                    "-c:a",
                    "flac",
                    "-compression_level",
                    "8",
                    temp_flac,
                ]
                result = eventlet.tpool.execute(safe_subprocess_run, convert_cmd, timeout=300)

                if result.returncode != 0:
                    print(f"Failed to convert to FLAC (exit code {result.returncode})")
                    continue

                working_audio = temp_flac

            # Get total duration
            probe_cmd = [
                "ffprobe",
                "-v",
                "quiet",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                working_audio,
            ]
            result = eventlet.tpool.execute(safe_subprocess_run, probe_cmd, capture_output=True, text=True, timeout=30, stderr_devnull=True)
            total_duration = (
                float(result.stdout.strip()) if result.stdout.strip() else None
            )

            # Split tracks
            disc_tracks_created = 0

            for i, track in enumerate(tracks):
                # Check cancellation flag
                if _cue_split_cancelled:
                    safe_emit(
                        "cue_split_progress",
                        {"status": "cancelled", "message": "CUE split cancelled"},
                    )
                    # Clean up temp file
                    if temp_flac and os.path.exists(temp_flac):
                        os.remove(temp_flac)
                    return jsonify({
                        "success": False,
                        "error": "Cancelled by user",
                        "tracks_created": total_tracks_created,
                    })

                track_num = track["number"]
                track_title = track["title"] or f"Track {track_num}"
                track_performer = (
                    track["performer"] or album_performer or "Unknown Artist"
                )
                start_time = track["start_seconds"] or 0

                if i < len(tracks) - 1:
                    end_time = tracks[i + 1]["start_seconds"]
                else:
                    end_time = total_duration

                # Clean filename - include disc number if multi-disc
                safe_title = re.sub(r'[<>:"/\\|?*]', "", track_title)
                if is_multi_disc:
                    output_filename = (
                        f"{disc_number}-{track_num:02d} - {safe_title}.flac"
                    )
                else:
                    output_filename = f"{track_num:02d} - {safe_title}.flac"
                output_path = os.path.join(folder_path, output_filename)

                cmd = ["ffmpeg", "-y", "-ss", str(start_time), "-i", working_audio]

                if end_time:
                    duration = end_time - start_time
                    cmd.extend(["-t", str(duration)])

                cmd.extend(
                    [
                        "-c:a",
                        "flac",
                        "-metadata",
                        f"title={track_title}",
                        "-metadata",
                        f"artist={track_performer}",
                        "-metadata",
                        f'album={album_title or ""}',
                        "-metadata",
                        f"track={track_num}/{len(tracks)}",
                        "-metadata",
                        f"disc={disc_number}/{total_discs}",
                        output_path,
                    ]
                )

                global_track_index += 1

                safe_emit(
                    "cue_split_progress",
                    {
                        "status": "splitting",
                        "current": global_track_index,
                        "total": total_tracks_all_discs,
                        "track_name": track_title,
                        "message": f"Disc {disc_number}, Track {track_num}: {track_title}",
                        "disc_number": disc_number,
                    },
                )

                def _set_pid(pid):
                    global _cue_split_pid
                    _cue_split_pid = pid

                result = eventlet.tpool.execute(safe_subprocess_run, cmd, timeout=300, pid_callback=_set_pid)
                _cue_split_pid = None

                if result.returncode == 0:
                    disc_tracks_created += 1
                    total_tracks_created += 1
                    all_created_files.append(output_filename)
                else:
                    print(f"Error splitting track {track_num} (exit code {result.returncode})")

            # Clean up temp file
            if temp_flac and os.path.exists(temp_flac):
                os.remove(temp_flac)

            print(
                f"Disc {disc_number}: Created {disc_tracks_created}/{len(tracks)} tracks"
            )

        # Note: Original files are kept - import cleanup will handle deletion

        safe_emit(
            "cue_split_progress",
            {
                "status": "complete",
                "current": total_tracks_all_discs,
                "total": total_tracks_all_discs,
                "message": f"Successfully split {total_discs} disc(s) into {total_tracks_created} tracks",
            },
        )

        return jsonify(
            {
                "success": True,
                "tracks_created": total_tracks_created,
                "total_tracks": total_tracks_all_discs,
                "disc_count": total_discs,
                "files": all_created_files,
                "message": f"Successfully split {total_discs} disc(s) into {total_tracks_created} tracks",
            }
        )

    except Exception as e:

        traceback.print_exc()
        return _error_response(e)


@api.route("/api/imports/folder-contents", methods=["POST"])
def get_folder_contents():
    """Get list of files in an import folder with audio metadata"""

    from mutagen import File as MutagenFile

    data = request.get_json()
    base_path = data.get("path")
    subpath = data.get("subpath", "")  # Optional subfolder navigation

    if not base_path:
        return jsonify({"success": False, "error": "Path required"}), 400

    # Build full path
    if subpath:
        folder_path = os.path.join(base_path, subpath)
    else:
        folder_path = base_path

    # Normalize path to prevent directory traversal
    folder_path = os.path.normpath(folder_path)

    if not os.path.exists(folder_path):
        return jsonify({"success": False, "error": "Folder not found"}), 404

    # Security: only allow paths in downloads folders
    allowed_prefixes = Config.DOWNLOADS_ALLOWED
    if not any(folder_path.startswith(p) for p in allowed_prefixes):
        return jsonify({"success": False, "error": "Access denied"}), 403

    audio_extensions = [
        ".flac",
        ".mp3",
        ".m4a",
        ".wav",
        ".ogg",
        ".opus",
        ".ape",
        ".wv",
        ".aiff",
        ".aif",
    ]

    files = []
    formats_found = set()

    for item in sorted(os.listdir(folder_path)):
        item_path = os.path.join(folder_path, item)
        is_dir = os.path.isdir(item_path)
        size = os.path.getsize(item_path) if not is_dir else 0
        ext = os.path.splitext(item)[1].lower() if not is_dir else ""

        file_info = {
            "name": item,
            "path": item_path,
            "is_directory": is_dir,
            "size": size,
            "size_formatted": format_size(size) if not is_dir else "",
            "extension": ext,
        }

        # For directories, count contents
        if is_dir:
            try:
                dir_contents = os.listdir(item_path)
                file_info["item_count"] = len(dir_contents)
                audio_count = sum(
                    1
                    for f in dir_contents
                    if os.path.splitext(f)[1].lower() in audio_extensions
                )
                file_info["audio_count"] = audio_count
            except Exception:
                file_info["item_count"] = 0
                file_info["audio_count"] = 0

        # For audio files, read metadata
        elif ext in audio_extensions:
            formats_found.add(ext.upper().replace(".", ""))
            try:
                audio = MutagenFile(item_path)
                if audio:
                    file_info["duration"] = (
                        int(audio.info.length)
                        if hasattr(audio.info, "length")
                        else None
                    )
                    file_info["duration_formatted"] = (
                        f"{int(audio.info.length) // 60}:{int(audio.info.length) % 60:02d}"
                        if hasattr(audio.info, "length")
                        else None
                    )

                    # Format-specific metadata
                    if hasattr(audio.info, "sample_rate"):
                        file_info["sample_rate"] = audio.info.sample_rate
                        file_info["sample_rate_formatted"] = (
                            f"{audio.info.sample_rate / 1000:.1f}kHz"
                        )

                    if hasattr(audio.info, "bits_per_sample"):
                        file_info["bit_depth"] = audio.info.bits_per_sample

                    if hasattr(audio.info, "bitrate"):
                        file_info["bitrate"] = audio.info.bitrate
                        file_info["bitrate_formatted"] = (
                            f"{audio.info.bitrate // 1000}kbps"
                        )

                    if hasattr(audio.info, "channels"):
                        file_info["channels"] = audio.info.channels

                    # Build format string
                    format_parts = [ext.upper().replace(".", "")]
                    if file_info.get("bit_depth"):
                        format_parts.append(f"{file_info['bit_depth']}-bit")
                    if file_info.get("sample_rate_formatted"):
                        format_parts.append(file_info["sample_rate_formatted"])
                    elif file_info.get("bitrate_formatted"):
                        format_parts.append(file_info["bitrate_formatted"])
                    file_info["format_display"] = " / ".join(format_parts)
            except Exception as e:
                file_info["format_display"] = ext.upper().replace(".", "")

        files.append(file_info)

    # Build breadcrumb path
    breadcrumbs = []
    if subpath:
        parts = subpath.split(os.sep)
        for i, part in enumerate(parts):
            breadcrumbs.append({"name": part, "path": os.sep.join(parts[: i + 1])})

    return jsonify(
        {
            "success": True,
            "base_path": base_path,
            "current_path": folder_path,
            "subpath": subpath,
            "folder_name": os.path.basename(folder_path),
            "breadcrumbs": breadcrumbs,
            "files": files,
            "file_count": len([f for f in files if not f["is_directory"]]),
            "audio_count": len(
                [f for f in files if f.get("extension") in audio_extensions]
            ),
            "formats_found": sorted(list(formats_found)),
        }
    )


@api.route("/api/imports/read-cue", methods=["POST"])
def read_cue_contents():
    """Read raw contents of a CUE file"""

    data = request.get_json()
    file_path = data.get("path")

    if not file_path or not os.path.exists(file_path):
        return jsonify({"success": False, "error": "File not found"}), 404

    # Security: only allow paths in downloads folders
    allowed_prefixes = Config.DOWNLOADS_ALLOWED
    if not any(file_path.startswith(p) for p in allowed_prefixes):
        return jsonify({"success": False, "error": "Access denied"}), 403

    if not file_path.lower().endswith(".cue"):
        return jsonify({"success": False, "error": "Not a CUE file"}), 400

    try:
        # Try different encodings
        content = None
        for encoding in ["utf-8", "utf-8-sig", "latin-1", "cp1252", "shift-jis"]:
            try:
                with open(file_path, "r", encoding=encoding) as f:
                    content = f.read()
                break
            except UnicodeDecodeError:
                continue

        if content is None:
            return jsonify({"success": False, "error": "Could not decode file"}), 400

        return jsonify(
            {
                "success": True,
                "filename": os.path.basename(file_path),
                "content": content,
            }
        )
    except Exception as e:
        return _error_response(e)


@api.route("/api/imports/read-tags", methods=["POST"])
def read_folder_tags():
    """Read metadata tags from audio files in a folder"""

    from mutagen import File as MutagenFile

    data = request.get_json()
    folder_path = data.get("path")

    if not folder_path or not os.path.exists(folder_path):
        return jsonify({"success": False, "error": "Folder not found"}), 404

    # Security: only allow paths in downloads folders
    allowed_prefixes = Config.DOWNLOADS_ALLOWED
    if not any(folder_path.startswith(p) for p in allowed_prefixes):
        return jsonify({"success": False, "error": "Access denied"}), 403

    # Find audio files
    audio_extensions = [".flac", ".mp3", ".m4a", ".wav", ".ogg", ".opus", ".ape", ".wv"]
    audio_files = []

    for item in os.listdir(folder_path):
        ext = os.path.splitext(item)[1].lower()
        if ext in audio_extensions:
            audio_files.append(os.path.join(folder_path, item))

    if not audio_files:
        return jsonify({"success": False, "error": "No audio files found"}), 404

    # Try to read tags from first few files to find good metadata
    artist = None
    album = None
    year = None

    for audio_path in audio_files[:5]:  # Check first 5 files
        try:
            audio = MutagenFile(audio_path, easy=True)
            if audio is None:
                continue

            # Extract tags
            if not artist and audio.get("artist"):
                artist = audio.get("artist")[0]
            if not artist and audio.get("albumartist"):
                artist = audio.get("albumartist")[0]
            if not album and audio.get("album"):
                album = audio.get("album")[0]
            if not year and audio.get("date"):
                year_str = audio.get("date")[0]
                # Extract just the year if it's a full date
                if year_str:
                    year = year_str[:4] if len(year_str) >= 4 else year_str

            # If we have all we need, stop
            if artist and album:
                break

        except Exception as e:
            print(f"Error reading tags from {audio_path}: {e}")
            continue

    return jsonify({"success": True, "artist": artist, "album": album, "year": year})


@api.route("/api/musicbrainz/tracks/<release_group_id>", methods=["GET"])
def get_musicbrainz_tracks(release_group_id):
    """Get track listing from a MusicBrainz release group"""

    headers = {"User-Agent": "NASRadio/1.0 (https://github.com/simpson1045/NASRadio)"}

    def _credit_from(artist_credit):
        """Turn a MusicBrainz artist-credit array into a display string +
        structured list. Returns (display, [{name, mbid}, ...]).

        The join phrases ("feat. ", " & ", " x ") come straight from MB, so
        the display string reconstructs exactly how the track is credited
        (e.g. "Drake feat. Rihanna"). parse_artists() splits that back into
        individual artists on the import side; the structured list carries
        MBIDs for callers that want exact matching later.
        """
        if not artist_credit:
            return None, []
        parts = []
        artists = []
        for ac in artist_credit:
            name = ac.get("name") or (ac.get("artist") or {}).get("name") or ""
            if not name:
                continue
            parts.append(name)
            parts.append(ac.get("joinphrase") or "")
            artists.append(
                {"name": name, "mbid": (ac.get("artist") or {}).get("id")}
            )
        display = "".join(parts).strip() or None
        return display, artists

    try:
        # First, get releases in this release group. inc=artist-credits pulls
        # the per-track credits (incl. featured/guest artists) so the importer
        # can store every artist, not just the album's primary.
        url = (
            f"https://musicbrainz.org/ws/2/release?release-group={release_group_id}"
            "&inc=recordings+artist-credits&fmt=json"
        )
        response = mb_requests.get(url, headers=headers, timeout=25)

        if response.status_code != 200:
            return jsonify({"error": "Failed to fetch from MusicBrainz"}), 500

        data = response.json()
        releases = data.get("releases", [])

        if not releases:
            return jsonify({"error": "No releases found"}), 404

        # Find the best release (prefer one with the most tracks, or first official)
        best_release = None
        best_track_count = 0

        for release in releases:
            media = release.get("media", [])
            track_count = sum(m.get("track-count", 0) for m in media)
            if track_count > best_track_count:
                best_track_count = track_count
                best_release = release

        if not best_release:
            best_release = releases[0]

        # Extract tracks from the release
        tracks = []
        media = best_release.get("media", [])

        for medium in media:
            medium_tracks = medium.get("tracks", [])
            for track in medium_tracks:
                recording = track.get("recording", {})
                # Per-track credit lives on the track (preferred — reflects how
                # this release credits it) and/or the recording. Fall back from
                # one to the other.
                artist_display, artist_list = _credit_from(
                    track.get("artist-credit")
                    or recording.get("artist-credit")
                )
                tracks.append(
                    {
                        "number": track.get("number"),
                        "position": track.get("position"),
                        "title": recording.get("title") or track.get("title"),
                        "duration": recording.get("length"),  # in milliseconds
                        "artist": artist_display,  # joined string, or None
                        "artists": artist_list,  # [{name, mbid}], possibly empty
                    }
                )

        # Release-level credit (the album artist — "Various Artists" for comps).
        release_display, release_artists = _credit_from(
            best_release.get("artist-credit")
        )

        return jsonify(
            {
                "success": True,
                "release_id": best_release.get("id"),
                "release_title": best_release.get("title"),
                "release_artist": release_display,
                "release_artists": release_artists,
                "track_count": len(tracks),
                "tracks": tracks,
            }
        )

    except mb_requests.exceptions.Timeout:
        return jsonify({"error": "MusicBrainz timeout"}), 504
    except Exception as e:
        return _error_response(e)


@api.route("/api/album/<int:album_id>/local-image/<path:filename>", methods=["GET"])
def get_album_local_image(album_id, filename):
    """Serve a local image from an album's folder"""
    from flask import send_file

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        cursor.execute("SELECT folder_path FROM albums WHERE id = %s", (album_id,))
        album = cursor.fetchone()

        if not album or not album["folder_path"]:
            return jsonify({"error": "Album not found"}), 404

        # Security: sanitize filename to prevent directory traversal
        safe_filename = os.path.basename(filename)
        image_path = os.path.join(album["folder_path"], safe_filename)

        if not os.path.exists(image_path):
            return jsonify({"error": "Image not found"}), 404

        # Verify it's actually an image
        ext = os.path.splitext(safe_filename)[1].lower()
        if ext not in [".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp"]:
            return jsonify({"error": "Not an image file"}), 400

        return send_file(image_path)
    finally:
        conn.close()


@api.route("/api/album/<int:album_id>/set-local-artwork", methods=["POST"])
def set_album_local_artwork(album_id):
    """Set a local image from the album folder as the album artwork"""

    data = request.get_json()
    filename = data.get("filename")

    if not filename:
        return jsonify({"error": "filename required"}), 400

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        cursor.execute("SELECT folder_path FROM albums WHERE id = %s", (album_id,))
        album = cursor.fetchone()

        if not album or not album["folder_path"]:
            return jsonify({"error": "Album not found"}), 404

        # Security: sanitize filename
        safe_filename = os.path.basename(filename)
        source_path = os.path.join(album["folder_path"], safe_filename)

        if not os.path.exists(source_path):
            return jsonify({"error": "Image not found"}), 404

        # Verify it's an image
        ext = os.path.splitext(safe_filename)[1].lower()
        if ext not in [".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp"]:
            return jsonify({"error": "Not an image file"}), 400

        # Always save as JPG for consistency with other artwork functions
        artwork_filename = f"album_{album_id}.jpg"
        artwork_path = os.path.join("artwork", artwork_filename)

        # Ensure artwork directory exists
        os.makedirs("artwork", exist_ok=True)

        # Load, convert, and save as optimized JPEG (like other artwork functions)
        from PIL import Image

        img = Image.open(source_path)
        if img.mode in ("RGBA", "LA", "P"):
            img = img.convert("RGB")
        # No resize — keep original resolution
        img.save(artwork_path, "JPEG", quality=95)

        # Update database with just the filename (not the path)
        cursor.execute(
            "UPDATE albums SET artwork_path = %s WHERE id = %s",
            (artwork_filename, album_id),
        )
        conn.commit()

        return jsonify(
            {
                "success": True,
                "message": f"Artwork set from {safe_filename}",
                "artwork_path": artwork_path,
            }
        )
    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


# Track active MBID backfill operations for cancellation
_mbid_backfill_cancelled = {}


@api.route("/api/backfill-mbids", methods=["POST"])
def backfill_mbids():
    """Backfill MusicBrainz IDs for albums and artists missing them"""

    operation_id = str(uuid.uuid4())[:8]
    _mbid_backfill_cancelled[operation_id] = False

    def run_backfill():
        db = get_db()
        conn = db.get_connection()
        cursor = db.get_cursor(conn)

        headers = {
            "User-Agent": "NASRadio/1.0 (https://github.com/simpson1045/NASRadio)"
        }

        try:
            # Get albums without mbid
            cursor.execute(
                """
                SELECT a.id, a.title, a.year, ar.name as artist_name, ar.id as artist_id, ar.mbid as artist_mbid
                FROM albums a
                JOIN artists ar ON a.artist_id = ar.id
                WHERE a.mbid IS NULL
                ORDER BY ar.name, a.title
            """
            )
            albums = cursor.fetchall()
            total = len(albums)

            safe_emit(
                "mbid_backfill_progress",
                {
                    "operation_id": operation_id,
                    "status": "started",
                    "message": f"Starting backfill for {total} albums",
                    "current": 0,
                    "total": total,
                    "updated_albums": 0,
                    "updated_artists": 0,
                },
            )

            updated_albums = 0
            updated_artists = 0

            for i, album in enumerate(albums):
                # Check for cancellation
                if _mbid_backfill_cancelled.get(operation_id, False):
                    safe_emit(
                        "mbid_backfill_progress",
                        {
                            "operation_id": operation_id,
                            "status": "cancelled",
                            "message": f"Cancelled. Updated {updated_albums} albums and {updated_artists} artists",
                            "current": i,
                            "total": total,
                            "updated_albums": updated_albums,
                            "updated_artists": updated_artists,
                        },
                    )
                    _mbid_backfill_cancelled.pop(operation_id, None)
                    return

                album_id = album["id"]
                album_title = album["title"]
                artist_name = album["artist_name"]
                artist_id = album["artist_id"]
                has_artist_mbid = album["artist_mbid"] is not None

                # Build MusicBrainz query
                from urllib.parse import quote

                def clean_for_search(text):
                    if not text:
                        return ""
                    text = text.replace("ə", "e").replace("ɛ", "e")
                    text = re.sub(r"[\(\)\[\]]", "", text)
                    text = re.sub(r"[!@#$%^*]", "", text)
                    text = re.sub(r"\s+", " ", text).strip()
                    return text

                clean_artist = clean_for_search(artist_name)
                clean_album = clean_for_search(album_title)

                query_parts = []
                if clean_artist:
                    if " " in clean_artist:
                        query_parts.append(f'artist:"{clean_artist}"')
                    else:
                        query_parts.append(f"artist:{clean_artist}")
                if clean_album:
                    if " " in clean_album:
                        query_parts.append(f'releasegroup:"{clean_album}"')
                    else:
                        query_parts.append(f"releasegroup:{clean_album}")

                query = " AND ".join(query_parts)
                encoded_query = quote(query)
                url = f"https://musicbrainz.org/ws/2/release-group?query={encoded_query}&limit=5&fmt=json"

                try:
                    response = mb_requests.get(url, headers=headers, timeout=25)

                    if response.status_code == 200:
                        data = response.json()
                        release_groups = data.get("release-groups", [])

                        # Find best match - look for exact or very close match
                        best_match = None
                        for rg in release_groups:
                            rg_title = rg.get("title", "").lower()
                            rg_artist = ""
                            artist_credit = rg.get("artist-credit", [])
                            if artist_credit:
                                rg_artist = artist_credit[0].get("name", "").lower()
                                rg_artist_mbid = (
                                    artist_credit[0].get("artist", {}).get("id")
                                )

                            # Check for good match
                            title_match = (
                                rg_title == album_title.lower()
                                or clean_for_search(rg_title).lower()
                                == clean_album.lower()
                            )
                            artist_match = (
                                rg_artist == artist_name.lower()
                                or clean_for_search(rg_artist).lower()
                                == clean_artist.lower()
                            )

                            if title_match and artist_match:
                                best_match = {
                                    "mbid": rg.get("id"),
                                    "album_type": rg.get("primary-type"),
                                    "secondary_types": ",".join(
                                        rg.get("secondary-types") or []
                                    ),
                                    "artist_mbid": rg_artist_mbid,
                                }
                                break

                        if best_match:
                            # Update album
                            cursor.execute(
                                "UPDATE albums SET mbid = %s, album_type = %s, secondary_types = %s WHERE id = %s",
                                (
                                    best_match["mbid"],
                                    best_match["album_type"],
                                    best_match["secondary_types"],
                                    album_id,
                                ),
                            )
                            updated_albums += 1

                            # Update artist if needed
                            if not has_artist_mbid and best_match.get("artist_mbid"):
                                cursor.execute(
                                    "UPDATE artists SET mbid = %s WHERE id = %s AND mbid IS NULL",
                                    (best_match["artist_mbid"], artist_id),
                                )
                                if cursor.rowcount > 0:
                                    updated_artists += 1

                            conn.commit()

                except mb_requests.exceptions.RequestException as e:
                    print(
                        f"MusicBrainz request failed for {artist_name} - {album_title}: {e}"
                    )

                # Progress update every 10 albums or on match
                if i % 10 == 0 or best_match:
                    safe_emit(
                        "mbid_backfill_progress",
                        {
                            "operation_id": operation_id,
                            "status": "running",
                            "message": f"Processing: {artist_name} - {album_title}",
                            "current": i + 1,
                            "total": total,
                            "updated_albums": updated_albums,
                            "updated_artists": updated_artists,
                        },
                    )

                # Rate limit: 1 request per second for MusicBrainz
                time.sleep(1.0)

            safe_emit(
                "mbid_backfill_progress",
                {
                    "operation_id": operation_id,
                    "status": "complete",
                    "message": f"Backfill complete! Updated {updated_albums} albums and {updated_artists} artists",
                    "current": total,
                    "total": total,
                    "updated_albums": updated_albums,
                    "updated_artists": updated_artists,
                },
            )
            _mbid_backfill_cancelled.pop(operation_id, None)

        except Exception as e:
            print(f"Backfill error: {e}")
            safe_emit(
                "mbid_backfill_progress",
                {
                    "operation_id": operation_id,
                    "status": "error",
                    "message": str(e),
                },
            )
            _mbid_backfill_cancelled.pop(operation_id, None)
        finally:
            conn.close()

    thread = threading.Thread(target=run_backfill)
    thread.daemon = True
    thread.start()

    return jsonify(
        {
            "success": True,
            "message": "MBID backfill started",
            "operation_id": operation_id,
        }
    )


@api.route("/api/backfill-mbids/cancel/<operation_id>", methods=["POST"])
def cancel_mbid_backfill(operation_id):
    """Cancel a running MBID backfill operation"""
    if operation_id in _mbid_backfill_cancelled:
        _mbid_backfill_cancelled[operation_id] = True
        return jsonify({"success": True, "message": "Cancel requested"})
    else:
        return jsonify({"success": False, "message": "Operation not found"}), 404


@api.route("/api/mbid-stats", methods=["GET"])
def get_mbid_stats():
    """Get stats on MBID coverage"""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        cursor.execute("SELECT COUNT(*) as total, COUNT(mbid) as with_mbid FROM albums")
        album_stats = cursor.fetchone()

        cursor.execute(
            "SELECT COUNT(*) as total, COUNT(mbid) as with_mbid FROM artists"
        )
        artist_stats = cursor.fetchone()

        cursor.execute(
            """
            SELECT album_type, COUNT(*) as count 
            FROM albums 
            WHERE album_type IS NOT NULL 
            GROUP BY album_type 
            ORDER BY count DESC
        """
        )
        type_breakdown = [
            {"type": row["album_type"], "count": row["count"]}
            for row in cursor.fetchall()
        ]

        return jsonify(
            {
                "albums": {
                    "total": album_stats["total"],
                    "with_mbid": album_stats["with_mbid"],
                    "missing": album_stats["total"] - album_stats["with_mbid"],
                },
                "artists": {
                    "total": artist_stats["total"],
                    "with_mbid": artist_stats["with_mbid"],
                    "missing": artist_stats["total"] - artist_stats["with_mbid"],
                },
                "album_types": type_breakdown,
            }
        )
    finally:
        conn.close()


# ============================================================
# What's Happening - Upcoming & Recent Releases
# ============================================================


@api.route("/api/whats-happening", methods=["GET"])
def get_whats_happening():
    """Get cached upcoming and recent releases from library artists"""
    db = get_db()
    conn = db.get_connection()
    try:
        cursor = db.get_cursor(conn)
        cursor.execute(
            """
            SELECT ur.*, a.image_path as artist_image
            FROM upcoming_releases ur
            LEFT JOIN artists a ON a.id = ur.artist_id
            ORDER BY 
                CASE WHEN ur.release_date::date >= CURRENT_DATE THEN 0 ELSE 1 END,
                ur.release_date ASC
        """
        )
        releases = [dict(row) for row in cursor.fetchall()]

        # Split into upcoming vs recent

        today = date.today().isoformat()
        upcoming = [
            r for r in releases if r.get("release_date") and r["release_date"] >= today
        ]
        recent = [
            r for r in releases if r.get("release_date") and r["release_date"] < today
        ]

        return jsonify(
            {
                "upcoming": upcoming,
                "recent": recent,
                "total": len(releases),
                "last_refreshed": None,  # TODO: track this
            }
        )
    finally:
        conn.close()


@api.route("/api/whats-happening/refresh", methods=["POST"])
def refresh_whats_happening():
    """Scan MusicBrainz for upcoming/recent releases from all library artists"""

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Get all artists with MBIDs
        cursor.execute(
            "SELECT id, name, mbid FROM artists WHERE mbid IS NOT NULL AND mbid != ''"
        )
        artists = [dict(row) for row in cursor.fetchall()]

        if not artists:
            return jsonify({"error": "No artists with MBIDs found", "scanned": 0})

        headers = {
            "User-Agent": "NASRadio/1.0 (https://github.com/simpson1045/NASRadio)"
        }

        # Date window: 90 days ago to 180 days ahead
        date_from = (date.today() - timedelta(days=90)).strftime("%Y-%m-%d")
        date_to = (date.today() + timedelta(days=180)).strftime("%Y-%m-%d")

        # Get all local album titles for in_library detection
        cursor.execute("SELECT artist_id, LOWER(title) as title FROM albums")
        local_albums = {}
        for row in cursor.fetchall():
            if row["artist_id"] not in local_albums:
                local_albums[row["artist_id"]] = set()
            local_albums[row["artist_id"]].add(row["title"])

        total_found = 0
        scanned = 0
        errors = []

        # Clear old data
        cursor.execute("DELETE FROM upcoming_releases")
        conn.commit()

        for artist in artists:
            try:
                # Rate limit - MusicBrainz requires 1 req/sec
                time.sleep(1.1)

                # Query MusicBrainz for release groups by this artist
                rg_url = (
                    f"https://musicbrainz.org/ws/2/release-group"
                    f"?artist={artist['mbid']}"
                    f"&limit=100&fmt=json"
                )
                response = mb_requests.get(rg_url, headers=headers, timeout=15)

                if response.status_code != 200:
                    errors.append(f"{artist['name']}: HTTP {response.status_code}")
                    continue

                data = response.json()
                release_groups = data.get("release-groups", [])

                artist_local = local_albums.get(artist["id"], set())

                for rg in release_groups:
                    release_date = rg.get("first-release-date", "")

                    # Skip if no date or outside our window
                    if not release_date or len(release_date) < 4:
                        continue

                    # Pad partial dates (e.g. "2025-03" -> "2025-03-01")
                    if len(release_date) == 4:
                        release_date = f"{release_date}-01-01"
                    elif len(release_date) == 7:
                        release_date = f"{release_date}-01"

                    if release_date < date_from or release_date > date_to:
                        continue

                    title = rg.get("title", "Unknown")
                    primary_type = rg.get("primary-type", "Other")
                    rg_mbid = rg.get("id", "")

                    # Check if already in library
                    in_library = title.lower() in artist_local

                    cursor.execute(
                        """
                        INSERT INTO upcoming_releases 
                            (artist_id, artist_name, release_title, release_date, 
                             release_type, mbid, in_library)
                        VALUES (%s, %s, %s, %s, %s, %s, %s)
                        ON CONFLICT (artist_id, release_title) DO UPDATE SET
                            release_date = EXCLUDED.release_date,
                            in_library = EXCLUDED.in_library
                    """,
                        (
                            artist["id"],
                            artist["name"],
                            title,
                            release_date,
                            primary_type,
                            rg_mbid,
                            in_library,
                        ),
                    )

                    total_found += 1

                scanned += 1
                conn.commit()

            except Exception as e:
                errors.append(f"{artist['name']}: {str(e)}")
                continue

        conn.commit()

        return jsonify(
            {
                "scanned": scanned,
                "total_artists": len(artists),
                "releases_found": total_found,
                "errors": errors[:10],  # Limit error list
            }
        )

    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


def start_smb_keepalive(app):
    """Keep the SMB session to the NAS warm so the first stat after an idle
    stretch doesn't pay a cold re-handshake.

    The OLD version (a bare `os.path.exists(music_root)` every 30s) did NOT work,
    and we proved it: the NAS logged a brand-new CIFS login on every single
    keepalive tick — meaning Windows had already torn the session down between
    ticks. So the session was cold most of the time, a song start after a pause
    landed on a dead session, the stat crawled toward SMB_CALL_TIMEOUT_S (5s),
    and smb_exists_with_retry laddered it up to ~10s. THAT is the "great, then it
    gave up and never recovered — 10s even after a 2-minute pause" gremlin
    (diagnosed 2026-06-28).

    The fix: hold ONE real file handle open on the share. An open handle pins
    the SMB session so Windows can't reap it, and a 1-byte periodic read keeps
    both the session AND the disk platters warm (a metadata stat does neither
    reliably). If the handle ever dies (NAS reboot, network blip) we re-acquire
    on the next tick. All SMB touches route through _smb_call, so a genuinely
    down NAS stays timeout-bounded and never wedges the eventlet hub.
    """
    KEEPALIVE_INTERVAL_S = 20
    state = {"fh": None, "path": None}

    def _pick_warm_file():
        # Any readable library file pins the session. Prefer a real one from the
        # DB so we never write anything to the user's share.
        try:
            with app.app_context():
                db = get_db()
                conn = db.get_connection()
                cur = db.get_cursor(conn)
                cur.execute(
                    "SELECT file_path FROM songs WHERE file_path IS NOT NULL "
                    "AND source_type IS DISTINCT FROM 'podcast' ORDER BY id LIMIT 1"
                )
                row = cur.fetchone()
                conn.close()
            if row and row.get("file_path"):
                return ensure_windows_path(row["file_path"])
        except Exception as e:
            print(f"📡 [smb-keepalive] couldn't pick a warm file: {e}")
        return None

    def _acquire():
        path = _pick_warm_file()
        if not path:
            return
        try:
            state["fh"] = _smb_call(open, path, "rb")
            state["path"] = path
            print(f"📡 [smb-keepalive] session pinned open via {path}")
        except Exception as e:
            print(f"📡 [smb-keepalive] open failed, will retry next tick: {e}")
            state["fh"] = None

    def keepalive_loop():
        eventlet.sleep(5)  # let the app + DB finish coming up
        _acquire()
        while True:
            eventlet.sleep(KEEPALIVE_INTERVAL_S)
            fh = state["fh"]
            if fh is None:
                _acquire()
                continue
            t0 = time.monotonic()
            try:
                def _touch(h=fh):
                    h.seek(0)
                    return h.read(1)
                _smb_call(_touch)
                dt = time.monotonic() - t0
                if dt >= SMB_SLOW_WARN_S:
                    print(f"🐌 [smb-keepalive] touch took {dt:.2f}s — session went "
                          f"cold despite the held handle (interval may be too long)")
            except (SmbUnavailable, OSError, ValueError) as e:
                dt = time.monotonic() - t0
                print(f"⚠️ [smb-keepalive] held handle died after {dt:.2f}s ({e}) "
                      f"— re-acquiring")
                try:
                    if state["fh"]:
                        state["fh"].close()
                except Exception:
                    pass
                state["fh"] = None
                _acquire()
            except Exception:
                pass

    eventlet.spawn_n(keepalive_loop)
    print(f"📡 SMB keepalive started — persistent handle + {KEEPALIVE_INTERVAL_S}s 1-byte touch")


def start_podcast_cleanup_scheduler(app):
    """Periodically bound podcast download storage — delete completed episodes'
    downloads and evict oldest if over the size cap. On-completion delete is the
    primary mechanism; this catches abandoned half-listens."""

    def cleanup_loop():
        time.sleep(120)  # let startup settle
        while True:
            with app.app_context():
                try:
                    cleanup_podcast_downloads(get_db())
                except Exception as e:
                    print(f"Podcast cleanup error: {e}")
            time.sleep(1800)  # every 30 minutes

    eventlet.spawn_n(cleanup_loop)
    print("🧹 Podcast download cleanup scheduler started")


def start_rss_refresh_scheduler(app):
    """Background thread that refreshes podcast feeds periodically."""

    def refresh_loop():
        # Wait 60 seconds after startup before first run
        time.sleep(60)
        while True:
            with app.app_context():
                try:
                    db = get_db()
                    total = refresh_all_feeds(db)
                    if total > 0:
                        print(f"🎙️ RSS refresh: {total} new episodes")
                except Exception as e:
                    print(f"RSS refresh error: {e}")
            time.sleep(config.RSS_REFRESH_INTERVAL)

    eventlet.spawn_n(refresh_loop)
    print("🎙️ RSS feed refresh scheduler started")


def start_whats_happening_scheduler(app):
    """Background thread that refreshes upcoming releases once daily"""

    def refresh_loop():
        # Wait 30 seconds after startup before first run
        time.sleep(30)
        while True:
            with app.app_context():
                try:
                    db = get_db()
                    conn = db.get_connection()
                    cursor = db.get_cursor(conn)

                    # Check when we last refreshed
                    cursor.execute(
                        """
                        SELECT MAX(created_at) as last_refresh 
                        FROM upcoming_releases
                    """
                    )
                    row = cursor.fetchone()
                    conn.close()

                    last_refresh = (
                        row["last_refresh"] if row and row["last_refresh"] else None
                    )

                    needs_refresh = (
                        last_refresh is None
                        or datetime.now() - last_refresh > timedelta(hours=24)
                    )

                    if needs_refresh:
                        print("🔍 What's Happening: Starting daily release scan...")
                        # Call the refresh logic directly
                        with app.test_request_context():
                            result = refresh_whats_happening()
                            if hasattr(result, "get_json"):
                                data = result.get_json()
                            else:
                                data = result[0].get_json()
                            print(
                                f"✅ What's Happening: Scanned {data.get('scanned', 0)} artists, found {data.get('releases_found', 0)} releases"
                            )
                    else:
                        print(
                            f"ℹ️ What's Happening: Last refreshed {last_refresh}, skipping"
                        )

                except Exception as e:
                    print(f"⚠️ What's Happening scheduler error: {e}")

            # Sleep 6 hours, then check again (only actually refreshes if >24h old)
            time.sleep(6 * 3600)

    # Run as a green thread under the eventlet hub, NOT as a
    # threading.Thread. A real OS thread touching the DB pool
    # trips eventlet's cross-thread semaphore guard and crashes
    # with `greenlet.error: Cannot switch to a different thread`.
    # Matches the RSS refresh scheduler above.
    eventlet.spawn_n(refresh_loop)
    print("📅 What's Happening: Scheduled daily release checks")


# ── Song Recognition ──────────────────────────────────────────────

@api.route("/api/recognize", methods=["POST"])
def recognize_song():
    """Identify a song from an uploaded audio recording.
    Primary: ShazamIO. Fallback: AcoustID + Chromaprint."""
    import tempfile

    if "audio" not in request.files:
        return jsonify({"error": "No audio file provided"}), 400

    audio_file = request.files["audio"]

    # Save to temp file
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        tmp_path = tmp.name
        audio_file.save(tmp_path)

    try:
        # Primary: ShazamIO (runs in subprocess to avoid eventlet/asyncio conflicts)
        try:
            result = _recognize_with_shazam(tmp_path)
            print(f"🎵 ShazamIO result: matches={len(result.get('matches', []))}, has_track={'track' in result}")

            track = result.get("track")
            if track:
                # Extract album from sections metadata
                album = ""
                try:
                    sections = track.get("sections", [])
                    for section in sections:
                        for meta in section.get("metadata", []):
                            if meta.get("title", "").lower() == "album":
                                album = meta.get("text", "")
                                break
                        if album:
                            break
                except Exception:
                    pass

                return jsonify({
                    "source": "shazam",
                    "title": track.get("title", "Unknown"),
                    "artist": track.get("subtitle", "Unknown Artist"),
                    "album": album,
                    "genre": track.get("genres", {}).get("primary", ""),
                    "cover_url": track.get("images", {}).get("coverart", ""),
                    "shazam_url": track.get("url", ""),
                })
        except Exception as e:
            print(f"⚠️ ShazamIO failed: {e}, trying AcoustID fallback...")

        # Fallback: AcoustID + Chromaprint
        try:
            import acoustid
            ACOUSTID_KEY = config.ACOUSTID_API_KEY
            if ACOUSTID_KEY:
                results = acoustid.match(ACOUSTID_KEY, tmp_path)
                for score, recording_id, title, artist in results:
                    if score > 0.5:
                        return jsonify({
                            "source": "acoustid",
                            "title": title or "Unknown",
                            "artist": artist or "Unknown Artist",
                            "album": "",
                            "score": round(score, 2),
                        })
            print("⚠️ AcoustID: no match or no API key configured")
        except Exception as e:
            print(f"⚠️ AcoustID fallback failed: {e}")

        return jsonify({"error": "Could not identify the song. Try holding the mic closer."}), 404

    finally:
        # Clean up temp file
        try:
            os.unlink(tmp_path)
        except Exception:
            pass


# ============================================================================
# RSS Podcast Feeds
# ============================================================================

from app.rss_feeds import parse_feed, refresh_feed, refresh_all_feeds, download_episode, resolve_audio_url, delete_episode_download, cleanup_podcast_downloads


@api.route("/api/rss/feeds", methods=["POST"])
def rss_subscribe():
    """Subscribe to a podcast RSS feed."""
    data = request.get_json()
    feed_url = data.get("url", "").strip()

    if not feed_url:
        return jsonify({"error": "url is required"}), 400

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Check if already subscribed
        cursor.execute("SELECT id FROM rss_feeds WHERE feed_url = %s", (feed_url,))
        if cursor.fetchone():
            return jsonify({"error": "Already subscribed to this feed"}), 409

        # Parse the feed
        parsed = parse_feed(feed_url)

        # Insert feed
        cursor.execute(
            """INSERT INTO rss_feeds (feed_url, title, description, artwork_url, author, link, last_fetched_at)
               VALUES (%s, %s, %s, %s, %s, %s, NOW())
               RETURNING id""",
            (feed_url, parsed["title"], parsed["description"],
             parsed["artwork_url"], parsed["author"], parsed["link"]),
        )
        feed_id = cursor.fetchone()["id"]

        # Insert episodes
        episode_count = 0
        for ep in parsed["episodes"]:
            cursor.execute(
                """INSERT INTO rss_episodes
                   (feed_id, guid, title, description, audio_url, audio_type,
                    audio_duration, audio_size, link, published_at)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                   ON CONFLICT (feed_id, guid) DO NOTHING""",
                (feed_id, ep["guid"], ep["title"], ep["description"],
                 ep["audio_url"], ep["audio_type"], ep["audio_duration"],
                 ep["audio_size"], ep["link"], ep["published_at"]),
            )
            if cursor.rowcount > 0:
                episode_count += 1

        conn.commit()

        return jsonify({
            "success": True,
            "feed_id": feed_id,
            "title": parsed["title"],
            "episodes_added": episode_count,
        })

    except ValueError as e:
        # Validation errors are safe to show to the user
        return jsonify({"error": str(e)}), 400
    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/rss/opml/export", methods=["GET"])
def rss_opml_export():
    """Return an OPML 2.0 file listing every subscribed podcast feed.

    Intended for download — sets Content-Disposition so browsers save
    the response as `nasradio-subscriptions.opml`. Standard interchange
    format every podcast app reads; useful for backups and migrating
    to/from Pocket Casts, Overcast, etc.
    """
    from app.opml import build_opml
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute("SELECT feed_url, title, author, link FROM rss_feeds ORDER BY title")
        feeds = [dict(r) for r in cursor.fetchall()]
    finally:
        conn.close()

    xml = build_opml(feeds)
    from flask import Response
    return Response(
        xml,
        mimetype="text/x-opml",
        headers={
            "Content-Disposition": 'attachment; filename="nasradio-subscriptions.opml"',
        },
    )


@api.route("/api/rss/opml/import", methods=["POST"])
def rss_opml_import():
    """Bulk-subscribe from an OPML document.

    Accepts either:
      - {opml_text: "<opml>..."} — paste the XML directly
      - {opml_url: "https://example.com/feeds.opml"} — server fetches it

    Skips feeds already subscribed (by feed_url match) — rerunning is
    safe. Returns per-feed results so the UI can show which subscribed
    and which failed (often due to a broken RSS URL or SSRF block).
    """
    from app.opml import parse_opml
    from app.rss_feeds import _validate_url
    import requests as _requests

    data = request.get_json() or {}
    opml_text = (data.get("opml_text") or "").strip()
    opml_url = (data.get("opml_url") or "").strip()

    if not opml_text and not opml_url:
        return jsonify({"error": "Provide either opml_text or opml_url"}), 400

    if opml_url:
        try:
            _validate_url(opml_url)
            resp = _requests.get(opml_url, timeout=15)
            resp.raise_for_status()
            opml_text = resp.text
        except Exception as e:
            return jsonify({"error": f"Failed to fetch OPML: {e}"}), 400

    entries = parse_opml(opml_text)
    if not entries:
        return jsonify({"error": "No podcast subscriptions found in OPML"}), 400

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    added, skipped_existing, failed = [], [], []

    try:
        for entry in entries:
            feed_url = entry["feed_url"]
            # Skip if already subscribed — no noisy error, this is the
            # expected case on a re-import backup.
            cursor.execute("SELECT id FROM rss_feeds WHERE feed_url = %s", (feed_url,))
            if cursor.fetchone():
                skipped_existing.append({"title": entry["title"], "url": feed_url})
                continue

            try:
                parsed = parse_feed(feed_url)
                cursor.execute(
                    """INSERT INTO rss_feeds
                       (feed_url, title, description, artwork_url, author, link, last_fetched_at)
                       VALUES (%s, %s, %s, %s, %s, %s, NOW())
                       RETURNING id""",
                    (feed_url, parsed["title"], parsed["description"],
                     parsed["artwork_url"], parsed["author"], parsed["link"]),
                )
                feed_id = cursor.fetchone()["id"]

                # Insert episodes — same shape as rss_subscribe.
                for ep in parsed["episodes"]:
                    cursor.execute(
                        """INSERT INTO rss_episodes
                           (feed_id, guid, title, description, audio_url, audio_type,
                            audio_duration, audio_size, link, published_at)
                           VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                           ON CONFLICT (feed_id, guid) DO NOTHING""",
                        (feed_id, ep["guid"], ep["title"], ep["description"],
                         ep["audio_url"], ep["audio_type"], ep["audio_duration"],
                         ep["audio_size"], ep["link"], ep["published_at"]),
                    )
                conn.commit()
                added.append({"title": parsed["title"], "url": feed_url, "feed_id": feed_id})
            except Exception as e:
                conn.rollback()
                failed.append({"title": entry["title"], "url": feed_url, "error": str(e)})

        return jsonify({
            "success": True,
            "added": added,
            "skipped_already_subscribed": skipped_existing,
            "failed": failed,
        })
    finally:
        conn.close()


@api.route("/api/rss/feeds", methods=["GET"])
def rss_list_feeds():
    """List all subscribed podcast feeds with unplayed counts."""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        cursor.execute(
            """SELECT f.*,
                      COUNT(e.id) as episode_count,
                      COUNT(e.id) FILTER (WHERE e.is_completed = 0) as unplayed_count
               FROM rss_feeds f
               LEFT JOIN rss_episodes e ON e.feed_id = f.id
               GROUP BY f.id
               ORDER BY f.title"""
        )
        feeds = [dict(row) for row in cursor.fetchall()]

        # Convert timestamps to strings for JSON and apply custom_author override
        for feed in feeds:
            if feed.get("last_fetched_at"):
                feed["last_fetched_at"] = feed["last_fetched_at"].isoformat()
            if feed.get("created_at"):
                feed["created_at"] = feed["created_at"].isoformat()
            if feed.get("custom_author"):
                feed["author"] = feed["custom_author"]

        return jsonify({"success": True, "feeds": feeds})

    except Exception as e:
        traceback.print_exc()
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/rss/feeds/<int:feed_id>", methods=["GET"])
def rss_get_feed(feed_id):
    """Get a single feed's details."""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        cursor.execute(
            """SELECT f.*,
                      COUNT(e.id) as episode_count,
                      COUNT(e.id) FILTER (WHERE e.is_completed = 0) as unplayed_count
               FROM rss_feeds f
               LEFT JOIN rss_episodes e ON e.feed_id = f.id
               WHERE f.id = %s
               GROUP BY f.id""",
            (feed_id,),
        )
        feed = cursor.fetchone()
        if not feed:
            return jsonify({"error": "Feed not found"}), 404

        feed = dict(feed)
        if feed.get("last_fetched_at"):
            feed["last_fetched_at"] = feed["last_fetched_at"].isoformat()
        if feed.get("created_at"):
            feed["created_at"] = feed["created_at"].isoformat()
        if feed.get("custom_author"):
            feed["author"] = feed["custom_author"]

        return jsonify({"success": True, "feed": feed})

    except Exception as e:
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/rss/feeds/<int:feed_id>", methods=["DELETE"])
def rss_unsubscribe(feed_id):
    """Unsubscribe from a feed (CASCADE deletes episodes)."""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        cursor.execute("DELETE FROM rss_feeds WHERE id = %s RETURNING title", (feed_id,))
        row = cursor.fetchone()
        if not row:
            return jsonify({"error": "Feed not found"}), 404

        conn.commit()
        return jsonify({"success": True, "message": f"Unsubscribed from {row['title']}"})

    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/rss/feeds/<int:feed_id>", methods=["PUT"])
def rss_update_feed(feed_id):
    """Update feed settings (auto_download, play_order, etc.)."""
    data = request.get_json()
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        updates = []
        params = []

        if "auto_download" in data:
            updates.append("auto_download = %s")
            params.append(1 if data["auto_download"] else 0)

        if "play_order" in data:
            order = data["play_order"]
            if order not in ("newest_first", "oldest_first"):
                return jsonify({"error": "play_order must be 'newest_first' or 'oldest_first'"}), 400
            updates.append("play_order = %s")
            params.append(order)

        # Intro/outro auto-skip seconds (0 disables each).
        for field in ("intro_skip_seconds", "outro_skip_seconds", "retention_days"):
            if field in data:
                raw = data[field]
                try:
                    value = int(raw) if raw is not None else 0
                except (TypeError, ValueError):
                    return jsonify({"error": f"{field} must be an integer"}), 400
                if value < 0:
                    return jsonify({"error": f"{field} must be >= 0"}), 400
                updates.append(f"{field} = %s")
                params.append(value)

        if not updates:
            return jsonify({"error": "No fields to update"}), 400

        params.append(feed_id)
        cursor.execute(
            f"UPDATE rss_feeds SET {', '.join(updates)} WHERE id = %s",
            params,
        )
        conn.commit()

        return jsonify({"success": True})

    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/rss/feeds/<int:feed_id>/mark-all-played", methods=["POST"])
def rss_mark_all_played(feed_id):
    """Mark every episode in a feed as completed.

    Used for "catch up" — e.g. you subscribe to a show with 500 back
    episodes you don't intend to listen to and want to clear the unplayed
    count in one tap. Writes both the rss_episodes.is_completed flag and
    the songs.is_completed mirror so queries hitting either table agree.

    Returns {marked: N} where N is the number of rows actually updated
    (episodes that were already completed are left alone so the count
    reflects real changes only).
    """
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute(
            """
            UPDATE rss_episodes
               SET is_completed = 1,
                   played_position = COALESCE(audio_duration, played_position)
             WHERE feed_id = %s
               AND is_completed = 0
            """,
            (feed_id,),
        )
        marked = cursor.rowcount

        # Mirror into songs for the unified-model path.
        cursor.execute(
            """
            UPDATE songs
               SET is_completed = 1,
                   played_position = COALESCE(duration, played_position)
             WHERE podcast_feed_id = %s
               AND is_completed = 0
            """,
            (feed_id,),
        )
        conn.commit()
        return jsonify({"success": True, "marked": marked})
    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/rss/feeds/<int:feed_id>/refresh", methods=["POST"])
def rss_refresh_feed(feed_id):
    """Manually refresh a single feed."""
    db = get_db()
    new_count = refresh_feed(db, feed_id)
    return jsonify({"success": True, "new_episodes": new_count})


@api.route("/api/rss/feeds/refresh-all", methods=["POST"])
def rss_refresh_all():
    """Manually refresh all feeds."""
    db = get_db()
    total_new = refresh_all_feeds(db)
    return jsonify({"success": True, "new_episodes": total_new})


@api.route("/api/rss/feeds/<int:feed_id>/episodes", methods=["GET"])
def rss_list_episodes(feed_id):
    """List episodes for a feed, paginated.

    Query params:
      - page, per_page: pagination
      - sort: 'asc' | 'desc' (default 'desc')
      - search: substring filter on episode title (case-insensitive).
        When present, pagination still applies but the filter is server-
        side so feeds with thousands of episodes don't need the frontend
        to download everything.
    """
    page = request.args.get("page", 1, type=int)
    per_page = request.args.get("per_page", 50, type=int)
    sort = request.args.get("sort", "desc").lower()
    search = (request.args.get("search") or "").strip()
    offset = (page - 1) * per_page

    order = "ASC NULLS LAST" if sort == "asc" else "DESC NULLS LAST"

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        where = "feed_id = %s"
        args = [feed_id]
        if search:
            where += " AND title ILIKE %s"
            args.append(f"%{search}%")

        cursor.execute(
            f"""SELECT * FROM rss_episodes
               WHERE {where}
               ORDER BY published_at {order}
               LIMIT %s OFFSET %s""",
            args + [per_page, offset],
        )
        episodes = [dict(row) for row in cursor.fetchall()]

        for ep in episodes:
            if ep.get("published_at"):
                ep["published_at"] = ep["published_at"].isoformat()
            if ep.get("created_at"):
                ep["created_at"] = ep["created_at"].isoformat()
            # last_played_at is set by rss_update_progress; absent on
            # episodes that have never been listened to.
            if ep.get("last_played_at") and hasattr(ep["last_played_at"], "isoformat"):
                ep["last_played_at"] = ep["last_played_at"].isoformat()

        # Total count for pagination (respects search filter)
        count_where = "feed_id = %s"
        count_args = [feed_id]
        if search:
            count_where += " AND title ILIKE %s"
            count_args.append(f"%{search}%")
        cursor.execute(
            f"SELECT COUNT(*) as total FROM rss_episodes WHERE {count_where}",
            count_args,
        )
        total = cursor.fetchone()["total"]

        return jsonify({
            "success": True,
            "episodes": episodes,
            "total": total,
            "page": page,
            "per_page": per_page,
        })

    except Exception as e:
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/rss/episodes/<int:episode_id>", methods=["GET"])
def rss_get_episode(episode_id):
    """Get a single episode's details."""
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        cursor.execute(
            """SELECT e.*, f.title as feed_title, f.artwork_url as feed_artwork_url,
                      f.author as feed_author
               FROM rss_episodes e
               JOIN rss_feeds f ON e.feed_id = f.id
               WHERE e.id = %s""",
            (episode_id,),
        )
        episode = cursor.fetchone()
        if not episode:
            return jsonify({"error": "Episode not found"}), 404

        episode = dict(episode)
        if episode.get("published_at"):
            episode["published_at"] = episode["published_at"].isoformat()
        if episode.get("created_at"):
            episode["created_at"] = episode["created_at"].isoformat()
        if episode.get("last_played_at") and hasattr(episode["last_played_at"], "isoformat"):
            episode["last_played_at"] = episode["last_played_at"].isoformat()

        return jsonify({"success": True, "episode": episode})

    except Exception as e:
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/rss/episodes/<int:episode_id>/progress", methods=["PUT"])
def rss_update_progress(episode_id):
    """Save playback position and completed status."""
    data = request.get_json()
    position = data.get("position", 0)
    is_completed = data.get("is_completed")

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        # Always bump last_played_at so the resume banner can rank
        # in-progress episodes correctly. Marking complete still
        # touches this so re-opening a recently-finished episode lands
        # at the right one.
        updates = ["played_position = %s", "last_played_at = CURRENT_TIMESTAMP"]
        params = [position]

        if is_completed is not None:
            updates.append("is_completed = %s")
            params.append(1 if is_completed else 0)

        # Mirror played_position into songs.played_position when this
        # episode is also represented as a songs row (unified-model
        # migration). Otherwise the songs table stays stale and any
        # resume path that reads songs.played_position (which can
        # happen via the cross-device playback_state flow) sees an
        # outdated value.
        params.append(episode_id)
        cursor.execute(
            f"UPDATE rss_episodes SET {', '.join(updates)} WHERE id = %s",
            params,
        )

        try:
            songs_updates = ["played_position = %s"]
            songs_params = [position]
            if is_completed is not None:
                songs_updates.append("is_completed = %s")
                songs_params.append(1 if is_completed else 0)
            songs_params.append(episode_id)
            cursor.execute(
                f"UPDATE songs SET {', '.join(songs_updates)} "
                f"WHERE podcast_episode_id = %s",
                songs_params,
            )
        except Exception as e:
            # songs mirror is best-effort — pre-migration databases may
            # not have the columns yet, don't fail the primary update.
            print(f"⚠️ [podcast] Could not mirror progress to songs row: {e}")

        conn.commit()

        # Broadcast to other devices so they update their UI
        safe_emit("podcast_episode_updated", {
            "episode_id": episode_id,
            "position": position,
            "is_completed": bool(is_completed) if is_completed is not None else None,
        })

        # Episode finished → drop its NAS download in the background. We only
        # keep episodes we're actively working through, so storage stays bounded.
        if is_completed:
            eventlet.spawn_n(delete_episode_download, db, episode_id)

        return jsonify({"success": True})

    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/rss/feeds/<int:feed_id>/current-episode", methods=["GET"])
def rss_feed_current_episode(feed_id):
    """Return the episode the user is actually currently on in this feed.

    Definition: most-recently-progressed non-completed episode with
    played_position > 0. Used by:
      - Cold-start resume: if the cached episode is now marked completed,
        redirect to whatever the user has actually moved on to.
      - "Resume from device X": same remediation.

    Returns 404 if the feed has nothing in progress (user has either
    completed everything or never started anything).
    """
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        # rss_episodes.last_played_at is the source of truth (updated
        # on every progress save). Fall back to play_history via songs
        # mirror for old rows that pre-date the column. published_at is
        # the last-ditch fallback when nothing else exists.
        cursor.execute(
            """
            SELECT e.*,
                   COALESCE(
                       e.last_played_at,
                       MAX(ph.played_at),
                       e.published_at
                   ) as last_touched
              FROM rss_episodes e
              LEFT JOIN songs s ON s.podcast_episode_id = e.id
              LEFT JOIN play_history ph ON ph.song_id = s.id
             WHERE e.feed_id = %s
               AND COALESCE(e.is_completed, 0) = 0
               AND COALESCE(e.played_position, 0) > 0
             GROUP BY e.id
             ORDER BY last_touched DESC NULLS LAST
             LIMIT 1
            """,
            (feed_id,),
        )
        row = cursor.fetchone()
        if not row:
            return jsonify({"exists": False}), 404

        episode = dict(row)
        # Timestamps need to be JSON-safe
        if episode.get("published_at"):
            episode["published_at"] = episode["published_at"].isoformat()
        if episode.get("created_at"):
            episode["created_at"] = episode["created_at"].isoformat()
        if episode.get("last_played_at") and hasattr(episode["last_played_at"], "isoformat"):
            episode["last_played_at"] = episode["last_played_at"].isoformat()
        if episode.get("last_touched"):
            episode["last_touched"] = episode["last_touched"].isoformat() \
                if hasattr(episode["last_touched"], "isoformat") \
                else str(episode["last_touched"])
        return jsonify({"exists": True, "episode": episode})
    finally:
        conn.close()


@api.route("/api/rss/episodes/<int:episode_id>/chapters", methods=["GET"])
def rss_episode_chapters(episode_id):
    """Return chapters for a podcast episode, keyed by rss_episodes.id.

    The frontend's podcast-playback code path currently uses virtual Song
    objects with id = -episode_id (Phase 3a leaves that in place). Those
    virtual IDs can't be used to look up the real song row directly, so
    we accept episode_id here and map to the songs row internally.
    """
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute(
            "SELECT id FROM songs WHERE podcast_episode_id = %s LIMIT 1",
            (episode_id,),
        )
        row = cursor.fetchone()
        if not row:
            return jsonify({"episode_id": episode_id, "count": 0, "chapters": []})
        song_id = row["id"]
    finally:
        conn.close()

    # Prime the cache on first call.
    try:
        from app.chapters import ensure_chapters_for_song
        ensure_chapters_for_song(db, song_id)
    except Exception as e:
        print(f"[chapters api] Episode {episode_id}: prime failed: {e}")

    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute(
            """
            SELECT order_index, start_time_seconds, end_time_seconds,
                   title, image_url, link_url, is_skippable, source
              FROM song_chapters
             WHERE song_id = %s
             ORDER BY order_index
            """,
            (song_id,),
        )
        chapters = [dict(r) for r in cursor.fetchall()]
    finally:
        conn.close()

    return jsonify({
        "episode_id": episode_id,
        "song_id": song_id,
        "count": len(chapters),
        "chapters": chapters,
    })


@api.route("/api/rss/episodes/<int:episode_id>/resolve", methods=["POST"])
def rss_resolve_episode(episode_id):
    """Force-resolve an episode's audio URL now and cache on songs row.

    Used by the frontend when it's about to play an episode whose
    resolved_url is NULL or expired. Returns the fresh URL directly so
    the caller can use it without a second round trip.
    """
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute(
            "SELECT id, file_path, source_url, resolved_url, "
            "resolved_url_expires_at "
            "FROM songs WHERE podcast_episode_id = %s LIMIT 1",
            (episode_id,),
        )
        row = cursor.fetchone()
        if not row:
            return jsonify({"error": "Episode not mirrored to songs yet"}), 404

        # If cached and fresh, just return it.
        cached = row.get("resolved_url")
        expires = row.get("resolved_url_expires_at")
        if cached and (expires is None or expires > datetime.utcnow() + timedelta(seconds=60)):
            return jsonify({"resolved_url": cached, "from_cache": True})

        source = row.get("source_url") or row.get("file_path")
        final_url, new_expires = resolve_audio_url(source)
        cursor.execute(
            """
            UPDATE songs
               SET resolved_url = %s,
                   resolved_url_expires_at = %s,
                   source_url = COALESCE(source_url, %s)
             WHERE id = %s
            """,
            (final_url, new_expires, source, row["id"]),
        )
        conn.commit()
        return jsonify({
            "resolved_url": final_url,
            "expires_at": new_expires.isoformat() if new_expires else None,
            "from_cache": False,
        })
    except Exception as e:
        conn.rollback()
        return _error_response(e)
    finally:
        conn.close()


# Episodes with a download currently in flight. Prevents duplicate concurrent
# downloads of the same file — repeated play/resume triggers and app restarts
# re-fire the download, and without this guard those 130-280MB transfers fight
# for bandwidth and none ever finish, so the episode never goes local.
_podcast_downloads_in_progress = set()


@api.route("/api/rss/episodes/<int:episode_id>/download", methods=["POST"])
def rss_download_episode(episode_id):
    """Download an episode to the NAS in the background.

    Emits `podcast_download_complete` on success, `podcast_download_failed`
    on failure — the frontend listens for both to update the per-episode
    download button state (was previously silent on failure, so users had
    no way to know the download errored).
    """
    # One in-flight download per episode.
    if episode_id in _podcast_downloads_in_progress:
        return jsonify({"success": True, "message": "Already downloading"})
    _podcast_downloads_in_progress.add(episode_id)

    def _do_download():
      try:
        db = get_db()

        def _emit_progress(downloaded, total):
            safe_emit("podcast_download_progress", {
                "episode_id": episode_id,
                "downloaded": downloaded,
                "total": total,
            })

        try:
            result = download_episode(
                db, episode_id, config.PODCAST_DOWNLOAD_DIR, progress_cb=_emit_progress
            )
        except Exception as e:
            safe_emit("podcast_download_failed", {
                "episode_id": episode_id,
                "error": str(e),
            })
            return
        if result:
            safe_emit("podcast_download_complete", {
                "episode_id": episode_id,
                "path": result,
            })
        else:
            # download_episode returned None — most common cause is the
            # episode had no audio URL, or a graceful exit from an invalid
            # URL. Still a failure from the user's perspective.
            safe_emit("podcast_download_failed", {
                "episode_id": episode_id,
                "error": "Download returned no file — episode may be missing an audio URL or the source server rejected the request.",
            })
      finally:
        _podcast_downloads_in_progress.discard(episode_id)

    eventlet.spawn_n(_do_download)
    return jsonify({"success": True, "message": "Download started"})


@api.route("/api/rss/stream/<int:episode_id>", methods=["GET", "HEAD"])
def rss_stream_episode(episode_id):
    """Stream a podcast episode — serves downloaded file or proxies from source URL.

    Range-handling notes (matters for the rebuffer-restart bug):

    Many podcast CDNs ignore Range requests and respond 200 + the full
    body. If we just pass that response through unchanged but ALSO
    advertise ``Accept-Ranges: bytes``, the client (just_audio) will
    keep re-requesting with Range on every rebuffer, get 200 + full
    body each time, and end up restarting playback from byte 0
    instead of resuming at the dropped position.

    Fix: when upstream returns 200 to a Range request, synthesize the
    206 ourselves by skipping bytes off the upstream stream before
    yielding to the client. This is wasteful upstream-bandwidth-wise
    (we read+drop the first N bytes) but it's the only way to satisfy
    a Range request without downloading the whole file first. The
    client gets a real 206 with correct Content-Range/Content-Length,
    so its seek state stays consistent and rebuffer doesn't restart.
    """
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        cursor.execute(
            "SELECT audio_url, audio_type, downloaded_path, "
            "resolved_url, resolved_url_expires_at FROM rss_episodes WHERE id = %s",
            (episode_id,),
        )
        episode = cursor.fetchone()
        if not episode:
            return jsonify({"error": "Episode not found"}), 404

        # Path 1: Serve downloaded file directly (fast, seekable —
        # send_file already handles Range correctly).
        if episode["downloaded_path"] and os.path.exists(episode["downloaded_path"]):
            return send_file(
                episode["downloaded_path"],
                mimetype=episode["audio_type"] or "audio/mpeg",
                conditional=True,
            )

        # Path 2: Proxy stream from source URL
        audio_url = episode["audio_url"]
        if not audio_url:
            return jsonify({"error": "No audio URL for this episode"}), 404

        # Resolve the tracking-redirect chain (Podtrac/Chartable/Megaphone/...)
        # to the final CDN URL ONCE and cache it. Without this, every HEAD+GET
        # re-walks the whole chain (~15-20s per play). With a cached resolved
        # URL the proxy goes straight to the CDN (one hop). The HEAD request
        # populates the cache; the GET that follows reads it instantly. Falls
        # back to the raw audio_url if the resolve fails so a resolver hiccup
        # never blocks playback.
        play_url = audio_url
        cached_url = episode.get("resolved_url")
        cached_expiry = episode.get("resolved_url_expires_at")
        if cached_url and (
            cached_expiry is None
            or cached_expiry > datetime.utcnow() + timedelta(seconds=60)
        ):
            play_url = cached_url
        else:
            try:
                final_url, new_expiry = resolve_audio_url(audio_url)
                play_url = final_url
                cursor.execute(
                    "UPDATE rss_episodes SET resolved_url = %s, "
                    "resolved_url_expires_at = %s WHERE id = %s",
                    (final_url, new_expiry, episode_id),
                )
                conn.commit()
            except Exception as e:
                print(
                    f"⚠️ [podcast-stream] resolve failed for episode {episode_id}, "
                    f"using raw url: {e}"
                )
                play_url = audio_url

        # Parse incoming Range request, if any. Only single-range "bytes=N-"
        # or "bytes=N-M" forms are common in audio players; we don't try
        # to support multi-range (very rare for audio).
        range_header = request.headers.get("Range")
        req_start = None
        req_end = None
        if range_header:
            m = re.match(r"^bytes=(\d+)-(\d*)$", range_header.strip())
            if m:
                req_start = int(m.group(1))
                req_end = int(m.group(2)) if m.group(2) else None

        # HEAD: cheap probe — only ask upstream for headers, never body
        # bytes. Used by just_audio to discover Content-Length and
        # Range support before opening the stream.
        if request.method == "HEAD":
            upstream = mb_requests.head(
                play_url,
                headers={"User-Agent": "NASRadio/1.0"},
                allow_redirects=True,
                timeout=15,
            )
            resp_headers = {
                "Content-Type": episode["audio_type"] or upstream.headers.get("Content-Type", "audio/mpeg"),
                "Accept-Ranges": "bytes",
            }
            if "Content-Length" in upstream.headers:
                resp_headers["Content-Length"] = upstream.headers["Content-Length"]
            return Response("", status=200, headers=resp_headers)

        # Forward Range header for seeking
        headers = {"User-Agent": "NASRadio/1.0"}
        if range_header:
            headers["Range"] = range_header

        upstream = mb_requests.get(play_url, headers=headers, stream=True, timeout=30)

        upstream_status = upstream.status_code
        upstream_content_length = None
        try:
            if "Content-Length" in upstream.headers:
                upstream_content_length = int(upstream.headers["Content-Length"])
        except (TypeError, ValueError):
            upstream_content_length = None

        # Did the upstream actually honor the Range? 206 means yes,
        # 200 + Range-asked means it ignored us.
        needs_skip_synthesis = (
            range_header is not None
            and req_start is not None
            and upstream_status == 200
            and req_start > 0
        )

        if needs_skip_synthesis:
            # Upstream sent the full body — skip the first req_start
            # bytes and synthesize a 206 to the client. total_size is
            # required for a valid Content-Range header; if upstream
            # didn't tell us, fall back to passthrough (better than
            # responding with an unverifiable 206).
            if upstream_content_length is None:
                print(
                    f"⚠️ [podcast-stream] Episode {episode_id}: upstream ignored "
                    f"Range and didn't expose Content-Length — passthrough, "
                    f"seeking may misbehave."
                )
            else:
                end_byte = (
                    req_end
                    if req_end is not None
                    else upstream_content_length - 1
                )
                end_byte = min(end_byte, upstream_content_length - 1)
                if req_start >= upstream_content_length:
                    upstream.close()
                    return Response(
                        "",
                        status=416,
                        headers={
                            "Content-Range": f"bytes */{upstream_content_length}",
                        },
                    )
                client_length = end_byte - req_start + 1

                def synth_generate(skip_to=req_start, stop_at=end_byte):
                    # `stop_at` is inclusive (byte index). We yield
                    # bytes [skip_to, stop_at] from the upstream
                    # stream, dropping everything before skip_to and
                    # ignoring everything after stop_at.
                    bytes_seen = 0
                    bytes_yielded = 0
                    target_yield = stop_at - skip_to + 1
                    try:
                        for chunk in upstream.iter_content(chunk_size=65536):
                            if not chunk:
                                continue
                            chunk_end = bytes_seen + len(chunk)
                            if chunk_end <= skip_to:
                                bytes_seen = chunk_end
                                continue
                            # Trim front of first useful chunk
                            if bytes_seen < skip_to:
                                chunk = chunk[skip_to - bytes_seen:]
                                bytes_seen = skip_to
                            # Trim tail if we'd over-shoot stop_at
                            remaining = target_yield - bytes_yielded
                            if len(chunk) > remaining:
                                chunk = chunk[:remaining]
                            bytes_yielded += len(chunk)
                            bytes_seen += len(chunk)
                            yield chunk
                            if bytes_yielded >= target_yield:
                                break
                    finally:
                        upstream.close()

                resp_headers = {
                    "Content-Type": episode["audio_type"]
                    or upstream.headers.get("Content-Type", "audio/mpeg"),
                    "Accept-Ranges": "bytes",
                    "Content-Range": (
                        f"bytes {req_start}-{end_byte}/{upstream_content_length}"
                    ),
                    "Content-Length": str(client_length),
                }
                return Response(
                    stream_with_context(synth_generate()),
                    status=206,
                    headers=resp_headers,
                )

        # Normal path: either upstream returned 206 (yay, it supports
        # Range), or there was no Range request at all (200 passthrough
        # is correct), or upstream ignored Range but the request was
        # range=0- (no skip needed).
        resp_headers = {
            "Content-Type": episode["audio_type"] or upstream.headers.get("Content-Type", "audio/mpeg"),
            "Accept-Ranges": "bytes",
        }

        if "Content-Length" in upstream.headers:
            resp_headers["Content-Length"] = upstream.headers["Content-Length"]
        if "Content-Range" in upstream.headers:
            resp_headers["Content-Range"] = upstream.headers["Content-Range"]

        def generate():
            try:
                for chunk in upstream.iter_content(chunk_size=65536):
                    if chunk:
                        yield chunk
            finally:
                upstream.close()

        return Response(
            stream_with_context(generate()),
            status=upstream_status,
            headers=resp_headers,
        )

    except Exception as e:
        traceback.print_exc()
        return _error_response(e)
    finally:
        conn.close()


# ─── Podcast Discovery (Podcast Index API) ───────────────────────

@api.route("/api/podcasts/trending", methods=["GET"])
def podcasts_trending():
    """Get trending podcasts from Podcast Index."""
    from app.podcast_index import PodcastIndexClient
    try:
        client = PodcastIndexClient()
        max_results = request.args.get("max", 20, type=int)
        lang = request.args.get("lang", "en")
        category = request.args.get("cat", None)
        feeds = client.trending(max_results=max_results, lang=lang, category=category)
        return jsonify({"feeds": feeds, "count": len(feeds)})
    except Exception as e:
        return _error_response(e)


@api.route("/api/podcasts/search", methods=["GET"])
def podcasts_search():
    """Search podcasts by name via Podcast Index."""
    from app.podcast_index import PodcastIndexClient
    query = request.args.get("q", "").strip()
    if not query:
        return jsonify({"error": "Missing search query 'q'"}), 400
    try:
        client = PodcastIndexClient()
        max_results = request.args.get("max", 20, type=int)
        feeds = client.search(query, max_results=max_results)
        return jsonify({"feeds": feeds, "count": len(feeds)})
    except Exception as e:
        return _error_response(e)


@api.route("/api/podcasts/categories", methods=["GET"])
def podcasts_categories():
    """Get all podcast categories from Podcast Index."""
    from app.podcast_index import PodcastIndexClient
    try:
        client = PodcastIndexClient()
        cats = client.categories()
        return jsonify({"categories": cats, "count": len(cats)})
    except Exception as e:
        return _error_response(e)


@api.route("/api/podcasts/recommendations", methods=["GET"])
def podcasts_recommendations():
    """Get podcast recommendations based on subscribed feeds.
    Uses the ML recommendation service if available, falls back to trending."""
    from app.podcast_index import PodcastIndexClient
    import random

    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)

    try:
        cursor.execute("SELECT id, title, feed_url FROM rss_feeds")
        feeds = cursor.fetchall()
        if not feeds:
            return jsonify({"source": None, "feeds": [], "count": 0})

        source = random.choice(feeds)
        source_title = source["title"]
        sub_urls = {f["feed_url"] for f in feeds}

        # Try ML recommender service first (use tpool to avoid eventlet socket issues)
        try:
            import urllib.parse
            qs = urllib.parse.urlencode({"title": source_title, "n": 10})
            data = eventlet.tpool.execute(_recommender_get, f"/similar?{qs}", 30)
            recommended = [f for f in data.get("feeds", [])
                           if f.get("url") not in sub_urls]
            if recommended:
                return jsonify({
                    "source": source_title,
                    "feeds": recommended,
                    "count": len(recommended),
                })
        except ConnectionRefusedError:
            pass  # Recommender service is off — silently fall back
        except Exception as e:
            if "10061" not in str(e) and "refused" not in str(e).lower():
                print(f"Recommender call failed: {e}")  # Fall back

        # Fallback: trending in source podcast's category
        client = PodcastIndexClient()
        results = client.search(source_title, max_results=1)
        categories = results[0].get("categories", {}) if results else {}

        recommended = []
        for cat_name in categories.values():
            trending = client.trending(max_results=20, category=cat_name)
            recommended = [f for f in trending if f.get("url") not in sub_urls][:10]
            if len(recommended) >= 3:
                break

        return jsonify({
            "source": source_title,
            "feeds": recommended,
            "count": len(recommended),
        })

    except Exception as e:
        return _error_response(e)
    finally:
        conn.close()


def _recommender_get(path, timeout=10):
    """Call the recommender service via raw HTTP (bypasses eventlet DNS issues)."""
    import http.client, json as _json
    conn = http.client.HTTPConnection('127.0.0.1', 5003, timeout=timeout)
    conn.request('GET', path)
    resp = conn.getresponse()
    data = _json.loads(resp.read().decode())
    conn.close()
    return data


@api.route("/api/podcasts/recommender-status", methods=["GET"])
def podcasts_recommender_status():
    """Check if the ML recommendation service is running."""
    try:
        return jsonify(eventlet.tpool.execute(_recommender_get, '/health', 3))
    except Exception:
        return jsonify({"status": "offline", "count": 0})


@api.route("/api/podcasts/similar", methods=["GET"])
def podcasts_similar():
    """Get similar podcasts by title or ID. Proxies to recommender service."""
    title = request.args.get("title", "")
    feed_id = request.args.get("id", type=int)
    n = request.args.get("n", 10, type=int)

    if not feed_id and not title:
        return jsonify({"error": "Provide 'id' or 'title' parameter"}), 400

    try:
        import urllib.parse
        params = {"n": str(n)}
        if feed_id:
            params["id"] = str(feed_id)
        elif title:
            params["title"] = title
        qs = urllib.parse.urlencode(params)
        path = f"/similar?{qs}"
        return jsonify(eventlet.tpool.execute(_recommender_get, path, 30))
    except ConnectionRefusedError:
        return jsonify({"error": "Recommender service unavailable", "feeds": []}), 503
    except Exception as e:
        if "10061" not in str(e) and "refused" not in str(e).lower():
            print(f"Recommender proxy error: {e}")
        return jsonify({"error": "Recommender service unavailable", "feeds": []}), 503


@api.route("/api/podcasts/rating", methods=["GET"])
def podcasts_rating():
    """Get Spotify rating for a podcast by title. Proxies to recommender service."""
    title = request.args.get("title", "")
    if not title:
        return jsonify({"error": "Provide 'title' parameter"}), 400
    try:
        import urllib.parse
        qs = urllib.parse.urlencode({"title": title})
        return jsonify(eventlet.tpool.execute(_recommender_get, f"/rating?{qs}", 10))
    except Exception:
        return jsonify({"totalRatings": 0, "averageRating": 0})


@api.route("/api/rss/recent-episodes", methods=["GET"])
def rss_recent_episodes():
    """Get latest episodes across all subscribed feeds."""
    limit = request.args.get("limit", 20, type=int)
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute("""
            SELECT e.*, f.title AS feed_title, f.artwork_url AS feed_artwork_url,
                   f.author AS feed_author
            FROM rss_episodes e
            JOIN rss_feeds f ON e.feed_id = f.id
            ORDER BY e.published_at DESC NULLS LAST
            LIMIT %s
        """, (limit,))
        episodes = [dict(row) for row in cursor.fetchall()]
        return jsonify({"episodes": episodes, "count": len(episodes)})
    except Exception as e:
        return _error_response(e)
    finally:
        conn.close()


@api.route("/api/rss/recently-played", methods=["GET"])
def rss_recently_played():
    """Get episodes with playback progress, most recently played first.

    Previously ordered by `e.id DESC` — the episode INSERTION order in
    the DB. That meant the Continue Listening rail showed whichever
    in-progress episode happened to be added to the DB most recently,
    not the one the user actually last listened to. Now ordered by
    last_played_at (set by every progress save) with a fallback to id
    for legacy episodes that pre-date the column.
    """
    limit = request.args.get("limit", 20, type=int)
    db = get_db()
    conn = db.get_connection()
    cursor = db.get_cursor(conn)
    try:
        cursor.execute("""
            SELECT e.*, f.title AS feed_title, f.artwork_url AS feed_artwork_url,
                   f.author AS feed_author
            FROM rss_episodes e
            JOIN rss_feeds f ON e.feed_id = f.id
            WHERE e.played_position > 0 AND e.is_completed = 0
            ORDER BY e.last_played_at DESC NULLS LAST, e.id DESC
            LIMIT %s
        """, (limit,))
        episodes = [dict(row) for row in cursor.fetchall()]
        for ep in episodes:
            if ep.get("published_at") and hasattr(ep["published_at"], "isoformat"):
                ep["published_at"] = ep["published_at"].isoformat()
            if ep.get("created_at") and hasattr(ep["created_at"], "isoformat"):
                ep["created_at"] = ep["created_at"].isoformat()
            if ep.get("last_played_at") and hasattr(ep["last_played_at"], "isoformat"):
                ep["last_played_at"] = ep["last_played_at"].isoformat()
        return jsonify({"episodes": episodes, "count": len(episodes)})
    except Exception as e:
        return _error_response(e)
    finally:
        conn.close()
