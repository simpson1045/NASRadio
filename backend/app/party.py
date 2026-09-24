"""Party Mode — guests scan a QR on the TV, search the host's library,
and add tracks to the live queue.

v1 flow (spec in HANDOFF.md):
  host app  → POST /api/party/start          (full token)   → code + urls
  TV        ← PARTY_MODE custom message (cast) shows the QR overlay
  guest     → scans QR → GET /party/<code>   (public)       → landing page
  guest app → POST /api/party/<code>/join    (public)       → party token
  guest app → GET  /api/party/guest/search   (party token)  → library hits
  guest app → POST /api/party/guest/add      (party token)  → socketio
                'party_track_added' → HOST app inserts into the real queue
  host app  → POST /api/party/end            (full token)   → tokens die

The host phone stays the queue authority (meshes with cast UP_NEXT).
Guest tokens only pass THIS blueprint's gate — the main api blueprint
never sees them, so a leaked party token can't touch the real API.
"""

import io
import random
import string

from flask import Blueprint, g, jsonify, request, send_file

from app import auth
from app.config import Config
from app.extensions import safe_emit
from app.models import Database

party_api = Blueprint("party", __name__)
config = Config()

# Public base used in join links / QR payloads. Guests are usually NOT on
# the LAN, so the configured Public base URL is the right default; fall
# back to however this request reached us.
def _base_url():
    return Config.PUBLIC_BASE_URL or request.host_url.rstrip("/")

_MAX_GUEST_NAME = 24
_SEARCH_LIMIT = 25

_tables_ready = False


def _get_db():
    return Database(config.DATABASE_URL)


