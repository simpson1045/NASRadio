"""
Spotify Extended Streaming History Importer

Imports Spotify streaming history and matches to local library.
Exports missing items as JSON for Lidarr/manual lookup.
"""

import json
import psycopg2
import psycopg2.extras
import os
import re
from datetime import datetime
from unicodedata import normalize


def normalize_text(text):
    """Normalize text for fuzzy matching"""
    if not text:
        return ""
    # Unicode normalize
    text = normalize("NFKD", text).encode("ascii", "ignore").decode("ascii")
    # Lowercase
    text = text.lower()
    # Remove featuring artists
    text = re.sub(
        r"\s*[\(\[](feat\.?|ft\.?|featuring|with)[^\)\]]*[\)\]]",
        "",
        text,
        flags=re.IGNORECASE,
    )
    text = re.sub(r"\s*(feat\.?|ft\.?|featuring)\s+.*$", "", text, flags=re.IGNORECASE)

    # Remove common suffixes in parentheses/brackets
    # Handles: (2024 Remaster), (Remastered 2024), (Deluxe Edition), (Live at X), etc.
    suffix_patterns = [
        r"\d{4}\s*remaster",  # 2024 Remaster
        r"remaster(ed)?\s*\d{0,4}",  # Remastered 2024, Remaster
        r"\d{2,4}(th|st|nd|rd)?\s*anniversary",  # 25th Anniversary
        r"deluxe(\s*edition)?",  # Deluxe, Deluxe Edition
        r"expanded(\s*edition)?",  # Expanded Edition
        r"bonus(\s*track)?",  # Bonus Track
        r"live(\s*(at|from|in).*)?",  # Live, Live at X
        r"acoustic(\s*version)?",  # Acoustic
        r"radio\s*edit",  # Radio Edit
        r"single(\s*(edit|version))?",  # Single, Single Edit
        r"album\s*version",  # Album Version
        r"explicit",  # Explicit
        r"clean(\s*version)?",  # Clean
        r"mono(\s*mix)?",  # Mono
        r"stereo(\s*mix)?",  # Stereo Mix
        r"remix(ed)?",  # Remix
        r"extended(\s*(mix|version))?",  # Extended Mix
        r"original(\s*(mix|version))?",  # Original Mix
        r"demo(\s*version)?",  # Demo
        r"edit(ed)?",  # Edit
        r"version",  # Version
        r"mix",  # Mix
        r'from\s*["\']?.*["\']?',  # From "Movie"
        r"digital\s*\d*",  # Digital 45
        r"\d{4}\s*digital",  # 2024 Digital
        r"recording",  # Recording
        r"sessions?",  # Session, Sessions
        r"take\s*\d+",  # Take 2
        r"alt(ernate)?(\s*version)?",  # Alternate Version
        r"instrumental",  # Instrumental
        r"reprise",  # Reprise
        r"interlude",  # Interlude (keep this one actually, might be part of title)
        r"platinum(\s*edition)?",  # Platinum Edition
        r"gold(\s*edition)?",  # Gold Edition
        r"special(\s*edition)?",  # Special Edition
        r"legacy(\s*edition)?",  # Legacy Edition
        r"collector.?s?(\s*edition)?",  # Collector's Edition
        r"super\s*deluxe",  # Super Deluxe
    ]

    # Build combined pattern for parentheses/brackets
    combined = "|".join(suffix_patterns)
    text = re.sub(
        rf"\s*[\(\[]({combined})[^\)\]]*[\)\]]", "", text, flags=re.IGNORECASE
    )

    # Remove dash suffixes like "- 2015 Remaster", "- Live", "- Remastered"
    text = re.sub(rf"\s*-\s*({combined}).*$", "", text, flags=re.IGNORECASE)

    # Remove special characters
    text = re.sub(r"[^\w\s]", "", text)
    # Collapse whitespace
    text = re.sub(r"\s+", " ", text).strip()
    return text


