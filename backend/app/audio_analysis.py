import requests
import json
import psycopg2
import psycopg2.extras
import threading
import time
from app.config import Config
from app.operation_state import OperationState
from app.extensions import socketio, safe_emit

# Essentia service URL (optional ML analysis sidecar, typically WSL2;
# override with ESSENTIA_SERVICE_URL in .env)

# Path mapping via shared utility
from app.path_utils import map_to_wsl2, WSL2_MUSIC_MOUNT

# Formats Essentia's AudioLoader can actually decode in our build. Anything else
# (notably .opus from YouTube downloads, plus .ogg and exotic lossless like
# .wv/.ape/.dsf) makes the C++ AudioLoader abort BELOW Python's try/except,
# which hard-crashes the whole service process (confirmed on the NAS container:
# one .opus → container restart). So we whitelist the known-good formats and
# skip the rest before ever dispatching to Essentia — no crash, batch flows.
# 2026-09-20: the Essentia service now decodes EVERY file through ffmpeg to a
# plain WAV before its own loader touches it, so the formats that used to
# abort it are safe and analyzable. The list stays as a "this is audio" gate.
ESSENTIA_SUPPORTED_EXTS = (
    ".flac", ".mp3", ".m4a", ".wav", ".aiff", ".aif", ".aac",
    ".opus", ".ogg", ".ape", ".wv", ".dsf", ".dff", ".wma", ".mpc",
)


def _essentia_supports(file_path):
    fp = (file_path or "").lower()
    return fp.endswith(ESSENTIA_SUPPORTED_EXTS)


# Skip absurdly long files (YouTube mixes / ambient / compilations — the library
# has 3,600+ over 30min, up to a 21-HOUR file). Essentia loads the WHOLE track
# into memory at 16kHz and runs 14 models over it, so a multi-hour file times out
# and can OOM-crash the container. A genre/mood/BPM reading on a 3-hour mix is
# meaningless anyway. 1800s = 30min comfortably covers real songs (incl. long
# prog/classical/live tracks) while excluding the mixes.
ESSENTIA_MAX_DURATION_SEC = 1800


# Global flag for cancellation
_cancel_requested = False

# Essentia health-probe state — dedupes redundant probes and silences the
# every-30s log spam when the service is persistently down. /api/health calls
# check_essentia_service() on a fixed cadence; without this it opened a socket
# and logged an identical failure line every single time, burying real errors
# and churning file descriptors (a contributor to the eventlet 512-FD crash).
_essentia_probe_cooldown = 20.0     # don't re-probe more than once per N seconds
_essentia_log_suppress = 300.0      # while down, log the failure at most every N seconds
_essentia_last_probe_ts = 0.0
_essentia_last_result = None        # last known up/down (None = never probed)
_essentia_last_fail_log_ts = 0.0

# Track if we've already tried to auto-resume this session
_auto_resume_attempted = False


def _emit_analysis_progress(
    current,
    total,
    message,
    status="running",
    eta=None,
    analyzed=0,
    failed=0,
    current_song="",
):
    """Emit websocket progress event for audio analysis"""
    safe_emit(
        "analysis_progress",
        {
            "current": current,
            "total": total,
            "message": message,
            "status": status,
            "eta": eta,
            "analyzed": analyzed,
            "failed": failed,
            "current_song": current_song,
        },
    )


