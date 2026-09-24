# NASRadio batch transcode service.
#
# Runs on the NAS via Container Manager (or any Docker host). Pre-transcodes
# lossless music to AAC for cellular playback, reading the music LOCALLY and
# writing the shared .transcode_cache. The latency-critical on-demand path
# stays on the PC backend (local ffmpeg) — only the batch worker lives here.
#
# Unlike the Essentia image, the service code IS committed to the repo
# (transcode_service.py, env-configurable) — no models, nothing to copy in.
FROM python:3.12-slim

# ffmpeg does the actual transcoding.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY transcode_service.py .

EXPOSE 5006

# Config comes from the environment (see docker-compose.yml / README):
#   TRANSCODE_DB_HOST  → the PC running PostgreSQL (must be opened to the NAS)
#   TRANSCODE_MUSIC_DIR (default /mnt/music)  — bind-mounted music, read-write
#   TRANSCODE_CACHE_DIR (default /mnt/transcode_cache) — bind-mounted cache
CMD ["python3", "transcode_service.py"]