def import_streaming_history(db_url, json_folder):
    """Import all Spotify streaming history JSON files"""
    conn = psycopg2.connect(db_url)
    cursor = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    # Find all streaming history files
    json_files = [
        f
        for f in os.listdir(json_folder)
        if f.startswith("Streaming_History_Audio") and f.endswith(".json")
    ]

    if not json_files:
        print("No Streaming_History_Audio files found!")
        return {"success": False, "error": "No files found"}

    print(f"Found {len(json_files)} streaming history files")

    total_imported = 0
    total_skipped = 0

    for json_file in sorted(json_files):
        filepath = os.path.join(json_folder, json_file)
        print(f"\nProcessing {json_file}...")

        with open(filepath, "r", encoding="utf-8") as f:
            plays = json.load(f)

        file_imported = 0
        file_skipped = 0

        for play in plays:
            # Skip podcasts and audiobooks
            if play.get("episode_name") or play.get("audiobook_title"):
                file_skipped += 1
                continue

            # Skip if no track name
            track_name = play.get("master_metadata_track_name")
            if not track_name:
                file_skipped += 1
                continue

            # Check for duplicate (same timestamp + track)
            ts = play.get("ts")
            cursor.execute(
                """
                SELECT id FROM spotify_plays 
                WHERE ts = %s AND spotify_track_uri = %s
            """,
                (ts, play.get("spotify_track_uri")),
            )

            if cursor.fetchone():
                file_skipped += 1
                continue

            # Insert play
            cursor.execute(
                """
                INSERT INTO spotify_plays (
                    ts, platform, ms_played, track_name, artist_name, album_name,
                    spotify_track_uri, reason_start, reason_end, 
                    shuffle, skipped, offline
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            """,
                (
                    ts,
                    play.get("platform"),
                    play.get("ms_played", 0),
                    track_name,
                    play.get("master_metadata_album_artist_name"),
                    play.get("master_metadata_album_album_name"),
                    play.get("spotify_track_uri"),
                    play.get("reason_start"),
                    play.get("reason_end"),
                    1 if play.get("shuffle") else 0,
                    1 if play.get("skipped") else 0,
                    1 if play.get("offline") else 0,
                ),
            )
            file_imported += 1

        conn.commit()
        print(f"  Imported: {file_imported}, Skipped: {file_skipped}")
        total_imported += file_imported
        total_skipped += file_skipped

    conn.close()

    print(f"\n{'='*50}")
    print(f"Total imported: {total_imported}")
    print(f"Total skipped: {total_skipped}")

    return {
        "success": True,
        "imported": total_imported,
        "skipped": total_skipped,
        "files_processed": len(json_files),
    }


def match_to_library(db_url):
    """Match Spotify plays to local library songs"""
    conn = psycopg2.connect(db_url)
    cursor = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    # Get all unmatched plays with unique artist/track combos
    cursor.execute(
        """
        SELECT DISTINCT artist_name, track_name, album_name
        FROM spotify_plays 
        WHERE matched_song_id IS NULL
        AND artist_name IS NOT NULL 
        AND track_name IS NOT NULL
    """
    )

    unique_tracks = cursor.fetchall()
    print(f"Attempting to match {len(unique_tracks)} unique tracks...")

    # Build lookup of local songs
    cursor.execute(
        """
        SELECT s.id, s.title, a.name as artist_name, al.title as album_name
        FROM songs s
        JOIN artists a ON s.artist_id = a.id
        JOIN albums al ON s.album_id = al.id
    """
    )

    local_songs = {}
    for row in cursor.fetchall():
        key = (normalize_text(row["artist_name"]), normalize_text(row["title"]))
        if key not in local_songs:
            local_songs[key] = row["id"]

    print(f"Local library has {len(local_songs)} unique artist/track combinations")

    matched = 0
    for track in unique_tracks:
        artist_norm = normalize_text(track["artist_name"])
        track_norm = normalize_text(track["track_name"])

        key = (artist_norm, track_norm)
        if key in local_songs:
            song_id = local_songs[key]
            cursor.execute(
                """
                UPDATE spotify_plays 
                SET matched_song_id = %s, matched_at = CURRENT_TIMESTAMP
                WHERE artist_name = %s AND track_name = %s AND matched_song_id IS NULL
            """,
                (song_id, track["artist_name"], track["track_name"]),
            )
            matched += 1

    conn.commit()

    # Get stats
    cursor.execute(
        "SELECT COUNT(*) FROM spotify_plays WHERE matched_song_id IS NOT NULL"
    )
    total_matched_plays = cursor.fetchone()["count"]

    cursor.execute("SELECT COUNT(*) FROM spotify_plays WHERE matched_song_id IS NULL")
    total_unmatched_plays = cursor.fetchone()["count"]

    conn.close()

    print(f"\n{'='*50}")
    print(f"Matched {matched} unique tracks")
    print(f"Total matched plays: {total_matched_plays}")
    print(f"Total unmatched plays: {total_unmatched_plays}")

    return {
        "success": True,
        "unique_tracks_matched": matched,
        "total_matched_plays": total_matched_plays,
        "total_unmatched_plays": total_unmatched_plays,
    }


