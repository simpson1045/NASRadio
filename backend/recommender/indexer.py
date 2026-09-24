"""
Podcast Recommendation Indexer
Fetches podcasts from Podcast Index API, generates sentence embeddings,
and saves the index to disk for the recommendation service.
"""

import hashlib
import json
import os
import pickle
import re
import sys
import time
import threading

import numpy as np
import requests
from sentence_transformers import SentenceTransformer

# Add parent dir so we can import config
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from app.config import Config
from app.spotify_playcount import SpotifyPlayCount

DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
INDEX_PATH = os.path.join(DATA_DIR, "podcast_index.pkl")
PI_BASE = "https://api.podcastindex.org/api/1.0"


def pi_auth_headers():
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


def pi_get(endpoint, params=None):
    resp = requests.get(
        f"{PI_BASE}/{endpoint}",
        headers=pi_auth_headers(),
        params=params or {},
        timeout=15,
    )
    resp.raise_for_status()
    return resp.json()


def fetch_podcasts():
    """Fetch a diverse corpus of podcasts from Podcast Index."""
    seen_ids = set()
    podcasts = []

    def add_feeds(feeds):
        for f in feeds:
            pid = f.get("id")
            if pid and pid not in seen_ids:
                # Only English podcasts with episodes
                lang = (f.get("language") or "en").lower()
                if not lang.startswith("en"):
                    continue
                if (f.get("episodeCount") or 0) < 2:
                    continue
                if f.get("dead", 0) == 1:
                    continue

                desc = f.get("description", "")
                # Strip HTML
                desc = re.sub(r"<[^>]*>", " ", desc).strip()
                if len(desc) < 20:
                    continue

                seen_ids.add(pid)
                podcasts.append({
                    "id": pid,
                    "title": f.get("title", ""),
                    "author": f.get("author", ""),
                    "description": desc,
                    "artwork": f.get("artwork") or f.get("image", ""),
                    "url": f.get("url", ""),
                    "categories": f.get("categories") or {},
                    "episodeCount": f.get("episodeCount", 0),
                })

    # 1. Get trending (max 100)
    print("Fetching trending podcasts...")
    try:
        data = pi_get("podcasts/trending", {"max": 100})
        add_feeds(data.get("feeds", []))
    except Exception as e:
        print(f"  Error: {e}")
    print(f"  Got {len(podcasts)} from trending")

    # 2. Get categories and fetch trending per category
    print("Fetching categories...")
    cats_data = pi_get("categories/list")
    categories = cats_data.get("feeds", [])
    print(f"  Found {len(categories)} categories")

    for cat in categories:
        cat_name = cat.get("name", "")
        if not cat_name:
            continue
        print(f"  Fetching trending in '{cat_name}'...")
        try:
            data = pi_get("podcasts/trending", {"max": 100, "lang": "en", "cat": cat_name})
            add_feeds(data.get("feeds", []))
        except Exception as e:
            print(f"    Error: {e}")
        time.sleep(0.3)  # Rate limiting

    print(f"After category sweep: {len(podcasts)} podcasts")

    # 3. Search popular terms to broaden the corpus
    search_terms = [
        "comedy", "true crime", "news", "science", "history", "technology",
        "sports", "music", "health", "business", "education", "politics",
        "gaming", "movies", "tv", "rewatch", "interview", "storytelling",
        "anime", "horror", "fantasy", "superhero", "marvel", "dc comics",
        "star wars", "dungeons dragons", "cooking", "travel", "parenting",
        "finance", "crypto", "ai artificial intelligence", "space",
        "psychology", "philosophy", "religion", "fiction", "mystery",
    ]

    for term in search_terms:
        print(f"  Searching '{term}'...")
        try:
            data = pi_get("search/byterm", {"q": term, "max": 50, "clean": 1})
            add_feeds(data.get("feeds", []))
        except Exception as e:
            print(f"    Error: {e}")
        time.sleep(0.3)

    print(f"After search sweep: {len(podcasts)} podcasts")
    return podcasts