def _emit_analysis_result(song_id, title, analysis):
    """Emit a compact per-song result for the live feed in the settings
    modal. Pulls the most-glanceable fields out of the full analysis
    payload so the wire size stays small and the frontend doesn't have
    to know about every Essentia field.

    Top genre/mood are picked by highest confidence/probability. Some
    songs return empty genre/mood arrays from Essentia (instrumentals,
    speech, very short clips) — fields stay null in that case so the
    frontend can render "—" instead of crashing on a missing key.
    """
    bpm_info = analysis.get("bpm", {}) or {}
    key_info = analysis.get("key", {}) or {}
    moods = analysis.get("moods", {}) or {}
    genres = analysis.get("genres", []) or []
    loudness_info = analysis.get("loudness", {}) or {}

    # Top genre by confidence (genres come back as [{name, confidence}, ...])
    top_genre = None
    if genres:
        sorted_genres = sorted(
            genres,
            key=lambda g: g.get("confidence", 0) if isinstance(g, dict) else 0,
            reverse=True,
        )
        if sorted_genres and isinstance(sorted_genres[0], dict):
            top_genre = sorted_genres[0].get("name")

    # Top mood by probability — only mood_* keys, ignore tonal/bright/etc.
    # that aren't really "moods" so much as audio characteristics.
    mood_keys = [
        "happy", "sad", "aggressive", "relaxed",
        "party", "danceability",
    ]
    top_mood = None
    top_mood_score = 0.0
    for k in mood_keys:
        v = moods.get(k)
        if v is not None and v > top_mood_score:
            top_mood = k
            top_mood_score = v

    musical_key = key_info.get("key")
    musical_scale = key_info.get("scale")
    key_label = None
    if musical_key:
        key_label = (
            f"{musical_key} {musical_scale}" if musical_scale else musical_key
        )

    safe_emit(
        "analysis_result",
        {
            "song_id": song_id,
            "title": title,
            "bpm": bpm_info.get("bpm"),
            "key": key_label,
            "top_genre": top_genre,
            "top_mood": top_mood,
            "integrated_loudness_lufs": loudness_info.get(
                "integrated_loudness_lufs"
            ),
        },
    )


def map_path_for_essentia(file_path):
    """Convert local file path to Essentia WSL2 service path."""
    return map_to_wsl2(file_path, WSL2_MUSIC_MOUNT)


def check_essentia_service(force=False):
    """Check if Essentia service is running.

    Timeout sized for WSL2 networking jitter. /api/health polls this
    every 30s and the Flutter client gives up after 5s total; a slow
    sidecar should not produce a false "server unreachable" banner on
    the main app.

    Previously 1.5s, which was too aggressive when WSL2 was momentarily
    busy and produced false "essentia: false" readings even though the
    service was reachable in <100ms with a real probe. 5s gives WSL2
    room to breathe without making the health probe feel sluggish.

    Failures are logged on the DOWN transition and the recovery
    transition, plus at most once every `_essentia_log_suppress` seconds
    while it stays down — so a persistently-offline Essentia no longer
    floods the log with an identical line every 30s. Probes are also
    rate-limited to once per `_essentia_probe_cooldown` seconds (callers
    within that window get the cached result), which cuts socket churn.
    Pass force=True to bypass the cache (e.g. before a restart attempt).
    """
    global _essentia_last_probe_ts, _essentia_last_result, _essentia_last_fail_log_ts

    now = time.monotonic()

    # Serve a cached result inside the cooldown window — no new socket.
    if (
        not force
        and _essentia_last_result is not None
        and (now - _essentia_last_probe_ts) < _essentia_probe_cooldown
    ):
        return _essentia_last_result

    was_up = _essentia_last_result
    reason = None
    try:
        response = requests.get(f"{Config.ESSENTIA_SERVICE_URL}/health", timeout=5)
        is_up = response.status_code == 200
        if not is_up:
            reason = f"HTTP {response.status_code}"
    except requests.exceptions.ConnectTimeout:
        is_up, reason = False, "connect timeout"
    except requests.exceptions.ConnectionError as e:
        is_up, reason = False, f"connection error: {e}"
    except requests.exceptions.Timeout:
        # The socket was accepted but no reply came in time. On the NAS
        # container this means the single-process Flask server is busy
        # inside an Essentia/TensorFlow compute that holds the GIL — it is
        # alive, just working. Calling that DOWN flipped the app's health
        # indicator on every long track and stalled the reconciler
        # (2026-09-12). A truly wedged service is caught by the compose
        # healthcheck (nasradio-essentia goes "unhealthy"), not here.
        is_up, reason = True, "busy (read timeout)"
    except Exception as e:
        is_up, reason = False, f"unexpected {type(e).__name__}: {e}"

    _essentia_last_probe_ts = now
    _essentia_last_result = is_up

    if is_up:
        if was_up is False:
            print(f"[essentia] health: recovered (url={Config.ESSENTIA_SERVICE_URL})")
        return True

    # Down: log on the up→down transition, or once per suppression window.
    if was_up is not False or (now - _essentia_last_fail_log_ts) >= _essentia_log_suppress:
        print(
            f"[essentia] health: DOWN — {reason} (url={Config.ESSENTIA_SERVICE_URL}); "
            f"suppressing repeats for {int(_essentia_log_suppress)}s"
        )
        _essentia_last_fail_log_ts = now
    return False


