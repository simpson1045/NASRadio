"""Surround / Dolby helpers shared by the scanner and the stream route.

- probe_audio(): ffprobe-based reader for containers mutagen can't open
  (TrueHD/Atmos disc rips in .mka). Returns an object shaped enough like a
  mutagen File (``.info`` + Vorbis-style ``.tags``) that the scanner's
  metadata path works unchanged.
- cover_art(): embedded cover from a Matroska attachment or attached pic.
- make_cast_sidecar() / queue_cast_sidecar(): the ``<file>.cast.m4a`` E-AC-3
  5.1 version of a multichannel track. The LG's Cast player can only carry
  surround to the Denon as DD+, and can't play TrueHD at all, so casts (and
  every non-passthrough client, for TrueHD) get this file. Previously only
  backfill_audio_meta.py made these, by hand; now new imports queue one.

Every ffmpeg/ffprobe call runs through eventlet's tpool when eventlet is
loaded, so a long encode never blocks the hub.
"""

import json
import os
import queue
import shutil
import subprocess
import tempfile
import threading

EAC3_SIDECAR_BITRATE = "768k"
# Containers the scanner reads through ffprobe instead of mutagen.
PROBED_EXTENSIONS = (".mka",)


def _run(cmd, timeout):
    try:
        import eventlet.tpool
        return eventlet.tpool.execute(
            subprocess.run, cmd, capture_output=True, timeout=timeout)
    except ImportError:
        return subprocess.run(cmd, capture_output=True, timeout=timeout)


def _ffprobe():
    return shutil.which("ffprobe") or "ffprobe"


def _ffmpeg():
    return shutil.which("ffmpeg") or "ffmpeg"


def sidecar_path(path):
    return os.path.splitext(path)[0] + ".cast.m4a"


class ProbedInfo:
    def __init__(self, stream, fmt):
        self.codec = (stream.get("codec_name") or "").lower()
        self.profile = stream.get("profile") or ""
        self.channels = int(stream.get("channels") or 2)
        self.sample_rate = int(stream.get("sample_rate") or 0)
        self.bits_per_sample = int(stream.get("bits_per_raw_sample") or 0) or None
        try:
            self.length = float(fmt.get("duration") or stream.get("duration") or 0)
        except (TypeError, ValueError):
            self.length = 0.0
        try:
            self.bitrate = int(fmt.get("bit_rate") or stream.get("bit_rate") or 0)
        except (TypeError, ValueError):
            self.bitrate = 0


# ffprobe/Matroska tag names -> the Vorbis-style keys the scanner reads.
_TAG_ALIASES = {
    "album_artist": "albumartist", "album artist": "albumartist",
    "track": "tracknumber", "part_number": "tracknumber",
    "disc": "discnumber", "year": "date", "date_released": "date",
}


class ProbedAudio:
    """Just enough of mutagen's File interface for Scanner.extract_metadata."""

    def __init__(self, path, data):
        self.path = path
        streams = data.get("streams") or []
        audio = next((s for s in streams if s.get("codec_type") == "audio"), {})
        fmt = data.get("format") or {}
        self.info = ProbedInfo(audio, fmt)
        tags = {}
        for src in (fmt.get("tags") or {}, audio.get("tags") or {}):
            for k, v in src.items():
                key = _TAG_ALIASES.get(k.lower(), k.lower())
                if v not in (None, "") and key not in tags:
                    tags[key] = [str(v)]
        self.tags = tags
        self._streams = streams

    def get(self, key, default=None):
        """Easy-mode tag lookup, like mutagen's File(..., easy=True)."""
        return self.tags.get(key, default)


def probe_audio(path):
    """ProbedAudio for a file mutagen can't read, or None if it has no audio."""
    try:
        r = _run([_ffprobe(), "-v", "error", "-show_format", "-show_streams",
                  "-of", "json", path], timeout=60)
        data = json.loads(r.stdout or b"{}")
    except Exception as e:
        print(f"  ⚠️ ffprobe failed for {path}: {e}")
        return None
    if not any(s.get("codec_type") == "audio" for s in data.get("streams") or []):
        return None
    return ProbedAudio(path, data)