def _ensure_tables():
    global _tables_ready
    if _tables_ready:
        return
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS party_sessions (
                id SERIAL PRIMARY KEY,
                code TEXT UNIQUE NOT NULL,
                host_user_id INTEGER,
                active INTEGER DEFAULT 1,
                created_at TIMESTAMPTZ DEFAULT NOW(),
                ended_at TIMESTAMPTZ
            );
            CREATE TABLE IF NOT EXISTS party_log (
                id SERIAL PRIMARY KEY,
                party_id INTEGER NOT NULL,
                guest_name TEXT NOT NULL,
                song_id INTEGER NOT NULL,
                created_at TIMESTAMPTZ DEFAULT NOW()
            );
            """
        )
        conn.commit()
        _tables_ready = True
    finally:
        conn.close()


def _active_party_by_code(code):
    _ensure_tables()
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute(
            "SELECT id, code, host_user_id, created_at FROM party_sessions "
            "WHERE code = %s AND active = 1",
            (code,),
        )
        row = cur.fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


# ---- auth gate ---------------------------------------------------------
# This blueprint does NOT sit behind routes.py's api gate, so it enforces
# its own three tiers: public (join/QR/landing), party token (guest
# search/add), full token (host start/end/state).

_PUBLIC_ENDPOINTS = {"party.party_qr", "party.party_landing", "party.party_join"}
_GUEST_ENDPOINTS = {"party.party_guest_search", "party.party_guest_add"}


@party_api.before_request
def _party_gate():
    if request.method == "OPTIONS":
        return None
    ep = request.endpoint or ""
    if ep in _PUBLIC_ENDPOINTS:
        return None

    token = auth.extract_bearer_token()
    if not token:
        return jsonify({"error": "Authentication required"}), 401

    if ep in _GUEST_ENDPOINTS:
        info = auth.resolve_party_token(token)
        if not info:
            return jsonify({"error": "Invalid or expired party token"}), 401
        party = _active_party_by_code(info.get("code") or "")
        if not party or party["id"] != info.get("pid"):
            return jsonify({"error": "This party has ended"}), 410
        g.party = party
        g.party_guest = (info.get("guest") or "Guest")[:_MAX_GUEST_NAME]
        return None

    # Host endpoints: full-scope user token only.
    user, scope = auth.resolve_token(token)
    if not user or scope != "full":
        return jsonify({"error": "Host authentication required"}), 401
    g.user = user
    return None


# ---- host endpoints ----------------------------------------------------

def _new_code():
    # Unambiguous alphabet (no 0/O/1/I) — guests may type it manually.
    alphabet = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"
    return "".join(random.choice(alphabet) for _ in range(5))


@party_api.route("/api/party/start", methods=["POST"])
def party_start():
    _ensure_tables()
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        # One active party per host — starting a new one ends the old.
        cur.execute(
            "UPDATE party_sessions SET active = 0, ended_at = NOW() "
            "WHERE host_user_id = %s AND active = 1",
            (g.user["id"],),
        )
        code = _new_code()
        cur.execute(
            "INSERT INTO party_sessions (code, host_user_id) VALUES (%s, %s) "
            "RETURNING id, code",
            (code, g.user["id"]),
        )
        row = cur.fetchone()
        conn.commit()
        print(f"🎉 [party] Started party {row['code']} (host user {g.user['id']})")
        return jsonify({
            "id": row["id"],
            "code": row["code"],
            "join_url": f"{_base_url()}/party/{row['code']}",
            "qr_url": f"{_base_url()}/api/party/qr/{row['code']}.png",
        })
    except Exception as e:
        conn.rollback()
        return jsonify({"error": str(e)}), 500
    finally:
        conn.close()


@party_api.route("/api/party/end", methods=["POST"])
def party_end():
    _ensure_tables()
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute(
            "UPDATE party_sessions SET active = 0, ended_at = NOW() "
            "WHERE host_user_id = %s AND active = 1 RETURNING code",
            (g.user["id"],),
        )
        rows = cur.fetchall()
        conn.commit()
        for r in rows:
            print(f"🎉 [party] Ended party {r['code']}")
        return jsonify({"ended": [r["code"] for r in rows]})
    except Exception as e:
        conn.rollback()
        return jsonify({"error": str(e)}), 500
    finally:
        conn.close()


@party_api.route("/api/party/state", methods=["GET"])
def party_state():
    """Host's view: active party + who added what (for the queue screen)."""
    _ensure_tables()
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute(
            "SELECT id, code, created_at FROM party_sessions "
            "WHERE host_user_id = %s AND active = 1",
            (g.user["id"],),
        )
        party = cur.fetchone()
        if not party:
            return jsonify({"active": False})
        cur.execute(
            "SELECT guest_name, song_id, created_at FROM party_log "
            "WHERE party_id = %s ORDER BY id DESC LIMIT 100",
            (party["id"],),
        )
        log = [dict(r) for r in cur.fetchall()]
        return jsonify({
            "active": True,
            "code": party["code"],
            "join_url": f"{_base_url()}/party/{party['code']}",
            "qr_url": f"{_base_url()}/api/party/qr/{party['code']}.png",
            "log": log,
        })
    finally:
        conn.close()


# ---- public endpoints --------------------------------------------------

@party_api.route("/api/party/qr/<code>.png", endpoint="party_qr")
def party_qr(code):
    """Brand-styled QR for the TV overlay. Only renders for a live party."""
    party = _active_party_by_code(code.upper())
    if not party:
        return jsonify({"error": "No such party"}), 404
    try:
        import qrcode
        from qrcode.image.styledpil import StyledPilImage
        from qrcode.image.styles.moduledrawers.pil import RoundedModuleDrawer
        from qrcode.image.styles.colormasks import SolidFillColorMask

        qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M,
                           box_size=12, border=2)
        qr.add_data(f"{_base_url()}/party/{party['code']}")
        qr.make(fit=True)
        img = qr.make_image(
            image_factory=StyledPilImage,
            module_drawer=RoundedModuleDrawer(),
            color_mask=SolidFillColorMask(
                back_color=(13, 27, 42),      # app card navy
                front_color=(0, 212, 255),    # NASRadio cyan
            ),
        )
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        buf.seek(0)
        return send_file(buf, mimetype="image/png", max_age=0)
    except ImportError:
        return jsonify({"error": "qrcode library not installed"}), 500


