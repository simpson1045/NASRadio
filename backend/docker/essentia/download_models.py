#!/usr/bin/env python3
"""Fetch the TensorFlow models the Essentia service needs from Essentia's
public model zoo (https://essentia.upf.edu/models/). About 32 MB in total.

Run at image build time (see Dockerfile) or by hand:
    python3 download_models.py [models_dir]
Files already present with a non-zero size are skipped, so re-runs are cheap.
"""
import os
import sys
import urllib.request

BASE = "https://essentia.upf.edu/models"

# (zoo path, file name) - .json metadata (class labels) sits next to each .pb
FILES = [
    ("feature-extractors/discogs-effnet", "discogs-effnet-bs64-1.pb"),
    ("classification-heads/genre_discogs400", "genre_discogs400-discogs-effnet-1.pb"),
    ("classification-heads/genre_discogs400", "genre_discogs400-discogs-effnet-1.json"),
    ("classification-heads/mtg_jamendo_instrument", "mtg_jamendo_instrument-discogs-effnet-1.pb"),
    ("classification-heads/mtg_jamendo_instrument", "mtg_jamendo_instrument-discogs-effnet-1.json"),
    ("classification-heads/mtg_jamendo_moodtheme", "mtg_jamendo_moodtheme-discogs-effnet-1.pb"),
    ("classification-heads/mtg_jamendo_moodtheme", "mtg_jamendo_moodtheme-discogs-effnet-1.json"),
]
for head in (
    "danceability", "gender", "mood_acoustic", "mood_aggressive", "mood_electronic",
    "mood_happy", "mood_party", "mood_relaxed", "mood_sad", "timbre", "tonal_atonal",
    "voice_instrumental",
):
    FILES.append((f"classification-heads/{head}", f"{head}-discogs-effnet-1.pb"))
    FILES.append((f"classification-heads/{head}", f"{head}-discogs-effnet-1.json"))


def main(models_dir):
    os.makedirs(models_dir, exist_ok=True)
    for zoo_path, name in FILES:
        dest = os.path.join(models_dir, name)
        if os.path.isfile(dest) and os.path.getsize(dest) > 0:
            print(f"  have {name}")
            continue
        url = f"{BASE}/{zoo_path}/{name}"
        print(f"  get  {name}", flush=True)
        try:
            with urllib.request.urlopen(url, timeout=120) as r, open(dest + ".part", "wb") as f:
                while True:
                    chunk = r.read(1 << 20)
                    if not chunk:
                        break
                    f.write(chunk)
            os.replace(dest + ".part", dest)
        except Exception as e:
            print(f"FAILED {url}: {e}", file=sys.stderr)
            return 1
    print(f"models ready in {models_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "models")))
