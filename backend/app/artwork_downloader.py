import os
import time
import requests
from PIL import Image
from io import BytesIO
from app.models import Database
from app.config import Config
from app.extensions import socketio, safe_emit
import shutil


class ArtworkDownloader:
    """Download artwork from multiple sources with fallback"""

    def __init__(self, db, progress_tracker=None, operation_id=None):
        self.db = db
        self.config = Config()
        self.artwork_dir = self.config.ARTWORK_FOLDER
        self.artwork_downloaded = 0
        self.artwork_failed = 0
        self.from_folder = 0
        self.from_musicbrainz = 0
        self.from_lastfm = 0
        self.progress_tracker = progress_tracker
        self.operation_id = operation_id

        # Create artwork directory if it doesn't exist
        if not os.path.exists(self.artwork_dir):
            os.makedirs(self.artwork_dir)

        # API headers
        self.headers = {
            "User-Agent": "NASRadio/1.0 (https://github.com/yourusername/nasradio)"
        }

        # Last.fm API key (public, read-only; LASTFM_API_KEY in .env)
        self.lastfm_api_key = Config.LASTFM_API_KEY

    def _emit_progress(self, current, total, message, status="running"):
        """Emit websocket progress event"""
        if self.operation_id:
            safe_emit(
                "artwork_progress",
                {
                    "operation_id": self.operation_id,
                    "current": current,
                    "total": total,
                    "message": message,
                    "status": status,
                    "downloaded": self.artwork_downloaded,
                    "failed": self.artwork_failed,
                },
            )

    def download_all_artwork(self):
        """Download artwork for all albums in database"""
        print("🎨 Starting artwork download...")

        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        # Get all albums that aren't verified (rescan even if they have artwork)
        cursor.execute(
            """
            SELECT albums.id, albums.title, artists.name as artist_name, songs.file_path
            FROM albums
            JOIN artists ON albums.artist_id = artists.id
            LEFT JOIN songs ON songs.album_id = albums.id
            WHERE (albums.artwork_verified IS NULL OR albums.artwork_verified = 0)
            GROUP BY albums.id, albums.title, artists.name, songs.file_path
        """
        )

        albums = cursor.fetchall()
        total_albums = len(albums)

        print(f"📊 Found {total_albums} albums without artwork")

        if self.progress_tracker and self.operation_id:
            self.progress_tracker.start_operation(
                self.operation_id, total_albums, "artwork download"
            )

        # Emit initial status
        self._emit_progress(
            0, total_albums, f"Found {total_albums} albums to process", "running"
        )

        for idx, album in enumerate(albums, 1):
            album_id = album["id"]
            album_title = album["title"]
            artist_name = album["artist_name"]
            sample_file = album["file_path"]

            print(f"[{idx}/{total_albums}] Processing: {artist_name} - {album_title}")

            # Check if cancelled
            if self.progress_tracker and self.operation_id:
                progress = self.progress_tracker.get_progress(self.operation_id)
                if progress and progress["status"] == "cancelled":
                    print("⏹️ Artwork download cancelled by user")
                    self._emit_progress(
                        idx, total_albums, "Cancelled by user", "cancelled"
                    )
                    conn.close()
                    return

            # Try multiple sources
            artwork_path = self.get_artwork(
                album_id, artist_name, album_title, sample_file
            )

            if artwork_path:
                self.artwork_downloaded += 1
            else:
                self.artwork_failed += 1

            # Update progress
            if self.progress_tracker and self.operation_id:
                self.progress_tracker.update_progress(
                    self.operation_id, idx, f"Processing: {artist_name} - {album_title}"
                )

            # Emit websocket progress
            self._emit_progress(
                idx, total_albums, f"Processing: {artist_name} - {album_title}"
            )

        if self.progress_tracker and self.operation_id:
            self.progress_tracker.complete_operation(
                self.operation_id,
                f"Artwork download complete! Downloaded {self.artwork_downloaded} images",
            )

        # Emit complete status
        self._emit_progress(
            total_albums,
            total_albums,
            f"Complete! Downloaded {self.artwork_downloaded}, failed {self.artwork_failed}",
            "complete",
        )

        conn.close()

        print(f"\n✅ Artwork download complete!")
        print(f"🖼️  Total downloaded: {self.artwork_downloaded}")
        print(f"📁 From folder: {self.from_folder}")
        print(f"🎵 From MusicBrainz: {self.from_musicbrainz}")
        print(f"🎧 From Last.fm: {self.from_lastfm}")
        print(f"❌ Failed: {self.artwork_failed}")

    def get_artwork(self, album_id, artist_name, album_title, sample_file):
        """Try multiple sources to get artwork"""

        # Method 1: Check album folder for artwork files
        artwork = self.get_folder_artwork(album_id, sample_file)
        if artwork:
            self.from_folder += 1
            print(f"  ✅ Found folder artwork")
            return artwork

        # Method 2: Try MusicBrainz
        artwork = self.get_musicbrainz_artwork(album_id, artist_name, album_title)
        if artwork:
            self.from_musicbrainz += 1
            print(f"  ✅ Downloaded from MusicBrainz")
            return artwork

        # Small delay before Last.fm
        time.sleep(0.5)

        # Method 3: Try Last.fm
        artwork = self.get_lastfm_artwork(album_id, artist_name, album_title)
        if artwork:
            self.from_lastfm += 1
            print(f"  ✅ Downloaded from Last.fm")
            return artwork

        print(f"  ❌ No artwork found from any source")
        return None

    def get_folder_artwork(self, album_id, sample_file):
        """Look for artwork files in the album folder"""
        try:
            if not sample_file:
                return None

            # Get the directory containing the music file
            album_dir = os.path.dirname(sample_file)

            # Check for common artwork filenames
            for artwork_name in self.config.ARTWORK_FORMATS:
                artwork_file = os.path.join(album_dir, artwork_name)

                if os.path.exists(artwork_file):
                    # Copy and resize the artwork
                    return self.process_and_save_artwork(
                        artwork_file, album_id, is_file=True
                    )

            return None

        except Exception as e:
            print(f"  ⚠️  Error checking folder: {e}")
            return None

    def get_musicbrainz_artwork(self, album_id, artist_name, album_title):
        """Download artwork from MusicBrainz Cover Art Archive with confidence check"""
        try:
            # Search MusicBrainz for the release
            search_url = "https://musicbrainz.org/ws/2/release/"
            params = {
                "query": f'artist:"{artist_name}" AND release:"{album_title}"',
                "fmt": "json",
                "limit": 5,
            }

            response = requests.get(
                search_url, params=params, headers=self.headers, timeout=25
            )

            if response.status_code != 200:
                return None

            data = response.json()

            if not data.get("releases") or len(data["releases"]) == 0:
                return None

            # Score every confident match, then rank them the way the
            # manual picker does (routes.search_artwork): digital first,
            # US first, Europe next, then confidence. The old code took
            # the single best text match, which was usually the original
            # vinyl pressing and its scanned, ring-worn cover.
            candidates = []
            for release in data["releases"]:
                release_id = release.get("id")
                release_title = release.get("title", "")
                artist_credit = release.get("artist-credit", [])
                result_artist = artist_credit[0].get("name", "") if artist_credit else ""
                confidence = self.calculate_confidence(
                    artist_name, album_title, result_artist, release_title
                )
                if confidence < 80:
                    continue
                media = release.get("media") or []
                fmt = " ".join((m.get("format") or "") for m in media).lower()
                country = (release.get("country") or "").upper()
                candidates.append((
                    1 if "digital" in fmt else 0,
                    1 if country == "US" else 0,
                    1 if country == "XE" else 0,
                    confidence,
                    release_id,
                ))
            if not candidates:
                print("  ⚠️  No confident match (80+), skipping auto-download")
                return None
            candidates.sort(reverse=True)
            # Cover Art Archive doesn't have every release; walk the top few.
            for _d, _us, _xe, _conf, release_id in candidates[:4]:
                cover_art_url = f"https://coverartarchive.org/release/{release_id}/front"
                time.sleep(0.5)
                response = requests.get(cover_art_url, headers=self.headers, timeout=25)
                if response.status_code == 200 and response.content:
                    return self.process_and_save_artwork(response.content, album_id)
            return None

        except Exception as e:
            return None

    def calculate_confidence(
        self, search_artist, search_album, result_artist, result_album
    ):
        """Calculate confidence score based on name matching"""
        score = 0

        # Normalize strings for comparison
        search_artist_lower = search_artist.lower().strip()
        search_album_lower = search_album.lower().strip()
        result_artist_lower = result_artist.lower().strip()
        result_album_lower = result_album.lower().strip()

        # Exact artist match = 50 points
        if search_artist_lower == result_artist_lower:
            score += 50
        # Partial artist match (one contains the other)
        elif (
            search_artist_lower in result_artist_lower
            or result_artist_lower in search_artist_lower
        ):
            score += 25

        # Exact album match = 50 points
        if search_album_lower == result_album_lower:
            score += 50
        # Partial album match
        elif (
            search_album_lower in result_album_lower
            or result_album_lower in search_album_lower
        ):
            score += 25

        return score

    def get_lastfm_artwork(self, album_id, artist_name, album_title):
        """Download artwork from Last.fm API"""
        try:
            # Last.fm album.getInfo API
            url = "http://ws.audioscrobbler.com/2.0/"
            params = {
                "method": "album.getinfo",
                "api_key": self.lastfm_api_key,
                "artist": artist_name,
                "album": album_title,
                "format": "json",
            }

            response = requests.get(
                url, params=params, headers=self.headers, timeout=25
            )

            if response.status_code != 200:
                return None

            data = response.json()

            if "album" not in data or "image" not in data["album"]:
                return None

            # Get the largest image
            images = data["album"]["image"]
            artwork_url = None

            for img in reversed(images):  # Last.fm lists from smallest to largest
                if img["size"] in ["extralarge", "large", "mega"]:
                    artwork_url = img["#text"]
                    break

            if not artwork_url:
                return None

            # Download the image
            response = requests.get(artwork_url, headers=self.headers, timeout=25)

            if response.status_code != 200:
                return None

            # Process and save the artwork
            return self.process_and_save_artwork(response.content, album_id)

        except Exception as e:
            return None

    def process_and_save_artwork(self, source, album_id, is_file=False):
        """Process and save artwork from either file path or bytes"""
        try:
            artwork_filename = f"album_{album_id}.jpg"
            artwork_path = os.path.join(self.artwork_dir, artwork_filename)

            if is_file:
                # Source is a file path, open it
                img = Image.open(source)
            else:
                # Source is bytes, load from BytesIO
                img = Image.open(BytesIO(source))

            # Convert to RGB if necessary
            if img.mode in ("RGBA", "LA", "P"):
                img = img.convert("RGB")

            # Resize to high-res (1200x1200 max)
            img.thumbnail((1200, 1200), Image.Resampling.LANCZOS)
            img.save(artwork_path, "JPEG", quality=92)

            # Update database
            self.update_album_artwork(album_id, artwork_filename)

            return artwork_filename

        except Exception as e:
            print(f"  ⚠️  Error saving artwork: {e}")
            return None

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
            print(f"  ❌ Database error: {e}")
        finally:
            conn.close()
