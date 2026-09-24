from datetime import datetime
from app.models import Database
from app.config import Config
from app import auth


class Favorites:
    """Handle all favorites operations"""

    def __init__(self):
        self.config = Config()
        self.db = Database(self.config.DATABASE_URL)

    def add_favorite(self, item_type, item_id, user_id=None):
        """Add an item to favorites"""
        user_id = auth.current_user_id() if user_id is None else user_id
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        try:
            cursor.execute(
                """INSERT INTO favorites (user_id, item_type, item_id) 
                   VALUES (%s, %s, %s)""",
                (user_id, item_type, item_id),
            )
            conn.commit()
            return {"success": True, "message": "Added to favorites"}
        except Exception as e:
            conn.rollback()
            # If it's a duplicate, that's fine
            if "UNIQUE constraint" in str(e):
                return {"success": True, "message": "Already in favorites"}
            return {"success": False, "message": str(e)}
        finally:
            conn.close()

    def remove_favorite(self, item_type, item_id, user_id=None):
        """Remove an item from favorites"""
        user_id = auth.current_user_id() if user_id is None else user_id
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        try:
            cursor.execute(
                """DELETE FROM favorites 
                   WHERE user_id = %s AND item_type = %s AND item_id = %s""",
                (user_id, item_type, item_id),
            )
            conn.commit()
            return {"success": True, "message": "Removed from favorites"}
        except Exception as e:
            conn.rollback()
            return {"success": False, "message": str(e)}
        finally:
            conn.close()

    def is_favorite(self, item_type, item_id, user_id=None):
        """Check if an item is favorited"""
        user_id = auth.current_user_id() if user_id is None else user_id
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        try:
            cursor.execute(
                """SELECT COUNT(*) as count FROM favorites 
                   WHERE user_id = %s AND item_type = %s AND item_id = %s""",
                (user_id, item_type, item_id),
            )
            result = cursor.fetchone()
            return result["count"] > 0
        finally:
            conn.close()

    def get_favorite_songs(self, user_id=None):
        """Get all favorite songs"""
        user_id = auth.current_user_id() if user_id is None else user_id
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        try:
            cursor.execute(
                """
                SELECT songs.*,
                       artists.name as artist_name,
                       albums.title as album_title,
                       favorites.created_at as favorited_at,
                       sa.loudness, sa.integrated_loudness_lufs, sa.true_peak_dbfs
                FROM favorites
                JOIN songs ON favorites.item_id = songs.id
                JOIN artists ON songs.artist_id = artists.id
                JOIN albums ON songs.album_id = albums.id
                LEFT JOIN song_analysis sa ON songs.id = sa.song_id
                WHERE favorites.user_id = %s AND favorites.item_type = 'song'
                ORDER BY favorites.created_at DESC
            """,
                (user_id,),
            )
            songs = [dict(row) for row in cursor.fetchall()]
            return songs
        finally:
            conn.close()

    def get_favorite_albums(self, user_id=None):
        """Get all favorite albums"""
        user_id = auth.current_user_id() if user_id is None else user_id
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        try:
            cursor.execute(
                """
                SELECT albums.*, 
                       artists.name as artist_name,
                       favorites.created_at as favorited_at
                FROM favorites
                JOIN albums ON favorites.item_id = albums.id
                JOIN artists ON albums.artist_id = artists.id
                WHERE favorites.user_id = %s AND favorites.item_type = 'album'
                ORDER BY favorites.created_at DESC
            """,
                (user_id,),
            )
            albums = [dict(row) for row in cursor.fetchall()]
            return albums
        finally:
            conn.close()

    def get_favorite_artists(self, user_id=None):
        """Get all favorite artists"""
        user_id = auth.current_user_id() if user_id is None else user_id
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        try:
            cursor.execute(
                """
                SELECT artists.*,
                       favorites.created_at as favorited_at
                FROM favorites
                JOIN artists ON favorites.item_id = artists.id
                WHERE favorites.user_id = %s AND favorites.item_type = 'artist'
                ORDER BY favorites.created_at DESC
            """,
                (user_id,),
            )
            artists = [dict(row) for row in cursor.fetchall()]
            return artists
        finally:
            conn.close()

    def get_favorite_stations(self, user_id=None):
        """Get all favorite stations (live internet radio)"""
        user_id = auth.current_user_id() if user_id is None else user_id
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        try:
            cursor.execute(
                """
                SELECT stations.*,
                       favorites.created_at as favorited_at
                FROM favorites
                JOIN stations ON favorites.item_id = stations.id
                WHERE favorites.user_id = %s AND favorites.item_type = 'station'
                ORDER BY favorites.created_at DESC
            """,
                (user_id,),
            )
            stations = [dict(row) for row in cursor.fetchall()]
            return stations
        finally:
            conn.close()

    def get_favorites_count(self, user_id=None):
        """Get count of favorites by type"""
        user_id = auth.current_user_id() if user_id is None else user_id
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        try:
            cursor.execute(
                """
                SELECT item_type, COUNT(*) as count
                FROM favorites
                WHERE user_id = %s
                GROUP BY item_type
            """,
                (user_id,),
            )
            results = cursor.fetchall()
            counts = {"songs": 0, "albums": 0, "artists": 0, "stations": 0}
            for row in results:
                counts[row["item_type"] + "s"] = row["count"]
            return counts
        finally:
            conn.close()
