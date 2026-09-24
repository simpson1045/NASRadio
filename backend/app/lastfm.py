import hashlib
import time
import eventlet
import requests
from app.models import Database
from app.config import Config

LASTFM_API_URL = "https://ws.audioscrobbler.com/2.0/"


class LastFM:
    """Handle Last.fm scrobbling integration"""

    def __init__(self):
        self.config = Config()
        self.db = Database(self.config.DATABASE_URL)

    def _get_credentials(self):
        """Get Last.fm config from DB as a dict"""
        conn = self.db.get_connection()
        cursor = self.db.get_cursor(conn)
        try:
            cursor.execute("SELECT key, value FROM lastfm_config")
            rows = cursor.fetchall()
            return {row["key"]: row["value"] for row in rows}
        except Exception:
            return {}
        finally:
            conn.close()

    # ---- read-only stats (public Last.fm methods: api_key + username only) ----

    @staticmethod
    def _pick_image(images):
        """Return the largest non-empty URL from a Last.fm image array."""
        best = None
        for im in images or []:
            url = im.get("#text")
            if url:
                best = url  # Last.fm orders small -> extralarge, so last wins
        return best

    def _read_call(self, method, extra=None):
        creds = self._get_credentials()
        api_key = creds.get("api_key")
        username = creds.get("username")
        if not api_key or not username:
            return None
        params = {
            "method": method,
            "user": username,
            "api_key": api_key,
            "format": "json",
        }
        if extra:
            params.update(extra)
        try:
            resp = requests.get(LASTFM_API_URL, params=params, timeout=8)
            if resp.status_code == 200:
                return resp.json()
        except Exception as e:
            print(f"Last.fm {method} failed: {e}")
        return None

    def get_stats(self, period="overall", limit=25):
        """One-shot bundle for the in-app stats screen: profile totals, top
        artists + top tracks for the period, and recent scrobbles."""
        if period not in ("7day", "1month", "3month", "6month", "12month", "overall"):
            period = "overall"

        # Fire all four calls concurrently as green threads (monkey-patched
        # requests cooperate) so the endpoint takes ~one call's time, not four.
        # NOTE: do NOT wrap this in eventlet.tpool — that runs on the small
        # native thread pool that streaming/SMB share, and a slow Last.fm
        # response there starves the whole backend.
        g_info = eventlet.spawn(self._read_call, "user.getInfo")
        g_artists = eventlet.spawn(
            self._read_call, "user.getTopArtists", {"period": period, "limit": limit}
        )
        g_tracks = eventlet.spawn(
            self._read_call, "user.getTopTracks", {"period": period, "limit": limit}
        )
        g_recent = eventlet.spawn(
            self._read_call, "user.getRecentTracks", {"limit": limit, "extended": 1}
        )
        info = g_info.wait()
        if info is None:
            return {"success": False, "error": "Last.fm not connected"}
        top_artists = g_artists.wait()
        top_tracks = g_tracks.wait()
        recent = g_recent.wait()

        def _int(v):
            try:
                return int(v)
            except (TypeError, ValueError):
                return 0

        user = (info or {}).get("user", {}) or {}
        reg = user.get("registered")
        registered = reg.get("#text") if isinstance(reg, dict) else reg

        artists = [
            {
                "name": a.get("name"),
                "playcount": _int(a.get("playcount")),
                "url": a.get("url"),
                "image": self._pick_image(a.get("image")),
            }
            for a in (top_artists or {}).get("topartists", {}).get("artist", [])
        ]
        tracks = [
            {
                "name": t.get("name"),
                "artist": (t.get("artist") or {}).get("name"),
                "playcount": _int(t.get("playcount")),
                "url": t.get("url"),
                "image": self._pick_image(t.get("image")),
            }
            for t in (top_tracks or {}).get("toptracks", {}).get("track", [])
        ]
        recent_list = []
        for t in (recent or {}).get("recenttracks", {}).get("track", []):
            artist = t.get("artist") or {}
            album = t.get("album") or {}
            date = t.get("date") or {}
            recent_list.append(
                {
                    "name": t.get("name"),
                    "artist": artist.get("name") or artist.get("#text"),
                    "album": album.get("#text"),
                    "url": t.get("url"),
                    "image": self._pick_image(t.get("image")),
                    "nowplaying": (t.get("@attr") or {}).get("nowplaying") == "true",
                    "date": date.get("#text"),
                }
            )

        return {
            "success": True,
            "period": period,
            "user": {
                "name": user.get("name"),
                "playcount": _int(user.get("playcount")),
                "artist_count": _int(user.get("artist_count")),
                "track_count": _int(user.get("track_count")),
                "album_count": _int(user.get("album_count")),
                "registered": registered,
                "url": user.get("url"),
                "image": self._pick_image(user.get("image")),
            },
            "top_artists": artists,
            "top_tracks": tracks,
            "recent": recent_list,
        }

    def _api_sig(self, params, secret):
        """Generate Last.fm API method signature (md5 of sorted key+value pairs + secret)"""
        sig_str = "".join(f"{k}{v}" for k, v in sorted(params.items()))
        sig_str += secret
        return hashlib.md5(sig_str.encode("utf-8")).hexdigest()

    def is_configured(self):
        """Check if Last.fm has a session key (fully authenticated)"""
        creds = self._get_credentials()
        return bool(creds.get("session_key"))

    def is_enabled(self):
        """Check if scrobbling is enabled"""
        creds = self._get_credentials()
        return creds.get("enabled", "true") == "true" and bool(
            creds.get("session_key")
        )

    def get_auth_token(self):
        """Get a request token from Last.fm API"""
        creds = self._get_credentials()
        api_key = creds.get("api_key")
        secret = creds.get("api_secret")
        if not api_key or not secret:
            return None

        params = {
            "method": "auth.getToken",
            "api_key": api_key,
        }
        params["api_sig"] = self._api_sig(params, secret)
        params["format"] = "json"

        resp = requests.get(LASTFM_API_URL, params=params, timeout=10)
        data = resp.json()
        token = data.get("token")

        if token:
            # Store token for later exchange
            conn = self.db.get_connection()
            cursor = self.db.get_cursor(conn)
            try:
                cursor.execute(
                    """INSERT INTO lastfm_config (key, value) VALUES ('pending_token', %s)
                       ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value""",
                    (token,),
                )
                conn.commit()
            finally:
                conn.close()

        return token

    def get_auth_url(self):
        """Generate Last.fm auth URL using a fresh token"""
        creds = self._get_credentials()
        api_key = creds.get("api_key")
        if not api_key:
            return None

        token = self.get_auth_token()
        if token:
            return f"https://www.last.fm/api/auth/?api_key={api_key}&token={token}"
        return None

    def complete_auth(self):
        """Exchange stored pending token for a session key (call after user approves in browser)"""
        creds = self._get_credentials()
        api_key = creds.get("api_key")
        secret = creds.get("api_secret")
        token = creds.get("pending_token")

        if not all([api_key, secret, token]):
            return {"success": False, "error": "Missing credentials or pending token"}

        params = {
            "method": "auth.getSession",
            "api_key": api_key,
            "token": token,
        }
        params["api_sig"] = self._api_sig(params, secret)
        params["format"] = "json"

        resp = requests.get(LASTFM_API_URL, params=params, timeout=10)
        data = resp.json()

        if "session" in data:
            session_key = data["session"]["key"]
            username = data["session"]["name"]

            conn = self.db.get_connection()
            cursor = self.db.get_cursor(conn)
            try:
                for key, value in [
                    ("session_key", session_key),
                    ("username", username),
                ]:
                    cursor.execute(
                        """INSERT INTO lastfm_config (key, value) VALUES (%s, %s)
                           ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value""",
                        (key, value),
                    )
                # Clean up pending token
                cursor.execute(
                    "DELETE FROM lastfm_config WHERE key = 'pending_token'"
                )
                conn.commit()
                return {"success": True, "username": username}
            finally:
                conn.close()
        else:
            error = data.get("error", 0)
            message = data.get("message", "Authentication failed")
            # Error 14 = token not yet authorized
            if error == 14:
                return {
                    "success": False,
                    "error": "Token not yet authorized. Please approve in your browser first.",
                }
            return {"success": False, "error": message}

    def scrobble(self, artist, track, album=None, duration=None, timestamp=None):
        """Scrobble a completed track to Last.fm"""
        creds = self._get_credentials()
        session_key = creds.get("session_key")
        api_key = creds.get("api_key")
        secret = creds.get("api_secret")

        if not session_key:
            return {"success": False, "error": "Not authenticated"}

        params = {
            "method": "track.scrobble",
            "api_key": api_key,
            "sk": session_key,
            "artist": artist,
            "track": track,
            "timestamp": str(timestamp or int(time.time())),
        }
        if album:
            params["album"] = album
        if duration:
            params["duration"] = str(duration)

        params["api_sig"] = self._api_sig(params, secret)
        params["format"] = "json"

        try:
            resp = requests.post(LASTFM_API_URL, data=params, timeout=10)
            data = resp.json()
            return {"success": "scrobbles" in data}
        except Exception as e:
            return {"success": False, "error": str(e)}

    def update_now_playing(self, artist, track, album=None, duration=None):
        """Send 'now playing' notification to Last.fm"""
        creds = self._get_credentials()
        session_key = creds.get("session_key")
        api_key = creds.get("api_key")
        secret = creds.get("api_secret")

        if not session_key:
            return

        params = {
            "method": "track.updateNowPlaying",
            "api_key": api_key,
            "sk": session_key,
            "artist": artist,
            "track": track,
        }
        if album:
            params["album"] = album
        if duration:
            params["duration"] = str(duration)

        params["api_sig"] = self._api_sig(params, secret)
        params["format"] = "json"

        try:
            requests.post(LASTFM_API_URL, data=params, timeout=10)
        except Exception:
            pass  # Fire and forget for now playing
