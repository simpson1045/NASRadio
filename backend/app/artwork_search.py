import time
import re
import requests
from io import BytesIO
from PIL import Image
import os
from app.config import Config


class ArtworkSearch:
    """Search for album artwork with confidence scoring"""

    # Class-level rate limiting
    _last_musicbrainz_request = 0
    _last_coverart_request = 0
    MUSICBRAINZ_DELAY = 1.1  # MusicBrainz requires 1 req/sec, small buffer
    COVERART_DELAY = 1.5  # Cover Art Archive needs more breathing room

    def __init__(self):
        self.config = Config()
        self.artwork_dir = self.config.ARTWORK_FOLDER
        self.headers = {"User-Agent": "NASRadio/1.0 (https://github.com/simpson1045/NASRadio)"}

        if not os.path.exists(self.artwork_dir):
            os.makedirs(self.artwork_dir)

    def _clean_album_title(self, title):
        """Remove common suffixes like (Remastered), (Deluxe Edition), etc."""
        # Patterns to remove (case-insensitive)
        patterns = [
            r"\s*\(.*?remaster.*?\)\s*",
            r"\s*\(.*?deluxe.*?\)\s*",
            r"\s*\(.*?anniversary.*?\)\s*",
            r"\s*\(.*?expanded.*?\)\s*",
            r"\s*\(.*?bonus.*?\)\s*",
            r"\s*\(.*?edition.*?\)\s*",
            r"\s*\(.*?version.*?\)\s*",
            r"\s*\[.*?remaster.*?\]\s*",
            r"\s*\[.*?deluxe.*?\]\s*",
            r"\s*\[.*?anniversary.*?\]\s*",
            r"\s*\[.*?expanded.*?\]\s*",
            r"\s*\[.*?bonus.*?\]\s*",
            r"\s*\[.*?edition.*?\]\s*",
            r"\s*\[.*?version.*?\]\s*",
            r"\s*-\s*remastered\s*$",
            r"\s*-\s*deluxe\s*$",
        ]

        cleaned = title
        for pattern in patterns:
            cleaned = re.sub(pattern, "", cleaned, flags=re.IGNORECASE)

        return cleaned.strip()

    def _rate_limit_musicbrainz(self):
        """Ensure we don't exceed MusicBrainz rate limits"""
        elapsed = time.time() - ArtworkSearch._last_musicbrainz_request
        if elapsed < self.MUSICBRAINZ_DELAY:
            time.sleep(self.MUSICBRAINZ_DELAY - elapsed)
        ArtworkSearch._last_musicbrainz_request = time.time()

    def _rate_limit_coverart(self):
        """Ensure we don't exceed Cover Art Archive rate limits"""
        elapsed = time.time() - ArtworkSearch._last_coverart_request
        if elapsed < self.COVERART_DELAY:
            time.sleep(self.COVERART_DELAY - elapsed)
        ArtworkSearch._last_coverart_request = time.time()

    def _get_artwork_info(self, release_id, max_retries=2):
        """Get artwork info from Cover Art Archive, returns dict with quality info or None"""
        for attempt in range(max_retries + 1):
            self._rate_limit_coverart()
            try:
                url = f"https://coverartarchive.org/release/{release_id}"
                response = requests.get(url, headers=self.headers, timeout=25)

                if response.status_code != 200:
                    return None

                data = response.json()
                images = data.get("images", [])

                # Find the front cover image
                front_image = None
                for img in images:
                    if img.get("front", False):
                        front_image = img
                        break

                # If no front image marked, use first image
                if not front_image and images:
                    front_image = images[0]

                if not front_image:
                    return None

                # Determine quality based on available thumbnails
                thumbnails = front_image.get("thumbnails", {})

                # Quality score: higher is better
                quality_score = 0
                best_thumbnail_url = None

                # Prefer highest resolution for sharp artwork display
                if "1200" in thumbnails:
                    quality_score = 1200
                    best_thumbnail_url = thumbnails["1200"]
                elif "large" in thumbnails:
                    quality_score = 500
                    best_thumbnail_url = thumbnails["large"]
                elif "500" in thumbnails:
                    quality_score = 500
                    best_thumbnail_url = thumbnails["500"]
                elif "small" in thumbnails:
                    quality_score = 250
                    best_thumbnail_url = thumbnails["small"]
                elif "250" in thumbnails:
                    quality_score = 250
                    best_thumbnail_url = thumbnails["250"]
                else:
                    # Fallback to main image URL (full resolution)
                    quality_score = 1200
                    best_thumbnail_url = front_image.get("image")

                # Validate URL exists and is not empty
                if not best_thumbnail_url:
                    return None

                # Ensure URLs use HTTPS
                if best_thumbnail_url.startswith("http://"):
                    best_thumbnail_url = best_thumbnail_url.replace(
                        "http://", "https://", 1
                    )

                full_url = front_image.get("image")
                if full_url and full_url.startswith("http://"):
                    full_url = full_url.replace("http://", "https://", 1)

                return {
                    "exists": True,
                    "quality_score": quality_score,
                    "thumbnail_url": best_thumbnail_url,
                    "full_url": full_url,
                }

            except (requests.exceptions.ConnectionError, ConnectionResetError) as e:
                print(
                    f"Connection error checking artwork for {release_id} (attempt {attempt + 1}): {e}"
                )
                if attempt < max_retries:
                    time.sleep(2)  # Extra delay before retry
                    continue
                return None
            except Exception as e:
                print(f"Error checking artwork for {release_id}: {e}")
                return None

        return None  # All retries exhausted

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

    def _get_format_string(self, media_list):
        """Extract format string from MusicBrainz media list"""
        if not media_list:
            return None
        formats = []
        for media in media_list:
            fmt = media.get("format")
            if fmt and fmt not in formats:
                formats.append(fmt)
        return " + ".join(formats) if formats else None

    def _get_country_date(self, release):
        """Get country and date as a formatted string"""
        country = release.get("country", "")
        date = release.get("date", "")

        parts = []
        if country:
            parts.append(country)
        if date:
            parts.append(date)

        return " • ".join(parts) if parts else None

    def search_musicbrainz(self, artist_name, album_title, limit=30, max_retries=2):
        """Search MusicBrainz releases directly and return options with
        confidence scores.

        One query per title. The previous version searched release-groups,
        then fetched the releases of EACH group with its own rate-limited
        call, then repeated all of it for the un-cleaned title — up to a
        dozen sequential MusicBrainz calls, which is why the artwork picker
        took ~60s. The release search endpoint returns media, date, country
        and artist credit in a single response."""
        cleaned_title = self._clean_album_title(album_title)
        titles_to_try = [cleaned_title]
        if cleaned_title != album_title:
            titles_to_try.append(album_title)

        all_results = []
        seen_release_ids = set()

        for search_title in titles_to_try:
            releases = None
            for attempt in range(max_retries + 1):
                try:
                    self._rate_limit_musicbrainz()
                    params = {
                        "query": f'artist:"{artist_name}" AND release:"{search_title}"',
                        "fmt": "json",
                        "limit": 50,
                    }
                    print(f"🔍 Searching releases for: {artist_name} - {search_title}")
                    response = requests.get(
                        "https://musicbrainz.org/ws/2/release/",
                        params=params, headers=self.headers, timeout=25,
                    )
                    if response.status_code != 200:
                        print(f"MusicBrainz release search failed with status "
                              f"{response.status_code} (attempt {attempt + 1})")
                        if attempt < max_retries:
                            time.sleep(2)
                            continue
                        break
                    releases = response.json().get("releases", [])
                    break
                except Exception as e:
                    print(f"Error searching MusicBrainz (attempt {attempt + 1}): {e}")
                    if attempt < max_retries:
                        time.sleep(2)
                        continue
                    break

            if not releases:
                continue
            print(f"📀 Found {len(releases)} releases for '{search_title}'")

            for release in releases:
                release_id = release.get("id")
                if not release_id or release_id in seen_release_ids:
                    continue
                seen_release_ids.add(release_id)

                artist_credit = release.get("artist-credit") or []
                result_artist = (artist_credit[0].get("name", "Unknown")
                                 if artist_credit else "Unknown")
                release_title = release.get("title", "Unknown")
                date = release.get("date", "")
                all_results.append({
                    "release_id": release_id,
                    "title": release_title,
                    "artist": result_artist,
                    "year": date[:4] if date else None,
                    "format": self._get_format_string(release.get("media", [])),
                    "country_date": self._get_country_date(release),
                    "confidence": self.calculate_confidence(
                        artist_name, album_title, result_artist, release_title),
                    "quality_score": 250,
                    "artwork_url": f"https://coverartarchive.org/release/{release_id}/front-250",
                })

            # The cleaned title found matches; the raw title would mostly
            # return the same releases at the cost of another throttled call.
            if all_results:
                break

        print(f"✅ Returning {len(all_results)} total results")

        # Sort by: Digital Media first, US/XE releases, then confidence
        def _sort_key(result):
            fmt = (result.get("format") or "").lower()
            country_date = result.get("country_date") or ""
            is_digital = 1 if "digital" in fmt else 0
            is_us = 1 if "US" in country_date else 0
            is_xe = 1 if "XE" in country_date else 0
            return (is_digital, is_us, is_xe, result["confidence"])

        all_results.sort(key=_sort_key, reverse=True)
        return all_results

    def get_releases_by_release_group(self, release_group_id):
        """All releases in a release group, one MusicBrainz call.

        The browse endpoint returns each release's media (format), date,
        country and artist credit directly, so there is no need for the
        old per-release lookup loop (16 releases = 16 throttled calls)."""
        try:
            self._rate_limit_musicbrainz()
            response = requests.get(
                "https://musicbrainz.org/ws/2/release/",
                params={"release-group": release_group_id,
                        "inc": "media+artist-credits",
                        "fmt": "json", "limit": 100},
                headers=self.headers, timeout=25,
            )
            if response.status_code != 200:
                print(f"Release group browse failed with status {response.status_code}")
                return None

            releases = response.json().get("releases", [])
            if not releases:
                return None

            results = []
            for release in releases:
                release_id = release.get("id")
                if not release_id:
                    continue
                artist_credit = release.get("artist-credit") or []
                artist = (artist_credit[0].get("name", "Unknown")
                          if artist_credit else "Unknown")
                date = release.get("date", "")
                results.append({
                    "release_id": release_id,
                    "title": release.get("title", "Unknown"),
                    "artist": artist,
                    "year": date[:4] if date else None,
                    "format": self._get_format_string(release.get("media", [])),
                    "country_date": self._get_country_date(release),
                    "confidence": 100,
                    "quality_score": 250,
                    "artwork_url": f"https://coverartarchive.org/release/{release_id}/front-250",
                })

            # Sort by: Digital Media first, US/XE releases
            def _sort_key(result):
                fmt = (result.get("format") or "").lower()
                country_date = result.get("country_date") or ""
                is_digital = 1 if "digital" in fmt else 0
                is_us = 1 if "US" in country_date else 0
                is_xe = 1 if "XE" in country_date else 0
                return (is_digital, is_us, is_xe)

            results.sort(key=_sort_key, reverse=True)
            return results if results else None

        except Exception as e:
            print(f"Error fetching release group {release_group_id}: {e}")
            return None

    def get_artwork_by_mbid(self, mbid):
        """Get artwork info for a MusicBrainz ID (release or release-group)"""
        try:
            # Albums almost always store a release-GROUP id, so try that
            # first: one browse call, no 404 round-trip on the release path.
            results = self.get_releases_by_release_group(mbid)
            if results:
                return {"releases": results, "is_single": False}

            # Not a release group — try as a release ID
            self._rate_limit_musicbrainz()

            url = f"https://musicbrainz.org/ws/2/release/{mbid}?inc=media+artist-credits&fmt=json"
            response = requests.get(url, headers=self.headers, timeout=25)

            if response.status_code == 200:
                # It's a release ID
                data = response.json()

                title = data.get("title", "Unknown")
                artist_credit = data.get("artist-credit", [])
                if artist_credit:
                    artist = artist_credit[0].get("name", "Unknown")
                else:
                    artist = "Unknown"

                date = data.get("date", "")
                year = date[:4] if date else None
                country = data.get("country", "")
                format_str = self._get_format_string(data.get("media", []))

                parts = []
                if country:
                    parts.append(country)
                if date:
                    parts.append(date)
                country_date = " • ".join(parts) if parts else None

                # Verify artwork exists (for manual lookup, we do verify)
                artwork_info = self._get_artwork_info(mbid)

                if artwork_info is None:
                    print(f"No artwork found in Cover Art Archive for release {mbid}")
                    return None

                if not artwork_info.get("thumbnail_url"):
                    return None

                return {
                    "release_id": mbid,
                    "title": title,
                    "artist": artist,
                    "year": year,
                    "format": format_str,
                    "country_date": country_date,
                    "confidence": 100,
                    "quality_score": artwork_info["quality_score"],
                    "artwork_url": artwork_info["thumbnail_url"],
                    "is_single": True,  # Flag to indicate single result
                }

            print(f"MBID {mbid} not found as release or release-group")
            return None

        except Exception as e:
            print(f"Error fetching MBID {mbid}: {e}")
            return None

    def save_uploaded_artwork(self, album_id, image_data):
        """Save uploaded image data as album artwork"""
        try:
            artwork_filename = f"album_{album_id}.jpg"
            artwork_path = os.path.join(self.artwork_dir, artwork_filename)

            img = Image.open(BytesIO(image_data))

            if img.mode in ("RGBA", "LA", "P"):
                img = img.convert("RGB")

            # No resize — keep original resolution for best quality on large displays
            img.save(artwork_path, "JPEG", quality=95)

            return artwork_filename
        except Exception as e:
            print(f"Error saving uploaded artwork: {e}")
            return None

    def download_and_save_artwork(self, release_id, album_id, max_retries=2):
        """Download artwork from Cover Art Archive and save it with retry logic"""
        # Try release URL first, then release-group URL
        urls_to_try = [
            f"https://coverartarchive.org/release/{release_id}/front",
            f"https://coverartarchive.org/release-group/{release_id}/front",
        ]

        for cover_art_url in urls_to_try:
            print(f"🎨 Trying to download: {cover_art_url}")
            for attempt in range(max_retries):
                try:
                    self._rate_limit_coverart()

                    response = requests.get(
                        cover_art_url, headers=self.headers, timeout=15
                    )

                    if response.status_code == 404:
                        break  # Try next URL

                    if response.status_code != 200:
                        print(
                            f"Failed to download artwork (attempt {attempt + 1}): HTTP {response.status_code}"
                        )
                        if attempt < max_retries - 1:
                            time.sleep(2)
                            continue
                        break  # Try next URL

                    # Process and save
                    artwork_filename = f"album_{album_id}.jpg"
                    artwork_path = os.path.join(self.artwork_dir, artwork_filename)

                    img = Image.open(BytesIO(response.content))

                    if img.mode in ("RGBA", "LA", "P"):
                        img = img.convert("RGB")

                    # No resize — keep original resolution for best quality on large displays
                    img.save(artwork_path, "JPEG", quality=95)

                    print(f"✅ Successfully saved artwork: {artwork_filename}")
                    return artwork_filename

                except Exception as e:
                    print(f"Error downloading artwork (attempt {attempt + 1}): {e}")
                    if attempt < max_retries - 1:
                        time.sleep(2)
                        continue
                    break  # Try next URL

        return None

    def best_youtube_thumbnail(self, video_id):
        """Return the highest-resolution YouTube thumbnail URL that actually
        exists for a video (maxres/sd aren't generated for every video), or
        None. YouTube serves a tiny grey placeholder rather than a 404 for a
        missing size, so we also reject trivially-small responses."""
        for name in ("maxresdefault", "sddefault", "hqdefault"):
            url = f"https://i.ytimg.com/vi/{video_id}/{name}.jpg"
            try:
                r = requests.get(url, headers=self.headers, timeout=8, stream=True)
                length = int(r.headers.get("Content-Length", "0") or 0)
                r.close()
                if r.status_code == 200 and (length == 0 or length > 3000):
                    return url
            except Exception:
                continue
        return None

    def search_spotify_cover(self, artist_name, album_title):
        """Find an album cover on Spotify via the official API (SpotifyDiscovery).
        Returns the largest cover image URL, or None. Great for obscure releases
        that Spotify has but MusicBrainz/Cover Art Archive don't."""
        try:
            from app.discovery import SpotifyDiscovery

            sp = SpotifyDiscovery().sp
            for q in (
                f'album:"{album_title}" artist:"{artist_name}"',
                f"{album_title} {artist_name}",
            ):
                try:
                    results = sp.search(q=q, type="album", limit=5)
                except Exception:
                    continue
                for item in results.get("albums", {}).get("items", []):
                    images = item.get("images", [])
                    if images:  # spotipy returns images largest-first
                        return images[0]["url"]
            return None
        except Exception as e:
            print(f"Spotify cover search failed: {e}")
            return None

    def download_and_save_from_url(self, image_url, album_id, crop_square=True,
                                   max_retries=2):
        """Download artwork directly from an image URL (YouTube thumbnail,
        Spotify cover, ...) and save it as this album's cover. YouTube
        thumbnails are 16:9, so we center-crop to a square; already-square
        images (Spotify) are unchanged."""
        for attempt in range(max_retries):
            try:
                response = requests.get(image_url, headers=self.headers, timeout=15)
                if response.status_code != 200:
                    if attempt < max_retries - 1:
                        time.sleep(1)
                        continue
                    return None

                img = Image.open(BytesIO(response.content))
                if img.mode in ("RGBA", "LA", "P"):
                    img = img.convert("RGB")
                if crop_square and img.width != img.height:
                    side = min(img.width, img.height)
                    left = (img.width - side) // 2
                    top = (img.height - side) // 2
                    img = img.crop((left, top, left + side, top + side))

                artwork_filename = f"album_{album_id}.jpg"
                artwork_path = os.path.join(self.artwork_dir, artwork_filename)
                img.save(artwork_path, "JPEG", quality=95)
                print(f"✅ Saved artwork from URL: {artwork_filename}")
                return artwork_filename
            except Exception as e:
                print(f"Direct-URL artwork download failed (attempt {attempt + 1}): {e}")
                if attempt < max_retries - 1:
                    time.sleep(1)
                    continue
                return None
        return None
