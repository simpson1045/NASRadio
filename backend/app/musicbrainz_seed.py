"""MusicBrainz release-editor seeding (MUSICBRAINZ_SUBMISSION_SPEC.md Phase 1).

MB has no silent "create release" API — the sanctioned path is seeding
the release editor: we POST a pre-filled form to musicbrainz.org, the
user reviews and submits under their own MB account, and MB redirects
back to our callback with the new release MBID appended.

Two seed sources:
  GET /api/musicbrainz/seed-folder?path=<staging folder>   (pre-import)
  GET /api/musicbrainz/seed/<album_id>                     (library album)
Both need a full-scope token (Authorization header or ?token= — the
page is opened in a plain browser, so query token is the normal path).

  GET /api/musicbrainz/callback?sig=...&release_mbid=...
Unauthenticated (the user's browser arrives bare from MB), so the
target is carried in an itsdangerous-signed `sig` we minted at seed
time: folder seeds get a `musicbrainz.mbid` file written into the
staging folder for the eventual import; album seeds get albums.mbid
updated directly.

Metadata comes from the local files themselves (mutagen): richer than
any external lookup for WEB rips — Apple Music files carry the barcode,
label, release date and the Apple album id. Spotify fallback for
tag-poor albums is spec Phase 2.
"""

import html
import os
import re
import time

from flask import Blueprint, jsonify, request
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer

from app import auth
from app.config import Config, user_agent
from app.models import Database

mb_seed_api = Blueprint("musicbrainz_seed", __name__)
config = Config()



def _base_url():
    """Public base for the MusicBrainz OAuth callback/handoff links: the
    configured Public base URL, else however this request reached us."""
    return Config.PUBLIC_BASE_URL or request.host_url.rstrip("/")

SEED_SALT = "nasradio-mb-seed-v1"
SIG_MAX_AGE = 86400  # seeds are one-evening artifacts; 24h is generous

AUDIO_EXTENSIONS = {".flac", ".mp3", ".m4a", ".wav", ".ogg", ".opus",
                    ".aac", ".wma", ".wv", ".ape", ".aiff", ".dsf", ".dff"}

# Folder seeds may only point inside these roots — the endpoint reads
# tags from arbitrary user-supplied paths otherwise.
ALLOWED_FOLDER_ROOTS = ("/downloads", "/music")


def _get_db():
    return Database(config.DATABASE_URL)


def _serializer():
    secret = os.environ.get("SECRET_KEY") or config.SECRET_KEY
    return URLSafeTimedSerializer(secret, salt=SEED_SALT)


def _require_full_token():
    token = auth.extract_bearer_token() or request.args.get("token")
    if not token:
        return None
    user, scope = auth.resolve_token(token)
    if user and scope == "full":
        return user
    return None


# ── Seed building ──────────────────────────────────────────────────────

def _first(tags, key):
    v = tags.get(key)
    if isinstance(v, list):
        v = v[0] if v else None
    return str(v) if v is not None else None


def _mp4_freeform(raw_tags, name):
    v = raw_tags.get(f"----:com.apple.iTunes:{name}")
    if v:
        b = v[0]
        return bytes(b).decode("utf-8", "replace")
    return None


def _track_sort_key(entry):
    n = entry.get("number")
    return (0, n) if isinstance(n, int) else (1, entry["file"])


