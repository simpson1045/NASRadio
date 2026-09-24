"""
Spotify Play Count fetcher using the internal Pathfinder API.
Uses TOTP authentication reverse-engineered from the web player.
Requires: pyotp, requests (or curl_cffi)
"""

import base64
import time
import threading
from time import time_ns
from email.utils import parsedate_to_datetime
import pyotp
import requests as std_requests

try:
    from curl_cffi import requests as cf_requests

    HAS_CURL_CFFI = True
except ImportError:
    HAS_CURL_CFFI = False


# TOTP secrets - these get updated when Spotify changes their web player JS
# Source: https://github.com/xyloflake/spot-secrets-go/blob/main/secrets/secretDict.json
SECRET_CIPHER_DICT = {
    "59": [
        123,
        105,
        79,
        70,
        110,
        59,
        52,
        125,
        60,
        49,
        80,
        70,
        89,
        75,
        80,
        86,
        63,
        53,
        123,
        37,
        117,
        49,
        52,
        93,
        77,
        62,
        47,
        86,
        48,
        104,
        68,
        72,
    ],
    "60": [
        79,
        109,
        69,
        123,
        90,
        65,
        46,
        74,
        94,
        34,
        58,
        48,
        70,
        71,
        92,
        85,
        122,
        63,
        91,
        64,
        87,
        87,
    ],
    "61": [
        44,
        55,
        47,
        42,
        70,
        40,
        34,
        114,
        76,
        74,
        50,
        111,
        120,
        97,
        75,
        76,
        94,
        102,
        43,
        69,
        49,
        120,
        118,
        80,
        64,
        78,
    ],
}

SECRETS_URL = "https://github.com/xyloflake/spot-secrets-go/blob/main/secrets/secretDict.json?raw=true"