def cover_art(probed):
    """Cover image bytes from a Matroska attachment or an attached picture."""
    for i, s in enumerate(probed._streams):
        is_pic = (s.get("disposition") or {}).get("attached_pic") == 1
        mime = ((s.get("tags") or {}).get("mimetype") or "").lower()
        if s.get("codec_type") == "attachment" and mime.startswith("image/"):
            try:
                with tempfile.TemporaryDirectory() as tmp:
                    out = os.path.join(tmp, "cover")
                    _run([_ffmpeg(), "-v", "error", f"-dump_attachment:{s.get('index', i)}", out,
                          "-i", probed.path, "-f", "null", "-"], timeout=60)
                    if os.path.exists(out) and os.path.getsize(out) > 0:
                        return open(out, "rb").read()
            except Exception as e:
                print(f"  ⚠️ attachment cover extract failed: {e}")
        elif s.get("codec_type") == "video" and is_pic:
            try:
                r = _run([_ffmpeg(), "-v", "error", "-i", probed.path,
                          "-map", f"0:{s.get('index', i)}", "-frames:v", "1",
                          "-f", "image2pipe", "-c:v", "mjpeg", "-"], timeout=60)
                if r.stdout:
                    return r.stdout
            except Exception as e:
                print(f"  ⚠️ attached-pic cover extract failed: {e}")
    return None


def make_cast_sidecar(path, timeout=1800):
    """Write <file>.cast.m4a (E-AC-3 5.1 @ 768k, 48 kHz). Returns
    'exists' | 'created' | 'failed'. Same recipe as backfill_audio_meta.py:
    -ac 6 because the C2's E-AC-3 decoder crashes on odd layouts (5.0, and
    a TrueHD 7.1 Atmos bed folds to 5.1 here); -f mp4 because the .m4a
    'ipod' muxer refuses eac3; +faststart for progressive Cast playback."""
    sidecar = sidecar_path(path)
    if os.path.exists(sidecar):
        return "exists"
    tmp = sidecar + ".part"
    try:
        r = _run([_ffmpeg(), "-y", "-v", "error", "-i", path,
                  "-map", "0:a:0", "-vn",
                  "-c:a", "eac3", "-b:a", EAC3_SIDECAR_BITRATE, "-ar", "48000",
                  "-ac", "6", "-movflags", "+faststart", "-f", "mp4", tmp],
                 timeout=timeout)
        if r.returncode != 0 or not os.path.exists(tmp) or os.path.getsize(tmp) == 0:
            print(f"  ⚠️ cast sidecar FAILED for {path}: {(r.stderr or b'')[-300:]!r}")
            return "failed"
        os.replace(tmp, sidecar)
        return "created"
    except Exception as e:
        print(f"  ⚠️ cast sidecar error for {path}: {e}")
        return "failed"
    finally:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass


# One background worker: imports can queue many tracks, and each encode is a
# full decode/encode pass, so they go one at a time.
_sidecar_q = queue.Queue()
_worker_started = False
_worker_lock = threading.Lock()


def _sidecar_worker():
    while True:
        path = _sidecar_q.get()
        try:
            result = make_cast_sidecar(path)
            if result == "created":
                print(f"  🔊 Cast 5.1 sidecar made: {os.path.basename(path)}")
        finally:
            _sidecar_q.task_done()


def queue_cast_sidecar(path):
    global _worker_started
    if os.path.exists(sidecar_path(path)):
        return
    with _worker_lock:
        if not _worker_started:
            threading.Thread(target=_sidecar_worker, name="cast-sidecar",
                             daemon=True).start()
            _worker_started = True
    _sidecar_q.put(path)
