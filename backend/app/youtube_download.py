"""
YouTube download integration for NASRadio
Download audio from YouTube using yt-dlp and tag with mutagen
"""

import os
import re
import json
import shutil
import subprocess
import eventlet
import eventlet.tpool
from datetime import datetime
from mutagen.oggopus import OggOpus
from mutagen.flac import FLAC
from mutagen.mp3 import MP3
from mutagen.id3 import ID3, TIT2, TPE1, TPE2, TALB, TRCK, TDRC, APIC
from mutagen.mp4 import MP4
from app.config import Config
from app.extensions import socketio, safe_emit
from app.utils import parse_artists

# Track active downloads for cancellation
_active_downloads = {}  # operation_id -> {"process": subprocess, "cancelled": False}

# Snapshot of last-emitted progress per operation, kept so the
# YouTube screen can show "you have an active download" + resume the
# progress display when the user navigates back. Cleared on terminal
# status (complete / error / cancelled) after a short grace window so
# the UI can still see the final state if the user opens the screen
# right after completion.
_job_state = {}  # operation_id -> dict


def _record_job_snapshot(operation_id, status, message, progress, kind=None, url=None):
    """Store the latest progress event for an operation.

    Called from _emit_progress so every websocket update also lands
    in a queryable dict. Older entries are pruned on terminal status
    after a brief delay so a screen opened right after completion
    still sees the final 'complete!' state.
    """
    if not operation_id:
        return
    entry = _job_state.setdefault(operation_id, {
        "operation_id": operation_id,
        "started_at": datetime.utcnow().isoformat() + "Z",
        "kind": kind,
        "url": url,
    })
    entry["status"] = status
    entry["message"] = message
    entry["progress"] = progress
    entry["updated_at"] = datetime.utcnow().isoformat() + "Z"
    if kind:
        entry["kind"] = kind
    if url:
        entry["url"] = url


def _retire_job(operation_id, delay_seconds=30):
    """Remove a finished/cancelled job from _job_state after a grace
    period. The grace window lets a user who navigated back to the
    YouTube screen right after the job finished still see the final
    state instead of a blank screen."""
    if not operation_id:
        return

    def _do():
        eventlet.sleep(delay_seconds)
        _job_state.pop(operation_id, None)
        _active_downloads.pop(operation_id, None)

    eventlet.spawn_n(_do)


def cancel_download(operation_id):
    """Cancel an active download by operation_id"""
    if operation_id in _active_downloads:
        _active_downloads[operation_id]["cancelled"] = True
        proc = _active_downloads[operation_id].get("process")
        if proc and proc.poll() is None:
            proc.terminate()
        _record_job_snapshot(operation_id, "cancelled", "Cancelled", 0)
        _retire_job(operation_id)
        return True
    return False


def is_cancelled(operation_id):
    """Check if download was cancelled"""
    return _active_downloads.get(operation_id, {}).get("cancelled", False)


def list_active_jobs():
    """Return a list of currently-tracked jobs (running or recently
    finished, within the retire grace window). Used by the YouTube
    screen on open to rejoin in-flight jobs.
    """
    return list(_job_state.values())