def _ensure_essentia_alive():
    """In-batch auto-recovery for Essentia hangs.

    History (2026-05-28): this was disabled because the spawn flashed a
    cmd/PowerShell window every time it fired. The root cause turned
    out to be a buggy flag combo (DETACHED_PROCESS silently nullifies
    CREATE_NO_WINDOW per Microsoft's docs). That's fixed in
    service_restart.py as of 2026-06-01, so the watchdog is safe to
    re-enable: no visible window, no console flash.

    Behavior: if /health responds, return True immediately (fast path
    — no restart needed). If /health doesn't respond, force-restart
    Essentia (kill old + spawn new + poll /health up to 120s) and
    return whether the restart succeeded. analyze_song's existing
    retry path retries the same song against the freshly-restarted
    Essentia, so a single bad song's hang doesn't poison the rest of
    the batch — only that one song fails, and even it gets a second
    chance.
    """
    if check_essentia_service():
        return True

    # If Essentia is REMOTE (e.g. the NAS container), we don't own its
    # lifecycle — it self-heals via Docker's `restart: unless-stopped`. The
    # WSL2 kill/spawn below ONLY applies to a local WSL2 service, so thrashing
    # it here is pointless (and was restarting the orphaned WSL2 box). Bail.
    if "127.0.0.1" not in Config.ESSENTIA_SERVICE_URL and "localhost" not in Config.ESSENTIA_SERVICE_URL:
        print(
            f"[essentia] remote service ({Config.ESSENTIA_SERVICE_URL}) unreachable — "
            f"not restarting (Docker manages it on the NAS)"
        )
        return False

    # Local WSL2 service is unreachable — restart it. Imported lazily to avoid a
    # circular import at module load (service_restart imports from this
    # module for check_essentia_service).
    try:
        from app.service_restart import force_restart_essentia
        result = force_restart_essentia()
        if result.get("success"):
            killed = result.get("kill_result", {}).get("killed", 0)
            elapsed = result.get("elapsed_seconds", 0)
            print(
                f"[essentia] watchdog: killed {killed} stale process(es), "
                f"new instance online in {elapsed}s"
            )
            return True
        print(
            f"[essentia] watchdog: restart failed — "
            f"{result.get('message') or result.get('error') or 'unknown error'}"
        )
        return False
    except Exception as e:
        print(f"[essentia] watchdog: exception during restart: {e}")
        return False


def _essentia_post(endpoint, file_path):
    """One request to the Essentia service. ALWAYS returns a dict:
      success              -> the service's JSON
      input is the problem -> {"error": ..., "permanent": True}   (never retry)
      analysis blew up     -> {"error": ..., "permanent": False}  (retry once, later)
      service unreachable  -> {"error": ..., "service_down": True}
    The caller decides what to do; nothing here restarts or retries."""
    if not _essentia_supports(file_path):
        return {"error": "not an audio format Essentia is given", "permanent": True}
    essentia_path = map_path_for_essentia(file_path)
    try:
        response = requests.post(
            f"{Config.ESSENTIA_SERVICE_URL}/{endpoint}",
            json={"file_path": essentia_path},
            # 300s: the NAS is slow, and the first song after a container
            # start pays a one-time TensorFlow warm-up. Steady state ~30s.
            timeout=300,
        )
    except requests.exceptions.ReadTimeout:
        # Alive but still chewing on this one after five minutes.
        return {"error": "Essentia did not answer within 300s", "permanent": False}
    except (requests.exceptions.ConnectionError, requests.exceptions.Timeout) as e:
        return {"error": f"Essentia unreachable ({type(e).__name__})", "service_down": True}
    except Exception as e:
        return {"error": f"{type(e).__name__}: {e}", "permanent": False}

    if response.status_code == 200:
        try:
            return response.json()
        except ValueError:
            return {"error": "Essentia returned non-JSON", "permanent": False}
    try:
        body = response.json()
    except ValueError:
        body = {}
    msg = body.get("error") or f"HTTP {response.status_code} {response.text[:160]}"
    permanent = bool(body.get("permanent")) or response.status_code in (400, 422)
    print(f"[essentia] {endpoint} failed for {file_path}: {msg}")
    return {"error": msg, "permanent": permanent}


