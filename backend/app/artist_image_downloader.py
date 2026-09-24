import os
import time
import requests
from PIL import Image
from io import BytesIO
from app.models import Database
from app.config import Config
from app.extensions import socketio, safe_emit


class ArtistImageDownloader:
    """Download artist images from Last.fm"""

    def __init__(self, db, progress_tracker=None, operation_id=None):
        self.db = db
        self.config = Config()
        self.images_dir = "artist_images"
        self.images_downloaded = 0
        self.images_failed = 0
        self.progress_tracker = progress_tracker
        self.operation_id = operation_id

        # Create artist images directory if it doesn't exist
        if not os.path.exists(self.images_dir):
            os.makedirs(self.images_dir)

        # API headers
        self.headers = {
            "User-Agent": "NASRadio/1.0 (https://github.com/yourusername/nasradio)"
        }

        # Fanart.TV API key (FANART_API_KEY in .env)
        self.fanart_api_key = Config.FANART_API_KEY

    def _emit_progress(self, current, total, message, status="running"):
        """Emit websocket progress event"""
        if self.operation_id:
            safe_emit(
                "artist_images_progress",
                {
                    "operation_id": self.operation_id,
                    "current": current,
                    "total": total,
                    "message": message,
                    "status": status,
                    "downloaded": self.images_downloaded,
                    "failed": self.images_failed,
                },
            )

    def download_all_images(self):
        """Download images for all artists in database"""
        print("🎤 Starting artist image download...")

        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        # Get all artists that don't have images yet
        cursor.execute(
            """
            SELECT id, name
            FROM artists
            WHERE image_path IS NULL OR image_path = ''
        """
        )

        artists = cursor.fetchall()
        total_artists = len(artists)

        print(f"📊 Found {total_artists} artists without images")

        if self.progress_tracker and self.operation_id:
            self.progress_tracker.start_operation(
                self.operation_id, total_artists, "artist image download"
            )

        # Emit initial status
        self._emit_progress(
            0, total_artists, f"Found {total_artists} artists to process", "running"
        )

        for idx, artist in enumerate(artists, 1):
            artist_id = artist["id"]
            artist_name = artist["name"]

            print(f"[{idx}/{total_artists}] Processing: {artist_name}")

            # Check if cancelled
            if self.progress_tracker and self.operation_id:
                progress = self.progress_tracker.get_progress(self.operation_id)
                if progress and progress["status"] == "cancelled":
                    print("⏹️ Artist image download cancelled by user")
                    self._emit_progress(
                        idx, total_artists, "Cancelled by user", "cancelled"
                    )
                    conn.close()
                    return

            # Download artist image
            image_path = self.download_artist_image(artist_id, artist_name)

            if image_path:
                self.images_downloaded += 1
            else:
                self.images_failed += 1

            # Update progress
            if self.progress_tracker and self.operation_id:
                self.progress_tracker.update_progress(
                    self.operation_id, idx, f"Processing: {artist_name}"
                )

            # Emit websocket progress
            self._emit_progress(idx, total_artists, f"Processing: {artist_name}")

            # Rate limiting
            time.sleep(0.5)

        if self.progress_tracker and self.operation_id:
            self.progress_tracker.complete_operation(
                self.operation_id,
                f"Artist image download complete! Downloaded {self.images_downloaded} images",
            )

        # Emit complete status
        self._emit_progress(
            total_artists,
            total_artists,
            f"Complete! Downloaded {self.images_downloaded}, failed {self.images_failed}",
            "complete",
        )

        conn.close()

        print(f"\n✅ Artist image download complete!")
        print(f"🖼️  Downloaded: {self.images_downloaded}")
        print(f"❌ Failed: {self.images_failed}")

    def download_artist_image(self, artist_id, artist_name):
        """Download image for a specific artist from Spotify (primary) or Fanart.tv (fallback)"""
        try:
            # Step 1: Check DB for stored MBID first, fall back to MusicBrainz search
            mbid = None
            conn = self.db.get_connection()
            cursor = self.db.get_cursor(conn)
            cursor.execute("SELECT mbid FROM artists WHERE id = %s", (artist_id,))
            row = cursor.fetchone()
            conn.close()

            if row and row.get("mbid"):
                mbid = row["mbid"]
                print(f"  ✓ Using stored MBID: {mbid}")
            else:
                # Fall back to MusicBrainz name search
                mb_url = "https://musicbrainz.org/ws/2/artist/"
                params = {"query": f"artist:{artist_name}", "fmt": "json", "limit": 1}

                response = requests.get(
                    mb_url, params=params, headers=self.headers, timeout=25
                )

                if response.status_code != 200:
                    print(f"  ⚠️  MusicBrainz search failed")
                    return None

                data = response.json()

                if not data.get("artists") or len(data["artists"]) == 0:
                    print(f"  ⚠️  Artist not found on MusicBrainz")
                    return None

                top = data["artists"][0]
                mbid = top["id"]
                print(f"  ✓ Found MBID via search: {mbid}")

                # Persist a confident match so we never re-run this search for
                # the artist again (this lookup used to be discarded, which is
                # why artwork refreshes were slow and most artists had no mbid).
                def _key(x):
                    x = (x or "").lower()
                    for ch in "ʻʼ‘’'.,&":
                        x = x.replace(ch, "")
                    return " ".join(x.split())

                if _key(top.get("name")) == _key(artist_name) or int(top.get("score", 0)) >= 95:
                    try:
                        wconn = self.db.get_connection()
                        wcur = self.db.get_cursor(wconn)
                        wcur.execute(
                            "UPDATE artists SET mbid = %s "
                            "WHERE id = %s AND (mbid IS NULL OR mbid = '')",
                            (mbid, artist_id),
                        )
                        wconn.commit()
                        wconn.close()
                    except Exception as _e:
                        print(f"  ⚠️  could not store MBID: {_e}")

            # Step 2: Try Spotify first (most accurate artist matching)
            self.last_source = None
            image_url = self._get_spotify_image(mbid, artist_name)
            if image_url:
                self.last_source = f"spotify:{getattr(self, 'last_spotify_id', '')}"

            # Step 3: Fall back to Fanart.tv
            if not image_url:
                time.sleep(0.5)
                image_url = self._get_fanart_image(mbid)
                if image_url:
                    self.last_source = f"fanart:{image_url}"

            if not image_url:
                print(f"  ⚠️  No artist image found from any source")
                return None

            # Download the image
            response = requests.get(image_url, headers=self.headers, timeout=10)

            if response.status_code != 200:
                print(f"  ⚠️  Image download failed")
                return None

            # Process and save the image
            return self.process_and_save_image(response.content, artist_id)

        except Exception as e:
            print(f"  ⚠️  Error: {e}")
            return None

    def _get_spotify_image(self, mbid, artist_name):
        """Get artist image from Spotify via MBID → Spotify ID lookup"""
        try:
            from app.discovery import SpotifyDiscovery

            spotify_artist_id = None

            # Try MBID → Spotify ID via MusicBrainz URL relationships
            if mbid:
                try:
                    mb_url = f"https://musicbrainz.org/ws/2/artist/{mbid}?inc=url-rels&fmt=json"
                    mb_resp = requests.get(mb_url, headers=self.headers, timeout=25)
                    if mb_resp.status_code == 200:
                        mb_data = mb_resp.json()
                        for rel in mb_data.get("relations", []):
                            if rel.get("type") in ("streaming music", "free streaming"):
                                url = rel.get("url", {}).get("resource", "")
                                if "open.spotify.com/artist/" in url:
                                    spotify_artist_id = url.split("/artist/")[-1].split(
                                        "?"
                                    )[0]
                                    print(
                                        f"  ✓ Spotify ID via MBID: {spotify_artist_id}"
                                    )
                                    break
                except Exception as e:
                    print(f"  ⚠️  MBID→Spotify lookup failed: {e}")

            # Fallback to name search (exact match only)
            if not spotify_artist_id:
                try:
                    discovery = SpotifyDiscovery()
                    results = discovery.sp.search(
                        q=f'artist:"{artist_name}"', type="artist", limit=5
                    )
                    for sp_artist in results.get("artists", {}).get("items", []):
                        if sp_artist["name"].lower() == artist_name.lower():
                            spotify_artist_id = sp_artist["id"]
                            print(f"  ✓ Spotify ID via name match: {spotify_artist_id}")
                            break
                except Exception as e:
                    print(f"  ⚠️  Spotify name search failed: {e}")

            if not spotify_artist_id:
                print(f"  ⚠️  No Spotify artist ID found")
                return None

            # Get artist images
            discovery = SpotifyDiscovery()
            self.last_spotify_id = spotify_artist_id
            sp_artist = discovery.sp.artist(spotify_artist_id)
            images = sp_artist.get("images", [])
            if images:
                # Pick the largest image
                image_url = images[0]["url"]
                print(f"  ✓ Got Spotify image: {image_url}")
                return image_url

            print(f"  ⚠️  Spotify artist has no images")
            return None

        except Exception as e:
            print(f"  ⚠️  Spotify image lookup failed: {e}")
            return None

    def _get_fanart_image(self, mbid):
        """Get artist image from Fanart.tv (fallback)"""
        try:
            fanart_url = f"https://webservice.fanart.tv/v3/music/{mbid}"
            fanart_headers = {"api-key": self.fanart_api_key}

            response = requests.get(fanart_url, headers=fanart_headers, timeout=10)

            if response.status_code != 200:
                print(f"  ⚠️  No Fanart.tv data available")
                return None

            fanart_data = response.json()

            if "artistthumb" in fanart_data and len(fanart_data["artistthumb"]) > 0:
                url = fanart_data["artistthumb"][0]["url"]
                print(f"  ✓ Got Fanart.tv thumbnail: {url}")
                return url
            elif (
                "artistbackground" in fanart_data
                and len(fanart_data["artistbackground"]) > 0
            ):
                url = fanart_data["artistbackground"][0]["url"]
                print(f"  ✓ Got Fanart.tv background: {url}")
                return url

            print(f"  ⚠️  No Fanart.tv images found")
            return None

        except Exception as e:
            print(f"  ⚠️  Fanart.tv lookup failed: {e}")
            return None

    def process_and_save_image(self, image_data, artist_id):
        """Process and save artist image"""
        try:
            image_filename = f"artist_{artist_id}.jpg"
            image_path = os.path.join(self.images_dir, image_filename)

            # Load image
            img = Image.open(BytesIO(image_data))

            # Convert to RGB if necessary
            if img.mode in ("RGBA", "LA", "P"):
                img = img.convert("RGB")

            # Resize to high quality (1200x1200 max — matches album artwork resolution)
            img.thumbnail((1200, 1200), Image.Resampling.LANCZOS)
            img.save(image_path, "JPEG", quality=92)

            # Update database
            self.update_artist_image(artist_id, image_filename)

            print(f"  ✅ Image saved")
            return image_filename

        except Exception as e:
            print(f"  ⚠️  Error saving image: {e}")
            return None

    def update_artist_image(self, artist_id, image_filename):
        """Update artist with image path"""
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        try:
            cursor.execute(
                "UPDATE artists SET image_path = %s, image_source = %s WHERE id = %s",
                (image_filename, getattr(self, "last_source", None), artist_id),
            )
            conn.commit()
        except Exception as e:
            print(f"  ❌ Database error: {e}")
        finally:
            conn.close()


# ---------------------------------------------------------------------------
# Fire-and-forget fetch for a freshly created artist (scanner / YouTube /
# RSS importers). Imports used to create artists with a name only, so every
# new artist sat blank until someone pressed the download button.
# ---------------------------------------------------------------------------
_bg_db = None


def _bg_database():
    global _bg_db
    if _bg_db is None:
        _bg_db = Database(Config().DATABASE_URL)
    return _bg_db


def fetch_artist_image_async(artist_id, artist_name):
    import threading

    def _go():
        try:
            ArtistImageDownloader(_bg_database()).download_artist_image(artist_id, artist_name)
        except Exception as e:
            print(f"  ⚠️  Background artist image fetch failed for {artist_name}: {e}")

    t = threading.Thread(target=_go, daemon=True)
    t.start()