class SpotifyPlayCount:
    """Fetches real play counts from Spotify's internal Pathfinder API."""

    def __init__(self, sp_dc):
        self.sp_dc = sp_dc
        self._access_token = None
        self._token_expires_at = 0
        self._lock = threading.Lock()

    def _get_server_time(self):
        """Get Spotify's server time from HTTP Date header."""
        resp = std_requests.head("https://open.spotify.com/", timeout=5)
        resp.raise_for_status()
        date_hdr = resp.headers.get("Date")
        if not date_hdr:
            raise RuntimeError("Missing 'Date' header from Spotify")
        return int(parsedate_to_datetime(date_hdr).timestamp())

    def _generate_totp(self):
        """Generate TOTP code using the highest available secret version."""
        ver = str(max(int(v) for v in SECRET_CIPHER_DICT))
        secret_cipher = SECRET_CIPHER_DICT[ver]

        transformed = [e ^ ((t % 33) + 9) for t, e in enumerate(secret_cipher)]
        joined = "".join(str(num) for num in transformed)
        hex_str = joined.encode().hex()
        secret = base64.b32encode(bytes.fromhex(hex_str)).decode().rstrip("=")

        totp_obj = pyotp.TOTP(secret, digits=6, interval=30)
        return totp_obj, int(ver)

    def _refresh_token(self):
        """Get a fresh access token using sp_dc cookie + TOTP."""
        server_time = self._get_server_time()
        totp_obj, totp_ver = self._generate_totp()
        otp_value = totp_obj.at(server_time)

        resp = std_requests.get(
            "https://open.spotify.com/api/token",
            params={
                "reason": "transport",
                "productType": "web-player",
                "totp": otp_value,
                "totpServer": otp_value,
                "totpVer": totp_ver,
            },
            headers={
                "Cookie": f"sp_dc={self.sp_dc}",
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36",
                "Referer": "https://open.spotify.com/",
            },
            timeout=10,
        )
        resp.raise_for_status()
        data = resp.json()

        if "accessToken" not in data:
            raise RuntimeError(f"No accessToken in response: {data}")

        self._access_token = data["accessToken"]
        # Expire 5 min early to avoid edge cases
        self._token_expires_at = (data["accessTokenExpirationTimestampMs"] / 1000) - 300
        print(
            f"🎫 Spotify Pathfinder token refreshed (anonymous={data.get('isAnonymous')})"
        )

    def _get_token(self):
        """Get a valid access token, refreshing if needed. Thread-safe."""
        with self._lock:
            if not self._access_token or time.time() >= self._token_expires_at:
                self._refresh_token()
            return self._access_token

    def _pathfinder_request(self, operation_name, variables, sha256_hash):
        """Make a request to the Pathfinder v2 API."""
        token = self._get_token()

        headers = {
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            "App-Platform": "WebPlayer",
            "Origin": "https://open.spotify.com",
            "Referer": "https://open.spotify.com/",
        }

        payload = {
            "operationName": operation_name,
            "variables": variables,
            "extensions": {
                "persistedQuery": {
                    "version": 1,
                    "sha256Hash": sha256_hash,
                }
            },
        }

        if HAS_CURL_CFFI:
            resp = cf_requests.post(
                "https://api-partner.spotify.com/pathfinder/v2/query",
                impersonate="chrome",
                headers=headers,
                json=payload,
            )
        else:
            headers["User-Agent"] = (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36"
            )
            resp = std_requests.post(
                "https://api-partner.spotify.com/pathfinder/v2/query",
                headers=headers,
                json=payload,
                timeout=15,
            )

        resp.raise_for_status()
        return resp.json()

    def get_artist_play_counts(self, spotify_artist_id):
        """
        Get top tracks with real play counts for a Spotify artist.

        Args:
            spotify_artist_id: Spotify artist ID (e.g. '5x6H8meBBWk6J8qcIWxW7w')

        Returns:
            dict with 'tracks' list containing name, playcount, album, etc.
        """
        data = self._pathfinder_request(
            operation_name="queryArtistOverview",
            variables={
                "uri": f"spotify:artist:{spotify_artist_id}",
                "locale": "",
                "includePrerelease": True,
            },
            sha256_hash="35648a112beb1794e39ab931365f6ae4a8d45e65396d641eeda94e4003d41497",
        )

        artist_union = data.get("data", {}).get("artistUnion", {})
        top_items = (
            artist_union.get("discography", {}).get("topTracks", {}).get("items", [])
        )

        tracks = []
        for item in top_items:
            t = item.get("track", {})
            album = t.get("albumOfTrack", {})

            # Get album art
            artwork_url = None
            cover_art = album.get("coverArt", {})
            sources = cover_art.get("sources", [])
            if sources:
                artwork_url = sources[0].get("url")

            # Get artists
            artists = []
            for a in t.get("artists", {}).get("items", []):
                artists.append(a.get("profile", {}).get("name", ""))

            tracks.append(
                {
                    "name": t.get("name", ""),
                    "playcount": int(t.get("playcount", 0)),
                    "spotify_id": t.get("uri", "").replace("spotify:track:", ""),
                    "album_name": album.get("name", ""),
                    "artwork_url": artwork_url,
                    "artists": artists,
                }
            )

        # Also grab monthly listeners and follower count
        stats = artist_union.get("stats", {})

        return {
            "success": True,
            "tracks": tracks,
            "monthly_listeners": stats.get("monthlyListeners"),
            "follower_count": stats.get("followers"),
        }

    def update_secrets(self):
        """Download latest TOTP secrets from remote source."""
        try:
            resp = std_requests.get(SECRETS_URL, timeout=10)
            resp.raise_for_status()
            new_secrets = resp.json()

            if isinstance(new_secrets, dict) and new_secrets:
                SECRET_CIPHER_DICT.update(new_secrets)
                highest = max(int(v) for v in SECRET_CIPHER_DICT)
                print(f"🔑 Updated Spotify TOTP secrets (latest version: {highest})")
                return True
        except Exception as e:
            print(f"⚠️ Failed to update TOTP secrets: {e}")
        return False
