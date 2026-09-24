# Contributing to NASRadio

Thanks for looking. This project grew out of one person's library, so the most
useful contributions right now are reports of what breaks on a different setup,
followed by fixes for those.

## Reporting a problem

Open an issue with: what you did, what happened, what you expected, your host
(OS, Docker or native), the app platform, and any backend log lines
(`docker compose logs backend` or `backend/logs/`). Screenshots help for app
issues.

## Development setup

You need PostgreSQL, Python 3.12, ffmpeg, and the Flutter SDK for the app.

Backend:

```bash
cd backend
python -m venv venv && . venv/bin/activate
pip install -r requirements.txt
cp .env.example .env            # DATABASE_URL + MUSIC_LIBRARY_PATH; point at a small test library
mkdir -p logs data
python run.py                   # creates the schema on first start, listens on :5002
```

App:

```bash
cd frontend
flutter pub get
flutter run -d windows          # or an Android device
```

On first launch the app asks for the server address; use `http://127.0.0.1:5002`.
A fresh database has no users, so the app offers to create the admin account,
then runs the setup wizard.

## Layout

- `backend/app/routes.py` holds most of the API. It is large; new features are
  welcome as their own blueprint (see `party.py`, `cast_sender.py`,
  `admin_settings.py`) rather than growing it further.
- `backend/app/settings.py` is the schema for every user-facing setting. Add a
  setting there, read it through `Config.KEY`, and it appears in the wizard and
  in Settings, Integrations with no app changes. Never hardcode a host, path,
  key or device.
- `backend/app/models.py` creates and migrates the schema at startup with
  `CREATE TABLE IF NOT EXISTS` and `ADD COLUMN IF NOT EXISTS`. Schema changes go
  there, additive only.
- `frontend/lib/services/api_service.dart` is the app's API client;
  `frontend/lib/widgets/integration_cards.dart` is the one list of settings
  cards shared by the wizard and Settings.
- `backend/cast/` is the Chromecast receiver page the backend serves.

## Rules of the road

- Nothing personal in the tree: no IPs, hostnames, domains, API keys or paths
  from your own install. Use a setting.
- Settings are runtime: read `Config.X` where you use it, do not copy it into a
  module constant at import time.
- Keep `flutter analyze` at zero errors and run `flutter test` before opening a
  pull request. The live first-run test needs an empty database:
  `NASRADIO_TEST_BACKEND=http://127.0.0.1:5002 flutter test`.
- One change per pull request, with a short description of what it does and
  why. Mention the platform you tested on.
- Dashes in docs and UI text are plain hyphens.

## Releases

Version and build number live in `frontend/pubspec.yaml`; `CHANGELOG.md` gets
an entry per release in the existing style. Release packaging is not yet
automated for contributors.