def analyze_song(file_path):
    """Full analysis of one song. Dict with "error" on failure (see _essentia_post)."""
    return _essentia_post("analyze", file_path)


def analyze_song_loudness_only(file_path):
    """Loudness-only fast path. Dict with "error" on failure."""
    return _essentia_post("analyze-loudness", file_path)


# ── Failure memory ──────────────────────────────────────────────────────
# Before 2026-09-20 nothing recorded WHICH song failed, so every batch
# started from the same poison file (a 912 MB 192 kHz FLAC that OOM-killed
# the service), the rest of the batch burned as "failed" while the container
# rebooted, and the reconciler relaunched the identical batch forever.
MAX_ANALYSIS_ATTEMPTS = 2


def _record_failure(db_url, song_id, error, permanent):
    try:
        conn = psycopg2.connect(db_url)
        try:
            cur = conn.cursor()
            cur.execute(
                """INSERT INTO song_analysis_failures
                       (song_id, attempts, last_error, permanent, last_attempt_at)
                   VALUES (%s, 1, %s, %s, NOW())
                   ON CONFLICT (song_id) DO UPDATE SET
                       attempts = song_analysis_failures.attempts + 1,
                       last_error = EXCLUDED.last_error,
                       permanent = song_analysis_failures.permanent OR EXCLUDED.permanent,
                       last_attempt_at = NOW()""",
                (song_id, (error or "")[:500], bool(permanent)),
            )
            conn.commit()
        finally:
            conn.close()
    except Exception as e:
        print(f"[essentia] could not record failure for song {song_id}: {e}")


def _clear_failure(db_url, song_id):
    try:
        conn = psycopg2.connect(db_url)
        try:
            cur = conn.cursor()
            cur.execute("DELETE FROM song_analysis_failures WHERE song_id = %s", (song_id,))
            conn.commit()
        finally:
            conn.close()
    except Exception:
        pass


def _wait_for_essentia(max_wait=180):
    """Essentia dropped mid-batch (usually Docker restarting it). Poll until
    it answers again. True when it's back, False if it stays gone."""
    print(f"[essentia] service dropped mid-batch — waiting up to {max_wait}s for it")
    deadline = time.time() + max_wait
    while time.time() < deadline:
        if _cancel_requested:
            return False
        time.sleep(10)
        if check_essentia_service(force=True):
            # Up, but give TensorFlow a moment to finish loading its models.
            time.sleep(5)
            return True
    return False


def backfill_loudness(db_url, song_id, loudness_data):
    """Patch only the loudness columns for a song that already has a
    song_analysis row. Avoids touching the other 20+ fields."""
    conn = psycopg2.connect(db_url)
    cursor = conn.cursor()
    try:
        loudness_info = loudness_data.get("loudness", {}) or {}
        cursor.execute(
            """
            UPDATE song_analysis SET
                loudness = COALESCE(%s, loudness),
                dynamic_complexity = COALESCE(%s, dynamic_complexity),
                integrated_loudness_lufs = %s,
                loudness_range_lu = %s,
                true_peak_dbfs = %s
            WHERE song_id = %s
            """,
            (
                loudness_info.get("loudness"),
                loudness_info.get("dynamic_complexity"),
                loudness_info.get("integrated_loudness_lufs"),
                loudness_info.get("loudness_range_lu"),
                loudness_info.get("true_peak_dbfs"),
                song_id,
            ),
        )
        conn.commit()
        return True
    except Exception as e:
        print(f"Error backfilling loudness for song {song_id}: {e}")
        conn.rollback()
        return False
    finally:
        conn.close()


