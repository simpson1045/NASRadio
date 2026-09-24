"""
Shared playlist-import machinery.

Both the Spotify importer and the M3U8 (custom file) importer match tracks
against the local library exactly the same way and store matched/missing tracks
in `playlist_songs` exactly the same way. That shared logic lives here so we
never copy-paste the matching algorithm.

A "normalized track" is a dict with these keys:
    {
        "source_id": <str|None>,   # Spotify track id, or None for file imports
        "name":      <str>,        # track title
        "artists":   <list[str]>,  # one or more artist names
        "album":     <str>,        # album name, or "" when unknown
    }
"""

from app.models import Database
from app.config import Config
from app.extensions import socketio, safe_emit
from app import auth
import re
import requests
import time
import unicodedata

# Apostrophe-like marks that differ between sources but mean the same thing:
# Hawaiian ʻokina (U+02BB), curly quotes, backtick, acute accent, straight quote.
_APOSTROPHE_CHARS = "ʻ'‘’`´"


def _normalize_for_match(text):
    """Fold a title or artist name to a comparable form: lowercase, drop
    apostrophe-like marks and accents (José→jose, Hawaiʻi→hawaii), and turn
    separators/punctuation into spaces (so "A / B" == "A,B")."""
    text = (text or "").lower().strip()
    for ch in _APOSTROPHE_CHARS:
        text = text.replace(ch, "")
    # Decompose accented letters and drop the combining marks
    text = unicodedata.normalize("NFKD", text)
    text = "".join(c for c in text if not unicodedata.combining(c))
    text = text.replace(".", "")  # collapse "U.S.A." -> "usa", not "u s a"
    # Separators and any leftover punctuation become spaces
    text = re.sub(r"[^0-9a-z\s]", " ", text)
    return " ".join(text.split())

# Global cancel flag — shared across both importers and the cancel endpoint.
_import_cancelled = False


def cancel_import():
    """Set the cancel flag to stop the current import"""
    global _import_cancelled
    _import_cancelled = True


def reset_cancel_flag():
    """Reset the cancel flag"""
    global _import_cancelled
    _import_cancelled = False


def is_import_cancelled():
    """Check if import has been cancelled"""
    return _import_cancelled


