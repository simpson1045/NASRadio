"""
Import custom .m3u8 / .m3u playlist files.

Reuses the shared matching + missing-track storage from BasePlaylistImporter.
The only thing unique here is parsing the file into normalized tracks. Because
a file has no album info and no Spotify track id, missing tracks are stored with
song_id NULL and no MBID — they still show up in the playlist as "not in library"
and can be linked manually exactly like Spotify-imported missing tracks.
"""

import os
from app.playlist_import_base import BasePlaylistImporter


class M3U8Importer(BasePlaylistImporter):
    """Import a playlist from an uploaded .m3u8 file."""

    def _split_artist_title(self, label):
        """Split an 'Artist - Title' label on the FIRST ' - '."""
        label = label.strip()
        if " - " in label:
            artist, title = label.split(" - ", 1)
            return artist.strip(), title.strip()
        # No separator — treat the whole thing as the title
        return "", label

    def parse_m3u8(self, content, fallback_name=None):
        """
        Parse extended-M3U content into (playlist_name, [normalized tracks]).

        Handles:
          #PLAYLIST:<name>                      → playlist name
          #EXTINF:<secs>,<Artist> - <Title>     → track metadata
          <path/uri>                            → the entry itself (filename
                                                  used as a fallback if there
                                                  was no #EXTINF before it)
        """
        lines = content.replace("\r\n", "\n").replace("\r", "\n").split("\n")

        playlist_name = None
        tracks = []
        pending = None  # (artist, title) carried from the preceding #EXTINF

        for raw in lines:
            line = raw.strip()
            if not line:
                continue

            upper = line.upper()
            if upper.startswith("#PLAYLIST:"):
                playlist_name = line.split(":", 1)[1].strip()
                continue

            if upper.startswith("#EXTINF:"):
                # Everything after the first comma is "Artist - Title"
                parts = line.split(",", 1)
                label = parts[1].strip() if len(parts) > 1 else ""
                pending = self._split_artist_title(label)
                continue

            if line.startswith("#"):
                continue  # other directives (#EXTM3U, #EXTGRP, etc.)

            # A non-comment line is the actual entry (file path or URL)
            if pending:
                artist, title = pending
                pending = None
            else:
                # No #EXTINF — derive artist/title from the filename stem
                stem = os.path.splitext(os.path.basename(line))[0]
                artist, title = self._split_artist_title(stem)

            if title:
                tracks.append(
                    {
                        "source_id": None,
                        "name": title,
                        "artists": [artist] if artist else [],
                        "album": "",
                    }
                )

        if not playlist_name:
            if fallback_name:
                playlist_name = os.path.splitext(os.path.basename(fallback_name))[0]
            else:
                playlist_name = "Imported Playlist"

        return playlist_name, tracks

    def import_m3u8(
        self,
        content,
        filename=None,
        create_local_playlist=True,
        user_id=None,
        existing_playlist_id=None,
        skip_existing=False,
    ):
        """Parse an m3u8 file and match its tracks against the local library."""
        print(f"🎵 Starting M3U8 import (file: {filename or 'pasted content'})")

        try:
            playlist_name, tracks = self.parse_m3u8(content, fallback_name=filename)
            print(f"📝 Playlist: {playlist_name}")
            print(f"✅ Parsed {len(tracks)} tracks from file")

            if not tracks:
                return {
                    "success": False,
                    "error": "No tracks found in the file. Is it a valid .m3u8 playlist?",
                }

            return self.process_tracks(
                tracks,
                playlist_name=playlist_name,
                display_description="Imported from file",
                store_description="Imported from M3U8 file",
                create_local_playlist=create_local_playlist,
                user_id=user_id,
                existing_playlist_id=existing_playlist_id,
                skip_existing=skip_existing,
                progress_event="m3u8_import_progress",
                do_mbid_lookup=True,
                mbid_lookup_mode="recording",
            )

        except Exception as e:
            print(f"❌ M3U8 import failed: {str(e)}")
            return {"success": False, "error": str(e)}
