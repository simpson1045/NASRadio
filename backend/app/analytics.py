from datetime import datetime
from app.models import Database
from app.config import Config


class Analytics:
    """Handle all analytics tracking operations"""

    def __init__(self):
        self.config = Config()
        self.db = Database(self.config.DATABASE_URL)

    def track_play_start(self, song_id):
        """Track when a song starts playing"""
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        try:
            # Get song details to update artist and album
            cursor.execute(
                "SELECT artist_id, album_id FROM songs WHERE id = %s", (song_id,)
            )
            song = cursor.fetchone()

            if song:
                now = datetime.now().isoformat()

                # Update last_played for song, album, and artist
                cursor.execute(
                    "UPDATE songs SET last_played = %s WHERE id = %s", (now, song_id)
                )
                cursor.execute(
                    "UPDATE albums SET last_played = %s WHERE id = %s",
                    (now, song["album_id"]),
                )
                cursor.execute(
                    "UPDATE artists SET last_played = %s WHERE id = %s",
                    (now, song["artist_id"]),
                )

                # Create play_history entry
                cursor.execute(
                    "INSERT INTO play_history (song_id, played_at) VALUES (%s, %s)",
                    (song_id, now),
                )

                conn.commit()
                return {"success": True, "message": "Play tracked"}

            return {"success": False, "message": "Song not found"}

        except Exception as e:
            conn.rollback()
            return {"success": False, "message": str(e)}
        finally:
            conn.close()

    def track_play_complete(self, song_id, completion_percentage):
        """Track when a song completes (or gets to a certain %)"""
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        try:
            # Get the most recent play_history entry for this song
            cursor.execute(
                """SELECT id FROM play_history 
                   WHERE song_id = %s 
                   ORDER BY played_at DESC 
                   LIMIT 1""",
                (song_id,),
            )
            history = cursor.fetchone()

            if history:
                # Update the play_history entry with completion data
                completed = (
                    1 if completion_percentage >= 80 else 0
                )  # Consider 80%+ as "completed"
                cursor.execute(
                    """UPDATE play_history 
                       SET completed = %s, completion_percentage = %s 
                       WHERE id = %s""",
                    (completed, completion_percentage, history["id"]),
                )

                # Increment play_count if completed
                if completed:
                    cursor.execute(
                        "UPDATE songs SET play_count = play_count + 1 WHERE id = %s",
                        (song_id,),
                    )

                conn.commit()
                return {"success": True, "message": "Completion tracked"}

            return {"success": False, "message": "No play history found"}

        except Exception as e:
            conn.rollback()
            return {"success": False, "message": str(e)}
        finally:
            conn.close()

    def track_skip(self, song_id):
        """Track when a song is skipped"""
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        try:
            # Increment skip_count
            cursor.execute(
                "UPDATE songs SET skip_count = skip_count + 1 WHERE id = %s", (song_id,)
            )

            conn.commit()
            return {"success": True, "message": "Skip tracked"}

        except Exception as e:
            conn.rollback()
            return {"success": False, "message": str(e)}
        finally:
            conn.close()

    def get_recently_played(self, limit=50):
        """Get recently played music songs.

        Filters to source_type='local' — Continue Listening for podcasts
        is served by /api/rss/recently-played-episodes instead.
        """
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        try:
            cursor.execute(
                """
                SELECT DISTINCT songs.*,
                       artists.name as artist_name,
                       albums.title as album_title,
                       songs.last_played,
                       sa.loudness, sa.integrated_loudness_lufs, sa.true_peak_dbfs
                FROM songs
                JOIN artists ON songs.artist_id = artists.id
                JOIN albums ON songs.album_id = albums.id
                LEFT JOIN song_analysis sa ON songs.id = sa.song_id
                WHERE songs.last_played IS NOT NULL
                  AND songs.source_type = 'local'
                ORDER BY songs.last_played DESC
                LIMIT %s
            """,
                (limit,),
            )

            songs = [dict(row) for row in cursor.fetchall()]
            return songs

        finally:
            conn.close()

    def get_most_played(self, limit=50):
        """Get most played music songs.

        Podcast episodes track play_count via the same mechanism but
        they belong on the podcast side of the app, not in the music
        home's Most Played carousel. Filter to source_type='local'.
        """
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        try:
            cursor.execute(
                """
                SELECT songs.*,
                       artists.name as artist_name,
                       albums.title as album_title,
                       songs.play_count,
                       sa.loudness, sa.integrated_loudness_lufs, sa.true_peak_dbfs
                FROM songs
                JOIN artists ON songs.artist_id = artists.id
                JOIN albums ON songs.album_id = albums.id
                LEFT JOIN song_analysis sa ON songs.id = sa.song_id
                WHERE songs.play_count > 0
                  AND songs.source_type = 'local'
                ORDER BY songs.play_count DESC
                LIMIT %s
            """,
                (limit,),
            )

            songs = [dict(row) for row in cursor.fetchall()]
            return songs

        finally:
            conn.close()

    def get_analytics_stats(self):
        """Get overall analytics statistics"""
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        try:
            # Total plays
            cursor.execute("SELECT COUNT(*) as total FROM play_history")
            total_plays = cursor.fetchone()["total"]

            # Total completed plays
            cursor.execute(
                "SELECT COUNT(*) as total FROM play_history WHERE completed = 1"
            )
            completed_plays = cursor.fetchone()["total"]

            # Most played song — music only.
            cursor.execute(
                """
                SELECT songs.title, artists.name as artist_name, songs.play_count
                FROM songs
                JOIN artists ON songs.artist_id = artists.id
                WHERE songs.play_count > 0
                  AND songs.source_type = 'local'
                ORDER BY songs.play_count DESC
                LIMIT 1
            """
            )
            most_played_song = cursor.fetchone()

            # Most played artist — music only. Podcast play counts
            # would otherwise drown out real artists for heavy podcast
            # listeners.
            cursor.execute(
                """
                SELECT artists.name, SUM(songs.play_count) as total_plays
                FROM artists
                JOIN songs ON songs.artist_id = artists.id
                WHERE songs.source_type = 'local'
                GROUP BY artists.id, artists.name
                ORDER BY total_plays DESC
                LIMIT 1
            """
            )
            most_played_artist = cursor.fetchone()

            return {
                "total_plays": total_plays,
                "completed_plays": completed_plays,
                "completion_rate": (
                    (completed_plays / total_plays * 100) if total_plays > 0 else 0
                ),
                "most_played_song": (
                    dict(most_played_song) if most_played_song else None
                ),
                "most_played_artist": (
                    dict(most_played_artist) if most_played_artist else None
                ),
            }

        finally:
            conn.close()