class BasePlaylistImporter:
    """Library matching + missing-track storage shared by all importers."""

    def __init__(self):
        self.config = Config()
        self.db = Database(self.config.DATABASE_URL)

    def search_song_in_library(self, track_name, artist_names, spotify_album=None):
        """Search for a song in the local library by title and artist with smart scoring"""
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)

        try:
            import re
            from difflib import SequenceMatcher

            # Keywords that indicate alternate versions — penalize in BOTH title and album
            alt_title_keywords = [
                "alt",
                "demo",
                "live",
                "acoustic",
                "unplugged",
                "remix",
                "alternate",
            ]
            alt_album_keywords = [
                "outtake",
                "demo",
                "live",
                "bootleg",
                "b-side",
                "session",
                "rehearsal",
                "alternate",
                "deluxe",
            ]

            def basic_clean(title):
                """Remove remaster/remix info but keep alt/demo/live"""
                title = title.lower().strip()
                title = re.sub(r"\s*\(\d{4}.*?(remaster|remix|mix).*?\)", "", title)
                title = re.sub(r"\s*\((remaster|remix|mix).*?\d{4}.*?\)", "", title)
                title = re.sub(r"\s*\(.*?(remaster|remix|mix).*?\)", "", title)
                title = re.sub(r"\s*-\s*(remaster|remix|mix).*", "", title)
                return title.strip()

            def aggressive_clean(title):
                """Remove ALL parentheses and brackets for fuzzy matching"""
                title = title.lower().strip()
                title = re.sub(r"\s*\([^)]*\)", "", title)
                title = re.sub(r"\s*\[[^\]]*\]", "", title)
                title = re.sub(r"\s*-\s*\d{4}.*$", "", title)
                title = " ".join(title.split())
                return title.strip()

            def album_clean(name):
                """Normalize album name for comparison"""
                name = name.lower().strip()
                name = re.sub(r"\s*\(.*?(remaster|deluxe|edition|anniversary|bonus).*?\)", "", name)
                name = re.sub(r"\s*\[.*?\]", "", name)
                return name.strip()

            best_match = None
            best_score = 0
            n_track = _normalize_for_match(track_name)
            na_track = _normalize_for_match(aggressive_clean(track_name))

            for artist_name in artist_names:
                # Get all songs by this artist along with album info.
                # TRANSLATE strips apostrophe-like marks from both sides so the
                # Hawaiian ʻokina ("Kamakawiwoʻole") matches a plain apostrophe
                # ("Kamakawiwo'ole") stored in the library.
                cursor.execute(
                    """
                    SELECT songs.id, songs.title, artists.name as artist_name,
                           albums.title as album_title, albums.id as album_id
                    FROM songs
                    JOIN artists ON songs.artist_id = artists.id
                    JOIN albums ON songs.album_id = albums.id
                    WHERE LOWER(TRANSLATE(artists.name, %s, '')) = LOWER(TRANSLATE(%s, %s, ''))
                    """,
                    (_APOSTROPHE_CHARS, artist_name, _APOSTROPHE_CHARS),
                )

                for row in cursor.fetchall():
                    db_title = row["title"]
                    db_album = row["album_title"]
                    score = 0

                    # Level 1: EXACT match (case-insensitive) - highest priority
                    if db_title.lower() == track_name.lower():
                        score = 1000

                    # Level 2: Match after basic cleaning (remove remaster info)
                    elif basic_clean(db_title) == basic_clean(track_name):
                        score = 500

                    # Level 3: Match after normalizing apostrophes/accents/separators
                    # (e.g. "Hawaiʻi" == "Hawai'i", "A / B" == "A,B")
                    elif _normalize_for_match(db_title) == n_track:
                        score = 400

                    # Level 4: Match after aggressive cleaning (remove all parens/brackets)
                    elif aggressive_clean(db_title) == aggressive_clean(track_name):
                        score = 200

                    # Level 5: Match after aggressive cleaning + normalization
                    # (e.g. "Surfin' U.S.A. (2021 Mix)" == "Surfin' USA")
                    elif _normalize_for_match(aggressive_clean(db_title)) == na_track:
                        score = 180

                    # Level 6: Fuzzy match for typos (e.g. "Dcotor" vs "Doctor")
                    elif SequenceMatcher(None, _normalize_for_match(aggressive_clean(db_title)), na_track).ratio() > 0.85:
                        score = 150

                    else:
                        continue  # No match at any level

                    # --- Penalties for alt keywords in song title ---
                    title_lower = db_title.lower()
                    for keyword in alt_title_keywords:
                        if keyword in title_lower:
                            score -= 100

                    # --- Penalties for alt keywords in album title ---
                    album_lower = db_album.lower() if db_album else ""
                    for keyword in alt_album_keywords:
                        if keyword in album_lower:
                            score -= 150  # Album-level penalties are heavier

                    # --- Album name matching bonus (if the source told us the album) ---
                    if spotify_album:
                        cleaned_db_album = album_clean(db_album)
                        cleaned_sp_album = album_clean(spotify_album)
                        if cleaned_db_album == cleaned_sp_album:
                            score += 200  # Big bonus for matching album

                    # Track count tiebreaker (main albums have more tracks than singles/EPs)
                    cursor.execute(
                        "SELECT COUNT(*) as track_count FROM songs WHERE album_id = %s",
                        (row["album_id"],),
                    )
                    track_count = cursor.fetchone()["track_count"] or 0
                    score += min(track_count, 20)  # Cap at 20 so it doesn't dominate

                    # Track the best match
                    if score > best_score:
                        best_score = score
                        best_match = dict(row)

            # Minimum confidence threshold — don't return garbage matches
            if best_score < 150:
                return None

            return best_match

        finally:
            conn.close()

    def search_musicbrainz_release(self, album_name, artist_name, max_retries=3):
        """
        Search MusicBrainz for album and return release-group MBID.
        Release-groups cover ALL versions (original, remaster, expanded, etc.)
        """
        for attempt in range(max_retries):
            try:
                response = requests.get(
                    "https://musicbrainz.org/ws/2/release/",
                    params={
                        "query": f'release:"{album_name}" AND artist:"{artist_name}"',
                        "fmt": "json",
                        "limit": 1,
                    },
                    headers={"User-Agent": "NASRadio/1.0 (https://github.com/simpson1045/NASRadio)"},
                    timeout=10,
                )

                if response.status_code == 200:
                    data = response.json()
                    if data.get("releases"):
                        release = data["releases"][0]

                        # Get release-group ID instead of release ID
                        release_group = release.get("release-group", {})
                        release_group_id = release_group.get("id")

                        if release_group_id:
                            return {
                                "mbid": release_group_id,
                                "title": release["title"],
                                "score": release.get("score", 0),
                                "type": "release-group",
                            }
                elif response.status_code == 503:
                    # Rate limited - wait longer and retry
                    wait_time = 2 ** (attempt + 1)
                    print(f"⏳ MusicBrainz rate limited, waiting {wait_time}s...")
                    time.sleep(wait_time)
                    continue

                return None

            except (requests.exceptions.ConnectionError, ConnectionResetError) as e:
                if attempt < max_retries - 1:
                    wait_time = 2 ** (attempt + 1)
                    print(
                        f"⏳ MusicBrainz connection error, retrying in {wait_time}s..."
                    )
                    time.sleep(wait_time)
                else:
                    print(
                        f"⚠️ MusicBrainz error for '{album_name}' by '{artist_name}': {e}"
                    )
            except Exception as e:
                print(f"⚠️ MusicBrainz error for '{album_name}' by '{artist_name}': {e}")
                break

        return None

    @staticmethod
    def categorize_release_group(primary_type, secondary_types):
        """Human-facing category for an album, from its MB primary/secondary types."""
        secondary = [s for s in (secondary_types or [])]
        if secondary:
            for tag in ("Compilation", "Live", "Soundtrack", "Remix", "DJ-mix", "Demo", "Mixtape/Street"):
                if tag in secondary:
                    return "DJ-Mix" if tag == "DJ-mix" else tag.split("/")[0]
            return secondary[0]
        if primary_type == "Album":
            return "Studio Album"
        return primary_type or "Other"

    # Sort order for the picker: studio albums first, junk last.
    _CATEGORY_RANK = {
        "Studio Album": 0, "EP": 1, "Single": 2, "Compilation": 3,
        "Soundtrack": 4, "Live": 5, "Remix": 6, "DJ-Mix": 7, "Demo": 8,
    }

    def _mb_get(self, url, params, max_retries=3):
        """GET a MusicBrainz endpoint with 503-backoff. Returns JSON or None."""
        for attempt in range(max_retries):
            try:
                resp = requests.get(
                    url,
                    params=params,
                    headers={"User-Agent": "NASRadio/1.0 (https://github.com/simpson1045/NASRadio)"},
                    timeout=15,
                )
                if resp.status_code == 200:
                    return resp.json()
                if resp.status_code == 503:
                    time.sleep(2 ** (attempt + 1))
                    continue
                return None
            except requests.exceptions.RequestException:
                time.sleep(2 ** (attempt + 1))
        return None

    def list_track_release_groups(self, track_name, artist_name, limit=25):
        """
        Return ALL distinct albums (release-groups) a track appears on, each
        tagged with a category (Studio Album / Compilation / Live / EP / ...),
        sorted studio-first. Powers the manual album picker so the user can
        choose which release to search for rather than trusting auto-resolution.

        Two complementary searches, merged:
          1. Recording search — albums the track appears ON. Broad, but MB's
             recording entries are fragmented (one per remaster lineage), so
             the canonical album can be crowded out by junk comps.
          2. Release-group TITLE search — catches title-track cases the first
             search misses (e.g. the 1968 "The Dock of the Bay" album and the
             original single, which share the track's name).
        """
        groups = {}

        def add_group(rg, score, fallback_date=""):
            rg_id = rg.get("id")
            if not rg_id:
                return
            date = rg.get("first-release-date") or fallback_date or ""
            existing = groups.get(rg_id)
            if existing:
                # keep the higher-scored sighting, but fill an empty date
                if not existing["date"] and date:
                    existing["date"] = date
                if existing["_score"] >= score:
                    return
            secondary = rg.get("secondary-types") or []
            groups[rg_id] = {
                "mbid": rg_id,
                "album": rg.get("title"),
                "primary_type": rg.get("primary-type"),
                "secondary_types": secondary,
                "category": self.categorize_release_group(rg.get("primary-type"), secondary),
                "date": date,
                "_score": score,
            }

        # Search 1: recordings (albums the track appears on)
        data = self._mb_get(
            "https://musicbrainz.org/ws/2/recording/",
            {
                "query": f'recording:"{track_name}" AND artist:"{artist_name}"',
                "fmt": "json",
                "limit": limit,
            },
        )
        for rec in (data or {}).get("recordings", []):
            score = rec.get("score", 0)
            for rel in rec.get("releases", []):
                add_group(rel.get("release-group", {}) or {}, score, rel.get("date") or "")

        # Search 2: release-groups whose TITLE matches the track (title-track
        # albums / the original single). Strip parentheticals first — the
        # "(Sittin' On)" in the track name doesn't appear in the album title
        # "The Dock of the Bay" and would sink the match. Respect MB's
        # 1 req/sec rate limit.
        clean_title = re.sub(r"\s*\([^)]*\)|\s*\[[^\]]*\]", "", track_name)
        clean_title = " ".join(clean_title.split()).strip() or track_name
        time.sleep(1.1)
        data = self._mb_get(
            "https://musicbrainz.org/ws/2/release-group/",
            {
                "query": f'releasegroup:"{clean_title}" AND artist:"{artist_name}"',
                "fmt": "json",
                "limit": 10,
            },
        )
        for rg in (data or {}).get("release-groups", []):
            score = rg.get("score", 0)
            if score < 80:
                continue  # weak title matches are usually unrelated albums
            add_group(rg, score)

        result = list(groups.values())
        result.sort(
            key=lambda g: (
                self._CATEGORY_RANK.get(g["category"], 9),
                -g["_score"],
                g["date"] or "9999",
            )
        )
        for g in result:
            g.pop("_score", None)
        return result

    def search_musicbrainz_recording(self, track_name, artist_name, max_retries=3):
        """
        Look up a track (recording) on MusicBrainz to discover the album it
        appears on, when the source playlist gave us no album. Returns the
        best album title + its release-group MBID, preferring real studio
        albums over compilations/singles/live releases.
        """
        for attempt in range(max_retries):
            try:
                response = requests.get(
                    "https://musicbrainz.org/ws/2/recording/",
                    params={
                        "query": f'recording:"{track_name}" AND artist:"{artist_name}"',
                        "fmt": "json",
                        "limit": 25,
                    },
                    headers={"User-Agent": "NASRadio/1.0 (https://github.com/simpson1045/NASRadio)"},
                    timeout=10,
                )

                if response.status_code == 200:
                    data = response.json()
                    best_key = None
                    best = None
                    primary_rank = {"album": 0, "ep": 1, "single": 2}
                    for rec in data.get("recordings", []):
                        rec_score = rec.get("score", 0)
                        for rel in rec.get("releases", []):
                            rg = rel.get("release-group", {}) or {}
                            rg_id = rg.get("id")
                            if not rg_id:
                                continue
                            primary = (rg.get("primary-type") or "").lower()
                            secondary = rg.get("secondary-types", []) or []
                            date = rg.get("first-release-date") or rel.get("date") or "9999"
                            # Sort key (smaller = better): studio releases (no
                            # secondary type like Live/Compilation) first, then
                            # Album > EP > Single, then the highest text score,
                            # and only then earliest date as a final tiebreak.
                            # Score must beat date — MB often returns no date, and
                            # treating "no date" as year 9999 used to sink the real
                            # studio album below a junk reissue that had a date.
                            key = (
                                1 if secondary else 0,
                                primary_rank.get(primary, 3),
                                -rec_score,
                                date or "9999",
                            )
                            if best_key is None or key < best_key:
                                best_key = key
                                best = {
                                    "mbid": rg_id,
                                    "album": rg.get("title") or rel.get("title"),
                                    "score": rec_score,
                                    "type": "release-group",
                                }

                    if best:
                        return best
                elif response.status_code == 503:
                    wait_time = 2 ** (attempt + 1)
                    print(f"⏳ MusicBrainz rate limited, waiting {wait_time}s...")
                    time.sleep(wait_time)
                    continue

                return None

            except (requests.exceptions.ConnectionError, ConnectionResetError) as e:
                if attempt < max_retries - 1:
                    wait_time = 2 ** (attempt + 1)
                    print(f"⏳ MusicBrainz connection error, retrying in {wait_time}s...")
                    time.sleep(wait_time)
                else:
                    print(f"⚠️ MusicBrainz recording error for '{track_name}' by '{artist_name}': {e}")
            except Exception as e:
                print(f"⚠️ MusicBrainz recording error for '{track_name}' by '{artist_name}': {e}")
                break

        return None

    def process_tracks(
        self,
        tracks,
        playlist_name,
        display_description="",
        store_description=None,
        create_local_playlist=True,
        user_id=None,
        existing_playlist_id=None,
        skip_existing=False,
        progress_event="spotify_import_progress",
        do_mbid_lookup=True,
        mbid_lookup_mode="release",
    ):
        """
        Match a normalized track list against the library and store the results.

        mbid_lookup_mode controls how missing tracks find a MusicBrainz id:
          "release"   — search by album (Spotify, which always has an album)
          "recording" — search by track+artist to discover the album when the
                        source gave us none (file imports)

        Returns the same result shape the Spotify importer has always returned, so
        the frontend results UI works for any import source unchanged.
        """
        try:
            user_id = auth.current_user_id() if user_id is None else user_id
            # Auto-detect existing playlist with same name
            merged_into_existing = False
            skipped_count = 0
            # Smart merge: when a playlist already exists, skip tracks that are
            # already in the playlist (by source id) OR that the user has
            # manually fixed (by title match on manually_fixed entries).
            if not existing_playlist_id and create_local_playlist:
                detect_conn = None
                try:
                    detect_conn = self.db.get_connection()
                    cursor = self.db.get_cursor(detect_conn)
                    cursor.execute(
                        "SELECT id FROM playlists WHERE LOWER(name) = LOWER(%s) AND user_id = %s LIMIT 1",
                        (playlist_name, user_id),
                    )
                    existing = cursor.fetchone()
                    if existing:
                        existing_playlist_id = existing["id"]
                        skip_existing = True
                        merged_into_existing = True
                        print(f"🔄 Found existing playlist '{playlist_name}' (ID: {existing_playlist_id}), smart-merging...")
                except Exception as e:
                    print(f"⚠️ Auto-detect failed (proceeding with new playlist): {type(e).__name__}: {e}")
                finally:
                    if detect_conn:
                        detect_conn.close()

            # Filter out tracks already in the playlist
            tracks_to_process = tracks
            if existing_playlist_id and skip_existing:
                conn = self.db.get_connection()
                cursor = self.db.get_cursor(conn)

                # Check 1: tracks already in playlist by source id
                cursor.execute(
                    "SELECT spotify_track_id FROM playlist_songs WHERE playlist_id = %s AND spotify_track_id IS NOT NULL",
                    (existing_playlist_id,),
                )
                existing_source_ids = {row["spotify_track_id"] for row in cursor.fetchall()}

                # Check 2: tracks the user manually fixed — match by song title
                # so we never re-add a track the user explicitly chose a replacement for
                cursor.execute(
                    """SELECT LOWER(s.title) AS title FROM playlist_songs ps
                       JOIN songs s ON ps.song_id = s.id
                       WHERE ps.playlist_id = %s AND ps.manually_fixed = TRUE""",
                    (existing_playlist_id,),
                )
                manually_fixed_titles = {row["title"] for row in cursor.fetchall()}

                # Check 3: file imports have no source id, so dedupe them by
                # (title, artist) against everything already in the playlist —
                # otherwise re-importing the same .m3u8 duplicates every track.
                cursor.execute(
                    """SELECT LOWER(spotify_track_name) AS tname,
                              LOWER(COALESCE(spotify_artist, '')) AS aname
                       FROM playlist_songs WHERE playlist_id = %s AND spotify_track_name IS NOT NULL""",
                    (existing_playlist_id,),
                )
                existing_name_keys = {(row["tname"], row["aname"]) for row in cursor.fetchall()}
                conn.close()

                tracks_to_process = []
                skipped_by_id = 0
                skipped_by_fixed = 0
                for t in tracks:
                    name_key = (t["name"].lower(), ", ".join(t["artists"]).lower())
                    if t["source_id"] and t["source_id"] in existing_source_ids:
                        skipped_by_id += 1
                    elif t["name"].lower() in manually_fixed_titles:
                        skipped_by_fixed += 1
                    elif not t["source_id"] and name_key in existing_name_keys:
                        # Sourceless (file) track already present by title+artist
                        skipped_by_id += 1
                    else:
                        tracks_to_process.append(t)

                skipped_count = skipped_by_id + skipped_by_fixed
                if skipped_count:
                    print(f"⏭️  Skipped {skipped_by_id} by source id, {skipped_by_fixed} by manually_fixed flag")
                    print(f"🔍 Will match {len(tracks_to_process)} genuinely missing tracks")

            matched = []
            missing = []
            was_cancelled = False

            if tracks_to_process:
                print(f"🔍 Matching songs against local library...")

            # Reset cancel flag at start of import
            reset_cancel_flag()

            total_to_process = len(tracks_to_process)

            # Try to match each track
            for i, track in enumerate(tracks_to_process, 1):
                # Check for cancellation
                if is_import_cancelled():
                    print(
                        f"🛑 Import cancelled by user at track {i}/{total_to_process}"
                    )
                    was_cancelled = True
                    safe_emit(
                        progress_event,
                        {
                            "current": i,
                            "total": total_to_process,
                            "message": "Import cancelled",
                            "status": "cancelled",
                        },
                    )
                    break

                # Emit progress
                safe_emit(
                    progress_event,
                    {
                        "current": i,
                        "total": total_to_process,
                        "message": f"Matching: {track['name'][:40]}...",
                        "status": "running",
                        "matched": len(matched),
                        "missing": len(missing),
                    },
                )

                if i % 50 == 0:
                    print(f"   Progress: {i}/{total_to_process} songs processed...")
                local_song = self.search_song_in_library(
                    track["name"], track["artists"], spotify_album=track.get("album")
                )

                if local_song:
                    matched.append(
                        {
                            "song_id": local_song["id"],
                            "spotify_id": track["source_id"],
                            "title": local_song["title"],
                            "artist": local_song["artist_name"],
                            "spotify_title": track["name"],
                            "spotify_artists": ", ".join(track["artists"]),
                            "spotify_album": track["album"],
                            "_order": i,
                        }
                    )
                else:
                    # Find a MusicBrainz id for missing songs. With an album we
                    # look up the release directly; without one (file imports) we
                    # look up the recording to discover which album it's on, so
                    # the playlist's Prowlarr search has something to search for.
                    mbid_info = None
                    resolved_album = track["album"]
                    if do_mbid_lookup and track["artists"]:
                        if mbid_lookup_mode == "recording":
                            rec = self.search_musicbrainz_recording(
                                track["name"], track["artists"][0]
                            )
                            if rec:
                                mbid_info = {
                                    "mbid": rec["mbid"],
                                    "title": rec.get("album", ""),
                                    "score": rec.get("score", 0),
                                }
                                if not resolved_album and rec.get("album"):
                                    resolved_album = rec["album"]
                        else:
                            mbid_info = self.search_musicbrainz_release(
                                track["album"], track["artists"][0]
                            )
                        time.sleep(1.1)

                    missing_entry = {
                        "spotify_id": track["source_id"],
                        "title": track["name"],
                        "artists": ", ".join(track["artists"]),
                        "album": resolved_album,
                    }

                    if mbid_info:
                        missing_entry["mbid"] = mbid_info["mbid"]
                        missing_entry["mb_album"] = mbid_info["title"]
                        missing_entry["mb_score"] = mbid_info["score"]

                    missing_entry["_order"] = i
                    missing.append(missing_entry)

            print(f"✅ Matching complete!")
            print(f"   ✅ Matched: {len(matched)} songs")
            print(f"   ❌ Missing: {len(missing)} songs")

            # Count how many missing songs have MBIDs
            missing_with_mbid = sum(1 for song in missing if "mbid" in song)
            if missing_with_mbid > 0:
                print(
                    f"   🔍 Found MBIDs for {missing_with_mbid}/{len(missing)} missing songs"
                )

            # Create or update playlist with ALL songs (matched + missing)
            local_playlist_id = None
            from app.playlists import Playlists

            playlists = Playlists()

            # Check if updating existing or creating new
            if existing_playlist_id:
                print(f"💾 Updating existing playlist (ID: {existing_playlist_id})...")
                local_playlist_id = existing_playlist_id

            elif create_local_playlist:
                print(f"💾 Creating new local playlist...")

                # Create new playlist
                result = playlists.create_playlist(
                    name=playlist_name,
                    description=store_description if store_description is not None else display_description,
                    user_id=user_id,
                )

                # Extract the actual playlist ID from the result dict
                local_playlist_id = (
                    result.get("playlist_id") if isinstance(result, dict) else result
                )

            if local_playlist_id:
                conn = self.db.get_connection()
                cursor = self.db.get_cursor(conn)

                # Combine matched + missing and sort by original source order
                all_songs = []
                for song in matched:
                    all_songs.append(("matched", song))
                for song in missing:
                    all_songs.append(("missing", song))
                all_songs.sort(key=lambda x: x[1].get("_order", 0))

                for song_type, song in all_songs:
                    if song_type == "matched":
                        cursor.execute(
                            """INSERT INTO playlist_songs
                               (playlist_id, song_id, spotify_track_id, spotify_track_name, spotify_artist, spotify_album, position)
                               VALUES (%s, %s, %s, %s, %s, %s, (SELECT COALESCE(MAX(position), 0) + 1 FROM playlist_songs WHERE playlist_id = %s))""",
                            (
                                local_playlist_id,
                                song["song_id"],
                                song["spotify_id"],
                                song["spotify_title"],
                                song["spotify_artists"],
                                song.get("spotify_album", ""),
                                local_playlist_id,
                            ),
                        )
                    else:
                        cursor.execute(
                            """INSERT INTO playlist_songs
                               (playlist_id, song_id, spotify_track_id, spotify_track_name, spotify_artist, spotify_album, mbid, position)
                               VALUES (%s, NULL, %s, %s, %s, %s, %s, (SELECT COALESCE(MAX(position), 0) + 1 FROM playlist_songs WHERE playlist_id = %s))""",
                            (
                                local_playlist_id,
                                song.get("spotify_id"),
                                song["title"],
                                song["artists"],
                                song["album"],
                                song.get("mbid"),
                                local_playlist_id,
                            ),
                        )

                conn.commit()
                conn.close()

                print(
                    f"✅ Added {len(matched)} matched + {len(missing)} missing songs to playlist"
                )

            if was_cancelled:
                print(f"🛑 Import was cancelled")
            else:
                print(f"🎉 Import complete!")

            # Emit completion
            safe_emit(
                progress_event,
                {
                    "current": len(tracks_to_process),
                    "total": len(tracks_to_process),
                    "message": (
                        "Import complete!" if not was_cancelled else "Import cancelled"
                    ),
                    "status": "complete" if not was_cancelled else "cancelled",
                    "matched": len(matched),
                    "missing": len(missing),
                },
            )

            return {
                "success": True,
                "cancelled": was_cancelled,
                "playlist_info": {
                    "name": playlist_name,
                    "description": display_description or "",
                    "total_tracks": len(tracks),
                },
                "local_playlist_id": local_playlist_id,
                "total_tracks": len(tracks),
                "matched_count": len(matched),
                "missing_count": len(missing),
                "skipped_count": skipped_count,
                "merged_into_existing": merged_into_existing,
                "matched": matched,
                "missing": missing,
            }

        except Exception as e:
            print(f"❌ Import failed: {str(e)}")
            return {"success": False, "error": str(e)}
