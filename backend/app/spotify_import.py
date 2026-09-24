import spotipy
from spotipy.oauth2 import SpotifyClientCredentials
from app.config import Config
from app.playlist_import_base import (
    BasePlaylistImporter,
    cancel_import,
    reset_cancel_flag,
    is_import_cancelled,
)

# Re-exported for backwards compatibility — routes.py imports cancel_import
# (and historically the others) from this module.
__all__ = [
    "SpotifyImporter",
    "cancel_import",
    "reset_cancel_flag",
    "is_import_cancelled",
]


class SpotifyImporter(BasePlaylistImporter):
    """Import playlists from Spotify"""

    def __init__(self):
        super().__init__()

        # Initialize Spotify client
        auth_manager = SpotifyClientCredentials(
            client_id=self.config.SPOTIFY_CLIENT_ID,
            client_secret=self.config.SPOTIFY_CLIENT_SECRET,
        )
        self.sp = spotipy.Spotify(auth_manager=auth_manager)

    def extract_playlist_id(self, url_or_uri):
        """Extract playlist ID from Spotify URL or URI"""
        # Handle different formats:
        # - https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M
        # - spotify:playlist:37i9dQZF1DXcBWIGoYBM5M
        # - 37i9dQZF1DXcBWIGoYBM5M (just the ID)

        url_or_uri = url_or_uri.strip()

        if "open.spotify.com/playlist/" in url_or_uri:
            # Extract from URL
            playlist_id = url_or_uri.split("playlist/")[-1].split("?")[0]
        elif "spotify:playlist:" in url_or_uri:
            # Extract from URI
            playlist_id = url_or_uri.split("spotify:playlist:")[-1]
        else:
            # Assume it's just the ID
            playlist_id = url_or_uri

        return playlist_id

    def get_playlist_info(self, playlist_id):
        """Get basic playlist information"""
        try:
            playlist = self.sp.playlist(
                playlist_id, fields="name,description,tracks.total"
            )
            return {
                "name": playlist["name"],
                "description": playlist["description"] or "",
                "total_tracks": playlist["tracks"]["total"],
            }
        except Exception as e:
            raise Exception(f"Failed to fetch playlist info: {str(e)}")

    def get_playlist_tracks(self, playlist_id):
        """Get all tracks from a Spotify playlist"""
        try:
            tracks = []
            results = self.sp.playlist_tracks(playlist_id)

            while results:
                for item in results["items"]:
                    track = item["track"]
                    if track:  # Sometimes tracks can be None
                        tracks.append(
                            {
                                "spotify_id": track["id"],  # NEW - Spotify track ID
                                "name": track["name"],
                                "artists": [
                                    artist["name"] for artist in track["artists"]
                                ],
                                "album": track["album"]["name"],
                                "duration_ms": track["duration_ms"],
                            }
                        )

                # Check if there are more tracks
                if results["next"]:
                    results = self.sp.next(results)
                else:
                    break

            return tracks
        except Exception as e:
            raise Exception(f"Failed to fetch playlist tracks: {str(e)}")

    def import_playlist(
        self,
        playlist_url,
        create_local_playlist=True,
        user_id=None,
        existing_playlist_id=None,
        skip_existing=False,
    ):
        """Import a Spotify playlist and match songs with local library"""
        print(f"🎵 Starting Spotify import from: {playlist_url}")

        try:
            # Extract playlist ID
            playlist_id = self.extract_playlist_id(playlist_url)
            print(f"📋 Extracted playlist ID: {playlist_id}")

            # Get playlist info
            playlist_info = self.get_playlist_info(playlist_id)
            print(f"📝 Playlist: {playlist_info['name']}")
            print(f"📊 Total tracks: {playlist_info['total_tracks']}")

            # Get all tracks
            print(f"📥 Fetching tracks from Spotify...")
            spotify_tracks = self.get_playlist_tracks(playlist_id)
            print(f"✅ Fetched {len(spotify_tracks)} tracks")

            # Normalize into the shared track shape
            tracks = [
                {
                    "source_id": t["spotify_id"],
                    "name": t["name"],
                    "artists": t["artists"],
                    "album": t["album"],
                }
                for t in spotify_tracks
            ]

            return self.process_tracks(
                tracks,
                playlist_name=playlist_info["name"],
                display_description=playlist_info["description"],
                store_description=f"Imported from Spotify: {playlist_info['description']}",
                create_local_playlist=create_local_playlist,
                user_id=user_id,
                existing_playlist_id=existing_playlist_id,
                skip_existing=skip_existing,
                progress_event="spotify_import_progress",
                do_mbid_lookup=True,
            )

        except Exception as e:
            print(f"❌ Import failed: {str(e)}")
            return {"success": False, "error": str(e)}