def store_analysis(db_url, song_id, analysis):
    """Store analysis results in database"""
    conn = psycopg2.connect(db_url)
    cursor = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    try:
        moods = analysis.get("moods", {})
        bpm_info = analysis.get("bpm", {})
        key_info = analysis.get("key", {})
        loudness_info = analysis.get("loudness", {})
        voice_gender = analysis.get("voice_gender", {})

        genres_json = json.dumps(analysis.get("genres", []))
        instruments_json = json.dumps(analysis.get("instruments", []))
        themes_json = json.dumps(analysis.get("themes", []))

        cursor.execute("SELECT id FROM song_analysis WHERE song_id = %s", (song_id,))
        existing = cursor.fetchone()

        if existing:
            cursor.execute(
                """
                UPDATE song_analysis SET
                    bpm = %s, bpm_confidence = %s,
                    musical_key = %s, musical_scale = %s, key_confidence = %s,
                    loudness = %s, dynamic_complexity = %s,
                    integrated_loudness_lufs = %s,
                    loudness_range_lu = %s,
                    true_peak_dbfs = %s,
                    mood_happy = %s, mood_sad = %s, mood_aggressive = %s, mood_relaxed = %s,
                    mood_acoustic = %s, mood_electronic = %s, mood_danceability = %s,
                    mood_instrumental = %s, mood_party = %s, mood_tonal = %s, mood_bright = %s,
                    voice_female = %s, voice_male = %s,
                    genres = %s, instruments = %s, themes = %s,
                    analyzed_at = CURRENT_TIMESTAMP
                WHERE song_id = %s
            """,
                (
                    bpm_info.get("bpm"),
                    bpm_info.get("confidence"),
                    key_info.get("key"),
                    key_info.get("scale"),
                    key_info.get("confidence"),
                    loudness_info.get("loudness"),
                    loudness_info.get("dynamic_complexity"),
                    loudness_info.get("integrated_loudness_lufs"),
                    loudness_info.get("loudness_range_lu"),
                    loudness_info.get("true_peak_dbfs"),
                    moods.get("happy"),
                    moods.get("sad"),
                    moods.get("aggressive"),
                    moods.get("relaxed"),
                    moods.get("acoustic"),
                    moods.get("electronic"),
                    moods.get("danceability"),
                    moods.get("instrumental"),
                    moods.get("party"),
                    moods.get("tonal"),
                    moods.get("bright"),
                    voice_gender.get("female"),
                    voice_gender.get("male"),
                    genres_json,
                    instruments_json,
                    themes_json,
                    song_id,
                ),
            )
        else:
            cursor.execute(
                """
                INSERT INTO song_analysis (
                    song_id, bpm, bpm_confidence,
                    musical_key, musical_scale, key_confidence,
                    loudness, dynamic_complexity,
                    integrated_loudness_lufs, loudness_range_lu, true_peak_dbfs,
                    mood_happy, mood_sad, mood_aggressive, mood_relaxed,
                    mood_acoustic, mood_electronic, mood_danceability,
                    mood_instrumental, mood_party, mood_tonal, mood_bright,
                    voice_female, voice_male,
                    genres, instruments, themes
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            """,
                (
                    song_id,
                    bpm_info.get("bpm"),
                    bpm_info.get("confidence"),
                    key_info.get("key"),
                    key_info.get("scale"),
                    key_info.get("confidence"),
                    loudness_info.get("loudness"),
                    loudness_info.get("dynamic_complexity"),
                    loudness_info.get("integrated_loudness_lufs"),
                    loudness_info.get("loudness_range_lu"),
                    loudness_info.get("true_peak_dbfs"),
                    moods.get("happy"),
                    moods.get("sad"),
                    moods.get("aggressive"),
                    moods.get("relaxed"),
                    moods.get("acoustic"),
                    moods.get("electronic"),
                    moods.get("danceability"),
                    moods.get("instrumental"),
                    moods.get("party"),
                    moods.get("tonal"),
                    moods.get("bright"),
                    voice_gender.get("female"),
                    voice_gender.get("male"),
                    genres_json,
                    instruments_json,
                    themes_json,
                ),
            )

        conn.commit()
        return True
    except Exception as e:
        print(f"Error storing analysis for song {song_id}: {e}")
        conn.rollback()
        return False
    finally:
        conn.close()


