"""
Podcast Recommendation Service
Loads pre-built sentence embeddings index and serves similarity queries.
"""

import hashlib
import os
import pickle
import re
import sys
import time

import numpy as np
import requests
from flask import Flask, jsonify, request as flask_request

# Add parent dir for config access
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
INDEX_PATH = os.path.join(DATA_DIR, "podcast_index.pkl")

app = Flask(__name__)

# Global state
_index = None
_model = None
_spotify_sp = None
_spotify_spc = None


def _init_spotify():
    """Lazy-init Spotify clients for on-demand rating lookups."""
    global _spotify_sp, _spotify_spc
    if _spotify_sp is not None:
        return True
    try:
        from app.config import Config
        from app.spotify_playcount import SpotifyPlayCount
        import spotipy
        from spotipy.oauth2 import SpotifyClientCredentials

        config = Config()
        if not config.SPOTIFY_SP_DC or not config.SPOTIFY_CLIENT_ID:
            return False
        _spotify_sp = spotipy.Spotify(auth_manager=SpotifyClientCredentials(
            client_id=config.SPOTIFY_CLIENT_ID,
            client_secret=config.SPOTIFY_CLIENT_SECRET,
        ))
        _spotify_spc = SpotifyPlayCount(config.SPOTIFY_SP_DC)
        return True
    except Exception as e:
        print(f"Spotify init failed: {e}")
        return False


_ratings_cache = {}  # {title: {totalRatings, averageRating}} — persists for service lifetime


def _get_spotify_ratings(titles):
    """Look up Spotify totalRatings for a list of podcast titles. Returns {title: totalRatings}."""
    if not _init_spotify():
        return {}

    ratings = {}
    uncached = []
    for title in titles:
        if title in _ratings_cache:
            ratings[title] = _ratings_cache[title]
        else:
            uncached.append(title)

    # Only look up uncached titles, limit to 5 to keep response fast
    for title in uncached[:5]:
        try:
            results = _spotify_sp.search(q=title, type="show", limit=1, market="US")
            shows = results.get("shows", {}).get("items", [])
            if not shows:
                _ratings_cache[title] = {"totalRatings": 0, "averageRating": 0}
                continue
            show_id = shows[0]["id"]
            data = _spotify_spc._pathfinder_request(
                operation_name="queryShowMetadataV2",
                variables={
                    "uri": f"spotify:show:{show_id}",
                    "includeContentCapabilityTrait": True,
                },
                sha256_hash="aaad798a17a43c0f443c45d630a83df39d2ca1062a090c2e4fb045d6b00ab360",
            )
            rating_data = data.get("data", {}).get("podcastUnionV2", {}).get("rating", {}).get("averageRating", {})
            entry = {
                "totalRatings": rating_data.get("totalRatings", 0),
                "averageRating": round(rating_data.get("average", 0), 1),
            }
            _ratings_cache[title] = entry
            ratings[title] = entry
        except Exception:
            _ratings_cache[title] = {"totalRatings": 0, "averageRating": 0}
            continue
    return ratings


def load_index():
    global _index
    if not os.path.exists(INDEX_PATH):
        print("No index found. Run indexer.py first.")
        return False
    with open(INDEX_PATH, "rb") as f:
        _index = pickle.load(f)
    print(f"Loaded index: {_index['count']} podcasts, built at {time.ctime(_index['built_at'])}")
    return True


def get_model():
    global _model
    if _model is None:
        from sentence_transformers import SentenceTransformer
        _model = SentenceTransformer("all-MiniLM-L6-v2")
    return _model


def cosine_similarity(a, b_matrix):
    """Compute cosine similarity between vector a and all rows in b_matrix."""
    a_norm = a / (np.linalg.norm(a) + 1e-10)
    b_norms = b_matrix / (np.linalg.norm(b_matrix, axis=1, keepdims=True) + 1e-10)
    return np.dot(b_norms, a_norm)


def embed_text(text):
    """Generate embedding for a single text string."""
    model = get_model()
    return model.encode([text[:1000]])[0]


def pi_auth_headers():
    """Generate Podcast Index auth headers."""
    from app.config import Config
    config = Config()
    now = str(int(time.time()))
    auth_hash = hashlib.sha1(
        (config.PODCAST_INDEX_KEY + config.PODCAST_INDEX_SECRET + now).encode()
    ).hexdigest()
    return {
        "User-Agent": "NASRadio/1.0",
        "X-Auth-Key": config.PODCAST_INDEX_KEY,
        "X-Auth-Date": now,
        "Authorization": auth_hash,
    }


def lookup_podcast(podcast_id):
    """Look up a podcast by ID from Podcast Index API."""
    try:
        resp = requests.get(
            f"https://api.podcastindex.org/api/1.0/podcasts/byfeedid",
            headers=pi_auth_headers(),
            params={"id": podcast_id},
            timeout=10,
        )
        resp.raise_for_status()
        data = resp.json()
        feed = data.get("feed", {})
        if feed:
            desc = re.sub(r"<[^>]*>", " ", feed.get("description", "")).strip()
            cat_names = " ".join(feed.get("categories", {}).values())
            return {
                "id": feed.get("id"),
                "title": feed.get("title", ""),
                "author": feed.get("author", ""),
                "description": desc,
                "artwork": feed.get("artwork") or feed.get("image", ""),
                "url": feed.get("url", ""),
                "categories": feed.get("categories", {}),
                "episodeCount": feed.get("episodeCount", 0),
                "text": f"{feed.get('title', '')}. {desc} {cat_names}",
            }
    except Exception as e:
        print(f"Podcast Index lookup failed for {podcast_id}: {e}")
    return None


