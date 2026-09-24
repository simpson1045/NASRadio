# Disable eventlet's greendns resolver. It queries DNS servers directly over UDP
# and bypasses the OS resolver (on Windows that breaks NRPT rules such as
# Tailscale MagicDNS names). With this flag eventlet falls back to the stdlib
# getaddrinfo via a thread pool, which honours the full system resolver.
# MUST be set before `import eventlet`, so .env can't carry it - load_dotenv runs later.
import os
os.environ.setdefault('EVENTLET_NO_GREENDNS', 'yes')

import eventlet
eventlet.monkey_patch()  # MUST be first — makes socket, time.sleep, etc. cooperative

# Make psycopg2 cooperative under eventlet. Without this, every DB query blocks
# the single event-loop thread, so concurrent queries SERIALIZE — that's what
# made a burst of /favorites/check calls each hold a pooled connection for ~3.6s
# and exhaust the pool. patch_psycopg installs a wait callback so a query yields
# to other greenthreads while it waits on the database. MUST run after
# monkey_patch and before any psycopg2 connection is opened.
from psycogreen.eventlet import patch_psycopg
patch_psycopg()

# Install log capture BEFORE any print statements so we catch everything
from app.log_service import log_service
log_service.install()

from app import create_app
from app.extensions import socketio, safe_emit
from app.models import Database
from app.scanner import MusicScanner
from app.config import Config
from app.backup import DatabaseBackup
import sys
import faulthandler

# Crash diagnostics. Dump a native stack on a hard/fatal crash (segfault in a C
# extension like psycopg2/PIL/mutagen, etc.), kept in a dedicated line-buffered
# file so it survives the process dying. Cheap general safety net — only writes
# when something actually faults. (Note: the silent code-1 exits on 2026-06-23
# were NOT a bug — another session was taskkill'ing python processes on this
# box; an external kill leaves no trace and faulthandler can't catch it either.)
_crash_log = open(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs", "crash.log"),
    "a", buffering=1,
)
faulthandler.enable(file=_crash_log, all_threads=True)


def main():
    """Main entry point for NASRadio backend"""
    config = Config()

    # Initialize database
    print("🎵 NASRadio Backend Starting...")
    db = Database(config.DATABASE_URL, migrate=True)  # the one place the schema is migrated

    # Note: SQLite backup disabled - PostgreSQL uses pg_dump for backups
    # backup = DatabaseBackup(config.DATABASE_PATH)
    # backup.create_backup()
    # backup.start_scheduled_backups(interval_hours=24)

    # Check if we should scan library on startup
    if len(sys.argv) > 1 and sys.argv[1] == "--scan":
        print("\n📂 Scanning music library...")
        scanner = MusicScanner(db)
        scanner.scan_library()
        print("\n")

    # Create Flask app
    app = create_app()
    print(f"🚀 Starting server on {config.HOST}:{config.PORT}")
    print(f"📁 Music library: {config.MUSIC_LIBRARY_PATH}")
    print(f"💾 Database: PostgreSQL")
    print(f"🔌 WebSocket enabled")
    print(f"\n✅ Server ready! API available at http://localhost:{config.PORT}/api/")

    # Run with SocketIO instead of app.run.
    # keepalive=False: close each HTTP connection after its response instead of
    # holding it open. A client that opens a fresh connection per request and
    # doesn't reuse it (the Android app hammering /api/artwork ~2.5x/sec while a
    # MediaSession update runs every 0.4s) would otherwise leave hundreds of
    # connections parked in eventlet's hub -> they pile up until the Windows
    # select() 512-FD cap and the worker crashes. Closing promptly removes them
    # from the hub so the watched-FD count stays flat. (Forwarded straight to
    # eventlet.wsgi.server by flask_socketio.)
    try:
        # If music was playing on the TV when this process last went down,
        # put it back (same queue, track and second). Only here — the real
        # server entry point — never from create_app, which scripts also call.
        from app.cast_sender import schedule_auto_resume
        schedule_auto_resume()

        socketio.run(
            app,
            host=config.HOST,
            port=config.PORT,
            debug=config.DEBUG,
            keepalive=False,
        )
    except BaseException:
        # Log ANY exit from the server loop, including SystemExit, which exits
        # with no traceback by default — that's what made the 2026-06-23 code-1
        # crashes invisible. Re-raise so the supervisor still restarts us.
        import traceback
        print("[CRASH] server loop exited unexpectedly:\n" + traceback.format_exc())
        raise


if __name__ == "__main__":
    main()