def analyze_all_songs(db_url, force_reanalyze=False):
    """Analyze all songs in the library with persistent state"""
    global _cancel_requested
    _cancel_requested = False

    op_state = OperationState(db_url)

    if not check_essentia_service():
        op_state.fail_operation("audio_analysis", "Essentia service not available")
        return {"success": False, "error": "Essentia service not available"}

    conn = psycopg2.connect(db_url)
    cursor = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    # Get songs to analyze (resume capability built-in).
    #
    # Two modes per row:
    #   - `needs_lufs_only = True`  → row exists but no LUFS yet. Fast path
    #     /analyze-loudness, ~10x cheaper than full ML pipeline.
    #   - `needs_lufs_only = False` → no analysis row at all. Full /analyze
    #     (BPM, key, moods, genres, instruments, voice, etc).
    # Podcast filter: the songs table holds podcast episodes too (unified
    # queue model — see songs.podcast_feed_id / podcast_episode_id /
    # file_path-as-http-url). Feeding 4-hour talk podcasts to Essentia's
    # RhythmExtractor2013 makes it deadlock and crash the whole service,
    # so we hard-exclude them from analysis. Discovered 2026-06-01 when
    # the batch kept hanging on WAN Show episodes.
    PODCAST_EXCLUSION = (
        "s.podcast_feed_id IS NULL "
        "AND s.podcast_episode_id IS NULL "
        "AND s.file_path NOT LIKE 'http%'"
    )

    if force_reanalyze:
        cursor.execute(
            f"""
            SELECT s.id, s.file_path, s.title, FALSE AS needs_lufs_only
            FROM songs s
            WHERE {PODCAST_EXCLUSION}
              AND (s.duration IS NULL OR s.duration <= {ESSENTIA_MAX_DURATION_SEC})
            ORDER BY s.id
            """
        )
    else:
        cursor.execute(
            f"""
            SELECT s.id, s.file_path, s.title,
                   (sa.id IS NOT NULL) AS needs_lufs_only
            FROM songs s
            LEFT JOIN song_analysis sa ON s.id = sa.song_id
            LEFT JOIN song_analysis_failures f ON f.song_id = s.id
            WHERE {PODCAST_EXCLUSION}
              AND (s.duration IS NULL OR s.duration <= {ESSENTIA_MAX_DURATION_SEC})
              AND (sa.id IS NULL
                   OR sa.integrated_loudness_lufs IS NULL)
              AND (f.song_id IS NULL
                   OR (f.permanent = FALSE AND f.attempts < {MAX_ANALYSIS_ATTEMPTS}))
            ORDER BY (sa.id IS NULL), s.id
            """
        )

    songs = cursor.fetchall()
    conn.close()

    total = len(songs)
    if total == 0:
        op_state.complete_operation("audio_analysis", "All songs already analyzed")
        return {"success": True, "message": "All songs already analyzed", "analyzed": 0}

    # Start operation
    op_state.start_operation("audio_analysis", total, "Starting audio analysis...")

    # Emit initial status
    _emit_analysis_progress(
        0, total, f"Starting analysis of {total} songs...", "running"
    )

    analyzed = 0
    failed = 0
    song_times = []

    for i, song in enumerate(songs):
        # Check for cancellation
        if _cancel_requested:
            op_state.cancel_operation("audio_analysis")
            _emit_analysis_progress(
                i,
                total,
                "Cancelled by user",
                "cancelled",
                analyzed=analyzed,
                failed=failed,
            )
            return {
                "success": False,
                "message": "Cancelled",
                "analyzed": analyzed,
                "failed": failed,
            }

        # Also check state in case cancelled from another request
        state = op_state.get_state("audio_analysis")
        if state["status"] == "cancelled":
            _emit_analysis_progress(
                i,
                total,
                "Cancelled by user",
                "cancelled",
                analyzed=analyzed,
                failed=failed,
            )
            return {
                "success": False,
                "message": "Cancelled",
                "analyzed": analyzed,
                "failed": failed,
            }

        song_id = song["id"]
        file_path = song["file_path"]
        title = song["title"]

        # Calculate ETA
        if song_times:
            avg_time = sum(song_times[-20:]) / len(song_times[-20:])
            remaining = total - (i + 1)
            eta_seconds = remaining * avg_time

            if eta_seconds < 60:
                eta = f"{int(eta_seconds)}s"
            elif eta_seconds < 3600:
                eta = f"{int(eta_seconds / 60)}m"
            elif eta_seconds < 86400:
                eta = f"{int(eta_seconds / 3600)}h {int((eta_seconds % 3600) / 60)}m"
            else:
                eta = (
                    f"{int(eta_seconds / 86400)}d {int((eta_seconds % 86400) / 3600)}h"
                )
        else:
            eta = "calculating..."

        # Update progress
        op_state.update_progress(
            "audio_analysis",
            i + 1,
            message=f"Analyzing: {title}",
            eta=eta,
            extra_data={"analyzed": analyzed, "failed": failed, "current_song": title},
        )

        # Emit websocket progress
        _emit_analysis_progress(
            i + 1,
            total,
            f"Analyzing: {title}",
            "running",
            eta=eta,
            analyzed=analyzed,
            failed=failed,
            current_song=title,
        )

        # Time the analysis
        song_start = time.time()

        # Dispatch: full analyze for unscored songs, loudness-only
        # backfill for songs that already have ML data but no LUFS.
        # The fast path skips the ~10x more expensive Discogs-Effnet
        # inference and just measures EBU R128 loudness + true peak.
        needs_lufs_only = song.get("needs_lufs_only", False)

        def _attempt():
            return (analyze_song_loudness_only(file_path) if needs_lufs_only
                    else analyze_song(file_path))

        result = _attempt()
        if result.get("service_down"):
            # Essentia vanished (crash + Docker restart, usually). Don't burn
            # the rest of the batch against a dead socket: wait, then retry
            # this one song once.
            if not _wait_for_essentia():
                msg = "Essentia went away mid-batch and didn't come back"
                op_state.fail_operation("audio_analysis", msg)
                _emit_analysis_progress(i, total, msg, "failed",
                                        analyzed=analyzed, failed=failed)
                return {"success": False, "error": msg,
                        "analyzed": analyzed, "failed": failed}
            result = _attempt()
            if result.get("service_down"):
                # Down again on the same song: this file is what kills it.
                result = {"error": "took the Essentia service down twice",
                          "permanent": True}
                if not _wait_for_essentia():
                    _record_failure(db_url, song_id, result["error"], True)
                    msg = "Essentia went away mid-batch and didn't come back"
                    op_state.fail_operation("audio_analysis", msg)
                    _emit_analysis_progress(i, total, msg, "failed",
                                            analyzed=analyzed, failed=failed + 1)
                    return {"success": False, "error": msg,
                            "analyzed": analyzed, "failed": failed + 1}

        stored = False
        if "error" not in result:
            if needs_lufs_only:
                stored = bool(backfill_loudness(db_url, song_id, result))
                if stored:
                    # Re-emit a partial result so the live feed shows the
                    # backfilled LUFS without the fields we didn't touch.
                    loud_info = result.get("loudness", {}) or {}
                    safe_emit(
                        "analysis_result",
                        {
                            "song_id": song_id,
                            "title": title,
                            "bpm": None,
                            "key": None,
                            "top_genre": None,
                            "top_mood": "(LUFS backfill)",
                            "integrated_loudness_lufs": loud_info.get(
                                "integrated_loudness_lufs"
                            ),
                        },
                    )
            else:
                stored = bool(store_analysis(db_url, song_id, result))
                if stored:
                    _emit_analysis_result(song_id, title, result)
            if not stored:
                result = {"error": "analysis succeeded but could not be stored",
                          "permanent": False}

        if stored:
            analyzed += 1
            _clear_failure(db_url, song_id)
        else:
            failed += 1
            _record_failure(db_url, song_id, result.get("error"),
                            result.get("permanent", False))

        song_time = time.time() - song_start
        song_times.append(song_time)

    # Complete
    op_state.complete_operation(
        "audio_analysis", f"Analyzed {analyzed} songs, {failed} failed"
    )

    # Emit complete status
    _emit_analysis_progress(
        total,
        total,
        f"Complete! Analyzed {analyzed} songs, {failed} failed",
        "complete",
        analyzed=analyzed,
        failed=failed,
    )

    return {"success": True, "analyzed": analyzed, "failed": failed, "total": total}


