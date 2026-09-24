# Roadmap

What is planned or wanted. Not a promise, and not in order. Open an issue if you
want to pick one up.

## Making it easy to run
- Generic Docker deployment: done. Native install docs: done. Next: a
  one-command install script and ARM images (Essentia is x86-64 only).
- Prebuilt app downloads (Android APK, Windows) attached to GitHub releases.
- Contributor CI: `flutter analyze` and the tests on every pull request.

## Multi-user
- "N listening now" badge and who is listening to what.
- A shared household queue any signed-in user can add to.
- Per-user listening stats and a household chart; listen-along.
- Per-user hiding of scan and maintenance controls is done; finer permissions
  (who may add downloads) are not.

## Cast
- Done: cast status reports shuffle and the source album or playlist, and
  `GET /api/cast/queue` returns the full queue next to the source's own order.
- Done: casts no longer stall mid-queue. The cause was a Postgres lock convoy
  (schema migrations run from helper processes); migrations now run only at
  startup and never take locks on a current schema. A single gentle track
  reload remains as a safety net.
- Repeat modes for headless casts.
- Gapless and crossfade on bitstream (surround) casts.

## Library
- Advanced library search filters.
- Similar-artist recommendations in the app (the backend already computes them).
- Unified podcast episode model (feature flag `PODCAST_UNIFIED_MODEL`).

## Housekeeping
- Split `backend/app/routes.py` into blueprints.
- Bump the `eventlet` pin so Python 3.13 works out of the box.
- Sign Android release builds with a project key instead of the debug key.
