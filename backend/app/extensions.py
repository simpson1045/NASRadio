from flask_socketio import SocketIO

# Importing config first guarantees .env is loaded before we read CORS settings
from app.config import cors_allowed_origins

# Create SocketIO instance globally (eventlet handles WebSocket disconnections gracefully).
# Socket.IO matches browser origins exactly (no wildcards). With no list it allows
# same-origin browsers and origin-less native clients (the Flutter app), which is
# the right default; public hostnames go in CORS_ALLOWED_ORIGINS.
socketio = SocketIO(
    cors_allowed_origins=cors_allowed_origins(None),
    async_mode="eventlet",
)


def safe_emit(event, data, **kwargs):
    """
    Safely emit a WebSocket event, catching race conditions during reconnection.
    Use this instead of socketio.emit() from background threads.
    """
    try:
        socketio.emit(event, data, **kwargs)
        socketio.sleep(0)  # Yield to eventlet so WebSocket messages actually send
    except (AssertionError, RuntimeError) as e:
        # Race condition during client reconnect - log and continue
        # The client will get the next update after reconnection completes
        print(f"⚠️ WebSocket emit skipped (client reconnecting): {e}")
    except Exception as e:
        print(f"⚠️ WebSocket emit failed: {e}")
