# NASRadio

Self-hosted music server and player for your own library. Point it at a folder
of music, and every phone, desktop and TV in the house gets a full-featured
player: artists, albums, playlists, podcasts, internet radio, lyrics, Chromecast,
Android Auto, and a Windows desktop client, all streaming from your hardware.

NASRadio is a Python backend (Flask, PostgreSQL) plus a Flutter app. It was
built for one household's 40,000-track library and is being opened up so
others can run it. Expect rough edges around the parts that were never
exercised outside that one install, and please report them.

## Features

**Library**
- Scans MP3, FLAC, M4A, AAC, OGG, Opus, WAV, WavPack, APE, AIFF, DSF and DFF.
- Artists, albums, genres, years, recently added and most played, with
  embedded and folder artwork plus Last.fm and fanart.tv lookups.
- Album editions and grouping, artist and album merge tools, duplicate review,
  folder exclusions.
- Full artist discographies from MusicBrainz, including releases you do not
  own yet, and a MusicBrainz release submission tool for what MusicBrainz lacks.
- Surround and Dolby Atmos detection with badges, HDCD detection, and spectral
  analysis that flags lossy files masquerading as lossless.
- AcoustID fingerprinting for untagged files, waveform seek bars, per-track
  chapters from YouTube.

**Playback**
- Gapless, crossfade, ReplayGain, playback speed, queue and shuffle, favourites,
  playlists with import from Spotify and M3U8, synced lyrics.
- Streams originals on the LAN and pre-transcoded AAC on mobile data.
- Chromecast with a custom receiver (now-playing screen, lyrics, party mode QR),
  plus a headless cast mode where the server itself casts to a TV and can drive
  a Denon/Marantz receiver for voice-assistant and automation setups.
- Android Auto, a home-screen widget, remote control of one device from
  another, and multi-user accounts with admin and user roles.

**Podcasts and radio**
- RSS subscriptions with downloads, chapters, OPML import and export, Podcast
  Index search, and an optional recommendation sidecar.
- Internet radio station directory with live now-playing metadata.

**Optional integrations**
- Prowlarr search, Transmission downloads and an import queue that files
  finished downloads into the library; Lidarr lookups.
- Essentia analysis sidecar: genres, mood, BPM, key and ReplayGain per track.
- Transcode sidecar that pre-bakes mobile AAC copies.
- Last.fm scrobbling, Spotify play counts and history, weather alerts.

## Requirements

- A Linux host with Docker and Docker Compose (x86-64; the Essentia sidecar has
  no ARM build). Any NAS that runs Docker is fine.
- Your music in a folder that host can see.
- A client: Android phone or TV, or Windows. macOS and Linux desktop builds
  exist in the tree but are not exercised.

Prowlarr, Transmission, Lidarr, Spotify and the other integrations are optional
and are configured from inside the app.

## Quick start (Docker)

```bash
git clone https://github.com/simpson1045/NASRadio.git
cd NASRadio
cp .env.example .env        # set MUSIC_DIR; everything else is optional
docker compose up -d        # Postgres + backend on port 5002
```

Add the analysis sidecars when you want them (they are heavier and x86-64 only):

```bash
docker compose --profile analysis up -d
```

Then install the app and open it:

1. The app asks for your server address. Enter `http://<host>:5002` and press
   Test, then Continue.
2. A fresh server has no accounts. Create the admin account.
3. The setup wizard walks through the music folder, optional download stack,
   metadata APIs, public address and living-room devices. Every page has a
   Test button and every page can be skipped. Finish with "Scan library".

Everything the wizard sets is also under Settings, Integrations (admin only)
and takes effect immediately without a restart. Values in `.env` are the
fallback; values saved in the app override them.

## Running without Docker

You need Python 3.12, PostgreSQL 15 or newer, and ffmpeg on the path
(plus `fpcalc` from chromaprint for AcoustID and `wavpack` for WV imports).

```bash
createuser nasradio -P && createdb -O nasradio nasradio
cd backend
python -m venv venv && . venv/bin/activate      # venv\Scripts\activate on Windows
pip install -r requirements.txt
cp .env.example .env                            # DATABASE_URL and MUSIC_LIBRARY_PATH at minimum
mkdir -p logs data
python run.py
```

The schema is created on first start. The API listens on port 5002; then
follow the same first-run steps in the app. Python 3.13 works if you upgrade
`eventlet` to 0.41 or newer.

## The app

The Flutter project is in `frontend/`. With the Flutter SDK installed:

```bash
cd frontend
flutter pub get
flutter run -d windows        # or an Android device / emulator
flutter build apk --release   # Android
flutter build windows         # Windows
```

Release builds should be signed with your own keystore; see
`frontend/android/app/build.gradle.kts`.

## How it fits together

```
frontend/            Flutter app (phone, TV layout, Windows desktop)
backend/app/         Flask API, Socket.IO, scanner, cast sender, party mode ...
backend/app/settings.py   the settings schema (env name, default, type, help)
backend/cast/        Chromecast custom receiver (HTML/JS served by the backend)
backend/docker/      Essentia and transcode sidecars
backend/recommender/ optional podcast recommender sidecar
docker-compose.yml   the whole stack
```

Settings resolve in this order: value saved in the app, then `.env`, then the
default in `backend/app/settings.py`. Adding a setting there is enough for it
to appear in the wizard and in Settings, Integrations.

Authentication is stateless signed tokens. Every API route needs one except
`/api/ping`, login and the first-run setup endpoints. Media URLs carry a
read-only token so players, image loaders and Chromecast can fetch them
directly without being able to reach the rest of the API.

## Tests

```bash
cd frontend && flutter test                      # widget tests
NASRADIO_TEST_BACKEND=http://127.0.0.1:5002 flutter test   # plus the live first-run flow, against an EMPTY database
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, layout and how to send a
change, and [ROADMAP.md](ROADMAP.md) for what is planned.

## License

MIT. See [LICENSE](LICENSE).
