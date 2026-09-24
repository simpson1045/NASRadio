# Sidecar services

Two optional containers that run next to the backend and read the music
library directly. Both are started by the root `docker-compose.yml` with
`docker compose --profile analysis up -d`.

## essentia/

Audio analysis with Essentia and TensorFlow: genres, mood, danceability, BPM,
key, instruments and ReplayGain per track. The backend calls it after scans
and from the pipeline reconciler; results show up as genres, moods and
ReplayGain in the app.

- The models (about 32 MB) come from Essentia's public model zoo and are
  downloaded by `download_models.py` when the image builds. Run it by hand
  first if you build offline.
- x86-64 only: `essentia-tensorflow` has no ARM build.
- Music is mounted read-only at `/mnt/music`.
- Health: `GET /health` on port 5005.

## transcode/

Pre-transcodes lossless tracks to AAC (320k high, 128k medium, and 96k MP3
low) into `<music>/.transcode_cache` so mobile playback does not wait on
ffmpeg. Talks to the same Postgres as the backend. Configuration is all
environment variables; see the comments in `transcode_service.py` and the
compose file.

Without this sidecar the backend transcodes on demand with its own ffmpeg.