class YouTubeDownloader:
    """Client for downloading and processing YouTube audio"""

    def __init__(self):
        self.config = Config()
        # Staging folder for downloads before tagging/import
        self.staging_dir = os.path.join(
            os.path.dirname(self.config.DATABASE_PATH), "youtube_staging"
        )
        os.makedirs(self.staging_dir, exist_ok=True)

    def _cookie_args(self):
        """Return the cookie-related argument list for yt-dlp invocations.

        Two modes, file wins when both are set:

        - `YT_DLP_COOKIES_FILE` → `--cookies <path>`. Preferred on
          Windows because Chromium-family browsers lock their cookies
          DB while running (yt-dlp issue 7271) and a static file
          sidesteps the lock entirely.
        - `YT_DLP_COOKIES_FROM_BROWSER` → `--cookies-from-browser <name>`.
          yt-dlp reads cookies directly from the named browser's
          profile.

        Returns [] when neither is configured (anonymous downloads;
        age-gated videos will fail). yt-dlp itself reports a clear
        error if the file path is invalid, so no preflight check here.
        """
        cookies_file = (self.config.YT_DLP_COOKIES_FILE or "").strip()
        if cookies_file:
            return ["--cookies", cookies_file]
        browser = (self.config.YT_DLP_COOKIES_FROM_BROWSER or "").strip()
        if not browser:
            return []
        return ["--cookies-from-browser", browser]

    def _emit_progress(self, operation_id, status, message, progress=0, data=None):
        """Emit WebSocket progress event AND record a snapshot so the
        YouTube screen can resume a job after navigating away.

        Terminal statuses (complete, error, cancelled) schedule a
        retire so the entry disappears after a short grace window;
        until then a fresh screen open still shows the final state.
        """
        payload = {
            "operation_id": operation_id,
            "status": status,
            "message": message,
            "progress": progress,
        }
        if data:
            payload["data"] = data
        safe_emit("youtube_progress", payload)

        # Mirror into the queryable snapshot dict.
        kind = None
        url = None
        if isinstance(data, dict):
            kind = data.get("kind")
            url = data.get("url")
        _record_job_snapshot(operation_id, status, message, progress,
                             kind=kind, url=url)

        if status in ("complete", "error", "cancelled"):
            _retire_job(operation_id)

    def validate_url(self, url):
        """
        Validate and identify YouTube URL type
        Returns: dict with 'valid', 'type' (video/playlist), 'id'
        """
        # YouTube URL patterns
        video_patterns = [
            r"(?:youtube\.com/watch\?v=|youtu\.be/)([a-zA-Z0-9_-]{11})",
            r"youtube\.com/embed/([a-zA-Z0-9_-]{11})",
            r"youtube\.com/v/([a-zA-Z0-9_-]{11})",
        ]

        playlist_patterns = [
            r"youtube\.com/playlist\?list=([a-zA-Z0-9_-]+)",
            r"youtube\.com/watch\?.*list=([a-zA-Z0-9_-]+)",
        ]

        # Check for playlist first (video URL might contain playlist param)
        for pattern in playlist_patterns:
            match = re.search(pattern, url)
            if match:
                # Check if it's ONLY a playlist URL or also has a video
                video_match = None
                for vp in video_patterns:
                    video_match = re.search(vp, url)
                    if video_match:
                        break

                return {
                    "valid": True,
                    "type": "playlist" if not video_match else "both",
                    "playlist_id": match.group(1),
                    "video_id": video_match.group(1) if video_match else None,
                }

        # Check for video only
        for pattern in video_patterns:
            match = re.search(pattern, url)
            if match:
                return {
                    "valid": True,
                    "type": "video",
                    "video_id": match.group(1),
                }

        return {"valid": False, "error": "Invalid YouTube URL"}

    def _parse_ytdlp_error(self, stderr):
        """Parse yt-dlp stderr into a user-friendly error with details"""
        lines = stderr.strip().split("\n") if stderr else []
        errors = []
        warnings = []

        for line in lines:
            line = line.strip()
            if not line:
                continue
            if line.startswith("ERROR:"):
                errors.append(line.replace("ERROR: ", "", 1))
            elif line.startswith("WARNING:"):
                warnings.append(line.replace("WARNING: ", "", 1))

        # Build user-friendly error message
        error_type = "unknown"
        if any("not available" in e.lower() for e in errors):
            error_type = "unavailable"
        elif any("private" in e.lower() for e in errors):
            error_type = "private"
        elif any("age" in e.lower() for e in errors):
            error_type = "age_restricted"
        elif any("copyright" in e.lower() for e in errors):
            error_type = "copyright"

        # Check warnings for JS runtime / outdated issues
        needs_update = any(
            "not supported" in w.lower() or "challenge solver" in w.lower()
            for w in warnings
        )
        if needs_update:
            error_type = "needs_update"

        # Primary error message
        error_msg = errors[0] if errors else "Unknown error"

        # Add context if JS runtime warnings suggest outdated yt-dlp
        if needs_update and error_type == "needs_update":
            error_msg = (
                "yt-dlp may be outdated and unable to process this video. "
                "Try updating yt-dlp using the update button above."
            )

        return {
            "error": error_msg,
            "error_type": error_type,
            "warnings": warnings,
            "details": errors,
        }

    def _extract_warnings(self, stderr):
        """Extract warning lines from stderr"""
        if not stderr:
            return []
        return [
            line.strip().replace("WARNING: ", "", 1)
            for line in stderr.strip().split("\n")
            if line.strip().startswith("WARNING:")
        ]

    def get_video_info(self, url):
        """
        Get metadata for a single video without downloading
        """
        try:
            cmd = [
                "yt-dlp",
                "--js-runtimes", "deno",
                "--remote-components", "ejs:github",
                *self._cookie_args(),
                "--dump-json",
                "--no-download",
                "--no-playlist",
                url,
            ]

            # Run yt-dlp on a tpool thread so its stdout buffering doesn't
            # block the eventlet hub. subprocess.run reads the pipe
            # synchronously to completion; eventlet doesn't monkey-patch
            # subprocess pipe I/O, so this blocking-on-pipe call would
            # otherwise wedge the entire backend (no HTTP responses, no
            # cast/phone stream serving) for the full 30-second timeout.
            result = eventlet.tpool.execute(
                lambda: subprocess.run(
                    cmd, capture_output=True, text=True, timeout=30
                )
            )

            if result.returncode != 0:
                # Surface the raw yt-dlp stderr to combined.log so we can
                # diagnose cookie-loading / extractor failures without
                # having to shell out manually. _parse_ytdlp_error only
                # returns a structured wrapper for the frontend; the
                # underlying message lives in stderr.
                print(f"yt-dlp get_video_info failed for {url}: {result.stderr.strip()}")
                error_details = self._parse_ytdlp_error(result.stderr)
                return {"success": False, **error_details}

            info = json.loads(result.stdout)

            # Include any warnings even on success
            warnings = self._extract_warnings(result.stderr)

            # See note in get_playlist_info — yt-dlp returns a float
            # duration on authenticated calls, frontend casts to int.
            duration = info.get("duration")
            if duration is not None:
                duration = int(duration)
            # Native YouTube chapters (only present when the uploader/auto-
            # parser produced real chapter markers). Each entry from yt-dlp:
            # {"start_time", "end_time", "title"}. Normalize to the same
            # shape we use for description-parsed chapters so the frontend
            # doesn't care about the source.
            native_chapters = []
            for idx, ch in enumerate(info.get("chapters") or []):
                start = ch.get("start_time")
                end = ch.get("end_time")
                native_chapters.append({
                    "order_index": idx,
                    "start_seconds": int(start) if start is not None else 0,
                    "end_seconds": int(end) if end is not None else None,
                    "title": ch.get("title") or f"Chapter {idx + 1}",
                })

            return {
                "success": True,
                "warnings": warnings,
                "info": {
                    "id": info.get("id"),
                    "title": info.get("title"),
                    "uploader": info.get("uploader"),
                    "channel": info.get("channel"),
                    "duration": duration,
                    "thumbnail": info.get("thumbnail"),
                    "upload_date": info.get("upload_date"),
                    # Bumped from 500 → 8000: YouTube allows descriptions up
                    # to 5000 chars, and the description-timestamp parser
                    # (youtube_chapters.py) needs the full tracklist. Most
                    # OST uploads have 20-50 timestamp lines.
                    "description": info.get("description", "")[:8000],
                    "view_count": info.get("view_count"),
                    "chapter_count": len(native_chapters),
                    "chapters": native_chapters,
                },
            }
        except subprocess.TimeoutExpired:
            return {"success": False, "error": "Request timed out", "error_type": "timeout"}
        except json.JSONDecodeError:
            return {"success": False, "error": "Failed to parse video info", "error_type": "parse_error"}
        except Exception as e:
            return {"success": False, "error": str(e), "error_type": "unknown"}

    def get_playlist_info(self, url):
        """
        Get metadata for all videos in a playlist without downloading
        """
        try:
            # A watch URL with &list= also carries &v=/&index=/&start_radio=,
            # and yt-dlp expands the Mix behind it into hundreds of entries.
            # Strip it to the bare playlist first.
            from app.youtube_curate import normalize_playlist
            norm = normalize_playlist(url)
            if norm:
                url = norm["url"]
            cmd = [
                "yt-dlp",
                "--js-runtimes", "deno",
                "--remote-components", "ejs:github",
                *self._cookie_args(),
                "--dump-json",
                "--flat-playlist",
                "--no-download",
                url,
            ]

            # See note on the get_video_info call about why this needs
            # tpool — playlist enumeration can run 120s and would block
            # the entire backend without it.
            result = eventlet.tpool.execute(
                lambda: subprocess.run(
                    cmd, capture_output=True, text=True, timeout=120
                )
            )

            if result.returncode != 0:
                print(f"yt-dlp get_playlist_info failed for {url}: {result.stderr.strip()}")
                return {"success": False, "error": result.stderr}

            # Each line is a JSON object for one video
            tracks = []
            for line in result.stdout.strip().split("\n"):
                if line:
                    try:
                        info = json.loads(line)
                        # yt-dlp returns duration as float when the call
                        # is authenticated (via --cookies / cookies-file),
                        # int when anonymous. The Flutter side casts to
                        # int, which throws on a double and silently
                        # kills the playlist-list itemBuilder mid-render.
                        # Coerce to int here so the API contract stays
                        # stable regardless of auth state.
                        duration = info.get("duration")
                        if duration is not None:
                            duration = int(duration)
                        tracks.append(
                            {
                                "id": info.get("id"),
                                "title": info.get("title"),
                                "uploader": info.get("uploader"),
                                "channel": info.get("channel"),
                                "duration": duration,
                                "url": f"https://www.youtube.com/watch?v={info.get('id')}",
                            }
                        )
                    except json.JSONDecodeError:
                        continue

            return {
                "success": True,
                "track_count": len(tracks),
                "tracks": tracks,
            }
        except subprocess.TimeoutExpired:
            return {"success": False, "error": "Request timed out"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def download_video(self, url, operation_id=None, video_title=None):
        """
        Download audio from a single YouTube video
        Returns path to downloaded file and metadata
        """
        import re
        import select
        import sys

        try:
            if operation_id:
                title_display = (
                    video_title[:50] + "..."
                    if video_title and len(video_title) > 50
                    else (video_title or "video")
                )
                self._emit_progress(
                    operation_id, "downloading", f"Starting: {title_display}", 0
                )

            # Generate unique filename based on video ID
            url_info = self.validate_url(url)
            video_id = url_info.get("video_id", datetime.now().strftime("%Y%m%d%H%M%S"))
            output_template = os.path.join(self.staging_dir, f"{video_id}.%(ext)s")

            cmd = [
                "yt-dlp",
                "--js-runtimes", "deno",
                "--remote-components", "ejs:github",
                *self._cookie_args(),
                "-x",  # Extract audio
                "--audio-format",
                # MP3 instead of opus: Essentia's AudioLoader can't decode opus
                # (it hard-crashes the analysis container), and mp3 plays/analyzes
                # everywhere. --audio-quality 0 keeps it ~245-320k VBR so we lose
                # next to nothing vs YouTube's ~128-160k opus source. The chapter
                # splitter below stream-copies this format, so chapters become mp3 too.
                "mp3",
                "--audio-quality",
                "0",  # Best quality
                "-o",
                output_template,
                "--no-playlist",  # Only download single video
                "--newline",  # Progress on new lines for parsing
                "--progress-template",
                "download:[%(progress._percent_str)s] %(progress._speed_str)s ETA:%(progress._eta_str)s",
                url,
            ]

            # Run yt-dlp and stream output
            process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )

            # Track for cancellation
            if operation_id:
                _active_downloads[operation_id] = {
                    "process": process,
                    "cancelled": False,
                }

            info = None
            last_progress = 0
            error_lines = []  # Capture error output

            # Read output line by line. Each `readline()` is a blocking
            # pipe read that eventlet does NOT monkey-patch, so doing it
            # directly here would freeze the eventlet hub between yt-dlp
            # output lines — and yt-dlp can be silent for many seconds
            # during the actual download phase. Result: cast / phone /
            # log all stop working for the entire download duration
            # (the bug simpson1045 repro'd by casting + downloading at the
            # same time). Solution: each readline() call goes through
            # tpool, so a real OS thread blocks on the pipe and the
            # eventlet hub stays free to serve other requests. The rest
            # of the loop body still runs on the hub (socketio emits,
            # progress tracking, etc. all eventlet-native).
            def _read_one_line():
                return process.stdout.readline()

            while True:
                line = eventlet.tpool.execute(_read_one_line)
                if not line:
                    break
                # Check for cancellation
                if operation_id and is_cancelled(operation_id):
                    process.terminate()
                    self._emit_progress(
                        operation_id, "cancelled", "Download cancelled", 0
                    )
                    if operation_id in _active_downloads:
                        del _active_downloads[operation_id]
                    return {"success": False, "error": "Cancelled by user"}
                if not line:
                    break

                line = line.strip()

                # Parse progress lines
                if line.startswith("download:["):
                    # Extract percentage from progress line
                    match = re.search(r"\[(\d+\.?\d*)%\]", line)
                    if match and operation_id:
                        percent = float(match.group(1))
                        # Only emit if progress changed significantly
                        if percent - last_progress >= 2 or percent >= 99:
                            last_progress = percent
                            # Extract speed and ETA
                            speed_match = re.search(r"\]\s*([\d.]+\s*\w+/s)", line)
                            eta_match = re.search(r"ETA:(\S+)", line)
                            speed = speed_match.group(1) if speed_match else ""
                            eta = eta_match.group(1) if eta_match else ""

                            msg = f"Downloading: {int(percent)}%"
                            if speed:
                                msg += f" ({speed})"
                            if eta and eta != "Unknown":
                                msg += f" ETA:{eta}"

                            self._emit_progress(
                                operation_id, "downloading", msg, int(percent)
                            )

                # Check for JSON metadata (printed at end)
                elif line.startswith("{") and '"id"' in line:
                    try:
                        info = json.loads(line)
                    except json.JSONDecodeError:
                        pass

                # Check for extraction message
                elif "Extracting audio" in line or "Post-process" in line:
                    if operation_id:
                        self._emit_progress(
                            operation_id, "processing", "Extracting audio...", 95
                        )

                # Capture error/warning lines
                elif (
                    "ERROR" in line or "WARNING" in line or "Video unavailable" in line
                ):
                    error_lines.append(line)
                    print(f"yt-dlp: {line}")

            # Wait for process exit on a tpool thread — blocks the OS
            # thread, not the eventlet hub.
            eventlet.tpool.execute(lambda: process.wait(timeout=60))

            if process.returncode != 0:
                error_msg = (
                    "; ".join(error_lines)
                    if error_lines
                    else "yt-dlp failed (no error details)"
                )
                print(f"yt-dlp failed for {url}: {error_msg}")
                if operation_id:
                    self._emit_progress(
                        operation_id, "error", f"Download failed: {error_msg[:100]}", 0
                    )
                return {"success": False, "error": error_msg}

            # Find the downloaded file
            downloaded_file = None
            for ext in ["opus", "ogg", "m4a", "mp3", "webm"]:
                potential_file = os.path.join(self.staging_dir, f"{video_id}.{ext}")
                if os.path.exists(potential_file):
                    downloaded_file = potential_file
                    break

            if not downloaded_file:
                return {"success": False, "error": "Downloaded file not found"}

            # Get metadata if we didn't capture it from output
            if not info:
                # Quick metadata fetch
                info_result = self.get_video_info(url)
                if info_result.get("success"):
                    info = info_result.get("info", {})
                else:
                    info = {}

            if operation_id:
                self._emit_progress(operation_id, "complete", "Download complete!", 100)

            # Cleanup tracking
            if operation_id and operation_id in _active_downloads:
                del _active_downloads[operation_id]

            return {
                "success": True,
                "file_path": downloaded_file,
                "filename": os.path.basename(downloaded_file),
                "video_id": video_id,
                "metadata": {
                    "title": info.get("title") if info else video_title,
                    "uploader": info.get("uploader") if info else None,
                    "channel": info.get("channel") if info else None,
                    "duration": info.get("duration") if info else None,
                    "thumbnail": info.get("thumbnail") if info else None,
                    "upload_date": info.get("upload_date") if info else None,
                },
            }

        except subprocess.TimeoutExpired:
            if operation_id:
                self._emit_progress(operation_id, "error", "Download timed out", 0)
            return {"success": False, "error": "Download timed out"}
        except Exception as e:
            if operation_id:
                self._emit_progress(operation_id, "error", str(e), 0)
            return {"success": False, "error": str(e)}

    def download_playlist(self, url, operation_id=None):
        """
        Download all audio from a YouTube playlist
        Returns list of downloaded files with metadata
        """
        try:
            if operation_id:
                self._emit_progress(
                    operation_id, "downloading", "Getting playlist info...", 0
                )

            # First get playlist info to know total count
            playlist_info = self.get_playlist_info(url)
            if not playlist_info["success"]:
                return playlist_info

            total_tracks = playlist_info["track_count"]
            downloaded = []

            for i, track in enumerate(playlist_info["tracks"]):
                # Check for cancellation
                if operation_id and is_cancelled(operation_id):
                    self._emit_progress(
                        operation_id,
                        "cancelled",
                        f"Cancelled after {i}/{total_tracks} tracks",
                        0,
                    )
                    if operation_id in _active_downloads:
                        del _active_downloads[operation_id]
                    return {
                        "success": False,
                        "error": "Cancelled by user",
                        "downloaded_count": len(downloaded),
                    }

                if operation_id:
                    progress = int((i / total_tracks) * 100)
                    self._emit_progress(
                        operation_id,
                        "downloading",
                        f"Downloading {i + 1}/{total_tracks}: {track['title']}",
                        progress,
                        {"current": i + 1, "total": total_tracks},
                    )

                result = self.download_video(
                    track["url"],
                    operation_id=operation_id,
                    video_title=track.get("title"),
                )
                if result["success"]:
                    downloaded.append(result)
                else:
                    # Log error but continue with other tracks
                    print(f"Failed to download {track['title']}: {result.get('error')}")

            if operation_id:
                self._emit_progress(
                    operation_id,
                    "complete",
                    f"Downloaded {len(downloaded)}/{total_tracks} tracks",
                    100,
                )

            return {
                "success": True,
                "total_tracks": total_tracks,
                "downloaded_count": len(downloaded),
                "tracks": downloaded,
            }

        except Exception as e:
            if operation_id:
                self._emit_progress(operation_id, "error", str(e), 0)
            return {"success": False, "error": str(e)}

    def apply_tags(self, file_path, tags):
        """
        Apply metadata tags to audio file using mutagen

        tags: dict with keys: title, artist, album, track_number, year, album_artist
        """
        try:
            ext = os.path.splitext(file_path)[1].lower()

            if ext in [".opus", ".ogg"]:
                audio = OggOpus(file_path)
                audio["title"] = tags.get("title", "")
                audio["artist"] = tags.get("artist", "")
                audio["album"] = tags.get("album", "")
                audio["albumartist"] = tags.get("album_artist", tags.get("artist", ""))
                if tags.get("track_number"):
                    audio["tracknumber"] = str(tags["track_number"])
                if tags.get("year"):
                    audio["date"] = str(tags["year"])
                audio.save()

            elif ext == ".flac":
                audio = FLAC(file_path)
                audio["title"] = tags.get("title", "")
                audio["artist"] = tags.get("artist", "")
                audio["album"] = tags.get("album", "")
                audio["albumartist"] = tags.get("album_artist", tags.get("artist", ""))
                if tags.get("track_number"):
                    audio["tracknumber"] = str(tags["track_number"])
                if tags.get("year"):
                    audio["date"] = str(tags["year"])
                audio.save()

            elif ext == ".mp3":
                # MP3 uses ID3 tags
                try:
                    audio = ID3(file_path)
                except Exception:
                    audio = ID3()

                audio["TIT2"] = TIT2(encoding=3, text=tags.get("title", ""))
                audio["TPE1"] = TPE1(encoding=3, text=tags.get("artist", ""))
                audio["TALB"] = TALB(encoding=3, text=tags.get("album", ""))
                # TPE2 = album artist. Lets a compilation file under "Various
                # Artists" (album) while TPE1 keeps the real per-track artist.
                audio["TPE2"] = TPE2(
                    encoding=3,
                    text=tags.get("album_artist", tags.get("artist", "")),
                )
                if tags.get("track_number"):
                    audio["TRCK"] = TRCK(encoding=3, text=str(tags["track_number"]))
                if tags.get("year"):
                    audio["TDRC"] = TDRC(encoding=3, text=str(tags["year"]))
                audio.save(file_path)

            elif ext in [".m4a", ".mp4"]:
                audio = MP4(file_path)
                audio["\xa9nam"] = tags.get("title", "")
                audio["\xa9ART"] = tags.get("artist", "")
                audio["\xa9alb"] = tags.get("album", "")
                audio["aART"] = tags.get("album_artist", tags.get("artist", ""))
                if tags.get("track_number"):
                    audio["trkn"] = [(int(tags["track_number"]), 0)]
                if tags.get("year"):
                    audio["\xa9day"] = str(tags["year"])
                audio.save()

            else:
                return {"success": False, "error": f"Unsupported format: {ext}"}

            return {"success": True}

        except Exception as e:
            return {"success": False, "error": str(e)}

    def import_to_library(self, file_path, artist_name, album_name):
        """
        Move tagged file from staging to music library
        Creates artist/album folder structure
        Returns the new file path
        """
        try:
            # Sanitize folder names
            def sanitize_name(name):
                # Remove invalid filesystem characters
                invalid_chars = '<>:"/\\|?*'
                for char in invalid_chars:
                    name = name.replace(char, "")
                return name.strip()

            safe_artist = sanitize_name(artist_name)
            safe_album = sanitize_name(album_name)

            # Create destination path
            dest_dir = os.path.join(
                self.config.MUSIC_LIBRARY_PATH, safe_artist, safe_album
            )
            os.makedirs(dest_dir, exist_ok=True)

            # Get filename and move
            filename = os.path.basename(file_path)
            dest_path = os.path.join(dest_dir, filename)

            # If file exists, add number suffix
            if os.path.exists(dest_path):
                base, ext = os.path.splitext(filename)
                counter = 1
                while os.path.exists(dest_path):
                    dest_path = os.path.join(dest_dir, f"{base}_{counter}{ext}")
                    counter += 1

            shutil.move(file_path, dest_path)

            return {
                "success": True,
                "file_path": dest_path,
                "artist_folder": safe_artist,
                "album_folder": safe_album,
            }

        except Exception as e:
            return {"success": False, "error": str(e)}

    def _resolve_artist_ids(self, cursor, names):
        """Resolve a list of artist names to artist ids, in order.

        Case-insensitive lookup; creates the artist when missing (with a
        best-effort MusicBrainz MBID, same as the single-artist path used to
        do). De-duplicates by resolved id so the caller's count loop can't
        credit the same artist twice. Returns at least one id.
        """
        from app.musicbrainz import lookup_artist_mbid
        ids = []
        for name in names:
            name = (name or "").strip()
            if not name:
                continue
            cursor.execute(
                "SELECT id FROM artists WHERE LOWER(name) = LOWER(%s)", (name,)
            )
            row = cursor.fetchone()
            if row:
                aid = row["id"]
            else:
                cursor.execute(
                    "INSERT INTO artists (name) VALUES (%s) RETURNING id", (name,)
                )
                aid = cursor.fetchone()["id"]
                # Store the MBID now so artwork/alias lookups don't re-search
                # it later. Best-effort, never fatal.
                try:
                    _mbid = lookup_artist_mbid(name)
                    from app.artist_image_downloader import fetch_artist_image_async
                    fetch_artist_image_async(aid, name)
                    if _mbid:
                        cursor.execute(
                            "UPDATE artists SET mbid = %s WHERE id = %s",
                            (_mbid, aid),
                        )
                except Exception:
                    pass
            if aid not in ids:
                ids.append(aid)
        return ids

    def import_video_as_album(self, url, chapters, album_meta, db,
                              operation_id=None, target_album_id=None):
        """
        Download a YouTube video, split it into tracks by chapter, tag each
        track, and insert as one album in the library.

        When [target_album_id] is supplied, skip artist/album creation, reuse
        the existing album's artist_id, and move the split files into that
        album's existing on-disk folder. Artwork is NOT overwritten in that
        case — the existing album keeps its current cover.

        Args:
            url: YouTube watch URL.
            chapters: list of {order_index, start_seconds, end_seconds, title,
                              track_number?, skip?}. Items with skip=True are
                              excluded; the remaining items are renumbered
                              1..N as track_number for the final album.
            album_meta: {title, artist, year?}. `year` may be None.
            db: app.database connection wrapper (provides get_connection / get_cursor).
            operation_id: optional, for progress emit + cancellation.

        Returns:
            {success: bool, album_id: int, songs_added: int, error?: str}
        """
        from urllib.request import urlopen, Request
        from urllib.error import URLError, HTTPError

        # Filter + renumber chapters. Caller's `skip` is the only opt-out.
        active = [c for c in chapters if not c.get("skip")]
        if not active:
            return {"success": False, "error": "No chapters selected"}
        # Defensive: sort by start_seconds in case the frontend reordered.
        active.sort(key=lambda c: c.get("start_seconds", 0))
        # Renumber sequentially — the user's manual reorder/skip becomes the
        # final track ordering on the album.
        for i, c in enumerate(active, start=1):
            c["track_number"] = i

        album_title = (album_meta.get("title") or "").strip()
        artist_name = (album_meta.get("artist") or "").strip()
        year = album_meta.get("year")
        if not album_title or not artist_name:
            return {"success": False, "error": "Album title and artist required"}

        # Split the hand-typed artist field into individual credits ("A & B",
        # "A feat. B", "A, B, C") so collaborations land on every artist via
        # the song_artists junction — not just the first name. The first
        # credit is the album's primary artist (folder + album.artist_id).
        artist_names = parse_artists(artist_name)

        total_tracks = len(active)
        created_files = []  # for cleanup on error
        source_file = None
        try:
            # 1) Download the full video into staging via the existing
            # download_video pipeline (cancellation + progress already wired).
            if operation_id:
                self._emit_progress(operation_id, "downloading",
                                    f"Downloading source video ({total_tracks} chapters)...", 0)

            download_result = self.download_video(url, operation_id=operation_id,
                                                  video_title=album_title)
            if not download_result.get("success"):
                return {"success": False,
                        "error": f"Download failed: {download_result.get('error')}"}

            source_file = download_result["file_path"]
            video_id = download_result.get("video_id")
            video_meta = download_result.get("metadata") or {}
            thumbnail_url = video_meta.get("thumbnail")

            # 2) Split with ffmpeg — stream-copy each chapter (no re-encode).
            # `-ss` before `-i` is fast seek; for chapter-second granularity
            # the small alignment imprecision (<20ms on opus) is inaudible.
            if operation_id:
                self._emit_progress(operation_id, "processing",
                                    f"Splitting into {total_tracks} chapters...", 80)

            src_ext = os.path.splitext(source_file)[1]  # e.g. ".opus"
            split_files = []
            for i, ch in enumerate(active):
                if operation_id and is_cancelled(operation_id):
                    raise RuntimeError("Cancelled by user")

                start = int(ch.get("start_seconds") or 0)
                end = ch.get("end_seconds")
                if end is None:
                    # Last chapter or unknown end — let ffmpeg run to source EOF.
                    duration = None
                else:
                    duration = max(1, int(end) - start)

                safe_title = re.sub(r'[<>:"/\\|?*]', "", ch.get("title", "")).strip() or f"Track {i + 1}"
                track_num = ch["track_number"]
                out_name = f"{video_id}_{track_num:02d} - {safe_title}{src_ext}"
                out_path = os.path.join(self.staging_dir, out_name)

                cmd = ["ffmpeg", "-y", "-ss", str(start), "-i", source_file]
                if duration is not None:
                    cmd.extend(["-t", str(duration)])
                cmd.extend(["-c:a", "copy", out_path])

                result = eventlet.tpool.execute(
                    subprocess.run, cmd, capture_output=True, timeout=120
                )
                if result.returncode != 0:
                    raise RuntimeError(
                        f"ffmpeg failed on chapter {track_num} '{safe_title}': "
                        f"exit {result.returncode}"
                    )
                created_files.append(out_path)

                # Tag with mutagen so the file is self-describing too.
                self.apply_tags(out_path, {
                    "title": ch.get("title", "").strip() or f"Track {track_num}",
                    "artist": artist_name,
                    "album": album_title,
                    "album_artist": artist_name,
                    "track_number": f"{track_num}/{total_tracks}",
                    "year": str(year) if year else None,
                })

                split_files.append({
                    "path": out_path,
                    "title": ch.get("title", "").strip() or f"Track {track_num}",
                    "track_number": track_num,
                    "duration": duration or 0,
                })

                if operation_id:
                    pct = 80 + int((i + 1) / total_tracks * 15)  # 80→95
                    self._emit_progress(operation_id, "processing",
                                        f"Split {i + 1}/{total_tracks}: {safe_title}", pct)

            # 3) DB inserts: artist + album + songs. Direct SQL — we have
            # all the metadata, no need to round-trip through MusicScanner.
            if operation_id:
                self._emit_progress(operation_id, "processing",
                                    "Creating album in library...", 95)

            conn = db.get_connection()
            cursor = db.get_cursor(conn)

            if target_album_id:
                # Importing into an EXISTING album — pin the song rows to that
                # album_id + its artist_id, and route the files into the
                # album's actual on-disk folder. We pull both from a sample
                # song already in the album (no separate album.folder_path
                # column is reliably populated for legacy library entries).
                cursor.execute(
                    "SELECT artist_id FROM albums WHERE id = %s",
                    (target_album_id,),
                )
                row = cursor.fetchone()
                if not row:
                    raise RuntimeError(f"Target album {target_album_id} not found")
                # Existing album: its artist stays the primary (per the
                # compilation-folder logic). Still resolve any additional
                # credits from the artist field so collaborators show up.
                primary_artist_id = row["artist_id"]
                album_id = target_album_id
                artist_ids = self._resolve_artist_ids(cursor, artist_names)
                artist_ids = [primary_artist_id] + [
                    a for a in artist_ids if a != primary_artist_id
                ]

                cursor.execute(
                    "SELECT file_path FROM songs WHERE album_id = %s LIMIT 1",
                    (target_album_id,),
                )
                song_row = cursor.fetchone()
                if not song_row:
                    raise RuntimeError(
                        f"Target album {target_album_id} has no songs to derive "
                        "the on-disk folder from"
                    )
                dest_dir = os.path.dirname(song_row["file_path"])
                if not os.path.isdir(dest_dir):
                    raise RuntimeError(f"Album directory not found: {dest_dir}")
            else:
                # Resolve every credited artist (case-insensitive lookup,
                # create-if-missing with best-effort MBID). The first is the
                # album's primary artist; the rest ride along on the junction.
                artist_ids = self._resolve_artist_ids(cursor, artist_names)
                primary_artist_id = artist_ids[0]
                primary_name = artist_names[0]

                # Album (case-insensitive uniqueness by (primary artist, title)).
                cursor.execute(
                    "SELECT id FROM albums WHERE LOWER(title) = LOWER(%s) AND artist_id = %s",
                    (album_title, primary_artist_id),
                )
                row = cursor.fetchone()
                if row:
                    album_id = row["id"]
                else:
                    cursor.execute(
                        "INSERT INTO albums (title, artist_id, year, album_type) "
                        "VALUES (%s, %s, %s, %s) RETURNING id",
                        (album_title, primary_artist_id, year, "album"),
                    )
                    album_id = cursor.fetchone()["id"]

                # Destination folder for a fresh album — filed under the
                # primary artist (matches how the library scanner organizes
                # multi-artist tracks), not the raw "A & B" string.
                def _sanitize(s):
                    for ch_ in '<>:"/\\|?*':
                        s = s.replace(ch_, "")
                    return s.strip() or "Unknown"

                dest_dir = os.path.join(
                    self.config.MUSIC_LIBRARY_PATH,
                    _sanitize(primary_name),
                    _sanitize(album_title),
                )
                os.makedirs(dest_dir, exist_ok=True)

            songs_added = 0
            song_ids = []
            for sf in split_files:
                final_path = os.path.join(dest_dir, os.path.basename(sf["path"]))
                # Collide-safe rename if a file with that name already exists.
                if os.path.exists(final_path):
                    base, ext = os.path.splitext(final_path)
                    n = 1
                    while os.path.exists(f"{base}_{n}{ext}"):
                        n += 1
                    final_path = f"{base}_{n}{ext}"
                shutil.move(sf["path"], final_path)

                file_size = os.path.getsize(final_path)
                ext = os.path.splitext(final_path)[1].lstrip(".").upper()

                cursor.execute(
                    """INSERT INTO songs
                       (title, artist_id, album_id, track_number, disc_number,
                        duration, file_path, file_size, file_format,
                        is_explicit, is_hdcd, source_type, source_url)
                       VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                       RETURNING id""",
                    (sf["title"], primary_artist_id, album_id, sf["track_number"], 1,
                     sf["duration"], final_path, file_size, ext, 0, 0,
                     "local", url),
                )
                new_song_id = cursor.fetchone()["id"]
                song_ids.append(new_song_id)
                # song_artists junction — credit every artist on the track,
                # in order (position 1 = primary).
                for position, aid in enumerate(artist_ids, start=1):
                    cursor.execute(
                        """INSERT INTO song_artists (song_id, artist_id, position)
                           VALUES (%s, %s, %s) ON CONFLICT DO NOTHING""",
                        (new_song_id, aid, position),
                    )
                songs_added += 1

            # Type the freshly-imported album by its shape (1 track=Single,
            # 2-6=EP, 7+=Album), but only while it still carries the un-inferred
            # default ('album') — never clobber a real MusicBrainz/user type.
            try:
                cursor.execute(
                    "SELECT COUNT(*) AS c FROM songs WHERE album_id = %s",
                    (album_id,),
                )
                tc = cursor.fetchone()["c"]
                inferred = "Single" if tc <= 1 else ("EP" if tc <= 6 else "Album")
                cursor.execute(
                    "UPDATE albums SET album_type = %s "
                    "WHERE id = %s AND (album_type IS NULL OR album_type IN ('', 'album'))",
                    (inferred, album_id),
                )
            except Exception as _e:
                print(f"[youtube] album type inference failed: {_e}")

            conn.commit()

            # 4) Album artwork: fetch YouTube thumbnail → 500×500 JPEG.
            # Skip when importing to an existing album — that album already
            # has whatever cover the user wants; we shouldn't clobber it.
            if thumbnail_url and not target_album_id:
                try:
                    artwork_dir = os.path.join(
                        os.path.dirname(os.path.dirname(__file__)),
                        Config.ARTWORK_FOLDER,
                    )
                    os.makedirs(artwork_dir, exist_ok=True)
                    artwork_filename = f"album_{album_id}.jpg"
                    artwork_path = os.path.join(artwork_dir, artwork_filename)

                    req = Request(thumbnail_url, headers={"User-Agent": "NASRadio/1.0"})
                    with urlopen(req, timeout=15) as resp:
                        img_bytes = resp.read()

                    from io import BytesIO
                    from PIL import Image
                    img = Image.open(BytesIO(img_bytes)).convert("RGB")
                    # Center-crop to square first (YouTube thumbnails are 16:9),
                    # then resize. Avoids distorted oval covers.
                    w, h = img.size
                    side = min(w, h)
                    left = (w - side) // 2
                    top = (h - side) // 2
                    img = img.crop((left, top, left + side, top + side))
                    img = img.resize((500, 500), Image.LANCZOS)
                    img.save(artwork_path, "JPEG", quality=90)

                    cursor.execute(
                        "UPDATE albums SET artwork_path = %s WHERE id = %s",
                        (artwork_filename, album_id),
                    )
                    conn.commit()
                except (URLError, HTTPError, Exception) as e:
                    # Non-fatal — album exists, just doesn't have a cover yet.
                    print(f"[youtube-as-album] thumbnail save failed: {e}")

            # 5) Update artist/album song counts (best-effort).
            try:
                cursor.execute(
                    "UPDATE albums SET song_count = "
                    "(SELECT COUNT(*) FROM songs WHERE album_id = %s) WHERE id = %s",
                    (album_id, album_id),
                )
                # Recompute counts for every credited artist. album_count =
                # albums where this artist is the primary (matches the scanner);
                # song_count = every track they're credited on (the junction).
                for aid in artist_ids:
                    cursor.execute(
                        "UPDATE artists SET album_count = "
                        "(SELECT COUNT(DISTINCT id) FROM albums WHERE artist_id = %s), "
                        "song_count = (SELECT COUNT(*) FROM song_artists WHERE artist_id = %s) "
                        "WHERE id = %s",
                        (aid, aid, aid),
                    )
                conn.commit()
            except Exception as e:
                print(f"[youtube-as-album] count update failed (non-fatal): {e}")

            # 6) Cleanup the source video — we have the chapter slices now.
            try:
                if source_file and os.path.exists(source_file):
                    os.remove(source_file)
            except Exception:
                pass

            if operation_id:
                self._emit_progress(operation_id, "complete",
                                    f"Imported '{album_title}' ({songs_added} tracks)", 100)

            return {
                "success": True,
                "album_id": album_id,
                "artist_id": primary_artist_id,
                "songs_added": songs_added,
                "song_ids": song_ids,
            }

        except Exception as e:
            # Best-effort cleanup of any split files left in staging.
            for p in created_files:
                try:
                    if os.path.exists(p):
                        os.remove(p)
                except Exception:
                    pass
            try:
                if source_file and os.path.exists(source_file):
                    os.remove(source_file)
            except Exception:
                pass
            err = str(e)
            print(f"[youtube-as-album] failed: {err}")
            if operation_id:
                self._emit_progress(operation_id, "error",
                                    f"Import failed: {err[:120]}", 0)
            return {"success": False, "error": err}

    def get_staged_files(self):
        """Get list of files currently in staging folder"""
        try:
            files = []
            for filename in os.listdir(self.staging_dir):
                file_path = os.path.join(self.staging_dir, filename)
                if os.path.isfile(file_path):
                    files.append(
                        {
                            "filename": filename,
                            "path": file_path,
                            "size": os.path.getsize(file_path),
                        }
                    )
            return {"success": True, "files": files}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def delete_staged_file(self, filename):
        """Delete a file from staging"""
        try:
            file_path = os.path.join(self.staging_dir, filename)
            if os.path.exists(file_path):
                os.remove(file_path)
                return {"success": True}
            return {"success": False, "error": "File not found"}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def clear_staging(self):
        """Clear all files from staging folder"""
        try:
            for filename in os.listdir(self.staging_dir):
                file_path = os.path.join(self.staging_dir, filename)
                if os.path.isfile(file_path):
                    os.remove(file_path)
            return {"success": True}
        except Exception as e:
            return {"success": False, "error": str(e)}
