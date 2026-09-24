"""
Authentication for the NASRadio API.

Stateless signed bearer tokens (itsdangerous, ships with Flask) — no session
table, no per-request token store. A token carries {uid, ver}; `ver` is the
user's `token_version`, so bumping that column in the DB instantly invalidates
every outstanding token for that user (password change / "log out everywhere" /
lost device). Passwords are hashed with werkzeug's scrypt.

The actual route guard lives in routes.py (@api.before_request) so it sits on
the same blueprint as the endpoints; this module is pure helpers with no Flask
blueprint import, to avoid a circular dependency.
"""

import functools

from flask import g, jsonify, request
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer
from werkzeug.security import check_password_hash, generate_password_hash

from app.config import Config
from app.models import Database

_TOKEN_SALT = "nasradio-auth-v1"
TOKEN_MAX_AGE = 30 * 24 * 60 * 60  # 30 days, in seconds
_DEFAULT_SECRET = "dev-secret-key-change-in-production"

# Endpoints (by Flask endpoint name) reachable WITHOUT a token.
EXEMPT_ENDPOINTS = {"api.auth_login", "api.ping", "api.setup_status", "api.setup_admin"}

# Media-scoped tokens (used in stream/artwork URLs that native players, image
# loaders, and Chromecast fetch directly) are accepted ONLY for read-only media
# delivery — never for the mutating API. So a leaked media URL can play a song
# but can't delete your library.
MEDIA_PATH_PREFIXES = (
    "/api/stream/",
    "/api/artwork/",
    "/api/artist-image/",
    "/api/rss/stream/",
    # HTTPS relay for plain-http station streams — the Chromecast fetches
    # this URL itself with the media token in the query string.
    "/api/station-proxy",
)


def is_media_request(path, method):
    return method == "GET" and any(path.startswith(p) for p in MEDIA_PATH_PREFIXES)

_db = None


def _get_db():
    global _db
    if _db is None:
        _db = Database(Config().DATABASE_URL)
    return _db


def _serializer():
    secret = Config().SECRET_KEY
    return URLSafeTimedSerializer(secret, salt=_TOKEN_SALT)


def secret_key_is_insecure():
    """True if SECRET_KEY is still the public default — tokens would be forgeable."""
    return Config().SECRET_KEY == _DEFAULT_SECRET


# ---- password helpers ----

def hash_password(password):
    return generate_password_hash(password)


def verify_password(password, password_hash):
    return check_password_hash(password_hash, password)


# ---- token helpers ----

def generate_token(user_id, token_version, scope="full"):
    return _serializer().dumps({"uid": user_id, "ver": token_version, "scope": scope})


# ---- party guest tokens ----
# Guests are NOT users: a party token is a signed {party_id, code, guest}
# blob on a separate salt. It can only reach /api/party/guest/* (the party
# blueprint's own gate enforces that) and dies with the party — ending the
# party invalidates every guest token at the DB check, no revocation
# plumbing needed.

_PARTY_TOKEN_SALT = "nasradio-party-guest-v1"
PARTY_TOKEN_MAX_AGE = 60 * 60 * 24  # one day of partying is plenty


def _party_serializer():
    return URLSafeTimedSerializer(Config().SECRET_KEY, salt=_PARTY_TOKEN_SALT)


def generate_party_token(party_id, code, guest_name):
    return _party_serializer().dumps(
        {"pid": party_id, "code": code, "guest": guest_name})


def resolve_party_token(token):
    """Signed-and-fresh check only — caller must still verify the party
    is ACTIVE in the DB (that's what kills tokens when the party ends)."""
    try:
        payload = _party_serializer().loads(token, max_age=PARTY_TOKEN_MAX_AGE)
    except (BadSignature, SignatureExpired, Exception):
        return None
    if not isinstance(payload, dict) or "pid" not in payload:
        return None
    return payload

def _decode_token(token):
    try:
        return _serializer().loads(token, max_age=TOKEN_MAX_AGE)
    except (BadSignature, SignatureExpired, Exception):
        return None


# ---- user lookups (own pooled connection, always returned) ----

def _row_to_user(row):
    if not row:
        return None
    return {
        "id": row["id"],
        "username": row["username"],
        "role": row["role"],
        "token_version": row["token_version"],
        "password_hash": row["password_hash"],
    }


def get_user_by_username(username):
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute(
            "SELECT id, username, password_hash, role, token_version FROM users WHERE LOWER(username) = LOWER(%s)",
            (username,),
        )
        return _row_to_user(cur.fetchone())
    finally:
        conn.close()


def get_user_by_id(user_id):
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute(
            "SELECT id, username, password_hash, role, token_version FROM users WHERE id = %s",
            (user_id,),
        )
        return _row_to_user(cur.fetchone())
    finally:
        conn.close()


def authenticate(username, password):
    """Return the user dict on valid credentials, else None."""
    user = get_user_by_username(username)
    if not user:
        return None
    if not verify_password(password, user["password_hash"]):
        return None
    return user


def resolve_token(token):
    """Verify a bearer token and return (user, scope), or (None, None).

    Re-reads token_version from the DB so a revoked/old token is rejected even
    before it expires. scope is "full" (normal session) or "media" (read-only,
    for URL-embedded stream/artwork tokens)."""
    payload = _decode_token(token)
    if not payload or "uid" not in payload:
        return None, None
    user = get_user_by_id(payload["uid"])
    if not user:
        return None, None
    if payload.get("ver") != user["token_version"]:
        return None, None  # token was revoked (version bumped)
    return user, payload.get("scope", "full")


def public_user(user):
    """Strip the password hash before returning a user over the API."""
    return {"id": user["id"], "username": user["username"], "role": user["role"]}