def find_by_title(title):
    """Search Podcast Index by title to find the feed ID."""
    try:
        resp = requests.get(
            f"https://api.podcastindex.org/api/1.0/search/byterm",
            headers=pi_auth_headers(),
            params={"q": title, "max": 1},
            timeout=10,
        )
        resp.raise_for_status()
        feeds = resp.json().get("feeds", [])
        if feeds:
            return feeds[0].get("id")
    except Exception as e:
        print(f"Title search failed for '{title}': {e}")
    return None


@app.route("/rating")
def rating():
    """Get Spotify rating for a single podcast by title."""
    title = flask_request.args.get("title", "")
    if not title:
        return jsonify({"error": "Provide 'title' parameter"}), 400

    ratings = _get_spotify_ratings([title])
    info = ratings.get(title, {"totalRatings": 0, "averageRating": 0})
    return jsonify(info)


@app.route("/health")
def health():
    if _index is None:
        return jsonify({"status": "no_index", "count": 0}), 503
    return jsonify({
        "status": "ok",
        "count": _index["count"],
        "built_at": time.ctime(_index["built_at"]),
        "built_ago_hours": round((time.time() - _index["built_at"]) / 3600, 1),
    })


@app.route("/similar")
def similar():
    """Find podcasts similar to the given one.

    Query params:
      id: Podcast Index feed ID
      title: Podcast title (used to look up ID if not provided)
      n: Number of results (default 10)
    """
    if _index is None:
        return jsonify({"error": "Index not loaded"}), 503

    podcast_id = flask_request.args.get("id", type=int)
    title = flask_request.args.get("title", "")
    n = flask_request.args.get("n", 10, type=int)

    # If no ID provided, look up by title
    if not podcast_id and title:
        podcast_id = find_by_title(title)
        if not podcast_id:
            return jsonify({"error": f"Could not find podcast: {title}", "feeds": []}), 404

    if not podcast_id:
        return jsonify({"error": "Provide 'id' or 'title' parameter"}), 400

    # Check if podcast is in our index
    idx = _index["id_to_idx"].get(podcast_id)

    if idx is not None:
        query_embedding = _index["embeddings"][idx]
    else:
        # Not in index — look up and embed on the fly
        podcast = lookup_podcast(podcast_id)
        if not podcast:
            return jsonify({"error": f"Podcast {podcast_id} not found", "feeds": []}), 404
        query_embedding = embed_text(podcast["text"])

    # Compute similarities
    sims = cosine_similarity(query_embedding, _index["embeddings"])

    # Get top candidates by pure similarity first (grab extra to filter dupes)
    top_indices = np.argsort(sims)[::-1][:n * 3]

    candidates = []
    seen_titles = set()
    for i in top_indices:
        i = int(i)
        p = _index["podcasts"][i]
        if p["id"] == podcast_id:
            continue
        title_lower = p["title"].lower()
        if title_lower in seen_titles:
            continue
        seen_titles.add(title_lower)
        candidates.append({
            "id": p["id"],
            "title": p["title"],
            "author": p["author"],
            "description": p["description"][:300],
            "artwork": p["artwork"],
            "url": p["url"],
            "categories": p["categories"],
            "episodeCount": p["episodeCount"],
            "similarity": round(float(sims[i]), 4),
        })
        if len(candidates) >= n + 5:
            break

    # Fetch Spotify ratings for candidates and re-rank
    spotify_ratings = _get_spotify_ratings([c["title"] for c in candidates])

    for c in candidates:
        rating_info = spotify_ratings.get(c["title"], {})
        total_ratings = rating_info.get("totalRatings", 0) if isinstance(rating_info, dict) else 0
        avg_rating = rating_info.get("averageRating", 0) if isinstance(rating_info, dict) else 0
        c["totalRatings"] = total_ratings
        c["averageRating"] = avg_rating
        # Blend: 60% similarity + 40% popularity (log-scaled ratings)
        pop_raw = total_ratings if total_ratings > 0 else c["episodeCount"]
        pop_score = np.log1p(pop_raw) / 10.0  # normalize roughly to 0-1 range
        c["score"] = round(0.6 * c["similarity"] + 0.4 * min(pop_score, 1.0), 4)

    # Sort by blended score
    candidates.sort(key=lambda c: c["score"], reverse=True)
    results = candidates[:n]

    return jsonify({
        "query_id": podcast_id,
        "feeds": results,
        "count": len(results),
    })


if __name__ == "__main__":
    print("=== Podcast Recommendation Service ===")
    if not load_index():
        print("WARNING: Starting without index. Run indexer.py to build one.")
    print("Starting on port 5003...")
    app.run(host="0.0.0.0", port=5003, debug=False)
