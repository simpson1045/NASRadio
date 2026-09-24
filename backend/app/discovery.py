"""
Spotify Discovery Service

Uses Spotify's recommendation engine to discover new music,
with 30-second preview playback support.
"""

import spotipy
from spotipy.oauth2 import SpotifyClientCredentials
from app.config import Config
import psycopg2
import psycopg2.extras
import random


class SpotifyDiscovery:
    """Discover new music using Spotify's recommendation engine"""

    def __init__(self, db_url=None):
        self.config = Config()
        self.db_url = db_url or self.config.DATABASE_URL

        # Initialize Spotify client
        auth_manager = SpotifyClientCredentials(
            client_id=self.config.SPOTIFY_CLIENT_ID,
            client_secret=self.config.SPOTIFY_CLIENT_SECRET,
        )
        self.sp = spotipy.Spotify(auth_manager=auth_manager)

    def _get_db_connection(self):
        """Get database connection"""
        conn = psycopg2.connect(self.db_url)
        return conn

    def _get_cursor(self, conn):
        """Get cursor with dict factory"""
        return conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    def get_seed_artists_from_library(self, limit=5):
        """
        Get top artists from local library based on play count.
        Returns Spotify artist IDs for seeding recommendations.
        """
        conn = self._get_db_connection()
        cursor = self._get_cursor(conn)

        # Get most played artists from local library
        cursor.execute(
            """
            SELECT a.name, SUM(s.play_count) as total_plays
            FROM artists a
            JOIN songs s ON s.artist_id = a.id
            WHERE s.play_count > 0
            GROUP BY a.id, a.name
            ORDER BY total_plays DESC
            LIMIT %s
        """,
            (limit * 2,),
        )  # Get extra in case some aren't on Spotify

        top_artists = cursor.fetchall()
        conn.close()

        # Search Spotify for these artists to get their IDs
        spotify_artists = []
        for artist in top_artists:
            if len(spotify_artists) >= limit:
                break
            try:
                results = self.sp.search(
                    q=f'artist:"{artist["name"]}"', type="artist", limit=1
                )
                if results["artists"]["items"]:
                    spotify_artist = results["artists"]["items"][0]
                    spotify_artists.append(
                        {
                            "id": spotify_artist["id"],
                            "name": spotify_artist["name"],
                            "local_name": artist["name"],
                            "plays": artist["total_plays"],
                        }
                    )
            except Exception as e:
                print(f"Error searching for artist {artist['name']}: {e}")
                continue

        return spotify_artists

    def get_seed_tracks_from_library(self, limit=5):
        """
        Get top tracks from local library based on play count.
        Returns Spotify track IDs for seeding recommendations.
        """
        conn = self._get_db_connection()
        cursor = self._get_cursor(conn)

        # Get most played songs from local library
        cursor.execute(
            """
            SELECT s.title, a.name as artist_name, s.play_count
            FROM songs s
            JOIN artists a ON s.artist_id = a.id
            WHERE s.play_count > 0
            ORDER BY s.play_count DESC
            LIMIT %s
        """,
            (limit * 2,),
        )  # Get extra in case some aren't on Spotify

        top_tracks = cursor.fetchall()
        conn.close()

        # Search Spotify for these tracks to get their IDs
        spotify_tracks = []
        for track in top_tracks:
            if len(spotify_tracks) >= limit:
                break
            try:
                query = f'track:"{track["title"]}" artist:"{track["artist_name"]}"'
                results = self.sp.search(q=query, type="track", limit=1)
                if results["tracks"]["items"]:
                    spotify_track = results["tracks"]["items"][0]
                    spotify_tracks.append(
                        {
                            "id": spotify_track["id"],
                            "name": spotify_track["name"],
                            "artist": spotify_track["artists"][0]["name"],
                            "local_title": track["title"],
                            "plays": track["play_count"],
                        }
                    )
            except Exception as e:
                print(f"Error searching for track {track['title']}: {e}")
                continue

        return spotify_tracks

    def get_local_artist_names(self):
        """Get set of all artist names in local library for filtering"""
        conn = self._get_db_connection()
        cursor = self._get_cursor(conn)
        cursor.execute("SELECT LOWER(name) FROM artists")
        artists = {row[0] for row in cursor.fetchall()}
        conn.close()
        return artists

    def get_local_album_keys(self):
        """Get set of (artist, album) tuples in local library for filtering"""
        conn = self._get_db_connection()
        cursor = self._get_cursor(conn)
        cursor.execute(
            """
            SELECT LOWER(ar.name), LOWER(al.title)
            FROM albums al
            JOIN artists ar ON al.artist_id = ar.id
        """
        )
        albums = {(row[0], row[1]) for row in cursor.fetchall()}
        conn.close()
        return albums

    def get_recommendations(
        self,
        seed_artists=None,
        seed_tracks=None,
        seed_genres=None,
        limit=20,
        filter_owned=True,
    ):
        """
        Get recommendations from Spotify.

        Args:
            seed_artists: List of Spotify artist IDs (max 5 total seeds)
            seed_tracks: List of Spotify track IDs (max 5 total seeds)
            seed_genres: List of genre strings (max 5 total seeds)
            limit: Number of recommendations to return
            filter_owned: If True, filter out artists/albums you already own

        Returns:
            List of recommended tracks with preview URLs
        """
        # If no seeds provided, get from library
        if not seed_artists and not seed_tracks and not seed_genres:
            # Mix of artists and tracks for variety
            library_artists = self.get_seed_artists_from_library(limit=3)
            library_tracks = self.get_seed_tracks_from_library(limit=2)

            seed_artists = [a["id"] for a in library_artists]
            seed_tracks = [t["id"] for t in library_tracks]

        # Spotify allows max 5 seeds total
        total_seeds = (
            len(seed_artists or []) + len(seed_tracks or []) + len(seed_genres or [])
        )
        if total_seeds > 5:
            print(f"Warning: Too many seeds ({total_seeds}), truncating to 5")
            # Prioritize: artists, then tracks, then genres
            if seed_artists and len(seed_artists) > 3:
                seed_artists = seed_artists[:3]
            if seed_tracks and len(seed_tracks) > 2:
                seed_tracks = seed_tracks[:2]
            seed_genres = None

        if total_seeds == 0:
            return {"success": False, "error": "No seeds available for recommendations"}

        try:
            results = self.sp.recommendations(
                seed_artists=seed_artists or None,
                seed_tracks=seed_tracks or None,
                seed_genres=seed_genres or None,
                limit=limit * 2 if filter_owned else limit,  # Get extra for filtering
            )
        except Exception as e:
            return {"success": False, "error": f"Spotify API error: {str(e)}"}

        # Get local library info for filtering
        local_artists = self.get_local_artist_names() if filter_owned else set()
        local_albums = self.get_local_album_keys() if filter_owned else set()

        recommendations = []
        for track in results["tracks"]:
            artist_name = track["artists"][0]["name"]
            album_name = track["album"]["name"]

            # Filter out tracks from artists/albums you already own
            if filter_owned:
                if artist_name.lower() in local_artists:
                    continue
                if (artist_name.lower(), album_name.lower()) in local_albums:
                    continue

            # Get album artwork (prefer large)
            artwork_url = None
            if track["album"]["images"]:
                artwork_url = track["album"]["images"][0]["url"]

            recommendations.append(
                {
                    "track_id": track["id"],
                    "track_name": track["name"],
                    "artist_id": track["artists"][0]["id"],
                    "artist_name": artist_name,
                    "album_id": track["album"]["id"],
                    "album_name": album_name,
                    "duration_ms": track["duration_ms"],
                    "preview_url": track["preview_url"],  # 30-sec MP3 preview!
                    "spotify_url": track["external_urls"].get("spotify"),
                    "artwork_url": artwork_url,
                    "release_date": track["album"].get("release_date"),
                    "popularity": track["popularity"],
                }
            )

            if len(recommendations) >= limit:
                break

        return {
            "success": True,
            "count": len(recommendations),
            "recommendations": recommendations,
            "seeds_used": {
                "artists": seed_artists,
                "tracks": seed_tracks,
                "genres": seed_genres,
            },
        }

    def get_similar_artists(self, artist_name=None, spotify_artist_id=None, limit=10):
        """
        Get artists similar to a given artist.

        Args:
            artist_name: Name of artist to find similar to (will search Spotify)
            spotify_artist_id: Direct Spotify artist ID
            limit: Number of similar artists to return
        """
        # Get Spotify artist ID if not provided
        if not spotify_artist_id and artist_name:
            try:
                results = self.sp.search(
                    q=f'artist:"{artist_name}"', type="artist", limit=1
                )
                if results["artists"]["items"]:
                    spotify_artist_id = results["artists"]["items"][0]["id"]
                else:
                    return {
                        "success": False,
                        "error": f"Artist not found: {artist_name}",
                    }
            except Exception as e:
                return {"success": False, "error": f"Search error: {str(e)}"}

        if not spotify_artist_id:
            return {"success": False, "error": "No artist specified"}

        try:
            results = self.sp.artist_related_artists(spotify_artist_id)
        except Exception as e:
            return {"success": False, "error": f"Spotify API error: {str(e)}"}

        # Get local artists for filtering
        local_artists = self.get_local_artist_names()

        similar = []
        for artist in results["artists"][:limit]:
            # Check if we already have this artist
            in_library = artist["name"].lower() in local_artists

            # Get artist image
            image_url = None
            if artist["images"]:
                image_url = artist["images"][0]["url"]

            similar.append(
                {
                    "artist_id": artist["id"],
                    "artist_name": artist["name"],
                    "genres": artist["genres"][:3],  # Top 3 genres
                    "popularity": artist["popularity"],
                    "image_url": image_url,
                    "spotify_url": artist["external_urls"].get("spotify"),
                    "in_library": in_library,
                }
            )

        return {
            "success": True,
            "count": len(similar),
            "similar_artists": similar,
        }

    def get_artist_top_tracks(
        self, artist_name=None, spotify_artist_id=None, market="US"
    ):
        """
        Get top tracks for an artist (with preview URLs).
        Useful for previewing an artist before adding to Lidarr.
        """
        # Get Spotify artist ID if not provided
        if not spotify_artist_id and artist_name:
            try:
                results = self.sp.search(
                    q=f'artist:"{artist_name}"', type="artist", limit=1
                )
                if results["artists"]["items"]:
                    spotify_artist_id = results["artists"]["items"][0]["id"]
                else:
                    return {
                        "success": False,
                        "error": f"Artist not found: {artist_name}",
                    }
            except Exception as e:
                return {"success": False, "error": f"Search error: {str(e)}"}

        if not spotify_artist_id:
            return {"success": False, "error": "No artist specified"}

        try:
            results = self.sp.artist_top_tracks(spotify_artist_id, country=market)
        except Exception as e:
            return {"success": False, "error": f"Spotify API error: {str(e)}"}

        tracks = []
        for track in results["tracks"]:
            artwork_url = None
            if track["album"]["images"]:
                artwork_url = track["album"]["images"][0]["url"]

            tracks.append(
                {
                    "track_id": track["id"],
                    "track_name": track["name"],
                    "album_name": track["album"]["name"],
                    "album_id": track["album"]["id"],
                    "duration_ms": track["duration_ms"],
                    "preview_url": track["preview_url"],
                    "artwork_url": artwork_url,
                    "popularity": track["popularity"],
                }
            )

        return {
            "success": True,
            "count": len(tracks),
            "tracks": tracks,
        }

    def search_spotify(self, query, search_type="track", limit=20):
        """
        Search Spotify for tracks, artists, or albums.
        Useful for finding specific content to preview.
        """
        try:
            results = self.sp.search(q=query, type=search_type, limit=limit)
        except Exception as e:
            return {"success": False, "error": f"Search error: {str(e)}"}

        items = []

        if search_type == "track":
            for track in results["tracks"]["items"]:
                artwork_url = None
                if track["album"]["images"]:
                    artwork_url = track["album"]["images"][0]["url"]

                items.append(
                    {
                        "track_id": track["id"],
                        "track_name": track["name"],
                        "artist_name": track["artists"][0]["name"],
                        "artist_id": track["artists"][0]["id"],
                        "album_name": track["album"]["name"],
                        "album_id": track["album"]["id"],
                        "duration_ms": track["duration_ms"],
                        "preview_url": track["preview_url"],
                        "artwork_url": artwork_url,
                        "popularity": track["popularity"],
                    }
                )

        elif search_type == "artist":
            local_artists = self.get_local_artist_names()
            for artist in results["artists"]["items"]:
                image_url = None
                if artist["images"]:
                    image_url = artist["images"][0]["url"]

                items.append(
                    {
                        "artist_id": artist["id"],
                        "artist_name": artist["name"],
                        "genres": artist["genres"][:3],
                        "popularity": artist["popularity"],
                        "image_url": image_url,
                        "in_library": artist["name"].lower() in local_artists,
                    }
                )

        elif search_type == "album":
            local_albums = self.get_local_album_keys()
            for album in results["albums"]["items"]:
                artwork_url = None
                if album["images"]:
                    artwork_url = album["images"][0]["url"]

                artist_name = (
                    album["artists"][0]["name"] if album["artists"] else "Unknown"
                )
                in_library = (
                    artist_name.lower(),
                    album["name"].lower(),
                ) in local_albums

                items.append(
                    {
                        "album_id": album["id"],
                        "album_name": album["name"],
                        "artist_name": artist_name,
                        "artist_id": (
                            album["artists"][0]["id"] if album["artists"] else None
                        ),
                        "release_date": album.get("release_date"),
                        "total_tracks": album.get("total_tracks"),
                        "artwork_url": artwork_url,
                        "in_library": in_library,
                    }
                )

        return {
            "success": True,
            "count": len(items),
            "results": items,
            "query": query,
            "type": search_type,
        }

    def get_available_genre_seeds(self):
        """Get list of available genre seeds from Spotify"""
        try:
            results = self.sp.recommendation_genre_seeds()
            return {
                "success": True,
                "genres": results["genres"],
            }
        except Exception as e:
            return {"success": False, "error": str(e)}