def current_user():
    return getattr(g, "user", None)


def current_user_id(default=1):
    """The logged-in user's id for data scoping. Falls back to `default`
    (admin, id 1) outside a request context — e.g. background jobs / CLI — so
    those keep working and attribute to the admin."""
    user = getattr(g, "user", None)
    return user["id"] if user else default


def require_admin(fn):
    """Decorator: 403 unless the authenticated user is an admin."""

    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        user = current_user()
        if not user or user.get("role") != "admin":
            return jsonify({"error": "Admin only"}), 403
        return fn(*args, **kwargs)

    return wrapper


def extract_bearer_token():
    """Pull the token from the Authorization header (or ?token= fallback)."""
    header = request.headers.get("Authorization", "")
    if header.startswith("Bearer "):
        return header[7:].strip()
    return request.args.get("token")


# ---- admin user management (used by the settings UI; mirrors manage_users.py) ----

def list_users():
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute("SELECT id, username, role, created_at FROM users ORDER BY id")
        return [
            {
                "id": r["id"],
                "username": r["username"],
                "role": r["role"],
                "created_at": r["created_at"].isoformat() if r["created_at"] else None,
            }
            for r in cur.fetchall()
        ]
    finally:
        conn.close()


def _admin_count(cursor):
    cursor.execute("SELECT COUNT(*) AS n FROM users WHERE role = 'admin'")
    return cursor.fetchone()["n"]


def create_user_account(username, password, role="user"):
    username = (username or "").strip()
    if not username:
        return {"success": False, "error": "Username required"}
    if role not in ("admin", "user"):
        return {"success": False, "error": "Role must be admin or user"}
    if len(password or "") < 8:
        return {"success": False, "error": "Password must be at least 8 characters"}
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute("SELECT id FROM users WHERE LOWER(username) = LOWER(%s)", (username,))
        if cur.fetchone():
            return {"success": False, "error": f"User '{username}' already exists"}
        cur.execute(
            "INSERT INTO users (username, password_hash, role) VALUES (%s, %s, %s) RETURNING id",
            (username, hash_password(password), role),
        )
        uid = cur.fetchone()["id"]
        conn.commit()
        return {"success": True, "id": uid}
    finally:
        conn.close()


def user_count():
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute("SELECT COUNT(*) AS n FROM users")
        return cur.fetchone()["n"]
    finally:
        conn.close()


def bootstrap_admin(username, password):
    """First-run only: create the initial admin while the users table is
    empty. The table lock makes two racing setup calls serialize, so exactly
    one succeeds; after that this always refuses and the normal admin-only
    user management takes over."""
    username = (username or "").strip()
    if not username:
        return {"success": False, "error": "Username required"}
    if len(password or "") < 8:
        return {"success": False, "error": "Password must be at least 8 characters"}
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute("LOCK TABLE users IN EXCLUSIVE MODE")
        cur.execute("SELECT COUNT(*) AS n FROM users")
        if cur.fetchone()["n"] > 0:
            conn.rollback()
            return {"success": False, "error": "Setup already completed", "status": 409}
        cur.execute(
            "INSERT INTO users (username, password_hash, role) VALUES (%s, %s, 'admin') RETURNING id",
            (username, hash_password(password)),
        )
        uid = cur.fetchone()["id"]
        conn.commit()
        return {"success": True, "id": uid}
    finally:
        conn.close()


def set_user_password(user_id, password):
    if len(password or "") < 8:
        return {"success": False, "error": "Password must be at least 8 characters"}
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute(
            "UPDATE users SET password_hash = %s, token_version = token_version + 1 WHERE id = %s",
            (hash_password(password), user_id),
        )
        conn.commit()
        return {"success": cur.rowcount > 0}
    finally:
        conn.close()


def set_user_role(user_id, role, acting_user_id=None):
    if role not in ("admin", "user"):
        return {"success": False, "error": "Role must be admin or user"}
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        # Don't let the last admin demote themselves into a lockout.
        if role == "user":
            cur.execute("SELECT role FROM users WHERE id = %s", (user_id,))
            row = cur.fetchone()
            if row and row["role"] == "admin" and _admin_count(cur) <= 1:
                return {"success": False, "error": "Can't demote the only admin"}
        cur.execute("UPDATE users SET role = %s WHERE id = %s", (role, user_id))
        conn.commit()
        return {"success": cur.rowcount > 0}
    finally:
        conn.close()


def revoke_user(user_id):
    """Bump token_version → logs the user out of all devices."""
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute("UPDATE users SET token_version = token_version + 1 WHERE id = %s", (user_id,))
        conn.commit()
        return {"success": cur.rowcount > 0}
    finally:
        conn.close()


def delete_user_account(user_id):
    """Delete a user and their personal data (playlists + favorites)."""
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute("SELECT role FROM users WHERE id = %s", (user_id,))
        row = cur.fetchone()
        if not row:
            return {"success": False, "error": "User not found"}
        if row["role"] == "admin" and _admin_count(cur) <= 1:
            return {"success": False, "error": "Can't delete the only admin"}
        cur.execute(
            "DELETE FROM playlist_songs WHERE playlist_id IN (SELECT id FROM playlists WHERE user_id = %s)",
            (user_id,),
        )
        cur.execute("DELETE FROM playlists WHERE user_id = %s", (user_id,))
        cur.execute("DELETE FROM favorites WHERE user_id = %s", (user_id,))
        cur.execute("DELETE FROM users WHERE id = %s", (user_id,))
        conn.commit()
        return {"success": True}
    finally:
        conn.close()