def start_analysis_background(db_url, force_reanalyze=False):
    """Start analysis in background thread"""
    op_state = OperationState(db_url)

    # Check if already running
    state = op_state.get_state("audio_analysis")
    if state["status"] == "running":
        return {"success": False, "error": "Analysis already in progress"}

    thread = threading.Thread(
        target=analyze_all_songs, args=(db_url, force_reanalyze), daemon=True
    )
    thread.start()
    return {"success": True, "message": "Analysis started in background"}


def cancel_analysis(db_url):
    """Cancel running analysis.

    Sets the cancel flag, marks the DB operation cancelled, AND kills
    the WSL Essentia process. The kill is what makes cancel actually
    snappy: without it, workers blocked in 120s HTTP timeouts against
    a hung Essentia don't see the cancel flag until the timeout fires
    (which it won't, if Essentia is genuinely deadlocked). Killing
    Essentia makes every in-flight request fail with ConnectionError
    immediately; workers exit cleanly on their next loop iteration.
    Next Start Analysis click will force-restart Essentia.
    """
    global _cancel_requested
    _cancel_requested = True

    op_state = OperationState(db_url)
    op_state.cancel_operation("audio_analysis")

    try:
        from app.service_restart import kill_essentia_only
        kill_result = kill_essentia_only()
    except Exception as e:
        # Don't fail cancellation just because the kill helper threw —
        # the workers will still drain on their 120s timeouts eventually.
        print(f"[cancel_analysis] kill_essentia_only failed: {e}")
        kill_result = {"killed": 0, "error": str(e)}

    return {
        "success": True,
        "message": "Cancellation requested — Essentia killed to fail in-flight requests fast",
        "kill_result": kill_result,
    }


