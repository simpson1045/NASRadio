# Essentia ML analysis service for NASRadio.
#
# Runs on any x86-64 Docker host next to the music library.
#
# The TensorFlow models (~32 MB) are fetched from Essentia's public model zoo
# at build time by download_models.py, so a fresh clone builds with no extra
# steps. Build offline by running that script first; present files are kept.
#
# NOTE: x86-64 only. essentia-tensorflow ships an x86-64 TF build (needs AVX).
# It will NOT run on ARM (e.g. Apple Silicon) without a native ARM rebuild.
FROM python:3.12-slim

# ffmpeg/libav: Essentia's MonoLoader decodes FLAC/MP3/M4A through these.
# libsndfile1: PCM/WAV backend.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg \
        libsndfile1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Pinned versions.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Models first (cached layer), then the service code.
COPY download_models.py .
RUN python3 download_models.py /app/models
COPY app.py .

# Quiet TF's startup spam.
ENV TF_CPP_MIN_LOG_LEVEL=3

EXPOSE 5005

# Music is bind-mounted read-only at /mnt/music by docker-compose; the backend
# maps its /music paths to that mount when it calls this service.
# -u: unbuffered stdout so per-file log lines reach docker logs immediately.
CMD ["python3", "-u", "app.py"]