def enrich_with_spotify_ratings(podcasts):
    """Look up each podcast on Spotify to get totalRatings as a popularity signal."""
    config = Config()
    if not config.SPOTIFY_SP_DC:
        print("No SPOTIFY_SP_DC configured, skipping Spotify ratings")
        return

    import spotipy
    from spotipy.oauth2 import SpotifyClientCredentials
    sp = spotipy.Spotify(auth_manager=SpotifyClientCredentials(
        client_id=config.SPOTIFY_CLIENT_ID,
        client_secret=config.SPOTIFY_CLIENT_SECRET,
    ))
    spc = SpotifyPlayCount(config.SPOTIFY_SP_DC)

    print(f"\nEnriching {len(podcasts)} podcasts with Spotify ratings...")
    found = 0
    for i, p in enumerate(podcasts):
        if i % 50 == 0 and i > 0:
            print(f"  Progress: {i}/{len(podcasts)} ({found} found)")

        try:
            # Search Spotify for this podcast
            results = sp.search(q=p["title"], type="show", limit=1, market="US")
            shows = results.get("shows", {}).get("items", [])
            if not shows:
                continue

            show_id = shows[0]["id"]

            # Get metadata via Pathfinder for ratings
            data = spc._pathfinder_request(
                operation_name="queryShowMetadataV2",
                variables={
                    "uri": f"spotify:show:{show_id}",
                    "includeContentCapabilityTrait": True,
                },
                sha256_hash="aaad798a17a43c0f443c45d630a83df39d2ca1062a090c2e4fb045d6b00ab360",
            )

            podcast_data = data.get("data", {}).get("podcastUnionV2", {})
            rating = podcast_data.get("rating", {}).get("averageRating", {})
            total_ratings = rating.get("totalRatings", 0)
            avg_rating = rating.get("average", 0)

            p["spotify_id"] = show_id
            p["totalRatings"] = total_ratings
            p["averageRating"] = avg_rating
            if total_ratings > 0:
                found += 1

            time.sleep(0.2)  # Rate limiting

        except Exception as e:
            # Skip silently — not all podcasts are on Spotify
            continue

    print(f"  Spotify ratings found for {found}/{len(podcasts)} podcasts")


def build_index(podcasts):
    """Generate sentence embeddings for all podcasts."""
    print(f"\nLoading sentence-transformers model...")
    model = SentenceTransformer("all-MiniLM-L6-v2")

    # Build text for embedding: title + description + category names
    texts = []
    for p in podcasts:
        cat_names = " ".join((p.get("categories") or {}).values())
        text = f"{p['title']}. {p['description']} {cat_names}"
        # Truncate to model's max (256 tokens ~ 1000 chars)
        texts.append(text[:1000])

    print(f"Generating embeddings for {len(texts)} podcasts...")
    embeddings = model.encode(texts, show_progress_bar=True, batch_size=64)

    # Build index
    index = {
        "podcasts": podcasts,
        "embeddings": np.array(embeddings, dtype=np.float32),
        "id_to_idx": {p["id"]: i for i, p in enumerate(podcasts)},
        "built_at": time.time(),
        "count": len(podcasts),
    }

    return index


def save_index(index):
    os.makedirs(DATA_DIR, exist_ok=True)
    with open(INDEX_PATH, "wb") as f:
        pickle.dump(index, f)
    size_mb = os.path.getsize(INDEX_PATH) / 1024 / 1024
    print(f"\nIndex saved to {INDEX_PATH} ({size_mb:.1f} MB)")
    print(f"Total podcasts: {index['count']}")


if __name__ == "__main__":
    print("=== Podcast Recommendation Indexer ===\n")
    start = time.time()

    podcasts = fetch_podcasts()
    if not podcasts:
        print("No podcasts fetched! Check API credentials.")
        sys.exit(1)

    # Spotify ratings are fetched on-demand in the service, not during indexing
    index = build_index(podcasts)
    save_index(index)

    elapsed = time.time() - start
    print(f"\nDone in {elapsed:.0f} seconds")
