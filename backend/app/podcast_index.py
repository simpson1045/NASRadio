import hashlib
import time
import requests
from app.config import Config

# In-memory cache with TTL
_cache = {}
_CACHE_TTL = 300  # 5 minutes


def _get_cached(key):
    """Return cached value if still fresh, else None."""
    entry = _cache.get(key)
    if entry and time.time() - entry['time'] < _CACHE_TTL:
        return entry['data']
    return None


def _set_cached(key, data):
    _cache[key] = {'data': data, 'time': time.time()}


class PodcastIndexClient:
    BASE_URL = "https://api.podcastindex.org/api/1.0"

    def __init__(self):
        config = Config()
        self.api_key = config.PODCAST_INDEX_KEY
        self.api_secret = config.PODCAST_INDEX_SECRET

    def _auth_headers(self):
        now = str(int(time.time()))
        auth_hash = hashlib.sha1(
            (self.api_key + self.api_secret + now).encode()
        ).hexdigest()
        return {
            "User-Agent": "NASRadio/1.0",
            "X-Auth-Key": self.api_key,
            "X-Auth-Date": now,
            "Authorization": auth_hash,
        }

    def _get(self, endpoint, params=None):
        """Make authenticated GET request to Podcast Index API."""
        resp = requests.get(
            f"{self.BASE_URL}/{endpoint}",
            headers=self._auth_headers(),
            params=params or {},
            timeout=10,
        )
        resp.raise_for_status()
        return resp.json()

    def search(self, query, max_results=20):
        """Search podcasts by term. Returns list of feed objects."""
        data = self._get("search/byterm", {
            "q": query,
            "max": max_results,
            "clean": 1,
            "fulltext": 1,
        })
        return data.get("feeds", [])

    def trending(self, max_results=20, lang="en", category=None):
        """Get trending podcasts. Cached for 5 minutes."""
        cache_key = f"trending:{max_results}:{lang}:{category}"
        cached = _get_cached(cache_key)
        if cached:
            return cached

        params = {"max": max_results, "lang": lang}
        if category:
            params["cat"] = category

        data = self._get("podcasts/trending", params)
        feeds = data.get("feeds", [])
        _set_cached(cache_key, feeds)
        return feeds

    def categories(self):
        """Get all podcast categories. Cached for 5 minutes."""
        cached = _get_cached("categories")
        if cached:
            return cached

        data = self._get("categories/list")
        cats = data.get("feeds", [])
        _set_cached("categories", cats)
        return cats