def extract_release_data(files):
    """files → (structured data dict, warnings). The data dict is what
    the in-app submission modal edits; `data_to_seed_fields` turns it
    into MB release-editor field names."""
    from mutagen import File as MutagenFile

    tracks = []
    album = artist = date = label = barcode = apple_album_id = None
    seen_dolby_codec = False
    warnings = []

    for path in files:
        try:
            easy = MutagenFile(path, easy=True)
            if easy is None:
                warnings.append(f"unreadable: {os.path.basename(path)}")
                continue
            tags = easy.tags or {}

            title = _first(tags, "title") or \
                os.path.splitext(os.path.basename(path))[0]
            number = None
            tn = _first(tags, "tracknumber")
            if tn:
                m = re.match(r"(\d+)", tn)
                if m:
                    number = int(m.group(1))
            length_ms = None
            info = getattr(easy, "info", None)
            if info is not None and getattr(info, "length", None):
                length_ms = int(info.length * 1000)
            codec = str(getattr(info, "codec", "") or "")
            if codec.startswith(("ec-3", "ac-3")):
                seen_dolby_codec = True

            tracks.append({"file": path, "name": title,
                           "number": number, "length": length_ms})

            album = album or _first(tags, "album")
            artist = artist or _first(tags, "albumartist") or _first(tags, "artist")
            date = date or _first(tags, "date")

            # Format-specific extras (barcode/label/Apple album id) —
            # need the raw (non-easy) tags.
            if barcode is None or label is None or apple_album_id is None:
                raw = MutagenFile(path)
                rt = getattr(raw, "tags", None) or {}
                if barcode is None:
                    barcode = _mp4_freeform(rt, "UPC") or _first(rt, "barcode") \
                        or _first(rt, "BARCODE")
                if label is None:
                    lab = rt.get("\xa9pub")
                    label = (str(lab[0]) if isinstance(lab, list) and lab
                             else None) or _first(rt, "label") or _first(rt, "LABEL")
                if apple_album_id is None:
                    pl = rt.get("plID")
                    if isinstance(pl, list) and pl:
                        apple_album_id = str(pl[0])
        except Exception as e:
            warnings.append(f"{os.path.basename(path)}: {e}")

    if not tracks:
        return None, warnings

    tracks.sort(key=_track_sort_key)

    # Disambiguation suggestion: the edition usually announces itself —
    # "Atmos" in the folder/file names, or Dolby bitstream codecs in
    # the files. The user approves/edits it in the modal.
    joined_names = " ".join(files)
    if re.search(r"atmos", joined_names, re.IGNORECASE):
        comment = "Dolby Atmos"
    elif seen_dolby_codec:
        comment = "Dolby Digital Plus"
    else:
        comment = ""

    data = {
        "album": album or "Unknown Album",
        "artist": artist or "Unknown Artist",
        "comment": comment,
        "type": "Album",
        "status": "official",
        "format": "Digital Media",
        "date": date or "",
        "label": label or "",
        "barcode": barcode or "",
        "url": (f"https://music.apple.com/us/album/{apple_album_id}"
                if apple_album_id else ""),
        "apple_source": bool(apple_album_id),
        "tracks": [{"number": t["number"] or i + 1,
                    "title": t["name"],
                    "length_ms": t["length"]}
                   for i, t in enumerate(tracks)],
    }
    return data, warnings


def data_to_seed_fields(data, comment=""):
    """Structured data (possibly user-edited in the app) → MB
    release-editor seed field names (spec §2)."""
    fields = {
        "name": data.get("album") or "Unknown Album",
        "artist_credit.names.0.name": data.get("artist") or "Unknown Artist",
        "type": data.get("type") or "Album",
        "status": data.get("status") or "official",
        "mediums.0.format": data.get("format") or "Digital Media",
        "edit_note": ("Seeded by NASRadio from local file tags"
                      + (" (Apple Music web files)"
                         if data.get("apple_source") else "")),
    }
    if comment:
        fields["comment"] = comment
    if data.get("barcode"):
        fields["barcode"] = data["barcode"]
    if data.get("label"):
        fields["labels.0.name"] = data["label"]
    if data.get("date"):
        m = re.match(r"(\d{4})(?:-(\d{2}))?(?:-(\d{2}))?", str(data["date"]))
        if m:
            fields["events.0.date.year"] = m.group(1)
            if m.group(2):
                fields["events.0.date.month"] = m.group(2)
            if m.group(3):
                fields["events.0.date.day"] = m.group(3)
    if data.get("url"):
        # Let the user pick the link type in the editor — safer than
        # hardcoding MB's numeric link-type ids.
        fields["urls.0.url"] = data["url"]

    for i, t in enumerate(data.get("tracks") or []):
        fields[f"mediums.0.track.{i}.name"] = t.get("title") or f"Track {i+1}"
        fields[f"mediums.0.track.{i}.number"] = str(t.get("number") or i + 1)
        if t.get("length_ms"):
            fields[f"mediums.0.track.{i}.length"] = str(t["length_ms"])

    return fields


