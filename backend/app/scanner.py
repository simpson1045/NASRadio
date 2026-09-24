import os
import re
import shutil
import subprocess
import psycopg2
from app.subprocess_helper import safe_subprocess_run
from mutagen import File
from mutagen.id3 import ID3, APIC
from mutagen.flac import FLAC, Picture
from mutagen.mp4 import MP4, MP4Cover
from app.models import Database
from app.config import Config
from app.extensions import socketio, safe_emit
from app.musicbrainz import lookup_artist_mbid
from PIL import Image
import io
import hashlib


def fetch_artwork_for_album(artist_name, album_title, album_id):
    """Use existing ArtworkSearch to fetch artwork for a new album"""
    try:
        from app.artwork_search import ArtworkSearch

        searcher = ArtworkSearch()
        results = searcher.search_musicbrainz(artist_name, album_title, limit=5)

        if results and len(results) > 0:
            # Get the best match (first result, already sorted by confidence)
            best = results[0]
            if best.get("confidence", 0) >= 50:
                release_id = best.get("release_id")
                if release_id:
                    artwork_filename = searcher.download_and_save_artwork(
                        release_id, album_id
                    )
                    if artwork_filename:
                        print(
                            f"  ↳ Downloaded artwork from MusicBrainz (confidence: {best.get('confidence')})"
                        )
                        return artwork_filename
        return None
    except Exception as e:
        print(f"  ↳ Artwork fetch failed: {e}")
        return None


# parse_artists now lives in app.utils so the YouTube importer can share the
# exact same splitting logic (re-exported here for existing callers/imports).
from app.utils import parse_artists  # noqa: E402,F401