@party_api.route("/party/<code>", endpoint="party_landing")
def party_landing(code):
    """What the QR opens. Tries the app deep link; explains otherwise."""
    party = _active_party_by_code(code.upper())
    body_note = (
        "This party has ended. Ask the host to start a new one!"
        if not party else
        "Tap below to join in the NASRadio app."
    )
    button = (
        "" if not party else
        f'<a class="btn" href="intent://party/{party["code"]}#Intent;'
        f'scheme=nasradio;package=com.example.frontend;end">Open NASRadio</a>'
        f'<div class="code">Party code: <b>{party["code"]}</b></div>'
    )
    return f"""<!DOCTYPE html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>NASRadio Party</title>
<style>
  body {{ background:#0d1b2a; color:#fff; font-family:sans-serif;
         display:flex; flex-direction:column; align-items:center;
         justify-content:center; min-height:90vh; text-align:center; }}
  h1 {{ color:#00d4ff; }}
  .btn {{ background:#00d4ff; color:#0d1b2a; font-weight:bold;
          padding:14px 34px; border-radius:28px; text-decoration:none;
          font-size:1.1em; }}
  .code {{ margin-top:18px; color:#9fb3c8; }}
</style></head>
<body><h1>🎉 NASRadio Party</h1><p>{body_note}</p>{button}</body></html>"""


@party_api.route("/api/party/<code>/join", methods=["POST"], endpoint="party_join")
def party_join(code):
    party = _active_party_by_code(code.upper())
    if not party:
        return jsonify({"error": "No such party (or it ended)"}), 404
    data = request.get_json(silent=True) or {}
    name = (data.get("name") or "").strip()[:_MAX_GUEST_NAME]
    if not name:
        return jsonify({"error": "A name is required"}), 400
    token = auth.generate_party_token(party["id"], party["code"], name)
    print(f"🎉 [party] {name} joined party {party['code']}")
    safe_emit("party_guest_joined", {"code": party["code"], "guest": name})
    return jsonify({"token": token, "code": party["code"], "guest": name})


# ---- guest endpoints ---------------------------------------------------

@party_api.route("/api/party/guest/search", endpoint="party_guest_search")
def party_guest_search():
    q = (request.args.get("q") or "").strip()
    if len(q) < 2:
        return jsonify([])
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute(
            """SELECT s.id, s.title, s.duration, s.album_id,
                      ar.name AS artist_name, al.title AS album_title
               FROM songs s
               LEFT JOIN artists ar ON ar.id = s.artist_id
               LEFT JOIN albums al ON al.id = s.album_id
               WHERE s.source_type = 'local'
                 AND (s.title ILIKE %s OR ar.name ILIKE %s
                      OR similarity(LOWER(s.title), LOWER(%s)) > 0.3)
               ORDER BY similarity(LOWER(s.title), LOWER(%s)) DESC, s.title
               LIMIT %s""",
            (f"%{q}%", f"%{q}%", q, q, _SEARCH_LIMIT),
        )
        return jsonify([dict(r) for r in cur.fetchall()])
    finally:
        conn.close()


@party_api.route("/api/party/guest/add", methods=["POST"], endpoint="party_guest_add")
def party_guest_add():
    data = request.get_json(silent=True) or {}
    song_id = data.get("song_id")
    if not isinstance(song_id, int):
        return jsonify({"error": "song_id required"}), 400
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute(
            "SELECT s.id, s.title, ar.name AS artist_name FROM songs s "
            "LEFT JOIN artists ar ON ar.id = s.artist_id "
            "WHERE s.id = %s AND s.source_type = 'local'",
            (song_id,),
        )
        song = cur.fetchone()
        if not song:
            return jsonify({"error": "Song not found"}), 404
        cur.execute(
            "INSERT INTO party_log (party_id, guest_name, song_id) "
            "VALUES (%s, %s, %s)",
            (g.party["id"], g.party_guest, song_id),
        )
        conn.commit()
    except Exception as e:
        conn.rollback()
        return jsonify({"error": str(e)}), 500
    finally:
        conn.close()

    # Relay to the host app (existing socket.io channel — at house scale a
    # broadcast is fine; the host filters on its active party code).
    safe_emit("party_track_added", {
        "code": g.party["code"],
        "guest": g.party_guest,
        "song_id": song_id,
        "title": song["title"],
        "artist": song["artist_name"],
    })
    print(f"🎉 [party] {g.party_guest} added \"{song['title']}\" "
          f"to party {g.party['code']}")
    return jsonify({"ok": True, "title": song["title"]})
