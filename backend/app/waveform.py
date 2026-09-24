import json
import os
import shutil
import subprocess
import numpy as np
import eventlet
import eventlet.tpool


# Preferred locations for ffmpeg. Checked in order; first hit wins.
# Keep the shutil.which() call last so an explicit install wins over
# whatever happens to be on PATH.
_FFMPEG_CANDIDATES = [
    os.environ.get("FFMPEG_PATH"),
    r"C:\ytdl\ffmpeg.exe",
    r"C:\Program Files\ffmpeg\bin\ffmpeg.exe",
]


def _find_ffmpeg():
    for p in _FFMPEG_CANDIDATES:
        if p and os.path.isfile(p):
            return p
    on_path = shutil.which("ffmpeg")
    return on_path


_FFMPEG_PATH = _find_ffmpeg()


class WaveformGenerator:
    # Module-level set of song_ids currently being generated, so a
    # rapid-fire sequence of /api/waveform/<id> calls for the same
    # track don't spawn duplicate decode jobs. Without this, the
    # cast+phone flow used to produce 6–7 identical generations
    # per song.
    _in_progress = set()

    def __init__(self, cache_dir=None):
        if cache_dir is None:
            # Store waveforms alongside the database for persistence
            from app.config import Config

            config = Config()
            self.cache_dir = os.path.join(
                os.path.dirname(config.DATABASE_PATH), "waveforms"
            )
        else:
            self.cache_dir = cache_dir
        os.makedirs(self.cache_dir, exist_ok=True)

    def generate_waveform(self, audio_path, song_id, num_samples=1000):
        """Generate waveform data for an audio file.

        Returns a dict with 'status' and 'waveform' keys:
        - status: 'ready', 'generating', or 'error'
        - waveform: list of float values (or placeholder)
        - error: error message (only when status is 'error')
        """
        cache_file = os.path.join(self.cache_dir, f"{song_id}.json")
        error_file = os.path.join(self.cache_dir, f"{song_id}.error")

        # Check cache first
        if os.path.exists(cache_file):
            with open(cache_file, "r") as f:
                return {"status": "ready", "waveform": json.load(f)}

        # Check if a previous generation failed
        if os.path.exists(error_file):
            with open(error_file, "r") as f:
                error_msg = f.read()
            return {
                "status": "error",
                "waveform": [0.5] * num_samples,
                "error": error_msg,
            }

        # Dedup: if another greenthread/tpool call is already
        # decoding this song, skip spawning a second one.
        if song_id in WaveformGenerator._in_progress:
            return {"status": "generating", "waveform": [0.5] * num_samples}

        # Not cached - generate in a real OS thread (ffmpeg subprocess
        # + numpy is blocking work; tpool runs it off the hub).
        WaveformGenerator._in_progress.add(song_id)

        def _bg_generate():
            try:
                eventlet.tpool.execute(
                    self._generate_and_cache, audio_path, song_id, num_samples
                )
            finally:
                WaveformGenerator._in_progress.discard(song_id)

        eventlet.spawn_n(_bg_generate)

        # Return placeholder immediately
        return {"status": "generating", "waveform": [0.5] * num_samples}

    def _load_audio(self, audio_path, target_sr=22050, timeout_seconds=60):
        """Decode any audio file to a float32 mono numpy array via
        a direct ffmpeg subprocess. Replaces librosa.load, which
        hangs indefinitely on m4a files over UNC paths because its
        audioread fallback has no timeout.
        """
        if not _FFMPEG_PATH:
            raise RuntimeError(
                "ffmpeg not found — set FFMPEG_PATH env var or install to PATH"
            )

        cmd = [
            _FFMPEG_PATH,
            "-v", "error",
            "-i", audio_path,
            "-f", "s16le",           # raw signed 16-bit little-endian PCM
            "-ac", "1",              # mono
            "-ar", str(target_sr),   # target sample rate
            "-",                     # stdout
        ]
        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                timeout=timeout_seconds,
                # Prevent subprocess from popping a console on Windows.
                creationflags=(
                    getattr(subprocess, "CREATE_NO_WINDOW", 0)
                    if os.name == "nt"
                    else 0
                ),
            )
        except subprocess.TimeoutExpired as e:
            raise RuntimeError(
                f"ffmpeg decode timed out after {timeout_seconds}s"
            ) from e

        if proc.returncode != 0:
            stderr_tail = proc.stderr.decode("utf-8", errors="ignore").strip()
            # Keep stderr short — the full message can be huge.
            raise RuntimeError(
                f"ffmpeg decode failed (exit {proc.returncode}): {stderr_tail[:300]}"
            )

        audio = np.frombuffer(proc.stdout, dtype=np.int16).astype(np.float32) / 32768.0
        if audio.size == 0:
            raise RuntimeError("ffmpeg produced zero audio samples")
        return audio, target_sr

    def _generate_and_cache(self, audio_path, song_id, num_samples=1000):
        """Background waveform generation (runs in a tpool OS thread)."""
        cache_file = os.path.join(self.cache_dir, f"{song_id}.json")
        error_file = os.path.join(self.cache_dir, f"{song_id}.error")
        try:
            # Load audio via ffmpeg (timeout-bounded)
            y, sr = self._load_audio(audio_path, target_sr=22050, timeout_seconds=60)

            # Take absolute values
            y = np.abs(y)

            # Simple downsampling - take every Nth sample
            step = len(y) // num_samples
            if step < 1:
                step = 1

            # Downsample by taking max in each window
            waveform_data = []
            for i in range(num_samples):
                start = i * step
                end = start + step
                if end > len(y):
                    end = len(y)
                window = y[start:end]
                if len(window) > 0:
                    waveform_data.append(float(np.max(window)))
                else:
                    waveform_data.append(0.0)

            # Find the 95th percentile for normalization (ignore extreme peaks)
            percentile_95 = np.percentile(waveform_data, 95)
            if percentile_95 > 0:
                waveform_data = [min(val / percentile_95, 1.0) for val in waveform_data]

            print(
                f"Waveform stats: min={min(waveform_data):.3f}, "
                f"max={max(waveform_data):.3f}, mean={np.mean(waveform_data):.3f}"
            )

            # A real track is never silent end-to-end. An all-zero / near-silent
            # result means the decode produced no usable signal (a transient UNC
            # read failure, a partial/corrupt decode, etc.). Do NOT cache it: a
            # flat all-zero waveform renders as an INVISIBLE scrubber and, once
            # written, is served forever — the client only re-polls on the 0.5
            # placeholder, never on zeros, so it's stuck. Raise instead, so the
            # error path returns the visible placeholder and a later request can
            # regenerate a real waveform once the source reads cleanly.
            if max(waveform_data) < 0.02:
                raise RuntimeError(
                    "decoded waveform is silent/degenerate (no usable signal)"
                )

            # Cache the result and clean up any previous error marker
            with open(cache_file, "w") as f:
                json.dump(waveform_data, f)
            if os.path.exists(error_file):
                os.remove(error_file)

            return waveform_data

        except Exception as e:
            error_msg = f"{type(e).__name__}: {e}"
            print(f"Error generating waveform for {audio_path}: {error_msg}")
            # Write error marker so client knows generation failed
            # and we don't keep retrying a broken decode on every request.
            try:
                with open(error_file, "w") as f:
                    f.write(error_msg)
            except Exception:
                pass