class MusicScanner:
    """Scan music library and populate database"""

    def __init__(self, db, progress_tracker=None, operation_id=None):
        self.db = db
        self.config = Config()
        self.scanned_files = 0
        self.artists_added = 0
        self.albums_added = 0
        self.songs_added = 0
        self.progress_tracker = progress_tracker
        self.operation_id = operation_id
        self.artwork_extracted = 0

        # Create artwork directory if it doesn't exist
        self.artwork_dir = self.config.ARTWORK_FOLDER
        if not os.path.exists(self.artwork_dir):
            os.makedirs(self.artwork_dir)

    def _emit_progress(self, current, total, message, status="running"):
        """Emit websocket progress event"""
        if self.operation_id:
            safe_emit(
                "scan_progress",
                {
                    "operation_id": self.operation_id,
                    "current": current,
                    "total": total,
                    "message": message,
                    "status": status,
                    "songs_added": self.songs_added,
                    "albums_added": self.albums_added,
                    "artists_added": self.artists_added,
                },
            )

    def scan_library(self):
        """Scan the music library directory"""
        print(f"📂 Scanning music library: {self.config.MUSIC_LIBRARY_PATH}")

        if not os.path.exists(self.config.MUSIC_LIBRARY_PATH):
            print(
                f"❌ Music library path does not exist: {self.config.MUSIC_LIBRARY_PATH}"
            )
            if self.progress_tracker and self.operation_id:
                self.progress_tracker.fail_operation(
                    self.operation_id, "Music library path does not exist"
                )
            self._emit_progress(0, 0, "Music library path does not exist", "failed")
            return

        # Emit counting status
        self._emit_progress(0, 0, "Counting files...", "counting")

        # First, count total files
        total_files = 0
        for root, dirs, files in os.walk(self.config.MUSIC_LIBRARY_PATH):
            # Skip Synology recycle bin and other hidden folders
            if "#recycle" in root.lower() or "/@" in root:
                continue
            for filename in files:
                file_ext = os.path.splitext(filename)[1].lower()
                if file_ext in self.config.SUPPORTED_FORMATS and not filename.lower().endswith(".cast.m4a"):
                    total_files += 1

        if self.progress_tracker and self.operation_id:
            self.progress_tracker.start_operation(
                self.operation_id, total_files, "library scan"
            )

        # Emit starting status with total
        self._emit_progress(
            0, total_files, f"Found {total_files} files to scan", "running"
        )

        # Walk through all subdirectories
        processed = 0
        for root, dirs, files in os.walk(self.config.MUSIC_LIBRARY_PATH):
            # Skip Synology recycle bin and other hidden folders
            if "#recycle" in root.lower() or "/@" in root:
                continue
            for filename in files:
                file_path = os.path.join(root, filename)
                file_ext = os.path.splitext(filename)[1].lower()

                # Check if it's a supported audio file
                if file_ext in self.config.SUPPORTED_FORMATS and not filename.lower().endswith(".cast.m4a"):
                    # Check if cancelled
                    if self.progress_tracker and self.operation_id:
                        progress = self.progress_tracker.get_progress(self.operation_id)
                        if progress and progress["status"] == "cancelled":
                            print("⏹️ Scan cancelled by user")
                            self._emit_progress(
                                processed, total_files, "Scan cancelled", "cancelled"
                            )
                            return

                    self.process_audio_file(file_path)
                    processed += 1

                    # Update progress (both tracker and websocket)
                    display_filename = os.path.basename(file_path)
                    if self.progress_tracker and self.operation_id:
                        self.progress_tracker.update_progress(
                            self.operation_id,
                            processed,
                            f"Scanning: {display_filename}",
                        )

                    # Emit websocket progress
                    self._emit_progress(
                        processed, total_files, f"Scanning: {display_filename}"
                    )

        print(f"\n✅ Scan complete!")
        print(f"📊 Files scanned: {self.scanned_files}")
        print(f"👤 Artists added: {self.artists_added}")
        print(f"💿 Albums added: {self.albums_added}")
        print(f"🎵 Songs added: {self.songs_added}")

        # Emit complete status
        self._emit_progress(
            total_files,
            total_files,
            f"Scan complete! Added {self.songs_added} songs",
            "complete",
        )

        if self.progress_tracker and self.operation_id:
            self.progress_tracker.complete_operation(
                self.operation_id, f"Scan complete! Added {self.songs_added} songs"
            )
        print(f"🖼️  Artwork extracted: {self.artwork_extracted}")

    def scan_folder(self, target_folder):
        """Scan a specific folder within the music library"""
        # If it's a relative path, prepend the music library path
        if not os.path.isabs(target_folder):
            target_folder = os.path.join(self.config.MUSIC_LIBRARY_PATH, target_folder)

        print(f"Scanning folder: {target_folder}")

        # Check if the exact path exists
        if not os.path.exists(target_folder):
            print(f"Folder does not exist: {target_folder}")
            if self.progress_tracker and self.operation_id:
                self.progress_tracker.fail_operation(
                    self.operation_id, "Folder does not exist at specified path"
                )
            self._emit_progress(
                0, 0, "Folder does not exist at specified path", "failed"
            )
            return

        if not os.path.isdir(target_folder):
            print(f"Path is not a directory: {target_folder}")
            if self.progress_tracker and self.operation_id:
                self.progress_tracker.fail_operation(
                    self.operation_id, "Path is not a directory"
                )
            self._emit_progress(0, 0, "Path is not a directory", "failed")
            return

        # Emit counting status
        self._emit_progress(0, 0, "Counting files...", "counting")

        # Count total files
        total_files = 0
        for root, dirs, files in os.walk(target_folder):
            # Skip Synology recycle bin and other hidden folders
            if "#recycle" in root.lower() or "/@" in root:
                continue
            for filename in files:
                file_ext = os.path.splitext(filename)[1].lower()
                if file_ext in self.config.SUPPORTED_FORMATS and not filename.lower().endswith(".cast.m4a"):
                    total_files += 1

        if self.progress_tracker and self.operation_id:
            self.progress_tracker.start_operation(
                self.operation_id, total_files, "folder scan"
            )

        # Emit starting status with total
        self._emit_progress(
            0, total_files, f"Found {total_files} files to scan", "running"
        )

        # Walk through the target folder ONLY
        processed = 0
        for root, dirs, files in os.walk(target_folder):
            # Skip Synology recycle bin and other hidden folders
            if "#recycle" in root.lower() or "/@" in root:
                continue
            for filename in files:
                file_path = os.path.join(root, filename)
                file_ext = os.path.splitext(filename)[1].lower()

                if file_ext in self.config.SUPPORTED_FORMATS and not filename.lower().endswith(".cast.m4a"):
                    if self.progress_tracker and self.operation_id:
                        progress = self.progress_tracker.get_progress(self.operation_id)
                        if progress and progress["status"] == "cancelled":
                            print("Scan cancelled by user")
                            self._emit_progress(
                                processed, total_files, "Scan cancelled", "cancelled"
                            )
                            return

                    self.process_audio_file(file_path)
                    processed += 1

                    # Update progress (both tracker and websocket)
                    display_filename = os.path.basename(file_path)
                    if self.progress_tracker and self.operation_id:
                        self.progress_tracker.update_progress(
                            self.operation_id,
                            processed,
                            f"Scanning: {display_filename}",
                        )

                    # Emit websocket progress
                    self._emit_progress(
                        processed, total_files, f"Scanning: {display_filename}"
                    )

        print(f"\nFolder scan complete!")
        print(f"Files scanned: {self.scanned_files}")
        print(f"Artists added: {self.artists_added}")
        print(f"Albums added: {self.albums_added}")

        # Emit complete status
        self._emit_progress(
            total_files,
            total_files,
            f"Folder scan complete! Added {self.songs_added} songs",
            "complete",
        )
        print(f"Songs added: {self.songs_added}")

        if self.progress_tracker and self.operation_id:
            self.progress_tracker.complete_operation(
                self.operation_id,
                f"Folder scan complete! Added {self.songs_added} songs",
            )
        print(f"Artwork extracted: {self.artwork_extracted}")

    def extract_artwork(self, audio, album_id):
        """Extract album artwork from audio file and save it"""
        try:
            artwork_data = None

            # Try to extract artwork based on file type
            if hasattr(audio, "tags") and audio.tags:
                # MP3/ID3 tags
                if isinstance(audio.tags, ID3):
                    for tag in audio.tags.values():
                        if isinstance(tag, APIC):
                            artwork_data = tag.data
                            break

                # FLAC
                elif isinstance(audio, FLAC):
                    if audio.pictures:
                        artwork_data = audio.pictures[0].data

                # MP4/M4A
                elif isinstance(audio, MP4):
                    if "covr" in audio.tags:
                        artwork_data = bytes(audio.tags["covr"][0])

            # If we found artwork, save it
            if artwork_data:
                # Generate filename based on album_id
                artwork_filename = f"album_{album_id}.jpg"
                artwork_path = os.path.join(self.artwork_dir, artwork_filename)

                # Only save if it doesn't already exist
                if not os.path.exists(artwork_path):
                    # Convert to JPEG and save
                    try:
                        img = Image.open(io.BytesIO(artwork_data))
                        # Convert to RGB if necessary (for PNG with transparency)
                        if img.mode in ("RGBA", "LA", "P"):
                            img = img.convert("RGB")
                        # Resize to reasonable size (500x500 max)
                        img.thumbnail((500, 500), Image.Resampling.LANCZOS)
                        img.save(artwork_path, "JPEG", quality=90)
                        self.artwork_extracted += 1
                        return artwork_filename
                    except Exception as e:
                        print(f"⚠️  Error saving artwork: {e}")
                else:
                    return artwork_filename

            return None

        except Exception as e:
            print(f"⚠️  Error extracting artwork: {e}")
            return None

    def process_audio_file(self, file_path):
        """Extract metadata from audio file and add to database"""
        try:
            # Check if this file path is excluded (manually deleted)
            conn = self.db.get_connection()
            cursor = self.db.get_cursor(conn)
            cursor.execute(
                "SELECT id FROM excluded_paths WHERE file_path = %s", (file_path,)
            )
            if cursor.fetchone():
                conn.close()
                return  # Skip excluded file
            conn.close()

            audio = File(file_path)
            if audio is None:
                return

            self.scanned_files += 1

            # Extract metadata
            metadata = self.extract_metadata(audio, file_path)

            # Detect HDCD encoding (only runs on 16-bit FLAC/WAV)
            metadata["is_hdcd"] = self.detect_hdcd(file_path, audio)
            if metadata["is_hdcd"]:
                print(f"  🎵 HDCD detected: {metadata['title']}")

            # Detect Dolby Atmos / JOC (only probes E-AC-3 streams)
            metadata["is_atmos"] = self.detect_atmos(
                file_path, metadata["audio_codec"]
            )
            if metadata["is_atmos"]:
                print(f"  🌌 Atmos detected: {metadata['title']}")

            # Add to database and get album_id + whether it's a new album
            album_id, is_new_album = self.add_to_database(metadata)

            # Extract artwork if we got an album_id
            if album_id:
                artwork_filename = self.extract_artwork(audio, album_id)
                if artwork_filename:
                    # Update album with artwork path
                    self.update_album_artwork(album_id, artwork_filename)
                elif is_new_album:
                    # No embedded artwork and it's a new album - try MusicBrainz
                    artwork_filename = fetch_artwork_for_album(
                        metadata["artist"], metadata["album"], album_id
                    )
                    if artwork_filename:
                        self.update_album_artwork(album_id, artwork_filename)
                        self.artwork_extracted += 1

            print(
                f"✅ Added: {metadata['artist']} - {metadata['album']} - {metadata['title']}"
            )

        except Exception as e:
            print(f"❌ Error processing {file_path}: {str(e)}")

    def detect_hdcd(self, file_path, audio):
        """Detect HDCD encoding by running ffmpeg's hdcd filter on the first 10 seconds.
        Only runs on 16-bit FLAC/WAV files since HDCD is only encoded in 16-bit PCM."""
        ext = os.path.splitext(file_path)[1].lower()
        if ext not in ('.flac', '.wav'):
            return 0

        # HDCD only exists in 16-bit audio
        if hasattr(audio.info, 'bits_per_sample') and audio.info.bits_per_sample != 16:
            return 0

        try:
            ffmpeg_path = shutil.which("ffmpeg") or "ffmpeg"
            import eventlet
            import eventlet.tpool
            result = eventlet.tpool.execute(safe_subprocess_run,
                [ffmpeg_path, "-i", file_path, "-af", "hdcd", "-t", "10", "-f", "null", "-"],
                capture_output=True, text=True, timeout=30
            )
            # ffmpeg's hdcd filter prints detection info to stderr
            if "HDCD detected: yes" in result.stderr:
                return 1
        except Exception as e:
            print(f"  ⚠️ HDCD detection error for {file_path}: {e}")

        return 0

    def detect_atmos(self, file_path, audio_codec):
        """Detect Dolby Atmos (E-AC-3 JOC). Only probes E-AC-3 streams —
        ffprobe reports the profile as "Dolby Digital Plus + Dolby Atmos"."""
        if audio_codec != "eac3":
            return 0

        try:
            ffprobe_path = shutil.which("ffprobe") or "ffprobe"
            import eventlet
            import eventlet.tpool
            result = eventlet.tpool.execute(safe_subprocess_run,
                [ffprobe_path, "-v", "error", "-select_streams", "a:0",
                 "-show_entries", "stream=profile", "-of", "csv=p=0", file_path],
                capture_output=True, text=True, timeout=30
            )
            if "Atmos" in (result.stdout or ""):
                return 1
        except Exception as e:
            print(f"  ⚠️ Atmos detection error for {file_path}: {e}")

        return 0

    # mutagen MP4 codec ids → our codec names. Anything eac3/ac3 is a Dolby
    # bitstream the C2's eARC passes through untouched when cast.
    _MP4_CODECS = {"ec-3": "eac3", "ac-3": "ac3", "alac": "alac"}

    def detect_audio_stream_info(self, audio, file_path):
        """Channel count + codec name from mutagen (no subprocess)."""
        channels = getattr(audio.info, "channels", None) or 2
        ext = os.path.splitext(file_path)[1].lower().lstrip(".")
        codec = {"m4a": "aac", "mp4": "aac", "ogg": "vorbis", "oga": "vorbis",
                 "wave": "wav"}.get(ext, ext)
        info_codec = getattr(audio.info, "codec", "")  # MP4 only
        if info_codec:
            for prefix, name in self._MP4_CODECS.items():
                if info_codec.startswith(prefix):
                    codec = name
                    break
        return codec, int(channels)

    def extract_metadata(self, audio, file_path):
        """Extract metadata from audio file"""
        import re

        metadata = {
            "title": "Unknown Title",
            "artist": "Unknown Artist",
            "album": "Unknown Album",
            "album_artist": None,  # None = same as track artist (album grouping)
            "track_number": 0,
            "disc_number": 1,
            "year": None,
            "duration": 0,
            "file_path": file_path,
            "file_size": os.path.getsize(file_path),
            "bitrate": 0,
            "is_explicit": None,  # None=unknown, 0=clean, 1=explicit
            "is_hdcd": 0,  # 0=not HDCD, 1=HDCD detected
            "is_atmos": 0,  # 0=not Atmos, 1=E-AC-3 JOC detected
        }

        # Codec + channel count (cheap, from mutagen's stream info)
        codec, channels = self.detect_audio_stream_info(audio, file_path)
        metadata["audio_codec"] = codec
        metadata["audio_channels"] = channels

        # Get duration
        if hasattr(audio.info, "length"):
            metadata["duration"] = int(audio.info.length)

        # Get bitrate
        if hasattr(audio.info, "bitrate"):
            metadata["bitrate"] = audio.info.bitrate

            # Check for explicit content tag
            metadata["is_explicit"] = self.check_explicit_tag(audio)

        # Extract tags based on file type
        if hasattr(audio, "tags") and audio.tags:
            tags = audio.tags

            # Try different tag formats
            metadata["title"] = str(
                tags.get("TIT2", tags.get("title", [metadata["title"]])[0])
            )
            # Every value of the artist tag, not str() of the frame. A
            # multi-value ID3 TPE1 stringifies with NUL between the names
            # (NUL is stripped later, which is how "Elton JohnEric Clapton"
            # was born), and taking [0] of a Vorbis list silently dropped
            # the second artist. Joined with "; " so parse_artists() splits
            # them back into separate credits.
            _artist_frame = tags.get("TPE1")
            if _artist_frame is not None and hasattr(_artist_frame, "text"):
                _artist_vals = [str(t) for t in _artist_frame.text]
            else:
                _artist_raw = tags.get("artist", [metadata["artist"]])
                if not isinstance(_artist_raw, (list, tuple)):
                    _artist_raw = [_artist_raw]
                _artist_vals = [str(v) for v in _artist_raw]
            _artist_vals = [
                part.strip()
                for v in _artist_vals
                for part in v.split("\x00")
                if part and part.strip()
            ]
            if _artist_vals:
                metadata["artist"] = "; ".join(_artist_vals)
            metadata["album"] = str(
                tags.get("TALB", tags.get("album", [metadata["album"]])[0])
            )

            # Album artist (TPE2 / albumartist / aART). Distinct from the
            # track artist (TPE1) — drives ALBUM grouping so a compilation
            # files under "Various Artists" while each song keeps its own
            # artist. Left None when the file doesn't tag one (→ falls back to
            # the track's primary artist, the original behavior).
            for _aa_key in ("TPE2", "albumartist", "album artist",
                            "ALBUMARTIST", "aART"):
                if _aa_key in tags:
                    _aa_val = tags[_aa_key]
                    if isinstance(_aa_val, (list, tuple)):
                        _aa_val = _aa_val[0] if _aa_val else None
                    if _aa_val is not None and str(_aa_val).strip():
                        metadata["album_artist"] = str(_aa_val).strip()
                        break

            # Track number from tags
            track = tags.get("TRCK", tags.get("tracknumber", ["0"]))[0]
            if isinstance(track, str) and "/" in track:
                track = track.split("/")[0]
            try:
                metadata["track_number"] = int(track)
            except Exception:
                metadata["track_number"] = 0

            # Year
            year = tags.get("TDRC", tags.get("date", [None]))[0]
            if year:
                try:
                    metadata["year"] = int(str(year)[:4])
                except Exception:
                    pass

            # Disc number from tags
            disc = tags.get("TPOS", tags.get("discnumber", ["1"]))[0]
            if isinstance(disc, str) and "/" in disc:
                disc = disc.split("/")[0]
            try:
                metadata["disc_number"] = int(disc)
            except Exception:
                metadata["disc_number"] = 1

        # If title ended up empty or whitespace after tag extraction
        # (some bootlegs / multi-disc rips store empty TIT2 frames),
        # derive from filename instead. Common pattern is
        # "Artist - Album - NN - Title.ext" — fall back through shorter
        # patterns. Last resort: the filename stem itself. Better than
        # storing an empty string and rendering blank rows in the UI.
        if not metadata["title"] or not str(metadata["title"]).strip():
            _stem = os.path.splitext(os.path.basename(file_path))[0]
            _parts = _stem.split(" - ")
            if len(_parts) >= 4:
                metadata["title"] = " - ".join(_parts[3:]).strip()
            elif len(_parts) >= 2:
                metadata["title"] = _parts[-1].strip()
            else:
                metadata["title"] = _stem.strip() or "Unknown Title"

        # ALWAYS try to extract disc/track from filename and folder path
        # This runs even if there are no tags
        filename = os.path.basename(file_path)
        folder_path = os.path.dirname(file_path)

        disc_from_path = None
        track_from_filename = None

        # Pattern 1: Filename like "101-artist-title.flac" (Disc 1, Track 01)
        disc_track_match = re.match(r"^(\d)(\d{2})-", filename)
        if disc_track_match:
            disc_from_path = int(disc_track_match.group(1))
            track_from_filename = int(disc_track_match.group(2))

        # Pattern 2: Folder contains "Disc 1", "Disc 2", "CD1", "CD2", etc.
        folder_disc_match = re.search(
            r"(?:disc|cd|disk)\s*(\d+)", folder_path, re.IGNORECASE
        )
        if folder_disc_match:
            disc_from_path = int(folder_disc_match.group(1))

        # Pattern 3: Filename like "1-01 Track Name.flac" or "2-05 Track Name.flac"
        if not disc_from_path:
            alt_match = re.match(r"^(\d+)-(\d+)", filename)
            if alt_match:
                potential_disc = int(alt_match.group(1))
                potential_track = int(alt_match.group(2))
                # Only treat as disc if first number is small (1-9) and second is reasonable track (1-99)
                if potential_disc <= 9 and 1 <= potential_track <= 99:
                    disc_from_path = potential_disc
                    track_from_filename = potential_track

        # Pattern 4: Filename like "01 Track Name.flac" or "01. Track Name.flac"
        if not track_from_filename:
            track_match = re.match(r"^(\d{1,2})[\.\s\-_]", filename)
            if track_match:
                track_from_filename = int(track_match.group(1))

        # Apply disc number from path/filename (overrides tags if found)
        if disc_from_path:
            metadata["disc_number"] = disc_from_path

        # Apply track number from filename if tags didn't have it
        if track_from_filename and metadata["track_number"] == 0:
            metadata["track_number"] = track_from_filename

        return metadata

    def check_explicit_tag(self, audio):
        """Check if audio file has iTunes Advisory tag indicating explicit content"""
        try:
            if not hasattr(audio, "tags") or not audio.tags:
                return None

            tags = audio.tags

            # Check for iTunes Advisory tag in different formats
            # ID3 tags (MP3)
            if hasattr(tags, "get"):
                # Standard ITUNESADVISORY tag
                advisory = tags.get("ITUNESADVISORY", tags.get("itunesadvisory"))
                if advisory:
                    value = str(advisory)
                    if "1" in value:
                        return 1  # Explicit
                    elif "0" in value:
                        return 0  # Clean
                    elif "2" in value:
                        return 0  # Edited (treat as clean)

            # MP4/M4A tags
            if isinstance(audio, MP4):
                for key in tags.keys():
                    if "ITUNESADVISORY" in str(key).upper():
                        value = tags[key]
                        if hasattr(value, "__iter__") and not isinstance(value, str):
                            value = value[0] if value else None
                        if value:
                            if (
                                b"\x01" in bytes(value)
                                if isinstance(value, bytes)
                                else "1" in str(value)
                            ):
                                return 1  # Explicit
                            elif (
                                b"\x00" in bytes(value)
                                if isinstance(value, bytes)
                                else "0" in str(value)
                            ):
                                return 0  # Clean

            # Vorbis comments (FLAC, OGG)
            if isinstance(audio, FLAC):
                if "itunesadvisory" in tags:
                    value = str(tags["itunesadvisory"][0])
                    if "1" in value:
                        return 1
                    elif "0" in value:
                        return 0

            return None  # No explicit tag found

        except Exception as e:
            return None

    def normalize_for_matching(self, text):
        """Normalize text for matching - handles Unicode variations"""
        if not text:
            return text
        # Replace various dash characters with regular hyphen
        text = text.replace("‐", "-")  # Unicode hyphen
        text = text.replace("–", "-")  # En dash
        text = text.replace("—", "-")  # Em dash
        text = text.replace("−", "-")  # Minus sign
        # Replace smart quotes with regular quotes
        text = text.replace(""", "'").replace(""", "'")
        text = text.replace('"', '"').replace('"', '"')
        # Collapse the ʻokina / modifier-letter apostrophes (U+02BB, U+02BC)
        # to a straight apostrophe so Hawaiian names like "Kamakawiwoʻole"
        # match their straight-apostrophe variants — without this they scan as
        # two separate artists (the ʻokina is a Unicode letter, so generic
        # punctuation handling leaves it intact).
        text = text.replace("ʻ", "'").replace("ʼ", "'")
        return text.strip()

    def _resolve_one_artist(self, cursor, artist_name):
        """Find an artist by exact then normalized name, else create it
        (storing a best-effort MBID). Returns (artist_id, created_bool).

        Factored out of the track-artist loop so the album artist (e.g.
        "Various Artists") resolves through the exact same matching.
        """
        cursor.execute(
            "SELECT id, name FROM artists WHERE name = %s", (artist_name,)
        )
        artist_row = cursor.fetchone()

        if not artist_row:
            normalized_name = self.normalize_for_matching(artist_name)
            cursor.execute("SELECT id, name FROM artists")
            for existing in cursor.fetchall():
                if self.normalize_for_matching(existing["name"]) == normalized_name:
                    artist_row = existing
                    print(
                        f"  ↳ Matched '{artist_name}' to existing '{existing['name']}'"
                    )
                    break

        if artist_row:
            return artist_row["id"], False

        cursor.execute(
            "INSERT INTO artists (name) VALUES (%s) RETURNING id", (artist_name,)
        )
        new_artist_id = cursor.fetchone()["id"]
        mbid = lookup_artist_mbid(artist_name)
        if mbid:
            cursor.execute(
                "UPDATE artists SET mbid = %s WHERE id = %s",
                (mbid, new_artist_id),
            )
        # New artist: get a picture in the background (never blocks the scan).
        try:
            from app.artist_image_downloader import fetch_artist_image_async
            fetch_artist_image_async(new_artist_id, artist_name)
        except Exception as e:
            print(f"  ⚠️  artist image fetch not started: {e}")
        return new_artist_id, True

    def add_to_database(self, metadata):
        """Add song metadata to database and return album_id"""
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)
        album_id = None

        try:
            # Parse the artist string into individual artists (TRACK artists)
            # — unless it is ONE act whose name merely contains a separator.
            # parse_artists() splits on "&" and ",", which is right for
            # "Elton John & Eric Clapton" and wrong for "Joan Jett & The
            # Blackhearts" (filed under "Joan Jett" with "The Blackhearts"
            # as a guest on 63 songs, 2025-12) or "Earth, Wind & Fire". Two
            # signals say "one act": the album-artist tag is the very same
            # string (a band's own album; a duet on someone's album differs),
            # or the library already knows an artist by that exact name.
            _full_artist = (metadata["artist"] or "").strip()
            _album_artist_tag = (metadata.get("album_artist") or "").strip()
            _one_act = False
            if _full_artist:
                if _album_artist_tag and _album_artist_tag.lower() == _full_artist.lower():
                    _one_act = True
                else:
                    cursor.execute(
                        "SELECT 1 FROM artists WHERE LOWER(name) = LOWER(%s) LIMIT 1",
                        (_full_artist,),
                    )
                    _one_act = cursor.fetchone() is not None
            artist_names = [_full_artist] if _one_act else parse_artists(metadata["artist"])
            primary_artist_name = artist_names[0]  # First artist is primary

            # Get or create all track artists and collect their IDs
            artist_ids = []
            for artist_name in artist_names:
                aid, created = self._resolve_one_artist(cursor, artist_name)
                artist_ids.append(aid)
                if created:
                    self.artists_added += 1

            # Primary TRACK artist (first in list) — the song's foreign key, so
            # the song shows under its real artist even on a compilation.
            primary_artist_id = artist_ids[0]

            # ALBUM artist — drives album grouping. When the file tags a
            # distinct album artist (e.g. "Various Artists" on a comp), the
            # album files under THAT, while the song stays under its track
            # artist above. No album-artist tag → fall back to the track
            # primary (the original behavior, so normal albums are unchanged).
            album_artist_name = (metadata.get("album_artist") or "").strip()
            if album_artist_name:
                album_artist_id, created = self._resolve_one_artist(
                    cursor, album_artist_name
                )
                if created:
                    self.artists_added += 1
            else:
                album_artist_id = primary_artist_id

            # Get or create album (associated with the ALBUM artist).
            # Use case-insensitive matching to prevent duplicates
            cursor.execute(
                "SELECT id FROM albums WHERE LOWER(title) = LOWER(%s) AND artist_id = %s",
                (metadata["album"], album_artist_id),
            )
            album_row = cursor.fetchone()

            is_new_album = False
            if album_row:
                album_id = album_row["id"]
            else:
                # Try to insert, but handle race condition where another process
                # might have created the album between our SELECT and INSERT
                try:
                    cursor.execute(
                        "INSERT INTO albums (title, artist_id, year) VALUES (%s, %s, %s) RETURNING id",
                        (metadata["album"], album_artist_id, metadata["year"]),
                    )
                    album_id = cursor.fetchone()["id"]
                    self.albums_added += 1
                    is_new_album = True
                except psycopg2.IntegrityError:
                    # Album was created by another process, fetch it
                    cursor.execute(
                        "SELECT id FROM albums WHERE LOWER(title) = LOWER(%s) AND artist_id = %s",
                        (metadata["album"], album_artist_id),
                    )
                    album_row = cursor.fetchone()
                    if album_row:
                        album_id = album_row["id"]
                    else:
                        raise  # Re-raise if it's a different integrity error

            # Add song (with primary artist as the foreign key for backward compatibility)
            cursor.execute(
                """INSERT INTO songs
                (title, artist_id, album_id, track_number, disc_number, duration, file_path, file_size, bitrate, is_explicit, is_hdcd, audio_codec, audio_channels, is_atmos)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) RETURNING id""",
                (
                    metadata["title"],
                    primary_artist_id,
                    album_id,
                    metadata["track_number"],
                    metadata["disc_number"],
                    metadata["duration"],
                    metadata["file_path"],
                    metadata["file_size"],
                    metadata["bitrate"],
                    metadata["is_explicit"],
                    metadata["is_hdcd"],
                    metadata.get("audio_codec"),
                    metadata.get("audio_channels"),
                    metadata.get("is_atmos", 0),
                ),
            )
            song_id = cursor.fetchone()["id"]
            self.songs_added += 1

            # Add entries to song_artists junction table
            for position, artist_id in enumerate(artist_ids, start=1):
                cursor.execute(
                    """INSERT INTO song_artists (song_id, artist_id, position)
                       VALUES (%s, %s, %s)
                       ON CONFLICT DO NOTHING""",
                    (song_id, artist_id, position),
                )

            # Update counts for ALL track artists on this song
            for artist_id in artist_ids:
                cursor.execute(
                    "UPDATE artists SET song_count = song_count + 1, album_count = (SELECT COUNT(DISTINCT id) FROM albums WHERE artist_id = %s) WHERE id = %s",
                    (artist_id, artist_id),
                )

            # If the album artist is someone else (e.g. "Various Artists" on a
            # compilation), refresh just their album_count — the song isn't
            # "by" them, so their song_count stays put.
            if album_artist_id not in artist_ids:
                cursor.execute(
                    "UPDATE artists SET album_count = (SELECT COUNT(DISTINCT id) FROM albums WHERE artist_id = %s) WHERE id = %s",
                    (album_artist_id, album_artist_id),
                )

            cursor.execute(
                "UPDATE albums SET song_count = song_count + 1 WHERE id = %s",
                (album_id,),
            )

            conn.commit()
            return album_id, is_new_album

        except psycopg2.IntegrityError:
            # Song already exists (duplicate file path)
            return None, False
        except Exception as e:
            print(f"❌ Database error: {str(e)}")
            conn.rollback()
            return None, False
        finally:
            conn.close()

    def update_album_artwork(self, album_id, artwork_filename):
        """Update album with artwork path"""
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        try:
            cursor.execute(
                "UPDATE albums SET artwork_path = %s WHERE id = %s",
                (artwork_filename, album_id),
            )
            conn.commit()
        except Exception as e:
            print(f"❌ Error updating artwork: {str(e)}")
        finally:
            conn.close()