def build_seed_from_files(files):
    """Back-compat wrapper for the URL-driven seed pages."""
    data, warnings = extract_release_data(files)
    if not data:
        return None, warnings
    return data_to_seed_fields(data), warnings


def _render_seed_page(fields, comment, redirect_uri):
    fields = dict(fields)
    if comment:
        fields["comment"] = comment  # MB disambiguation
    fields["redirect_uri"] = redirect_uri

    inputs = "\n".join(
        f'<input type="hidden" name="{html.escape(k, quote=True)}" '
        f'value="{html.escape(str(v), quote=True)}">'
        for k, v in fields.items()
    )
    n_tracks = sum(1 for k in fields if k.endswith(".name")
                   and k.startswith("mediums."))
    summary = html.escape(
        f"{fields.get('artist_credit.names.0.name')} — {fields.get('name')}"
        + (f" [{comment}]" if comment else "")
        + f" · {n_tracks} tracks"
        + (f" · barcode {fields['barcode']}" if fields.get("barcode") else "")
    )
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>NASRadio → MusicBrainz</title>
<style>body{{font-family:system-ui;background:#0d1b2a;color:#e0f2fe;
display:flex;flex-direction:column;align-items:center;justify-content:center;
height:100vh;gap:1rem}}button{{font-size:1.1rem;padding:.7rem 2rem;
border-radius:8px;border:0;background:#00d4ff;color:#012;cursor:pointer}}
</style></head><body>
<h2>Sending to the MusicBrainz release editor…</h2>
<p>{summary}</p>
<p>Review everything there, match the recordings, and submit —
NASRadio will catch the new MBID on the way back.</p>
<form id="mb" method="post" action="https://musicbrainz.org/release/add">
{inputs}
<button type="submit">Open MusicBrainz release editor</button>
</form>
<script>document.getElementById('mb').submit();</script>
</body></html>"""


def _collect_audio_files(folder):
    out = []
    for root, _dirs, names in os.walk(folder):
        for n in sorted(names):
            if os.path.splitext(n)[1].lower() in AUDIO_EXTENSIONS:
                out.append(os.path.join(root, n))
    return out


# ── Endpoints ──────────────────────────────────────────────────────────

@mb_seed_api.route("/api/musicbrainz/seed-folder", methods=["GET"])
def seed_folder():
    if not _require_full_token():
        return jsonify({"error": "Full authentication required"}), 401

    folder = (request.args.get("path") or "").strip()
    real = os.path.realpath(folder)
    if not any(real == r or real.startswith(r + "/")
               for r in ALLOWED_FOLDER_ROOTS):
        return jsonify({"error": "path outside allowed roots"}), 400
    if not os.path.isdir(real):
        return jsonify({"error": "folder not found"}), 404

    files = _collect_audio_files(real)
    fields, warnings = build_seed_from_files(files)
    if not fields:
        return jsonify({"error": "no readable audio files",
                        "warnings": warnings}), 422

    sig = _serializer().dumps({"kind": "folder", "ref": real})
    redirect_uri = f"{_base_url()}/api/musicbrainz/callback?sig={sig}"
    comment = (request.args.get("comment") or "").strip()
    return _render_seed_page(fields, comment, redirect_uri)


@mb_seed_api.route("/api/musicbrainz/seed/<int:album_id>", methods=["GET"])
def seed_album(album_id):
    if not _require_full_token():
        return jsonify({"error": "Full authentication required"}), 401

    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute(
            """SELECT s.file_path FROM songs s
               WHERE s.album_id = %s AND s.source_type = 'local'
               ORDER BY s.disc_number NULLS FIRST, s.track_number, s.id""",
            (album_id,))
        files = [r["file_path"] for r in cur.fetchall()]
    finally:
        conn.close()

    files = [f for f in files if f and os.path.exists(f)]
    if not files:
        return jsonify({"error": "album has no readable local files"}), 404

    fields, warnings = build_seed_from_files(files)
    if not fields:
        return jsonify({"error": "no readable audio files",
                        "warnings": warnings}), 422

    sig = _serializer().dumps({"kind": "album", "ref": album_id})
    redirect_uri = f"{_base_url()}/api/musicbrainz/callback?sig={sig}"
    comment = (request.args.get("comment") or "").strip()
    return _render_seed_page(fields, comment, redirect_uri)


@mb_seed_api.route("/api/musicbrainz/seed-data", methods=["GET"])
def seed_data():
    """Structured prefill for the in-app submission modal. Pass either
    ?path=<staging folder> or ?album_id=<library album>."""
    if not _require_full_token():
        return jsonify({"error": "Full authentication required"}), 401

    folder = (request.args.get("path") or "").strip()
    album_id = request.args.get("album_id", type=int)

    if folder:
        real = os.path.realpath(folder)
        if not any(real == r or real.startswith(r + "/")
                   for r in ALLOWED_FOLDER_ROOTS):
            return jsonify({"error": "path outside allowed roots"}), 400
        if not os.path.isdir(real):
            return jsonify({"error": "folder not found"}), 404
        files = _collect_audio_files(real)
        target = {"kind": "folder", "ref": real}
    elif album_id:
        db = _get_db()
        conn = db.get_connection()
        try:
            cur = db.get_cursor(conn)
            cur.execute(
                """SELECT s.file_path FROM songs s
                   WHERE s.album_id = %s AND s.source_type = 'local'
                   ORDER BY s.disc_number NULLS FIRST, s.track_number, s.id""",
                (album_id,))
            files = [r["file_path"] for r in cur.fetchall()]
        finally:
            conn.close()
        files = [f for f in files if f and os.path.exists(f)]
        target = {"kind": "album", "ref": album_id}
    else:
        return jsonify({"error": "path or album_id required"}), 400

    data, warnings = extract_release_data(files)
    if not data:
        return jsonify({"error": "no readable audio files",
                        "warnings": warnings}), 422

    return jsonify({"success": True, "data": data, "warnings": warnings,
                    "target": target})


# Staged handoffs: token → (mb_fields, target, created_ts). In-memory
# is fine — a handoff lives for the minute between the modal's submit
# and the browser opening; a backend restart just means re-submitting
# the modal.
_HANDOFFS = {}
_HANDOFF_TTL = 3600


@mb_seed_api.route("/api/musicbrainz/handoff", methods=["POST"])
def handoff_create():
    """The modal posts its (edited) structured data here; we stage the
    MB form and hand back a URL for the browser to open."""
    if not _require_full_token():
        return jsonify({"error": "Full authentication required"}), 401

    body = request.get_json(silent=True) or {}
    data = body.get("data") or {}
    target = body.get("target") or {}
    comment = (body.get("comment") or "").strip()
    if not data.get("tracks"):
        return jsonify({"error": "data.tracks required"}), 400
    if target.get("kind") not in ("folder", "album"):
        return jsonify({"error": "target.kind must be folder|album"}), 400

    import secrets
    now = time.time()
    for k in [k for k, v in _HANDOFFS.items() if now - v[2] > _HANDOFF_TTL]:
        _HANDOFFS.pop(k, None)

    token = secrets.token_urlsafe(24)
    fields = data_to_seed_fields(data, comment)
    _HANDOFFS[token] = (fields, {"kind": target["kind"],
                                 "ref": target["ref"]}, now)
    return jsonify({"success": True,
                    "url": f"{_base_url()}/api/musicbrainz/handoff/{token}"})


@mb_seed_api.route("/api/musicbrainz/handoff/<token>", methods=["GET"])
def handoff_page(token):
    """Unauthenticated by design (opened in a plain browser); the token
    is unguessable, short-lived, and carries no secrets — just the
    already-reviewed form contents."""
    entry = _HANDOFFS.get(token)
    if not entry or time.time() - entry[2] > _HANDOFF_TTL:
        _HANDOFFS.pop(token, None)
        return ("<h3>This MusicBrainz handoff has expired — "
                "re-submit from NASRadio.</h3>"), 410

    fields, target, _ts = entry
    sig = _serializer().dumps(target)
    redirect_uri = f"{_base_url()}/api/musicbrainz/callback?sig={sig}"
    return _render_seed_page(dict(fields), "", redirect_uri)


# Release-group → releases drill-down (spec §10 point 6). The import
# screen's results are release GROUPS; this lists a group's actual
# releases (format/date/tracks/disambiguation) so the user can SEE
# whether their edition exists before adding it to MusicBrainz.
_RG_CACHE = {}
_RG_TTL = 6 * 3600


@mb_seed_api.route("/api/musicbrainz/rg-releases", methods=["GET"])
def rg_releases():
    if not _require_full_token():
        return jsonify({"error": "Full authentication required"}), 401

    rgid = (request.args.get("rgid") or "").strip()
    if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-"
                        r"[0-9a-f]{4}-[0-9a-f]{12}", rgid):
        return jsonify({"error": "rgid must be a MusicBrainz UUID"}), 400

    cached = _RG_CACHE.get(rgid)
    if cached and time.time() - cached[0] < _RG_TTL:
        return jsonify({"success": True, "releases": cached[1],
                        "cached": True})

    import requests
    try:
        resp = requests.get(
            "https://musicbrainz.org/ws/2/release",
            params={"release-group": rgid, "limit": "100",
                    "fmt": "json", "inc": "media"},
            headers={"User-Agent":
                     user_agent()},
            timeout=15,
        )
        resp.raise_for_status()
        payload = resp.json()
    except Exception as e:
        return jsonify({"error": f"MusicBrainz lookup failed: {e}"}), 502

    releases = []
    for r in payload.get("releases", []):
        media = r.get("media") or []
        formats = sorted({m.get("format") or "?" for m in media})
        releases.append({
            "id": r.get("id"),
            "title": r.get("title"),
            "date": r.get("date") or "",
            "country": r.get("country") or "",
            "disambiguation": r.get("disambiguation") or "",
            "formats": [f for f in formats if f != "?"],
            "track_count": sum(m.get("track-count") or 0 for m in media),
        })
    # Newest-dated first; undated sink to the bottom.
    releases.sort(key=lambda r: r["date"] or "0000", reverse=True)

    _RG_CACHE[rgid] = (time.time(), releases)
    return jsonify({"success": True, "releases": releases,
                    "count": len(releases)})


@mb_seed_api.route("/api/musicbrainz/callback", methods=["GET"])
def seed_callback():
    """MB redirects the user's browser here after submit — no auth
    header possible, so trust rides entirely on the signed sig."""
    sig = request.args.get("sig") or ""
    mbid = (request.args.get("release_mbid") or "").strip()

    try:
        payload = _serializer().loads(sig, max_age=SIG_MAX_AGE)
    except (BadSignature, SignatureExpired):
        return jsonify({"error": "bad or expired signature"}), 403

    if not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-"
                        r"[0-9a-f]{4}-[0-9a-f]{12}", mbid):
        return jsonify({"error": "release_mbid missing or malformed"}), 400

    kind, ref = payload.get("kind"), payload.get("ref")
    if kind == "album":
        db = _get_db()
        conn = db.get_connection()
        try:
            cur = db.get_cursor(conn)
            cur.execute("UPDATE albums SET mbid = %s WHERE id = %s",
                        (mbid, ref))
            conn.commit()
        finally:
            conn.close()
        did = f"Linked MBID to library album #{ref}."
    elif kind == "folder":
        real = os.path.realpath(str(ref))
        if not any(real == r or real.startswith(r + "/")
                   for r in ALLOWED_FOLDER_ROOTS) or not os.path.isdir(real):
            return jsonify({"error": "seed folder no longer valid"}), 410
        with open(os.path.join(real, "musicbrainz.mbid"), "w") as f:
            f.write(mbid + "\n")
        did = "Wrote musicbrainz.mbid into the staging folder for import."
    else:
        return jsonify({"error": "unknown seed kind"}), 400

    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>MusicBrainz linked</title>
<style>body{{font-family:system-ui;background:#0d1b2a;color:#e0f2fe;
display:flex;flex-direction:column;align-items:center;justify-content:center;
height:100vh;gap:.6rem}}code{{background:#173a5e;padding:.2rem .5rem;
border-radius:6px}}</style></head><body>
<h2>&#127881; Release captured</h2>
<p>MusicBrainz release: <code>{html.escape(mbid)}</code></p>
<p>{html.escape(did)}</p>
<p>You can close this tab.</p>
</body></html>"""