def get_analysis_state(db_url):
    """Get current analysis state"""
    op_state = OperationState(db_url)
    state = op_state.get_state("audio_analysis")

    # Add service status
    state["service_online"] = check_essentia_service()

    # Add analysis stats
    stats = get_analysis_stats(db_url)
    state.update(stats)

    return state


def get_song_analysis(db_url, song_id):
    """Get analysis for a specific song"""
    conn = psycopg2.connect(db_url)
    cursor = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    cursor.execute("SELECT * FROM song_analysis WHERE song_id = %s", (song_id,))
    row = cursor.fetchone()
    conn.close()

    if not row:
        return None

    result = dict(row)

    if result.get("genres"):
        result["genres"] = json.loads(result["genres"])
    if result.get("instruments"):
        result["instruments"] = json.loads(result["instruments"])
    if result.get("themes"):
        result["themes"] = json.loads(result["themes"])

    return result


def get_analysis_stats(db_url):
    """Get stats about audio analysis coverage"""
    conn = psycopg2.connect(db_url)
    cursor = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    cursor.execute("SELECT COUNT(*) FROM songs")
    total_songs = cursor.fetchone()["count"]

    cursor.execute("SELECT COUNT(*) FROM song_analysis")
    analyzed_songs = cursor.fetchone()["count"]

    conn.close()

    return {
        "total_songs": total_songs,
        "analyzed_songs": analyzed_songs,
        "coverage_percent": round(
            (analyzed_songs / total_songs * 100) if total_songs > 0 else 0, 1
        ),
    }


def check_and_resume_analysis(db_url):
    """
    Check if there's an interrupted analysis and resume it.
    Called on application startup.

    DISABLED 2026-06-01 — was firing on every Flask restart because:
      (a) simpson1045's Cancel-then-restart workflow races: the cancel sets
          state='cancelled' in DB, but if the worker is mid-song when
          Flask is killed, the last update_progress call from the worker
          may have re-set state='running'. So at restart time the DB
          says 'running' and auto-resume kicks off another batch that
          immediately hangs on whatever song was the original problem.
      (b) The count query used here was missing the podcast filter
          (`s.podcast_feed_id IS NULL AND s.file_path NOT LIKE 'http%'`)
          so the "31868 remaining" message disagreed with the actual
          ~27300 the real batch query would find post-filter.

    Until those are fixed properly (deduce crash-vs-cancel from
    updated_at timestamp, use the same filtered count query), no auto-
    resume. simpson1045 explicitly clicks Start Audio Analysis to begin a
    batch — that path already does force-restart-Essentia for safety.
    """
    return {"resumed": False, "reason": "Auto-resume disabled — click Start to begin"}