def export_missing_items(db_url, output_path):
    """Export missing items as JSON, grouped by album, sorted by play time"""
    conn = psycopg2.connect(db_url)
    cursor = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    # Get all unmatched plays grouped by album
    cursor.execute(
        """
        SELECT 
            artist_name,
            album_name,
            track_name,
            spotify_track_uri,
            COUNT(*) as play_count,
            SUM(ms_played) as total_ms
        FROM spotify_plays
        WHERE matched_song_id IS NULL
        AND artist_name IS NOT NULL
        AND track_name IS NOT NULL
        GROUP BY artist_name, album_name, track_name, spotify_track_uri
        ORDER BY artist_name, album_name, total_ms DESC
    """
    )

    rows = cursor.fetchall()
    conn.close()

    # Group by album
    albums = {}
    for row in rows:
        key = (row["artist_name"], row["album_name"])
        if key not in albums:
            albums[key] = {
                "artist": row["artist_name"],
                "album": row["album_name"] or "Unknown Album",
                "total_plays": 0,
                "total_ms_played": 0,
                "tracks": [],
            }

        albums[key]["tracks"].append(
            {
                "title": row["track_name"],
                "spotify_uri": row["spotify_track_uri"],
                "plays": row["play_count"],
                "ms_played": row["total_ms"],
            }
        )
        albums[key]["total_plays"] += row["play_count"]
        albums[key]["total_ms_played"] += row["total_ms"]

    # Sort by total listen time
    sorted_albums = sorted(
        albums.values(), key=lambda x: x["total_ms_played"], reverse=True
    )

    # Add human-readable listen time
    for album in sorted_albums:
        ms = album["total_ms_played"]
        hours = ms // 3600000
        minutes = (ms % 3600000) // 60000
        album["listen_time"] = f"{hours}h {minutes}m"

        for track in album["tracks"]:
            t_ms = track["ms_played"]
            t_hours = t_ms // 3600000
            t_minutes = (t_ms % 3600000) // 60000
            track["listen_time"] = (
                f"{t_hours}h {t_minutes}m" if t_hours else f"{t_minutes}m"
            )

    output = {
        "generated_at": datetime.now().isoformat(),
        "total_missing_albums": len(sorted_albums),
        "total_missing_tracks": sum(len(a["tracks"]) for a in sorted_albums),
        "missing_albums": sorted_albums,
    }

    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(output, f, indent=2, ensure_ascii=False)

    print(f"\n{'='*50}")
    print(f"Exported {len(sorted_albums)} missing albums to {output_path}")
    print(f"\nTop 10 missing albums by listen time:")
    for album in sorted_albums[:10]:
        print(
            f"  {album['listen_time']:>8} - {album['artist']} - {album['album']} ({len(album['tracks'])} tracks)"
        )

    return {
        "success": True,
        "missing_albums": len(sorted_albums),
        "missing_tracks": sum(len(a["tracks"]) for a in sorted_albums),
        "output_file": output_path,
    }


def get_import_stats(db_url):
    """Get stats about imported Spotify data"""
    conn = psycopg2.connect(db_url)
    cursor = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)

    cursor.execute("SELECT COUNT(*) FROM spotify_plays")
    total_plays = cursor.fetchone()["count"]

    cursor.execute(
        "SELECT COUNT(*) FROM spotify_plays WHERE matched_song_id IS NOT NULL"
    )
    matched_plays = cursor.fetchone()["count"]

    cursor.execute("SELECT MIN(ts), MAX(ts) FROM spotify_plays")
    date_range = cursor.fetchone()

    cursor.execute("SELECT SUM(ms_played) FROM spotify_plays")
    total_ms = cursor.fetchone()["sum"] or 0

    cursor.execute(
        """
        SELECT COUNT(DISTINCT artist_name || '|||' || track_name)
        FROM spotify_plays WHERE matched_song_id IS NULL
    """
    )
    unique_unmatched = cursor.fetchone()["count"]

    conn.close()

    hours = total_ms // 3600000

    return {
        "total_plays": total_plays,
        "matched_plays": matched_plays,
        "unmatched_plays": total_plays - matched_plays,
        "match_rate": round(matched_plays / total_plays * 100, 1) if total_plays else 0,
        "date_range": {"start": date_range["min"], "end": date_range["max"]},
        "total_listen_hours": hours,
        "unmatched_unique_tracks": unique_unmatched,
    }


if __name__ == "__main__":
    import sys

    if len(sys.argv) < 3:
        print(
            "Usage: python spotify_history_import.py <db_path> <json_folder> [output_json]"
        )
        print(
            "Example: python spotify_history_import.py /path/to/nasradio.db /path/to/spotify/data"
        )
        sys.exit(1)

    db_path = sys.argv[1]
    json_folder = sys.argv[2]
    output_path = sys.argv[3] if len(sys.argv) > 3 else "missing_albums.json"

    print("=" * 50)
    print("SPOTIFY STREAMING HISTORY IMPORT")
    print("=" * 50)

    # Step 1: Import
    print("\n[1/3] Importing streaming history...")
    import_streaming_history(db_path, json_folder)

    # Step 2: Match
    print("\n[2/3] Matching to local library...")
    match_to_library(db_path)

    # Step 3: Export missing
    print("\n[3/3] Exporting missing items...")
    export_missing_items(db_path, output_path)

    # Final stats
    print("\n" + "=" * 50)
    print("FINAL STATS")
    print("=" * 50)
    stats = get_import_stats(db_path)
    print(f"Total plays imported: {stats['total_plays']}")
    print(f"Date range: {stats['date_range']['start']} to {stats['date_range']['end']}")
    print(f"Total listen time: {stats['total_listen_hours']} hours")
    print(f"Match rate: {stats['match_rate']}%")
    print(f"Unmatched unique tracks: {stats['unmatched_unique_tracks']}")
