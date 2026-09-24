# NASRadio backend — Linux container image (TrueNAS/Z620 deployment).
# Build from the backend/ directory:  docker build -t nasradio-backend .
# Runtime expectations (see deploy/truenas/docker-compose.yml):
#   MUSIC_LIBRARY_PATH  local bind-mount of the music library (default /music)
#   DATABASE_URL        PostgreSQL DSN (no SQLite — Postgres since v1.x native migration)
#   /app/data, /app/logs  persistent volumes (waveforms, staging, crash/app logs)
FROM python:3.12-slim

WORKDIR /app

# System deps:
#   ffmpeg               transcoding, waveforms, HDCD detection, yt-dlp post-processing
#   wavpack              WV/TTA conversion in the import queue
#   libsndfile1          librosa/soundfile audio decoding
#   libchromaprint-tools fpcalc for AcoustID fingerprinting (pyacoustid)
#   gcc                  any sdist fallbacks during pip install
#   curl, unzip          deno installer + image healthcheck
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    ffmpeg \
    wavpack \
    libsndfile1 \
    libchromaprint-tools \
    curl \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# deno — yt-dlp uses it to solve YouTube's JS challenges
RUN curl -fsSL https://deno.land/install.sh | sh
ENV DENO_INSTALL="/root/.deno"
ENV PATH="$DENO_INSTALL/bin:$PATH"

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Application code only — data/, logs/, .env etc. are excluded via .dockerignore
COPY . .

ENV PYTHONUNBUFFERED=1

# run.py opens logs/crash.log at startup; data/ holds waveforms + staging
RUN mkdir -p /app/data /app/logs

EXPOSE 5002

# /api/ping is the unauthenticated liveness endpoint (/api/health needs auth)
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS http://localhost:5002/api/ping || exit 1

CMD ["python", "run.py"]
