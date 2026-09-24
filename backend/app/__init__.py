import os
from flask import Flask, send_from_directory, abort
from flask_cors import CORS
from app.extensions import socketio, safe_emit
from app.config import Config, cors_allowed_origins

# Browser origins allowed by default: loopback plus the private LAN ranges.
# Anything public (your domain, a tailnet name) goes in CORS_ALLOWED_ORIGINS,
# which replaces this list entirely. Native apps aren't subject to CORS.
DEFAULT_CORS_ORIGINS = [
    r"http://localhost(:\d+)?",
    r"http://127\.0\.0\.1(:\d+)?",
    r"http://192\.168\.\d+\.\d+(:\d+)?",
    r"http://10\.\d+\.\d+\.\d+(:\d+)?",
    r"http://172\.(1[6-9]|2\d|3[01])\.\d+\.\d+(:\d+)?",
]


def create_app():
    """Create and configure Flask application"""
    app = Flask(__name__)
    app.config.from_object(Config)

    # Enable CORS for Flutter app — restrict to known origins
    # (CORS_ALLOWED_ORIGINS in .env replaces this list for self-hosters)
    CORS(app, origins=cors_allowed_origins(DEFAULT_CORS_ORIGINS))

    # Security headers
    @app.after_request
    def add_security_headers(response):
        response.headers['X-Content-Type-Options'] = 'nosniff'
        response.headers['X-Frame-Options'] = 'DENY'
        response.headers['X-XSS-Protection'] = '1; mode=block'
        response.headers['Referrer-Policy'] = 'strict-origin-when-cross-origin'
        return response

    # Initialize SocketIO with app
    socketio.init_app(app)

    # Import and register routes AFTER socketio is initialized
    from app.routes import api
    from app.update_routes import update_api

    app.register_blueprint(api)
    app.register_blueprint(update_api)

    # Party mode — its own blueprint with its OWN auth gate (public join/QR,
    # party-scoped guest tokens, full tokens for host endpoints).
    from app.party import party_api
    app.register_blueprint(party_api)

    # Headless cast sender — "Claude, play 5150 on the C2" (full-token gate).
    from app.cast_sender import cast_api
    app.register_blueprint(cast_api)

    # MusicBrainz release-editor seeding — full-token seed pages plus an
    # unauthenticated (signature-gated) callback that captures the new MBID.
    from app.musicbrainz_seed import mb_seed_api
    app.register_blueprint(mb_seed_api)

    # Admin settings API — runtime settings store, connection tests, services
    # summary (admin-only gate of its own). Backs the first-run wizard.
    from app.admin_settings import admin_api
    app.register_blueprint(admin_api)

    # Register device sync WebSocket handlers
    from app.device_sync import register_handlers as register_device_sync
    register_device_sync()

    # Serve Chromecast custom receiver files from /cast/
    cast_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'cast')

    @app.route('/cast/<path:filename>')
    def serve_cast_file(filename):
        """Serve custom Chromecast receiver files (HTML, CSS, JS)"""
        # Only allow specific file extensions for security
        allowed_ext = {'.html', '.css', '.js', '.png', '.svg', '.ico', '.woff', '.woff2', '.mp4'}
        ext = os.path.splitext(filename)[1].lower()
        if ext not in allowed_ext:
            abort(403)
        response = send_from_directory(cast_dir, filename)
        response.headers['Cache-Control'] = 'no-cache, no-store, must-revalidate'
        response.headers['Pragma'] = 'no-cache'
        response.headers['Expires'] = '0'
        return response

    # Auto-resume interrupted analysis on startup
    with app.app_context():
        try:
            from app.audio_analysis import check_and_resume_analysis

            config = Config()
            result = check_and_resume_analysis(config.DATABASE_URL)
            if result.get("resumed"):
                print(
                    f"🔄 Auto-resumed audio analysis ({result.get('remaining')} songs remaining)"
                )
            elif result.get("reason"):
                print(f"ℹ️ Audio analysis not resumed: {result.get('reason')}")
        except Exception as e:
            print(f"⚠️ Could not check for interrupted analysis: {e}")

        # Start What's Happening daily release checker
        try:
            from app.routes import start_whats_happening_scheduler

            start_whats_happening_scheduler(app)
        except Exception as e:
            print(f"⚠️ Could not start release checker: {e}")

        # Start RSS podcast feed refresh scheduler
        try:
            from app.routes import start_rss_refresh_scheduler

            start_rss_refresh_scheduler(app)
        except Exception as e:
            print(f"⚠️ Could not start RSS refresh scheduler: {e}")

        # Start the pipeline reconciler — self-healing sweep that keeps every
        # import transcoded (mobile AAC) + Essentia-analyzed even when the
        # one-shot scan-time triggers were missed (service down, nightly
        # restart killed a batch, yt-dlp import bypassed the scanner).
        try:
            from app.routes import start_pipeline_reconciler

            start_pipeline_reconciler(app)
        except Exception as e:
            print(f"⚠️ Could not start pipeline reconciler: {e}")

        # Keep the NAS SMB session warm so cold-stat stalls / skip cascades
        # can't happen after an idle stretch.
        try:
            from app.routes import start_smb_keepalive

            start_smb_keepalive(app)
        except Exception as e:
            print(f"⚠️ Could not start SMB keepalive: {e}")

        # Bound podcast download storage (delete completed + size cap)
        try:
            from app.routes import start_podcast_cleanup_scheduler

            start_podcast_cleanup_scheduler(app)
        except Exception as e:
            print(f"⚠️ Could not start podcast cleanup scheduler: {e}")

    return app
