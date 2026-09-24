from datetime import datetime
from app.models import Database
from app.config import Config
from app import auth


class Playlists:
    """Handle all playlist operations"""

    def __init__(self):
        self.config = Config()
        self.db = Database(self.config.DATABASE_URL)

    def _owns(self, cursor, playlist_id, user_id=None):
        """True if the playlist belongs to the (current) user. Used to gate
        mutations so one user can't edit another's playlist by id."""
        uid = auth.current_user_id() if user_id is None else user_id
        cursor.execute("SELECT user_id FROM playlists WHERE id = %s", (playlist_id,))
        row = cursor.fetchone()
        return bool(row) and row["user_id"] == uid

    def create_playlist(self, name, description=None, user_id=None):
        """Create a new playlist"""
        user_id = auth.current_user_id() if user_id is None else user_id
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        try:
            cursor.execute(
                "INSERT INTO playlists (name, description, user_id) VALUES (%s, %s, %s) RETURNING id",
                (name, description, user_id),
            )
            playlist_id = cursor.fetchone()["id"]
            conn.commit()

            return {
                "success": True,
                "message": "Playlist created",
                "playlist_id": playlist_id,
            }
        except Exception as e:
            conn.rollback()
            return {"success": False, "message": str(e)}
        finally:
            conn.close()

    def get_playlists(self, user_id=None):
        """Get all playlists for a user"""
        user_id = auth.current_user_id() if user_id is None else user_id
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)
        try:
            cursor.execute(
                """
                SELECT p.id, p.name, p.description,
                       COUNT(ps.song_id) as song_count,
                       COALESCE(SUM(s.duration), 0) as total_duration,
                       p.created_at, p.updated_at, p.last_played_at, p.pinned,
                       p.source,
                       (SELECT a.id FROM playlist_songs ps2
                        JOIN songs s2 ON ps2.song_id = s2.id 
                        JOIN albums a ON s2.album_id = a.id 
                        WHERE ps2.playlist_id = p.id AND a.artwork_path IS NOT NULL
                        ORDER BY ps2.position LIMIT 1) as first_album_id
                FROM playlists p
                LEFT JOIN playlist_songs ps ON p.id = ps.playlist_id
                LEFT JOIN songs s ON ps.song_id = s.id
                WHERE p.user_id = %s
                GROUP BY p.id, p.name, p.description, p.created_at, p.updated_at, p.last_played_at, p.pinned, p.source
                ORDER BY p.updated_at DESC
                """,
                (user_id,),
            )
            playlists = [dict(row) for row in cursor.fetchall()]
            return playlists
        finally:
            conn.close()

    def get_playlist(self, playlist_id, user_id=None):
        """Get a single playlist with all its songs (only if owned by the user)"""
        user_id = auth.current_user_id() if user_id is None else user_id
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        try:
            # Get playlist info
            cursor.execute(
                """
                SELECT id, name, description, song_count, total_duration,
                       created_at, updated_at
                FROM playlists
                WHERE id = %s AND user_id = %s
                """,
                (playlist_id, user_id),
            )
            playlist = cursor.fetchone()

            if not playlist:
                return None

            playlist = dict(playlist)

            # Get all songs in playlist (available songs with full info)
            cursor.execute(
                """
                SELECT songs.id, songs.title, songs.artist_id, songs.album_id,
                       songs.track_number, songs.disc_number, songs.duration,
                       songs.file_path, songs.file_size, songs.bitrate, songs.is_explicit,
                       artists.name as artist_name, albums.title as album_title,
                       playlist_songs.position, playlist_songs.added_at,
                       playlist_songs.spotify_track_id, playlist_songs.spotify_track_name,
                       playlist_songs.spotify_artist, playlist_songs.spotify_album,
                       playlist_songs.mbid,
                       sa.loudness, sa.integrated_loudness_lufs, sa.true_peak_dbfs,
                       1 as available
                FROM playlist_songs
                JOIN songs ON playlist_songs.song_id = songs.id
                JOIN artists ON songs.artist_id = artists.id
                JOIN albums ON songs.album_id = albums.id
                LEFT JOIN song_analysis sa ON songs.id = sa.song_id
                WHERE playlist_songs.playlist_id = %s
                ORDER BY playlist_songs.position
                """,
                (playlist_id,),
            )
            available_songs = [dict(row) for row in cursor.fetchall()]

            # Get unavailable songs (song_id is NULL)
            cursor.execute(
                """
                SELECT playlist_songs.id, playlist_songs.position, playlist_songs.added_at,
                       playlist_songs.spotify_track_id, playlist_songs.spotify_track_name,
                       playlist_songs.spotify_artist, playlist_songs.spotify_album,
                       playlist_songs.mbid,
                       0 as available
                FROM playlist_songs
                WHERE playlist_songs.playlist_id = %s
                AND playlist_songs.song_id IS NULL
                ORDER BY playlist_songs.position
                """,
                (playlist_id,),
            )
            unavailable_songs = [dict(row) for row in cursor.fetchall()]

            # Combine and sort by position
            songs = available_songs + unavailable_songs
            songs.sort(key=lambda x: x["position"])

            # Add all artists for each available song
            for song in songs:
                if song.get("available") == 1 and song.get("id"):
                    cursor.execute(
                        """
                        SELECT artists.id, artists.name 
                        FROM song_artists 
                        JOIN artists ON song_artists.artist_id = artists.id 
                        WHERE song_artists.song_id = %s
                        ORDER BY song_artists.position
                        """,
                        (song["id"],),
                    )
                    artist_list = [
                        {"id": row["id"], "name": row["name"]}
                        for row in cursor.fetchall()
                    ]
                    song["artists"] = (
                        artist_list
                        if artist_list
                        else [{"id": song["artist_id"], "name": song["artist_name"]}]
                    )

            playlist["songs"] = songs

            # Generate artwork if it doesn't exist
            import os

            playlist_artwork_path = f"playlist_artwork/playlist_{playlist_id}.jpg"
            if not os.path.exists(playlist_artwork_path):
                self.generate_playlist_artwork(playlist_id)

            playlist["artwork_path"] = (
                playlist_artwork_path if os.path.exists(playlist_artwork_path) else None
            )

            return playlist

        finally:
            conn.close()

    def update_playlist(self, playlist_id, name=None, description=None):
        """Update playlist name and/or description"""
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        try:
            updates = []
            params = []

            if name is not None:
                updates.append("name = %s")
                params.append(name)

            if description is not None:
                updates.append("description = %s")
                params.append(description)

            if not updates:
                return {"success": False, "message": "No fields to update"}

            updates.append("updated_at = %s")
            params.append(datetime.now().isoformat())
            params.append(playlist_id)
            params.append(auth.current_user_id())

            cursor.execute(
                f"UPDATE playlists SET {', '.join(updates)} WHERE id = %s AND user_id = %s",
                params,
            )
            conn.commit()

            return {"success": True, "message": "Playlist updated"}
        except Exception as e:
            conn.rollback()
            return {"success": False, "message": str(e)}
        finally:
            conn.close()

    def delete_playlist(self, playlist_id):
        """Delete a playlist"""
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        try:
            cursor.execute(
                "DELETE FROM playlists WHERE id = %s AND user_id = %s",
                (playlist_id, auth.current_user_id()),
            )
            conn.commit()

            return {"success": True, "message": "Playlist deleted"}
        except Exception as e:
            conn.rollback()
            return {"success": False, "message": str(e)}
        finally:
            conn.close()

    def add_song(self, playlist_id, song_id, position=None):
        """Add a song to a playlist at a specific position (or end if not specified)"""
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        try:
            if not self._owns(cursor, playlist_id):
                return {"success": False, "message": "Playlist not found"}
            # Check if song already in playlist
            cursor.execute(
                "SELECT id FROM playlist_songs WHERE playlist_id = %s AND song_id = %s",
                (playlist_id, song_id),
            )
            if cursor.fetchone():
                return {"success": False, "message": "Song already in playlist"}

            if position is not None:
                # Insert at specific position - shift existing songs down
                cursor.execute(
                    """
                    UPDATE playlist_songs 
                    SET position = position + 1 
                    WHERE playlist_id = %s AND position >= %s
                    """,
                    (playlist_id, position),
                )
                next_position = position
            else:
                # Get next position (end of playlist)
                cursor.execute(
                    "SELECT MAX(position) as max_pos FROM playlist_songs WHERE playlist_id = %s",
                    (playlist_id,),
                )
                max_pos = cursor.fetchone()["max_pos"] or 0
                next_position = max_pos + 1

            # Get song duration
            cursor.execute("SELECT duration FROM songs WHERE id = %s", (song_id,))
            song = cursor.fetchone()
            if not song:
                return {"success": False, "message": "Song not found"}

            # Add song to playlist
            cursor.execute(
                "INSERT INTO playlist_songs (playlist_id, song_id, position) VALUES (%s, %s, %s)",
                (playlist_id, song_id, next_position),
            )

            # Update playlist counts
            cursor.execute(
                """
                UPDATE playlists 
                SET song_count = song_count + 1,
                    total_duration = total_duration + %s,
                    updated_at = %s
                WHERE id = %s
                """,
                (song["duration"], datetime.now().isoformat(), playlist_id),
            )

            conn.commit()
            return {"success": True, "message": "Song added to playlist"}

        except Exception as e:
            conn.rollback()
            return {"success": False, "message": str(e)}
        finally:
            conn.close()

    def remove_song(self, playlist_id, song_id):
        """Remove a song from a playlist"""
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        try:
            if not self._owns(cursor, playlist_id):
                return {"success": False, "message": "Playlist not found"}
            # Get song duration before removing
            cursor.execute(
                """
                SELECT songs.duration, playlist_songs.position
                FROM playlist_songs
                JOIN songs ON playlist_songs.song_id = songs.id
                WHERE playlist_songs.playlist_id = %s AND playlist_songs.song_id = %s
                """,
                (playlist_id, song_id),
            )
            song = cursor.fetchone()

            if not song:
                return {"success": False, "message": "Song not in playlist"}

            removed_position = song["position"]

            # Remove song
            cursor.execute(
                "DELETE FROM playlist_songs WHERE playlist_id = %s AND song_id = %s",
                (playlist_id, song_id),
            )

            # Update positions of remaining songs
            cursor.execute(
                """
                UPDATE playlist_songs 
                SET position = position - 1 
                WHERE playlist_id = %s AND position > %s
                """,
                (playlist_id, removed_position),
            )

            # Update playlist counts
            cursor.execute(
                """
                UPDATE playlists 
                SET song_count = song_count - 1,
                    total_duration = total_duration - %s,
                    updated_at = %s
                WHERE id = %s
                """,
                (song["duration"], datetime.now().isoformat(), playlist_id),
            )

            conn.commit()
            return {"success": True, "message": "Song removed from playlist"}

        except Exception as e:
            conn.rollback()
            return {"success": False, "message": str(e)}
        finally:
            conn.close()

    def reorder_songs(self, playlist_id, song_id, new_position):
        """Reorder a song within a playlist"""
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        try:
            if not self._owns(cursor, playlist_id):
                return {"success": False, "message": "Playlist not found"}
            # Get current position
            cursor.execute(
                "SELECT position FROM playlist_songs WHERE playlist_id = %s AND song_id = %s",
                (playlist_id, song_id),
            )
            result = cursor.fetchone()

            if not result:
                return {"success": False, "message": "Song not in playlist"}

            old_position = result["position"]

            if old_position == new_position:
                return {"success": True, "message": "No change needed"}

            if new_position < old_position:
                # Moving up - shift others down
                cursor.execute(
                    """
                    UPDATE playlist_songs 
                    SET position = position + 1 
                    WHERE playlist_id = %s AND position >= %s AND position < %s
                    """,
                    (playlist_id, new_position, old_position),
                )
            else:
                # Moving down - shift others up
                cursor.execute(
                    """
                    UPDATE playlist_songs 
                    SET position = position - 1 
                    WHERE playlist_id = %s AND position > %s AND position <= %s
                    """,
                    (playlist_id, old_position, new_position),
                )

            # Update the moved song's position
            cursor.execute(
                "UPDATE playlist_songs SET position = %s WHERE playlist_id = %s AND song_id = %s",
                (new_position, playlist_id, song_id),
            )

            # Update playlist timestamp
            cursor.execute(
                "UPDATE playlists SET updated_at = %s WHERE id = %s",
                (datetime.now().isoformat(), playlist_id),
            )

            conn.commit()
            return {"success": True, "message": "Song reordered"}

        except Exception as e:
            conn.rollback()
            return {"success": False, "message": str(e)}
        finally:
            conn.close()

    def add_songs(self, playlist_id, song_ids, position=None):
        """Add multiple songs to a playlist at once"""
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        try:
            if not self._owns(cursor, playlist_id):
                return {"success": False, "message": "Playlist not found"}
            # Get current max position
            cursor.execute(
                "SELECT MAX(position) as max_pos FROM playlist_songs WHERE playlist_id = %s",
                (playlist_id,),
            )
            max_pos = cursor.fetchone()["max_pos"] or 0

            if position is not None:
                # Insert at specific position - shift existing songs down
                cursor.execute(
                    """
                    UPDATE playlist_songs 
                    SET position = position + %s 
                    WHERE playlist_id = %s AND position >= %s
                    """,
                    (len(song_ids), playlist_id, position),
                )
                next_position = position
            else:
                next_position = max_pos + 1

            added_count = 0
            skipped_count = 0
            total_duration = 0

            for song_id in song_ids:
                # Check if song already in playlist
                cursor.execute(
                    "SELECT id FROM playlist_songs WHERE playlist_id = %s AND song_id = %s",
                    (playlist_id, song_id),
                )
                if cursor.fetchone():
                    skipped_count += 1
                    continue

                # Get song duration
                cursor.execute("SELECT duration FROM songs WHERE id = %s", (song_id,))
                song = cursor.fetchone()
                if not song:
                    skipped_count += 1
                    continue

                # Add song to playlist
                cursor.execute(
                    "INSERT INTO playlist_songs (playlist_id, song_id, position) VALUES (%s, %s, %s)",
                    (playlist_id, song_id, next_position),
                )
                next_position += 1
                added_count += 1
                total_duration += song["duration"]

            # Update playlist counts
            if added_count > 0:
                cursor.execute(
                    """
                    UPDATE playlists 
                    SET song_count = song_count + %s,
                        total_duration = total_duration + %s,
                        updated_at = %s
                    WHERE id = %s
                    """,
                    (
                        added_count,
                        total_duration,
                        datetime.now().isoformat(),
                        playlist_id,
                    ),
                )

            conn.commit()
            return {
                "success": True,
                "message": f"Added {added_count} songs to playlist",
                "added": added_count,
                "skipped": skipped_count,
            }

        except Exception as e:
            conn.rollback()
            return {"success": False, "message": str(e)}
        finally:
            conn.close()

    def bulk_reorder_songs(self, playlist_id, song_ids, new_position):
        """Move multiple songs to a new position in the playlist"""
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        try:
            if not self._owns(cursor, playlist_id):
                return {"success": False, "message": "Playlist not found"}
            # Get current positions of all songs to move
            placeholders = ",".join("?" * len(song_ids))
            cursor.execute(
                f"""
                SELECT song_id, position FROM playlist_songs 
                WHERE playlist_id = %s AND song_id IN ({placeholders})
                ORDER BY position
                """,
                [playlist_id] + list(song_ids),
            )
            songs_to_move = [
                (row["song_id"], row["position"]) for row in cursor.fetchall()
            ]

            if not songs_to_move:
                return {"success": False, "message": "No songs found to move"}

            # Get the old positions
            old_positions = [pos for _, pos in songs_to_move]
            min_old = min(old_positions)
            max_old = max(old_positions)

            # Temporarily set moved songs to negative positions
            for i, (song_id, _) in enumerate(songs_to_move):
                cursor.execute(
                    "UPDATE playlist_songs SET position = %s WHERE playlist_id = %s AND song_id = %s",
                    (-(i + 1), playlist_id, song_id),
                )

            # Close the gap left by removed songs
            cursor.execute(
                f"""
                UPDATE playlist_songs 
                SET position = position - (
                    SELECT COUNT(*) FROM (
                        SELECT position FROM playlist_songs 
                        WHERE playlist_id = %s AND position < 0
                    ) tmp
                    WHERE tmp.position * -1 <= (
                        SELECT COUNT(*) FROM playlist_songs WHERE playlist_id = %s AND position < 0
                    )
                )
                WHERE playlist_id = %s AND position > %s
                """,
                (playlist_id, playlist_id, playlist_id, max_old),
            )

            # Actually, let's do this more simply - renumber everything
            # Get all songs in order (excluding the ones we're moving)
            cursor.execute(
                """
                SELECT song_id, position FROM playlist_songs 
                WHERE playlist_id = %s AND position > 0
                ORDER BY position
                """,
                (playlist_id,),
            )
            remaining_songs = [row["song_id"] for row in cursor.fetchall()]

            # Determine insert index (accounting for the gap we just made)
            # new_position is 1-based, so insert_index is new_position - 1
            insert_index = max(0, min(new_position - 1, len(remaining_songs)))

            # Insert the moved songs at the new position
            for i, (song_id, _) in enumerate(songs_to_move):
                remaining_songs.insert(insert_index + i, song_id)

            # Now renumber everything
            for i, song_id in enumerate(remaining_songs):
                cursor.execute(
                    "UPDATE playlist_songs SET position = %s WHERE playlist_id = %s AND song_id = %s",
                    (i + 1, playlist_id, song_id),
                )

            # Update playlist timestamp
            cursor.execute(
                "UPDATE playlists SET updated_at = %s WHERE id = %s",
                (datetime.now().isoformat(), playlist_id),
            )

            conn.commit()
            return {"success": True, "message": f"Moved {len(songs_to_move)} songs"}

        except Exception as e:
            conn.rollback()
            return {"success": False, "message": str(e)}
        finally:
            conn.close()

    def generate_playlist_artwork(self, playlist_id):
        """Generate a 2x2 grid of album covers for playlist artwork"""
        from PIL import Image
        import os

        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        try:
            # Get first 4 unique albums from playlist (by position)
            cursor.execute(
                """
                    SELECT albums.artwork_path
                    FROM (
                        SELECT DISTINCT albums.id, MIN(playlist_songs.position) as min_pos, albums.artwork_path
                        FROM playlist_songs
                        JOIN songs ON playlist_songs.song_id = songs.id
                        JOIN albums ON songs.album_id = albums.id
                        WHERE playlist_songs.playlist_id = %s
                        AND albums.artwork_path IS NOT NULL
                        GROUP BY albums.id, albums.artwork_path
                        ORDER BY min_pos
                        LIMIT 4
                    ) as albums
                """,
                (playlist_id,),
            )

            artwork_paths = [row["artwork_path"] for row in cursor.fetchall()]

            if len(artwork_paths) < 4:
                return None  # Not enough unique albums

            # Create 2x2 grid (500x500 final size)
            grid = Image.new("RGB", (500, 500))
            positions = [(0, 0), (250, 0), (0, 250), (250, 250)]

            for i, artwork_filename in enumerate(artwork_paths):
                artwork_path = os.path.join(
                    self.config.ARTWORK_FOLDER, artwork_filename
                )

                if os.path.exists(artwork_path):
                    img = Image.open(artwork_path)
                    img = img.resize((250, 250), Image.Resampling.LANCZOS)
                    grid.paste(img, positions[i])

            # Save composite
            playlist_artwork_dir = "playlist_artwork"
            os.makedirs(playlist_artwork_dir, exist_ok=True)
            output_path = f"{playlist_artwork_dir}/playlist_{playlist_id}.jpg"
            grid.save(output_path, "JPEG", quality=90)

            return output_path

        finally:
            conn.close()
