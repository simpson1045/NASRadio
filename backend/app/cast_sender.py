"""Headless Cast sender — the backend casts to the TV itself.

The endgame of the 2026-08 cast saga: "Claude, play 5150 on the C2"
with no phone involved. The backend speaks CASTV2 directly (TLS :8009,
length-framed protobuf — same protocol the Flutter sender uses, same
frames we hand-rolled during the mDNS forensics), launches the NASRadio
receiver, LOADs the first track, and hands the receiver an UP_NEXT list
so it self-advances through the rest even after we hang up.

Wake choreography (all dependency-free):
  - Wake-on-LAN magic packet to the C2 (it answers cast even from
    standby once woken)
  - Denon AVR-X3700H over raw telnet :23 (ZMON / SITV) — the cast
    audio reaches the Denon via the C2's eARC as "TV Audio"

Endpoints (full-token gate, mirrors party host endpoints):
  POST /api/cast/play   {query, type?, device?, wake?}  → resolve + cast
  POST /api/cast/party  {wake?}                          → party + shuffle
  POST /api/cast/queue  {query, next?, by?, type?}  → add to live queue
  POST /api/cast/pause | /resume | /next | /previous
  POST /api/cast/seek   {position}
  POST /api/cast/volume {level 0-85 | action up/down/mute/unmute} → Denon
  POST /api/cast/lyrics {show?}          → push synced lyrics + toggle view
  POST /api/cast/sleep  {minutes | seconds}   (0 cancels)
  POST /api/cast/crossfade {seconds 0-12}     (segue ramp; 0 = off)
  POST /api/cast/black  {active?}
  POST /api/cast/stop
  GET  /api/cast/status

Receiver parity notes: the receiver's waveform canvas IS its scrubber,
and it asks the sender for the floats (WAVEFORM_REQUEST) — we answer
like the phone does, special-waveform skins included. Station casts get
a 15s NOW_PLAYING poll; queue casts get synced lyrics pushed per track
(hidden until toggled).

Ambiguity rule (per simpson1045): albums win over songs — "5150" is the album.
"""

import json
import os
import random
import socket
import ssl
import struct
import time

import eventlet
import eventlet.event
from flask import Blueprint, g, has_request_context, jsonify, request

from app import auth
from app.config import Config
from app.models import Database

cast_api = Blueprint("cast_sender", __name__)
config = Config()

# ── Device / room settings ──────────────────────────────────────────────
# The TV, its WOL MAC, the AV receiver and the Cast app ID are runtime
# settings (Settings → Cast in the app; CAST_* / DENON_* in .env). Nothing
# about a specific living room lives in this file.
C2_CAST_PORT = 8009


class CastNotConfigured(RuntimeError):
    """Raised when a cast is requested but no device / receiver / public URL
    is configured yet. The blueprint turns it into a 400 with the message."""


@cast_api.errorhandler(CastNotConfigured)
def _cast_not_configured(e):
    return jsonify({"error": str(e)}), 400


def _resolve_host(requested=None):
    host = (requested or config.CAST_DEVICE_HOST or "").strip()
    if not host:
        raise CastNotConfigured("No cast device configured — set the default "
                                "cast device in Settings → Cast, or pass \"device\"")
    return host


def _receiver_app_id():
    app_id = config.CAST_RECEIVER_APP_ID
    if not app_id:
        raise CastNotConfigured("No Cast receiver app ID configured (Settings → Cast)")
    return app_id


def _public_base():
    """Base for the stream/artwork URLs handed to the TV. The configured
    Public base URL, else the URL this request arrived on (LAN casts)."""
    base = config.PUBLIC_BASE_URL
    if base:
        return base
    if has_request_context():
        return request.host_url.rstrip("/")
    raise CastNotConfigured("Public base URL not configured (Settings → Server)")

NASRADIO_NS = "urn:x-cast:com.nasradio.custom"
NS_CONNECTION = "urn:x-cast:com.google.cast.tp.connection"
NS_HEARTBEAT = "urn:x-cast:com.google.cast.tp.heartbeat"
NS_RECEIVER = "urn:x-cast:com.google.cast.receiver"
NS_MEDIA = "urn:x-cast:com.google.cast.media"


UP_NEXT_COUNT = 10


def _get_db():
    return Database(config.DATABASE_URL)


# ── CASTV2 framing ─────────────────────────────────────────────────────

def _varint(n):
    out = b""
    while True:
        b7 = n & 0x7F
        n >>= 7
        out += bytes([b7 | (0x80 if n else 0)])
        if not n:
            return out


def _enc_str(fid, s):
    b = s.encode()
    return bytes([fid << 3 | 2]) + _varint(len(b)) + b


def _enc_int(fid, n):
    return bytes([fid << 3]) + _varint(n)


def _frame(ns, payload, source, dest):
    m = (_enc_int(1, 0) + _enc_str(2, source) + _enc_str(3, dest)
         + _enc_str(4, ns) + _enc_int(5, 0)
         + _enc_str(6, json.dumps(payload)))
    return struct.pack(">I", len(m)) + m


def _read_varint(buf, i):
    shift = 0
    val = 0
    while True:
        b = buf[i]
        i += 1
        val |= (b & 0x7F) << shift
        if not b & 0x80:
            return val, i
        shift += 7


def _parse_frame(body):
    """Minimal CastMessage parse → (namespace, payload_dict|None)."""
    i = 0
    ns = None
    payload = None
    try:
        while i < len(body):
            tag = body[i]
            i += 1
            fid = tag >> 3
            wire = tag & 7
            if wire == 0:
                _, i = _read_varint(body, i)
            elif wire == 2:
                ln, i = _read_varint(body, i)
                data = body[i:i + ln]
                i += ln
                if fid == 4:
                    ns = data.decode("utf-8", "ignore")
                elif fid == 6:
                    try:
                        payload = json.loads(data.decode("utf-8", "ignore"))
                    except Exception:
                        payload = None
            else:
                break
    except Exception:
        pass
    return ns, payload


# ── The headless session ───────────────────────────────────────────────

class HeadlessCastSession:
    """One connection to one cast device. Lives in a greenthread; keeps
    heartbeat flowing; tracks receiver/media state. The receiver's
    UP_NEXT self-advance means playback SURVIVES this session dying —
    we keep it alive anyway for stop/status and follow-up commands."""

    def __init__(self, host, port=C2_CAST_PORT):
        self.host = host
        self.port = port
        self.sock = None
        self.alive = False
        self.transport_id = None
        self.session_id = None
        self.media_session_id = None
        self.player_state = "UNKNOWN"
        self.current_song_id = None
        self.last_error = None
        self.started_at = time.time()
        self._req_id = 100
        # Queue memory for next/previous — the TV self-advances via
        # UP_NEXT, but jumps need the full resolved list.
        self.queue = []
        self._wf_pending = set()     # song ids with a waveform answer in flight
        self._lyrics_sent_for = None
        self._station_poll_gen = 0   # bumping this kills any station poll
        # Guest mode: another sender (simpson1045's phone) launched the receiver
        # and owns the queue. We joined its session instead of launching
        # our own; queue/skip/status go through the receiver, which relays
        # them to the owner. See _guest_session / QUEUE_INSERT.
        self.joined = False
        self.remote_headless = False   # joined media says headlessSender
        self._closing = False          # close() called on purpose
        self.media_metadata = {}
        # What we're playing and where in it — persisted by _save_state so
        # "resume" works after a stop, a dropped session or a backend restart.
        self.label = None            # "simpson1045's Mix", "5150 — Van Halen", ...
        self.kind = None             # album | playlist | song | station | party
        # Where the queue came from and whether it was shuffled, so status
        # can answer "is this shuffled?" and hand back the source's order.
        self.source = None           # {"type": "album"|"playlist"|"party", "id", "name"}
        self.shuffled = False
        # Wedge detection (see _wedged / _heal): when the receiver went IDLE
        # and why, plus the recent self-heal attempts.
        self.idle_since = None
        self.idle_reason = None
        self.last_active_state = None  # last non-IDLE playerState (PLAYING/PAUSED/...)
        self._our_session_id = None    # receiver sessionId of the app WE launched
        self.app_running = None        # is our receiver app in the latest RECEIVER_STATUS?
        self.taken_over = False        # a different sender launched a new session
        self._receiver_status_at = 0.0
        self._heal_times = []
        self._healing = False
        self._heal_gave_up = False
        self.station_query = None
        self.position = 0.0          # media currentTime at position_at
        self.position_at = time.time()
        self._hb_ticks = 0
        self._receiver_status_seen = False
        self._pending = {}           # requestId -> [Event, reply]

    def _next_req(self):
        self._req_id += 1
        return self._req_id

    def _send(self, ns, payload, dest=None):
        f = _frame(ns, payload, "sender-nasradio-backend",
                   dest or (self.transport_id or "receiver-0"))
        self.sock.sendall(f)

    def connect_and_launch(self, timeout=15, join=True, launch=True):
        """Open the socket and get a transport to the NASRadio receiver.

        join:   if the receiver is already running (phone-started cast),
                attach to that session as a guest instead of launching.
        launch: if nothing is running, LAUNCH our own. launch=False is the
                "only join, never take over" probe used by the guest routes.
        """
        ctx = ssl._create_unverified_context()
        raw = socket.create_connection((self.host, self.port), timeout=8)
        self.sock = ctx.wrap_socket(raw)
        self.alive = True
        self._send(NS_CONNECTION, {"type": "CONNECT"}, dest="receiver-0")
        eventlet.spawn_n(self._pump)
        eventlet.spawn_n(self._heartbeat)
        if join:
            self._send(NS_RECEIVER,
                       {"type": "GET_STATUS", "requestId": self._next_req()},
                       dest="receiver-0")
            deadline = time.time() + 3
            while time.time() < deadline and self.alive:
                if self.transport_id:
                    self.joined = True
                    break
                if self._receiver_status_seen:
                    break  # answered, and our app isn't in the list
                eventlet.sleep(0.1)
        if not self.transport_id:
            if not launch:
                return False
            self._send(NS_RECEIVER,
                       {"type": "LAUNCH", "appId": _receiver_app_id(),
                        "requestId": self._next_req()},
                       dest="receiver-0")
            deadline = time.time() + timeout
            while time.time() < deadline:
                if self.transport_id:
                    break
                if not self.alive:
                    return False
                eventlet.sleep(0.2)
            if not self.transport_id:
                return False
            self._our_session_id = self.session_id
        # Open the virtual connection to the app itself.
        self._send(NS_CONNECTION, {"type": "CONNECT"})
        if self.joined:
            # Learn the owner's media session so pause/seek work at once.
            self._send(NS_MEDIA, {"type": "GET_STATUS",
                                  "requestId": self._next_req()})
            print(f"📺 [cast-sender] joined a running cast on {self.host} as a guest")
        return True

    def request_custom(self, payload, timeout=6):
        """Send a custom message that the receiver answers with the same
        requestId (QUEUE_INSERT, SKIP, STATE_REQUEST). Returns the reply
        payload, or None on timeout."""
        rid = self._next_req()
        payload = dict(payload, requestId=rid)
        slot = [eventlet.event.Event(), None]
        self._pending[rid] = slot
        try:
            self.send_custom(payload)
            with eventlet.Timeout(timeout, False):
                slot[0].wait()
        finally:
            self._pending.pop(rid, None)
        return slot[1]

    def position_now(self):
        """Best estimate of the playhead: last reported currentTime, plus
        wall-clock since then while PLAYING."""
        if self.player_state == "PLAYING":
            return self.position + (time.time() - self.position_at)
        return self.position

    def _heartbeat(self):
        while self.alive:
            try:
                self._send(NS_HEARTBEAT, {"type": "PING"}, dest="receiver-0")
                self._hb_ticks += 1
                # Every ~10 s on a queue we own: ask the TV where the
                # playhead is (answer lands in _on_frame) and write the
                # state file, so a crash loses at most ten seconds.
                if (self._hb_ticks % 2 == 0 and not self.joined
                        and (self.media_session_id is not None or self.queue)):
                    self._send(NS_MEDIA, {"type": "GET_STATUS",
                                          "requestId": self._next_req()})
                    _save_state(self)
                if not self._healing and _wedged(self):
                    self._healing = True
                    eventlet.spawn_n(_heal, self)
            except Exception:
                break
            eventlet.sleep(5)

    def _pump(self):
        buf = b""
        try:
            while self.alive:
                data = self.sock.recv(8192)
                if not data:
                    break
                buf += data
                while len(buf) >= 4:
                    ln = struct.unpack(">I", buf[:4])[0]
                    if len(buf) < 4 + ln:
                        break
                    body = buf[4:4 + ln]
                    buf = buf[4 + ln:]
                    self._on_frame(*_parse_frame(body))
        except Exception as e:
            self.last_error = str(e)
        finally:
            self.alive = False
            try:
                self.sock.close()
            except Exception:
                pass
            # The TV drops this control socket now and then (webOS), and the
            # receiver keeps playing our queue on its own. Without a session
            # nothing tracks the playhead and later commands arrive as a
            # guest — that lost simpson1045's place on 2026-09-20. Re-attach.
            if not self._closing and not self.joined and (self.queue or self.kind == "station"):
                print(f"📺 [cast-sender] control socket to {self.host} died "
                      f"({self.last_error or 'closed by TV'}) — re-attaching")
                eventlet.spawn_n(_reattach_loop, self.host, self)

    def _on_frame(self, ns, payload):
        if not payload:
            return
        t = payload.get("type")
        if ns == NS_HEARTBEAT and t == "PING":
            try:
                self._send(NS_HEARTBEAT, {"type": "PONG"}, dest="receiver-0")
            except Exception:
                pass
        elif ns == NS_RECEIVER and t == "RECEIVER_STATUS":
            self._receiver_status_seen = True
            self._receiver_status_at = time.time()
            apps = (payload.get("status") or {}).get("applications") or []
            ours = [a for a in apps if a.get("appId") == config.CAST_RECEIVER_APP_ID]
            self.app_running = bool(ours)
            for a in ours:
                self.transport_id = a.get("transportId")
                self.session_id = a.get("sessionId")
            if (self._our_session_id and self.session_id
                    and self.session_id != self._our_session_id):
                self.taken_over = True
        elif ns == NS_MEDIA and t == "MEDIA_STATUS":
            statuses = payload.get("status") or []
            if not statuses and not self.joined and self.queue:
                # No media session at all on a queue we own: the receiver
                # dropped the media (the 2026-09-23 wedge looked like this).
                self.media_session_id = None
                self.player_state = "IDLE"
            if statuses:
                st = statuses[0]
                self.media_session_id = st.get("mediaSessionId")
                self.player_state = st.get("playerState") or self.player_state
                self.idle_reason = st.get("idleReason") if self.player_state == "IDLE" else None
            if self.player_state == "IDLE":
                self.idle_since = self.idle_since or time.time()
            else:
                self.idle_since = None
                if self.player_state not in ("UNKNOWN", None):
                    self.last_active_state = self.player_state
            if statuses:
                st = statuses[0]
                if isinstance(st.get("currentTime"), (int, float)):
                    self.position = float(st["currentTime"])
                    self.position_at = time.time()
                media = st.get("media") or {}
                if media.get("metadata"):
                    self.media_metadata = media["metadata"]
                custom = media.get("customData") or {}
                if self.joined:
                    # Not our queue (yet — see _reclaim_if_ours): just track
                    # what the TV is on. No lyrics push, no UP_NEXT refill.
                    self.remote_headless = bool(custom.get("headlessSender"))
                    if isinstance(custom.get("songId"), (int, float)):
                        self.current_song_id = int(custom["songId"])
                    return
                if isinstance(custom.get("songId"), (int, float)):
                    prev = self.current_song_id
                    self.current_song_id = int(custom["songId"])
                    # Covers first LOAD, our jumps, AND the TV's UP_NEXT
                    # self-advance — lyrics ride along on every track.
                    if self.current_song_id != prev and self.current_song_id > 0:
                        eventlet.spawn_n(self._push_lyrics, self.current_song_id)
                        # The TV self-advances by shifting items off the
                        # UP_NEXT list we gave it. Without a refill it runs
                        # dry after UP_NEXT_COUNT tracks and sits in IDLE
                        # with no error. Re-send the tail from wherever
                        # the TV is now, on every track change.
                        eventlet.spawn_n(self._refill_up_next)
                        # currentTime from this same status is already in
                        # self.position (a resume LOADs mid-song — don't
                        # zero it).
                        _save_state(self)
        elif ns == NASRADIO_NS and t in ("QUEUE_INSERT_RESULT", "SKIP_RESULT", "STATE"):
            slot = self._pending.get(payload.get("requestId"))
            if slot is not None:
                slot[1] = payload
                if not slot[0].ready():
                    slot[0].send(True)
        elif ns == NASRADIO_NS and t == "WAVEFORM_REQUEST":
            # The receiver's waveform canvas IS its scrubber; no answer,
            # no scrubber (the EVH skin needs the floats too).
            sid = payload.get("songId") or self.current_song_id
            if isinstance(sid, (int, float)) and int(sid) > 0:
                eventlet.spawn_n(self._answer_waveform, int(sid))

    def _refill_up_next(self):
        """Re-send UP_NEXT from the TV's current queue position with a
        fresh media token, so long queues outlive both the 10-item
        window and the token minted at cast time."""
        if not self.queue:
            return  # stations have no queue
        try:
            ids = [s["id"] for s in self.queue]
            try:
                idx = ids.index(self.current_song_id)
            except ValueError:
                return  # TV is on something we didn't queue
            tail = self.queue[idx + 1:idx + 1 + UP_NEXT_COUNT]
            if not tail:
                return  # genuinely the last track
            token = _media_token()
            self.send_custom({
                "type": "UP_NEXT",
                "items": [_song_media_message(s, token) for s in tail],
            })
        except Exception as e:
            print(f"📺 [cast-sender] UP_NEXT refill failed: {e}")

    def load(self, media_message, current_time=0):
        self._send(NS_MEDIA, {
            "type": "LOAD",
            "autoPlay": True,
            "currentTime": current_time,
            "media": media_message,
            "requestId": self._next_req(),
        })

    def send_custom(self, payload):
        self._send(NASRADIO_NS, payload)

    def media_command(self, mtype, **extra):
        if self.media_session_id is None:
            # A freshly joined guest session (or one that reconnected after
            # its owned socket dropped) hasn't captured the receiver's media
            # session yet: connect_and_launch fires a GET_STATUS but returns
            # without blocking on the reply. Ask again and wait briefly so the
            # FIRST pause/resume/seek works instead of racing the MEDIA_STATUS
            # that populates media_session_id. (Before this, guest pause 500'd
            # with "no active media session" and only a retry — on the now
            # cached session — succeeded. Owned sessions always had the id, so
            # only guest transport commands hit it.) Standard media-namespace
            # commands act on the media element by mediaSessionId regardless of
            # which sender issued them, so no receiver relay is needed here —
            # unlike QUEUE_INSERT/SKIP, which manipulate the owner's queue.
            self._send(NS_MEDIA, {"type": "GET_STATUS",
                                  "requestId": self._next_req()})
            deadline = time.time() + 3
            while (self.media_session_id is None and self.alive
                   and time.time() < deadline):
                eventlet.sleep(0.1)
        if self.media_session_id is None:
            raise RuntimeError("no active media session on the TV")
        msg = {"type": mtype, "mediaSessionId": self.media_session_id,
               "requestId": self._next_req()}
        msg.update(extra)
        self._send(NS_MEDIA, msg)

    def _answer_waveform(self, song_id):
        """Reply to WAVEFORM_REQUEST. Cache hit answers instantly; a miss
        kicks off generation and we keep checking — the receiver's own
        retry gives up at ~30s, so we push unprompted when it lands."""
        if song_id in self._wf_pending:
            return
        self._wf_pending.add(song_id)
        try:
            deadline = time.time() + 120
            while self.alive and time.time() < deadline:
                data = _waveform_for(song_id)
                if data:
                    self.send_custom({"type": "WAVEFORM", "songId": song_id,
                                      "data": data})
                    return
                if self.current_song_id not in (None, song_id):
                    return  # song moved on; stop caring
                eventlet.sleep(3)
        except Exception as e:
            print(f"📺 [cast-sender] waveform for song {song_id} failed: {e}")
        finally:
            self._wf_pending.discard(song_id)

    def _push_lyrics(self, song_id):
        """Send cached synced lyrics (or a clear) for a track. The
        receiver stores them hidden until TOGGLE_LYRICS."""
        if song_id == self._lyrics_sent_for:
            return
        try:
            synced = _synced_lyrics_for(song_id)
            self._lyrics_sent_for = song_id
            self.send_custom({"type": "LYRICS", "synced": synced})
        except Exception as e:
            print(f"📺 [cast-sender] lyrics push for song {song_id} failed: {e}")

    def stop_media(self):
        if self.media_session_id is not None:
            self._send(NS_MEDIA, {"type": "STOP",
                                  "mediaSessionId": self.media_session_id,
                                  "requestId": self._next_req()})

    def stop_receiver(self):
        """Close the receiver app on the TV entirely."""
        if self.session_id:
            self._send(NS_RECEIVER, {"type": "STOP",
                                     "sessionId": self.session_id,
                                     "requestId": self._next_req()},
                       dest="receiver-0")

    def close(self):
        self._closing = True
        self.alive = False
        try:
            self.sock.close()
        except Exception:
            pass


_sessions = {}  # host -> HeadlessCastSession


# ── Persistent cast state ──────────────────────────────────────────────
# One small JSON file on the data volume: the queue we own (song ids, in
# order), which track, how far in. Written on every change and every ~10 s
# while playing; read by /api/cast/resume and by the post-restart auto-
# resume. Without it a stop, a TV that killed the paused app, or a backend
# restart threw the whole queue away (simpson1045, 2026-09-20: "useless").
CAST_STATE_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "data", "cast_state.json")
AUTO_RESUME_MAX_AGE_SEC = 900


def _save_state(s, stopped=False):
    """Persist a session we own. Guests and idle sessions write nothing."""
    try:
        if s.joined:
            return
        if s.kind == "station":
            if not s.station_query:
                return
            state = {"kind": "station", "station_query": s.station_query}
        else:
            if not s.queue:
                return
            state = {"kind": s.kind or "songs",
                     "queue": [q["id"] for q in s.queue],
                     "current_song_id": s.current_song_id,
                     "position": round(max(0.0, s.position_now()), 1)}
        state.update({"host": s.host, "label": s.label,
                      "source": s.source, "shuffled": bool(s.shuffled),
                      "player_state": s.player_state,
                      "stopped": bool(stopped), "updated_at": time.time()})
        tmp = CAST_STATE_PATH + ".tmp"
        os.makedirs(os.path.dirname(CAST_STATE_PATH), exist_ok=True)
        with open(tmp, "w") as f:
            json.dump(state, f)
        os.replace(tmp, CAST_STATE_PATH)
    except Exception as e:
        print(f"📺 [cast-sender] state save failed: {e}")


def _load_state():
    try:
        with open(CAST_STATE_PATH) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _songs_by_ids(ids):
    """Library rows for these ids, in THIS order; ids that are gone drop out."""
    if not ids:
        return []
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute(
            f"""SELECT {_SONG_COLS} FROM songs s
                JOIN artists ar ON ar.id = s.artist_id
                JOIN albums al ON al.id = s.album_id
                WHERE s.id = ANY(%s)""", (list(ids),))
        by_id = {r["id"]: dict(r) for r in cur.fetchall()}
    finally:
        conn.close()
    return [by_id[i] for i in ids if i in by_id]


def _restore_cast(host, wake=True):
    """Bring back the last cast we owned: same queue, same track, same
    second. Returns a summary dict; raises RuntimeError when there is
    nothing to restore or the TV can't be reached."""
    st = _load_state()
    if not st:
        raise RuntimeError("nothing to resume — no saved cast")
    host = _resolve_host(host or st.get("host"))
    if st.get("kind") == "station":
        resolved = resolve_query(st.get("station_query") or "", "station")
        if not resolved or resolved.get("kind") != "station":
            raise RuntimeError("the saved station no longer resolves")
        session = _get_session(host, wake=wake)
        session.kind, session.label = "station", resolved["label"]
        session.station_query = st.get("station_query")
        _cast_station(session, resolved["station"])
        _save_state(session)
        return {"resumed": resolved["label"], "kind": "station"}

    songs = _songs_by_ids(st.get("queue") or [])
    if not songs:
        raise RuntimeError("nothing to resume — the saved queue is empty")
    ids = [t["id"] for t in songs]
    try:
        idx = ids.index(st.get("current_song_id"))
    except ValueError:
        idx = 0
    # Back up a couple of seconds so the resume doesn't land mid-word.
    pos = max(0.0, float(st.get("position") or 0) - 2.0)
    session = _get_session(host, wake=wake)
    session.queue = songs
    session.kind, session.label = st.get("kind"), st.get("label")
    session.source, session.shuffled = st.get("source"), bool(st.get("shuffled"))
    session._station_poll_gen += 1
    song = _load_queue_index(session, idx, current_time=pos)
    session.position, session.position_at = pos, time.time()
    _save_state(session)
    print(f"📺 [cast-sender] Resumed {st.get('label') or 'queue'}: "
          f"{song['title']} at {int(pos)}s, track {idx + 1} of {len(songs)} → {host}")
    return {"resumed": st.get("label"), "kind": st.get("kind"),
            "now_playing": song["title"], "artist": song["artist_name"],
            "position": int(pos), "track": idx + 1, "of": len(songs)}


def _auto_resume_after_restart():
    """If music was playing when the backend went down, put it back."""
    st = _load_state()
    if not st or st.get("stopped") or st.get("player_state") not in ("PLAYING", "BUFFERING"):
        return
    age = time.time() - float(st.get("updated_at") or 0)
    if age > AUTO_RESUME_MAX_AGE_SEC:
        return
    host = st.get("host") or config.CAST_DEVICE_HOST
    if not host:
        return
    # Look before leaping: if the TV is already busy, don't stomp on it.
    try:
        live = _guest_session(host)
    except Exception:
        live = None
    if live is not None and live.alive:
        busy = live.player_state in ("PLAYING", "BUFFERING", "PAUSED")
        if live.joined and busy:
            print("📺 [cast-sender] auto-resume skipped — someone else's cast "
                  "is on the TV")
            return
        if not live.joined and live.player_state in ("PLAYING", "BUFFERING"):
            print("📺 [cast-sender] auto-resume not needed — our cast is still "
                  "playing; ownership reclaimed")
            return
    print(f"📺 [cast-sender] cast was playing {int(age)}s ago — auto-resuming")
    try:
        # No wake: it was playing minutes ago, so the room is already on.
        _restore_cast(host, wake=False)
    except Exception as e:
        print(f"📺 [cast-sender] auto-resume failed: {e}")


def schedule_auto_resume(delay=25):
    if os.environ.get("NASRADIO_DISABLE_CAST_AUTORESUME"):
        return
    eventlet.spawn_after(delay, _auto_resume_after_restart)


def _get_session(host, wake=True):
    """A session WE drive: launches the receiver (or re-uses our own live
    session). Used by play/party, which replace whatever is on the TV.
    A guest session we hold from an earlier queue/status call is dropped
    first — its owner is about to lose the TV anyway."""
    s = _sessions.get(host)
    if s and s.alive and s.transport_id and not s.joined:
        if not _looks_frozen(s):
            return s
        print(f"📺 [cast-sender] session on {host} has sat IDLE with no media "
              f"for {int(time.time() - s.idle_since)}s — relaunching the receiver")
        _kill_receiver_app(s)
    if s is not None:
        try:
            s.close()
        except Exception:
            pass
        _sessions.pop(host, None)
    if wake:
        _wake_the_room(host)
    s = HeadlessCastSession(host)
    if not s.connect_and_launch(join=False):
        raise RuntimeError(
            f"could not reach/launch receiver on {host} "
            f"(last_error={s.last_error})")
    _sessions[host] = s
    return s


def _guest_session(host):
    """Join a cast somebody else started (simpson1045's phone), without waking
    anything or launching. Returns None when the TV is off / unreachable
    or no NASRadio receiver is running on it."""
    s = _sessions.get(host)
    if s and s.alive and s.transport_id:
        return s
    if s is not None:
        _sessions.pop(host, None)
    s = HeadlessCastSession(host)
    try:
        ok = s.connect_and_launch(join=True, launch=False)
    except OSError as e:
        print(f"📺 [cast-sender] guest join: {host} unreachable ({e})")
        return None
    if not ok:
        try:
            s.close()
        except Exception:
            pass
        return None
    _sessions[host] = s
    _reclaim_if_ours(s)
    return s


def _reclaim_if_ours(s):
    """We joined a running receiver as a guest. If what it's playing is the
    headless queue in our own state file, this is OUR cast whose control
    socket died (or the backend restarted under it): take ownership back —
    queue, label, playhead tracking, UP_NEXT refills, state saves."""
    if not s.joined:
        return False
    deadline = time.time() + 2.5
    while time.time() < deadline and s.current_song_id is None and s.alive:
        eventlet.sleep(0.1)
    st = _load_state()
    if (not st or st.get("kind") == "station" or not s.remote_headless
            or s.current_song_id not in (st.get("queue") or [])):
        return False
    songs = _songs_by_ids(st["queue"])
    if not songs:
        return False
    s.queue = songs
    s.kind, s.label = st.get("kind"), st.get("label")
    s.source, s.shuffled = st.get("source"), bool(st.get("shuffled"))
    s.joined = False
    s._our_session_id = s.session_id
    print(f"📺 [cast-sender] reclaimed our cast on {s.host}: "
          f"{s.label or 'queue'}, {len(songs)} tracks, on song {s.current_song_id}")
    eventlet.spawn_n(s._refill_up_next)
    _save_state(s)
    return True


def _reattach_loop(host, dead, tries=30, every=20):
    """An owned session's socket died. Keep trying to get back on for ten
    minutes; stop as soon as anything else has replaced the session (a new
    play, a stop, a resume)."""
    for _ in range(tries):
        eventlet.sleep(every)
        cur = _sessions.get(host)
        if cur is not dead and cur is not None and cur.alive:
            return  # someone already reconnected
        if cur is dead:
            _sessions.pop(host, None)
        try:
            s = _guest_session(host)
        except Exception as e:
            print(f"📺 [cast-sender] re-attach attempt failed: {e}")
            continue
        if s is not None and not s.joined:
            return  # reclaimed
        if s is not None:
            # A receiver is up but it isn't playing our queue (the phone took
            # over, or it went idle). Nothing to reclaim; leave it alone.
            return


# ── Self-heal for a frozen receiver ────────────────────────────────────
# 2026-09-23: the receiver stayed connected but sat IDLE at 0:00, fetched no
# streams, and "resume" only moved the pointer; a backend restart + fresh
# play fixed it. Now the sender notices and fixes it itself:
#   1st attempt  reload the current track at the saved position
#   2nd attempt  STOP the receiver app on the TV (kills the frozen instance),
#                relaunch it and restore the queue at the same song/second
#   then         give up for HEAL_WINDOW_SEC and log it - never loops.
IDLE_HEAL_AFTER_SEC = 45
FROZEN_FOR_PLAY_SEC = 20
HEAL_WINDOW_SEC = 600
HEAL_MAX_IN_WINDOW = 2


def _legitimately_idle(s):
    """IDLE that is not a fault: user stop or pause, a station, the end of the
    queue, the TV switched away from the cast app, or another sender took over."""
    if s.joined or not s.queue or s.kind == "station":
        return True
    if s.taken_over or s.app_running is False:
        return True
    if s.last_active_state == "PAUSED":
        return True
    ids = [q["id"] for q in s.queue]
    if s.idle_reason == "FINISHED" and ids and s.current_song_id == ids[-1]:
        return True
    st = _load_state()
    return bool(st and st.get("stopped"))


def _wedged(s):
    return (s.player_state == "IDLE" and s.idle_since is not None
            and time.time() - s.idle_since >= IDLE_HEAL_AFTER_SEC
            and not _legitimately_idle(s))


def _looks_frozen(s):
    """For play: an owned session idle for a while is not worth reusing."""
    return (s.player_state == "IDLE" and s.idle_since is not None
            and time.time() - s.idle_since >= FROZEN_FOR_PLAY_SEC)


def _kill_receiver_app(s):
    """Stop the NASRadio receiver app on the TV so the next LAUNCH starts a
    fresh instance instead of re-attaching to a frozen one."""
    try:
        s.stop_media()
    except Exception:
        pass
    try:
        s.stop_receiver()
    except Exception:
        pass
    eventlet.sleep(2)


def _heal(s):
    try:
        # Fresh look at what the TV is running before touching anything: if
        # the user switched inputs / opened another app, or another sender
        # launched over us, this is not ours to fix.
        asked = time.time()
        s._send(NS_RECEIVER, {"type": "GET_STATUS", "requestId": s._next_req()},
                dest="receiver-0")
        deadline = asked + 4
        while time.time() < deadline and s._receiver_status_at < asked and s.alive:
            eventlet.sleep(0.2)
        if s._receiver_status_at < asked or _legitimately_idle(s) or not _wedged(s):
            if s._receiver_status_at < asked:
                print(f"📺 [cast-sender] self-heal skipped on {s.host}: TV did not answer a status check")
            return
        now = time.time()
        s._heal_times = [t for t in s._heal_times if now - t < HEAL_WINDOW_SEC]
        if len(s._heal_times) >= HEAL_MAX_IN_WINDOW:
            if not s._heal_gave_up:
                s._heal_gave_up = True
                print(f"📺 [cast-sender] self-heal: {len(s._heal_times)} attempts in "
                      f"{HEAL_WINDOW_SEC // 60} min on {s.host} and still IDLE - giving up")
            return
        s._heal_times.append(now)
        attempt = len(s._heal_times)
        ids = [q["id"] for q in s.queue]
        idx = ids.index(s.current_song_id) if s.current_song_id in ids else 0
        pos = max(0.0, s.position_now() - 2.0)
        idle_for = int(now - (s.idle_since or now))
        if attempt == 1:
            print(f"📺 [cast-sender] self-heal 1/2: IDLE for {idle_for}s mid-queue on "
                  f"{s.host} - reloading track {idx + 1} of {len(ids)} at {int(pos)}s")
            s.idle_since = None
            _load_queue_index(s, idx, current_time=pos)
            s.position, s.position_at = pos, time.time()
            _save_state(s)
        else:
            print(f"📺 [cast-sender] self-heal 2/2: still IDLE on {s.host} - stopping the "
                  f"receiver app and relaunching at track {idx + 1}, {int(pos)}s")
            s.position, s.position_at = pos, time.time()
            _save_state(s)
            _kill_receiver_app(s)
            host = s.host
            s.close()
            if _sessions.get(host) is s:
                _sessions.pop(host, None)
            out = _restore_cast(host, wake=False)
            fresh = _sessions.get(host)
            if fresh is not None:
                fresh._heal_times = list(s._heal_times)
            print(f"📺 [cast-sender] self-heal: relaunched - {out.get('now_playing')}")
    except Exception as e:
        print(f"📺 [cast-sender] self-heal failed on {s.host}: {e}")
    finally:
        s._healing = False


# ── Wake choreography ──────────────────────────────────────────────────

def _send_wol(mac, host=None):
    """Magic packet, three ways. This container sits on a Docker bridge
    network, and a broadcast from there never leaves the bridge (verified
    with tcpdump on the NAS host, 2026-09-13: only the unicast packet hit
    the wire). Unicast to the TV's IP is what actually wakes it, and it
    relies on the host holding a permanent ARP entry for the TV so the
    frame still goes out with the TV's MAC after it has been off a while.
    The broadcasts stay for the day this runs somewhere with a real NIC."""
    try:
        raw = bytes.fromhex(mac.replace(":", ""))
        pkt = b"\xff" * 6 + raw * 16
        targets = [("255.255.255.255", 9)]
        if config.CAST_WOL_BROADCAST:
            targets.append((config.CAST_WOL_BROADCAST, 9))
        if host:
            targets.append((host, 9))
        for _ in range(3):
            for dst in targets:
                s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
                try:
                    s.sendto(pkt, dst)
                except Exception as e:
                    print(f"📺 [cast-sender] WOL to {dst[0]} failed: {e}")
                finally:
                    s.close()
    except Exception as e:
        print(f"📺 [cast-sender] WOL failed: {e}")


def _denon(*commands):
    """Fire raw Denon telnet commands, best-effort. No-op without DENON_HOST."""
    if not config.DENON_HOST:
        return False
    try:
        s = socket.create_connection((config.DENON_HOST, config.DENON_TELNET_PORT), timeout=4)
        for c in commands:
            s.sendall((c + "\r").encode())
            eventlet.sleep(0.3)
        s.close()
        return True
    except Exception as e:
        print(f"🔊 [cast-sender] Denon command failed: {e}")
        return False


def _wait_for_port(host, port, timeout=25):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            c = socket.create_connection((host, port), timeout=3)
            c.close()
            return True
        except Exception:
            eventlet.sleep(1.5)
    return False


def _wake_the_room(host):
    """TV awake + Denon on the eARC input. Cheap when already awake."""
    if config.CAST_DEVICE_WOL_MAC:
        _send_wol(config.CAST_DEVICE_WOL_MAC, host=host)
    _denon("ZMON", "Z2OFF")  # ZMON not PWON: PWON is system power and turns Zone 2 on
    up = _wait_for_port(host, C2_CAST_PORT)
    if up:
        # Input AFTER power-on settles; harmless if already there.
        _denon(config.DENON_INPUT_CMD)
    else:
        print(f"📺 [cast-sender] {host}:{C2_CAST_PORT} never came up after WOL")


# ── Library resolution ─────────────────────────────────────────────────

def _media_token():
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute(
            "SELECT id, token_version FROM users ORDER BY id LIMIT 1")
        u = cur.fetchone()
        return auth.generate_token(u["id"], u["token_version"], "media")
    finally:
        conn.close()


def refresh_artwork(album_id=None, artist_id=None):
    """Album cover or artist image changed in the app. If a headless cast is
    showing that album/artist right now, hand the receiver cache-busted URLs
    so the TV repaints without waiting for the next track (the URLs are
    otherwise identical per album/artist, and the TV's browser caches them).
    Called from the artwork/artist-image update routes; never raises."""
    if not _sessions:
        return 0
    sent = 0
    try:
        db = _get_db()
        conn = db.get_connection()
        try:
            cur = db.get_cursor(conn)
            for s in list(_sessions.values()):
                sid = s.current_song_id
                if not sid:
                    continue
                cur.execute("SELECT album_id, artist_id FROM songs WHERE id = %s", (sid,))
                row = cur.fetchone()
                if not row:
                    continue
                if album_id is not None and row["album_id"] != album_id:
                    continue
                if artist_id is not None and row["artist_id"] != artist_id:
                    continue
                token = _media_token()
                v = int(time.time())
                s.send_custom({
                    "type": "ARTWORK_REFRESH",
                    "songId": sid,
                    "artworkUrl": f"{_public_base()}/api/artwork/{row['album_id']}?token={token}&v={v}",
                    "artistImageUrl": f"{_public_base()}/api/artist-image/{row['artist_id']}?token={token}&v={v}",
                })
                sent += 1
        finally:
            conn.close()
    except Exception as e:
        print(f"📺 [cast-sender] artwork refresh failed: {e}")
    return sent


def _waveform_for(song_id):
    """Waveform floats for a song, None when not ready. Mirrors
    GET /api/waveform: a cache hit returns instantly; a miss starts
    background generation (the caller polls)."""
    from app.path_utils import ensure_windows_path
    from app.waveform import WaveformGenerator

    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute("SELECT file_path FROM songs WHERE id = %s", (song_id,))
        row = cur.fetchone()
    finally:
        conn.close()
    if not row or not row["file_path"]:
        return None
    result = WaveformGenerator().generate_waveform(
        ensure_windows_path(row["file_path"]), song_id)
    if isinstance(result, dict) and result.get("status") == "ready":
        return result.get("waveform")
    return None


def _synced_lyrics_for(song_id):
    """DB-cached synced lyrics only — the LRCLIB fetch-on-miss lives in
    GET /api/lyrics; anything ever viewed on the phone is cached here."""
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute("SELECT synced_lyrics FROM lyrics WHERE song_id = %s",
                    (song_id,))
        row = cur.fetchone()
        return row["synced_lyrics"] if row else None
    finally:
        conn.close()


_MIME = {"FLAC": "audio/flac", "MP3": "audio/mpeg", "M4A": "audio/mp4",
         "AAC": "audio/mp4", "WAV": "audio/wav", "WAVE": "audio/wav",
         "OGG": "audio/ogg", "OPUS": "audio/opus",
         "AIFF": "audio/aiff", "AIF": "audio/aiff"}


def _mime_for(file_path):
    ext = (file_path or "").rsplit(".", 1)[-1].upper()
    return _MIME.get(ext, "audio/flac")


def _special_waveform(artist, album, title):
    """Port of the app's _detectSpecialWaveform — EVH stripes for Van
    Halen (yes, 5150 gets the Frankenstein), DNA for Jurassic, sabers
    for Star Wars."""
    a, al, t = (artist or "").lower(), (album or "").lower(), (title or "").lower()
    if "van halen" in a:
        return "evh"
    if "jurassic park" in al or "jurassic world" in al:
        return "dna"
    if "star wars" in al or "star wars" in t:
        red = ["imperial", "vader", "duel of the fates", "sith", "dark side",
               "dark lord", "emperor", "palpatine", "order 66", "grievous",
               "dooku", "battle of the heroes", "immolation", "kylo",
               "snoke", "first order", "darth"]
        green = ["yoda", "dagobah", "jedi council", "qui-gon", "qui gon"]
        if any(k in t for k in red):
            return "lightsaber:red"
        if any(k in t for k in green):
            return "lightsaber:green"
        if "mace windu" in t:
            return "lightsaber:purple"
        return "lightsaber:blue"
    return None


def _song_media_message(song, token):
    tok = f"&token={token}"
    # Dolby bitstreams (eac3/ac3, incl. Atmos) stream as-is — the C2's eARC
    # passes them through to the Denon untouched. Multichannel PCM instead
    # requests quality=cast, which serves the E-AC-3 sidecar if one exists
    # (raw >2ch PCM gets folded to stereo by the TV). Stereo stays lossless.
    _codec = (song.get("audio_codec") or "").lower()
    _multich = (song.get("audio_channels") or 2) > 2
    _quality = "cast" if (_multich and _codec not in ("eac3", "ac3")) else "lossless"
    stream = (f"{_public_base()}/api/stream/{song['id']}?quality={_quality}{tok}")
    artwork = f"{_public_base()}/api/artwork/{song['album_id']}?token={token}"
    artist_img = f"{_public_base()}/api/artist-image/{song['artist_id']}?token={token}"
    return {
        "contentId": stream,
        "contentType": ("audio/mp4" if _quality == "cast"
                        else _mime_for(song.get("file_path"))),
        "streamType": "BUFFERED",
        "metadata": {
            "type": 3, "metadataType": 3,
            "title": song["title"], "songName": song["title"],
            "artist": song["artist_name"],
            "albumName": song["album_title"],
            "albumArtist": song["artist_name"],
            "trackNumber": song.get("track_number") or 0,
            "images": [{"url": artwork}],
        },
        "customData": {
            "artistImageUrl": artist_img,
            "specialWaveform": _special_waveform(
                song["artist_name"], song["album_title"], song["title"]),
            # Describe what the TV actually receives: sidecar/eac3 casts play
            # DD+, not the library file's container.
            "fileFormat": ("DD+" if (_quality == "cast" or _codec in ("eac3", "ac3"))
                           else (song.get("file_path") or "").rsplit(".", 1)[-1].upper()),
            "isHdcd": bool(song.get("is_hdcd")),
            "isAtmos": bool(song.get("is_atmos")),
            "audioChannels": song.get("audio_channels") or 2,
            "isExplicit": bool(song.get("is_explicit")),
            "songId": song["id"],
            # No phone racing us to LOAD → receiver uses the 250ms
            # self-advance grace instead of 4s of dead air per track.
            "headlessSender": True,
        },
    }


_SONG_COLS = ("s.id, s.title, s.track_number, s.disc_number, s.file_path, "
              "s.is_explicit, s.is_hdcd, s.audio_codec, s.audio_channels, "
              "s.is_atmos, s.artist_id, s.album_id, "
              "ar.name AS artist_name, al.title AS album_title")


def resolve_query(q, kind="auto"):
    """'5150' → {'kind': 'album', 'label': ..., 'songs': [...]}.
    Albums beat songs on ambiguity (simpson1045's call). Stations resolve from
    the saved stations table."""
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)

        if kind in ("auto", "album"):
            cur.execute(
                f"""SELECT al.id, al.title, ar.name AS artist_name
                    FROM albums al JOIN artists ar ON ar.id = al.artist_id
                    WHERE al.title ILIKE %s
                       OR similarity(LOWER(al.title), LOWER(%s)) > 0.45
                    ORDER BY similarity(LOWER(al.title), LOWER(%s)) DESC
                    LIMIT 1""", (f"%{q}%", q, q))
            album = cur.fetchone()
            if album:
                cur.execute(
                    f"""SELECT {_SONG_COLS} FROM songs s
                        JOIN artists ar ON ar.id = s.artist_id
                        JOIN albums al ON al.id = s.album_id
                        WHERE s.album_id = %s AND s.source_type = 'local'
                        ORDER BY s.disc_number NULLS FIRST, s.track_number, s.id""",
                    (album["id"],))
                songs = [dict(r) for r in cur.fetchall()]
                if songs:
                    return {"kind": "album",
                            "label": f"{album['title']} — {album['artist_name']}",
                            "source": {"type": "album", "id": album["id"],
                                       "name": album["title"],
                                       "artist": album["artist_name"]},
                            "songs": songs}

        if kind in ("auto", "playlist"):
            cur.execute(
                """SELECT id, name FROM playlists
                   WHERE name ILIKE %s
                      OR similarity(LOWER(name), LOWER(%s)) > 0.4
                   ORDER BY similarity(LOWER(name), LOWER(%s)) DESC
                   LIMIT 1""", (f"%{q}%", q, q))
            pl = cur.fetchone()
            if pl:
                cur.execute(
                    f"""SELECT {_SONG_COLS} FROM playlist_songs ps
                        JOIN songs s ON s.id = ps.song_id
                        JOIN artists ar ON ar.id = s.artist_id
                        JOIN albums al ON al.id = s.album_id
                        WHERE ps.playlist_id = %s AND s.source_type = 'local'
                        ORDER BY ps.position""", (pl["id"],))
                songs = [dict(r) for r in cur.fetchall()]
                if songs:
                    return {"kind": "playlist",
                            "label": pl["name"],
                            "source": {"type": "playlist", "id": pl["id"],
                                       "name": pl["name"]},
                            "songs": songs}

        if kind in ("auto", "song"):
            cur.execute(
                f"""SELECT {_SONG_COLS} FROM songs s
                    JOIN artists ar ON ar.id = s.artist_id
                    JOIN albums al ON al.id = s.album_id
                    WHERE s.source_type = 'local'
                      AND (s.title ILIKE %s
                           OR similarity(LOWER(s.title), LOWER(%s)) > 0.4)
                    ORDER BY similarity(LOWER(s.title), LOWER(%s)) DESC
                    LIMIT 1""", (f"%{q}%", q, q))
            hit = cur.fetchone()
            if hit:
                # The matched song, then the rest of its album after it.
                cur.execute(
                    f"""SELECT {_SONG_COLS} FROM songs s
                        JOIN artists ar ON ar.id = s.artist_id
                        JOIN albums al ON al.id = s.album_id
                        WHERE s.album_id = %s AND s.source_type = 'local'
                        ORDER BY s.disc_number NULLS FIRST, s.track_number, s.id""",
                    (hit["album_id"],))
                album_songs = [dict(r) for r in cur.fetchall()]
                ids = [s["id"] for s in album_songs]
                start = ids.index(hit["id"]) if hit["id"] in ids else 0
                return {"kind": "song",
                        "label": f"{hit['title']} — {hit['artist_name']}",
                        "source": {"type": "album", "id": hit["album_id"],
                                   "name": hit.get("album_title"),
                                   "artist": hit["artist_name"],
                                   "start_song_id": hit["id"]},
                        "songs": album_songs[start:]}

        if kind in ("auto", "station"):
            cur.execute(
                """SELECT id, name, url, favicon, genre FROM stations
                   WHERE is_active = 1
                     AND (name ILIKE %s
                          OR similarity(LOWER(name), LOWER(%s)) > 0.3)
                   ORDER BY similarity(LOWER(name), LOWER(%s)) DESC
                   LIMIT 1""", (f"%{q}%", q, q))
            st = cur.fetchone()
            if st:
                return {"kind": "station", "label": st["name"],
                        "station": dict(st)}

        return None
    finally:
        conn.close()


def _party_shuffle_songs(limit=25):
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        # Bias toward stuff that actually gets played, salted with random.
        cur.execute(
            f"""SELECT {_SONG_COLS} FROM songs s
                JOIN artists ar ON ar.id = s.artist_id
                JOIN albums al ON al.id = s.album_id
                WHERE s.source_type = 'local'
                ORDER BY random() LIMIT %s""", (limit * 3,))
        pool = [dict(r) for r in cur.fetchall()]
        random.shuffle(pool)
        return pool[:limit]
    finally:
        conn.close()


# ── Cast operations ────────────────────────────────────────────────────

def _cast_songs(session, songs, label=None, kind=None, source=None, shuffled=False):
    session.queue = list(songs)
    session.label, session.kind, session.station_query = label, kind, None
    session.source, session.shuffled = source, bool(shuffled)
    session._heal_times, session._heal_gave_up = [], False
    session._station_poll_gen += 1  # songs playing → any station poll dies
    song = _load_queue_index(session, 0)
    _save_state(session)
    return song


def _load_queue_index(session, idx, current_time=0):
    """LOAD queue[idx] + hand the receiver the UP_NEXT tail from there."""
    token = _media_token()
    song = session.queue[idx]
    session.load(_song_media_message(song, token), current_time=current_time)
    # Give the receiver a beat to process LOAD before custom messages —
    # same deferred-send lesson the phone sender learned the hard way.
    eventlet.sleep(2)
    up_next = [_song_media_message(s, token)
               for s in session.queue[idx + 1:idx + 1 + UP_NEXT_COUNT]]
    session.send_custom({"type": "UP_NEXT", "items": up_next})
    return song


def _queue_jump(session, offset):
    """next/previous relative to whatever the TV is on now (it may have
    self-advanced past what we last loaded)."""
    ids = [s["id"] for s in session.queue]
    if not ids:
        raise RuntimeError("no queue on this session (station or no cast?)")
    try:
        idx = ids.index(session.current_song_id)
    except ValueError:
        idx = 0
    target = idx + offset
    if not 0 <= target < len(ids):
        raise RuntimeError("already at the "
                           + ("start" if target < 0 else "end") + " of the queue")
    return _load_queue_index(session, target)


def _station_poll(session, station, gen):
    """Push NOW_PLAYING while this station is casting — the phone's 15s
    poll, in-process. Dies when the session dies, a new cast bumps the
    generation, or the poll itself errors out of existence."""
    from app.station_metadata import get_station_now_playing
    last = None
    while session.alive and session._station_poll_gen == gen:
        try:
            info = eventlet.tpool.execute(
                get_station_now_playing, station["url"],
                station.get("homepage")) or {}
            key = (info.get("title"), info.get("artist"),
                   info.get("artwork_url"))
            if info.get("title") and key != last:
                last = key
                session.send_custom({
                    "type": "NOW_PLAYING",
                    "title": info.get("title"),
                    "artist": info.get("artist"),
                    "artwork": info.get("artwork_url"),
                })
        except Exception as e:
            print(f"📻 [cast-sender] station poll ({station['name']}): {e}")
        eventlet.sleep(15)


def _cast_station(session, station):
    token = _media_token()
    from urllib.parse import quote
    relay = (f"{_public_base()}/api/station-proxy?url={quote(station['url'], safe='')}"
             f"&token={token}")
    session.queue = []  # stations have no queue; next/previous refuse
    session.load({
        "contentId": relay,
        "contentType": "audio/mpeg",
        "streamType": "LIVE",
        "metadata": {
            "type": 3, "metadataType": 3,
            "title": station["name"],
            "artist": station.get("genre") or "Live Radio",
            "images": [{"url": station["favicon"]}] if station.get("favicon") else [],
        },
        "customData": {"songId": -station["id"]},
    })
    session._station_poll_gen += 1
    eventlet.spawn_n(_station_poll, session, station,
                     session._station_poll_gen)


# ── Endpoints ──────────────────────────────────────────────────────────

@cast_api.before_request
def _cast_gate():
    if request.method == "OPTIONS":
        return None
    token = auth.extract_bearer_token()
    if not token:
        return jsonify({"error": "Authentication required"}), 401
    user, scope = auth.resolve_token(token)
    if not user or scope != "full":
        return jsonify({"error": "Full authentication required"}), 401
    g.user = user
    return None


@cast_api.route("/api/cast/play", methods=["POST"])
def cast_play():
    data = request.get_json(silent=True) or {}
    q = (data.get("query") or "").strip()
    kind = (data.get("type") or "auto").lower()
    host = _resolve_host(data.get("device"))
    wake = data.get("wake", True)
    if not q:
        return jsonify({"error": "query required"}), 400

    resolved = resolve_query(q, kind)
    if not resolved:
        return jsonify({"error": f"nothing in the library matches '{q}'"}), 404

    # shuffle:true randomizes the resolved track list (albums/playlists;
    # meaningless for stations, harmless for single-song resolves).
    if data.get("shuffle") and resolved.get("songs"):
        random.shuffle(resolved["songs"])

    try:
        session = _get_session(host, wake=wake)
    except Exception as e:
        return jsonify({"error": str(e)}), 502

    if resolved["kind"] == "station":
        session.kind, session.label, session.station_query = "station", resolved["label"], q
        session.queue = []
        session.source, session.shuffled = None, False
        _cast_station(session, resolved["station"])
        _save_state(session)
        print(f"📺 [cast-sender] Casting station {resolved['label']} → {host}")
        return jsonify({"ok": True, "casting": resolved["label"],
                        "kind": "station", "device": host})

    first = _cast_songs(session, resolved["songs"],
                        label=resolved["label"], kind=resolved["kind"],
                        source=resolved.get("source"),
                        shuffled=bool(data.get("shuffle")))
    print(f"📺 [cast-sender] Casting {resolved['label']} "
          f"({len(resolved['songs'])} tracks) → {host}")
    return jsonify({
        "ok": True, "kind": resolved["kind"], "casting": resolved["label"],
        "first_track": first["title"], "queued": len(resolved["songs"]),
        "device": host,
    })


@cast_api.route("/api/cast/party", methods=["POST"])
def cast_party():
    data = request.get_json(silent=True) or {}
    host = _resolve_host(data.get("device"))
    wake = data.get("wake", True)

    # Party session (same SQL as party.py's start — one active per host user).
    from app.party import _ensure_tables, _base_url as _party_base_url, _new_code
    _ensure_tables()
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute(
            "UPDATE party_sessions SET active = 0, ended_at = NOW() "
            "WHERE host_user_id = %s AND active = 1", (g.user["id"],))
        code = _new_code()
        cur.execute(
            "INSERT INTO party_sessions (code, host_user_id) "
            "VALUES (%s, %s) RETURNING code", (code, g.user["id"]))
        code = cur.fetchone()["code"]
        conn.commit()
    finally:
        conn.close()

    try:
        session = _get_session(host, wake=wake)
    except Exception as e:
        return jsonify({"error": str(e), "party_code": code}), 502

    songs = _party_shuffle_songs()
    if songs:
        _cast_songs(session, songs, label="Party mode", kind="party",
                    source={"type": "party"}, shuffled=True)
    session.send_custom({
        "type": "PARTY_MODE", "active": True,
        "qrUrl": f"{_party_base_url()}/api/party/qr/{code}.png",
        "code": code,
    })
    print(f"🎉 [cast-sender] PARTY TIME on {host} — code {code}")
    return jsonify({"ok": True, "party_code": code,
                    "join_url": f"{_party_base_url()}/party/{code}",
                    "opening_track": songs[0]["title"] if songs else None,
                    "device": host})


def _live_session_or_error(data):
    host = _resolve_host(data.get("device"))
    s = _sessions.get(host)
    if not s or not s.alive:
        s = _guest_session(host)
    if not s or not s.alive:
        return None, (jsonify({"error": f"no cast running on {host} "
                               "(nothing to join, and no headless session)"}), 409)
    return s, None


@cast_api.route("/api/cast/queue", methods=["POST"])
def cast_queue():
    """Add a track or album to the live cast queue, optionally as the
    very next item ("play Cabo Wabo next"). The TV shows an attribution
    toast: "«5150» added to the queue by Claude"."""
    data = request.get_json(silent=True) or {}
    s, err = _live_session_or_error(data)
    if err:
        return err
    q = (data.get("query") or "").strip()
    if not q:
        return jsonify({"error": "query required"}), 400
    if not s.queue and not s.joined:
        return jsonify({"error": "no song queue on this cast (station or "
                        "idle?) — use /api/cast/play"}), 409
    play_next = bool(data.get("next"))
    by = ((data.get("by") or "").strip()
          or (g.user or {}).get("username") or "someone")

    resolved = resolve_query(q, (data.get("type") or "auto").lower())
    if not resolved:
        return jsonify({"error": f"nothing in the library matches '{q}'"}), 404
    if resolved["kind"] == "station":
        return jsonify({"error": "stations can't sit in a queue — use "
                        "/api/cast/play to switch to one"}), 400

    songs = resolved["songs"]
    if resolved["kind"] == "song":
        songs = songs[:1]  # just the matched track, not its album tail

    if s.joined:
        return _guest_queue(s, songs, resolved["kind"], play_next, by)

    ids = [t["id"] for t in s.queue]
    try:
        idx = ids.index(s.current_song_id)
    except ValueError:
        idx = len(ids) - 1
    pos = idx + 1 if play_next else len(s.queue)
    s.queue[pos:pos] = songs

    token = _media_token()
    up_next = [_song_media_message(t, token)
               for t in s.queue[idx + 1:idx + 1 + UP_NEXT_COUNT]]
    s.send_custom({"type": "UP_NEXT", "items": up_next})
    _save_state(s)

    title = (songs[0]["album_title"] if resolved["kind"] == "album"
             else songs[0]["title"])
    s.send_custom({
        "type": "QUEUE_ADDED",
        "title": title,
        "artist": songs[0]["artist_name"],
        "by": by,
        "mode": "next" if play_next else "end",
        "kind": resolved["kind"],
        "artworkUrl": (f"{_public_base()}/api/artwork/{songs[0]['album_id']}"
                       f"?token={token}"),
        # Toast background — artist photo beats repeating the album art
        "artistImageUrl": (f"{_public_base()}/api/artist-image/"
                           f"{songs[0]['artist_id']}?token={token}"),
    })
    print(f"📺 [cast-sender] {by} queued {title} "
          f"({'next' if play_next else 'end of queue'}) on {s.host}")
    return jsonify({"ok": True, "added": title, "tracks": len(songs),
                    "position": "next" if play_next else "end",
                    "queue_length": len(s.queue), "by": by})


def _guest_queue(s, songs, kind, play_next, by):
    """Queue into a cast we don't own: hand the resolved tracks to the
    receiver as QUEUE_INSERT. The receiver forwards them to the owning
    sender (the phone inserts into its real queue and re-sends UP_NEXT),
    or, when no other sender is connected (an orphaned headless queue),
    splices them into its own self-advance list. Either way it answers
    QUEUE_INSERT_RESULT and shows the "by Claude" toast."""
    token = _media_token()
    items = [_song_media_message(t, token) for t in songs]
    for it in items:
        # The phone owns this queue and LOADs its own tracks; don't tell
        # the receiver to race it with the fast headless self-advance.
        it["customData"]["headlessSender"] = False
    title = songs[0]["album_title"] if kind == "album" else songs[0]["title"]
    reply = s.request_custom({
        "type": "QUEUE_INSERT",
        "items": items,
        "mode": "next" if play_next else "end",
        "by": by,
        "kind": kind,
        "title": title,
        "artist": songs[0]["artist_name"],
        "artworkUrl": f"{_public_base()}/api/artwork/{songs[0]['album_id']}?token={token}",
        "artistImageUrl": (f"{_public_base()}/api/artist-image/"
                           f"{songs[0]['artist_id']}?token={token}"),
    }, timeout=8)
    if reply is None:
        return jsonify({"error": "the cast's owner didn't acknowledge the "
                        "queue request (phone app asleep or on an old build?)",
                        "mode": "guest"}), 504
    if not reply.get("ok"):
        return jsonify({"error": reply.get("error") or "queue request refused",
                        "mode": "guest"}), 409
    print(f"📺 [cast-sender] {by} queued {title} as a guest "
          f"({'next' if play_next else 'end'}, handled by "
          f"{reply.get('handledBy')}) on {s.host}")
    return jsonify({"ok": True, "added": title, "tracks": len(songs),
                    "position": "next" if play_next else "end",
                    "queue_length": reply.get("queueLength"), "by": by,
                    "mode": "guest", "handled_by": reply.get("handledBy")})


@cast_api.route("/api/cast/pause", methods=["POST"])
def cast_pause():
    s, err = _live_session_or_error(request.get_json(silent=True) or {})
    if err:
        return err
    s.media_command("PAUSE")
    return jsonify({"ok": True})


@cast_api.route("/api/cast/resume", methods=["POST"])
def cast_resume():
    """Unpause if there's something live to unpause; otherwise bring the
    last cast back from the state file — same queue, track and second —
    whether it ended by stop, a dropped/killed receiver, or a restart."""
    data = request.get_json(silent=True) or {}
    host = _resolve_host(data.get("device"))
    s = _sessions.get(host)
    if not s or not s.alive:
        s = _guest_session(host)
        if s is not None:
            # Give the joined session a moment to learn the media state.
            deadline = time.time() + 2
            while time.time() < deadline and s.media_session_id is None:
                eventlet.sleep(0.1)
    if (s and s.alive and s.media_session_id is not None
            and s.player_state in ("PAUSED", "PLAYING", "BUFFERING")):
        s.media_command("PLAY")
        return jsonify({"ok": True, "mode": "unpaused"})
    try:
        out = _restore_cast(host, wake=data.get("wake", True))
    except RuntimeError as e:
        return jsonify({"error": str(e)}), 409
    except Exception as e:
        return jsonify({"error": f"resume failed: {e}"}), 502
    return jsonify(dict(out, ok=True, mode="restored"))


@cast_api.route("/api/cast/seek", methods=["POST"])
def cast_seek():
    data = request.get_json(silent=True) or {}
    s, err = _live_session_or_error(data)
    if err:
        return err
    try:
        position = float(data["position"])
    except (KeyError, TypeError, ValueError):
        return jsonify({"error": "position (seconds) required"}), 400
    s.media_command("SEEK", currentTime=max(0.0, position))
    return jsonify({"ok": True, "position": position})


@cast_api.route("/api/cast/next", methods=["POST"])
@cast_api.route("/api/cast/previous", methods=["POST"])
def cast_jump():
    s, err = _live_session_or_error(request.get_json(silent=True) or {})
    if err:
        return err
    offset = 1 if request.path.endswith("/next") else -1
    if s.joined:
        reply = s.request_custom(
            {"type": "SKIP", "direction": "next" if offset > 0 else "previous"},
            timeout=6)
        if reply is None:
            return jsonify({"error": "the cast's owner didn't acknowledge the "
                            "skip", "mode": "guest"}), 504
        if not reply.get("ok"):
            return jsonify({"error": reply.get("error") or "skip refused",
                            "mode": "guest"}), 409
        eventlet.sleep(1.5)  # let the owner's LOAD land before we ask
        st = s.request_custom({"type": "STATE_REQUEST"}, timeout=4) or {}
        np = st.get("nowPlaying") or {}
        return jsonify({"ok": True, "now_playing": np.get("title"),
                        "artist": np.get("artist"), "mode": "guest"})
    try:
        song = _queue_jump(s, offset)
    except RuntimeError as e:
        return jsonify({"error": str(e)}), 409
    return jsonify({"ok": True, "now_playing": song["title"],
                    "artist": song["artist_name"]})


@cast_api.route("/api/cast/volume", methods=["POST"])
def cast_volume():
    """Loudness lives on the Denon, not the TV — raw telnet like the
    wake choreography. MV scale capped at 85 to protect the room."""
    data = request.get_json(silent=True) or {}
    level = data.get("level")
    action = (data.get("action") or "").lower()
    if level is not None:
        try:
            lvl = max(0, min(int(level), 85))
        except (TypeError, ValueError):
            return jsonify({"error": "level must be an integer 0-85"}), 400
        ok = _denon(f"MV{lvl:02d}")
        return jsonify({"ok": bool(ok), "level": lvl})
    if action in ("up", "down"):
        ok = _denon("MVUP" if action == "up" else "MVDOWN")
        return jsonify({"ok": bool(ok)})
    if action in ("mute", "unmute"):
        ok = _denon("MUON" if action == "mute" else "MUOFF")
        return jsonify({"ok": bool(ok)})
    return jsonify({"error": "level (0-85) or action up/down/mute/unmute"}), 400


@cast_api.route("/api/cast/lyrics", methods=["POST"])
def cast_lyrics():
    """Toggle the TV lyrics view. Re-pushes the current track's synced
    lyrics first so 'show' always has data to show."""
    data = request.get_json(silent=True) or {}
    s, err = _live_session_or_error(data)
    if err:
        return err
    sid = s.current_song_id
    if sid and sid > 0:
        s._lyrics_sent_for = None  # force a fresh push
        s._push_lyrics(sid)
        eventlet.sleep(0.3)
    msg = {"type": "TOGGLE_LYRICS"}
    if data.get("show") is not None:
        msg["show"] = bool(data["show"])
    s.send_custom(msg)
    return jsonify({"ok": True})


@cast_api.route("/api/cast/sleep", methods=["POST"])
def cast_sleep():
    data = request.get_json(silent=True) or {}
    s, err = _live_session_or_error(data)
    if err:
        return err
    try:
        if data.get("seconds") is not None:
            remaining = int(data["seconds"])
        else:
            remaining = int(data.get("minutes") or 0) * 60
    except (TypeError, ValueError):
        return jsonify({"error": "minutes or seconds must be a number"}), 400
    s.send_custom({"type": "SLEEP_TIMER", "remaining": max(0, remaining)})
    return jsonify({"ok": True, "remaining_sec": max(0, remaining)})


@cast_api.route("/api/cast/crossfade", methods=["POST"])
def cast_crossfade():
    """Segue crossfade duration on the TV (volume ramp, Stage 1).
    {seconds: 0-12}; 0 disables. Receiver persists it across launches."""
    data = request.get_json(silent=True) or {}
    s, err = _live_session_or_error(data)
    if err:
        return err
    try:
        seconds = max(0.0, min(float(data.get("seconds", 4)), 12.0))
    except (TypeError, ValueError):
        return jsonify({"error": "seconds must be a number 0-12"}), 400
    s.send_custom({"type": "CROSSFADE", "seconds": seconds})
    return jsonify({"ok": True, "crossfade_sec": seconds})


@cast_api.route("/api/cast/black", methods=["POST"])
def cast_black():
    data = request.get_json(silent=True) or {}
    s, err = _live_session_or_error(data)
    if err:
        return err
    msg = {"type": "BLACK_SCREEN"}
    if data.get("active") is not None:
        msg["active"] = bool(data["active"])
    s.send_custom(msg)
    return jsonify({"ok": True})


@cast_api.route("/api/cast/stop", methods=["POST"])
def cast_stop():
    data = request.get_json(silent=True) or {}
    host = _resolve_host(data.get("device"))
    s = _sessions.get(host)
    if not s or not s.alive:
        s = _guest_session(host)
    if not s or not s.alive:
        return jsonify({"ok": True, "note": "no cast running"})
    _save_state(s, stopped=True)   # "resume" can bring this back later
    s.stop_media()
    eventlet.sleep(0.5)
    s.stop_receiver()
    s.close()
    _sessions.pop(host, None)
    print(f"📺 [cast-sender] Stopped cast on {host}")
    return jsonify({"ok": True})


@cast_api.route("/api/cast/status", methods=["GET"])
def cast_status():
    out = {}
    if not any(s.alive for s in _sessions.values()):
        # Nothing of ours — but the phone may be casting. Join quietly so
        # "what's playing?" answers either way (TV off -> None -> {}).
        if config.CAST_DEVICE_HOST:
            _guest_session(config.CAST_DEVICE_HOST)
    for host, s in list(_sessions.items()):
        if s.joined:
            st = s.request_custom({"type": "STATE_REQUEST"}, timeout=4) or {}
            np = st.get("nowPlaying") or {}
            out[host] = {
                "alive": s.alive,
                "mode": "guest",
                "player_state": st.get("playerState") or s.player_state,
                "current_song_id": np.get("songId") or s.current_song_id,
                "now_playing": ({"song_id": np.get("songId"),
                                 "title": np.get("title"),
                                 "artist": np.get("artist"),
                                 "album": np.get("album")} if np else None),
                "up_next": [{"song_id": u.get("songId"), "title": u.get("title"),
                             "artist": u.get("artist"), "album": u.get("album")}
                            for u in (st.get("upNext") or [])[:5]],
                "queue_length": None,
                "queue_position": None,
                "shuffled": None,   # the phone owns this queue; unknown here
                "source": None,
                "owner": "receiver" if st.get("headless") else "phone",
                "uptime_sec": int(time.time() - s.started_at),
                "last_error": s.last_error,
            }
            continue
        ids = [q["id"] for q in s.queue]
        try:
            qpos = ids.index(s.current_song_id) + 1
        except ValueError:
            qpos = None
        def _brief(song):
            return {"song_id": song["id"], "title": song.get("title"),
                    "artist": song.get("artist_name"),
                    "album": song.get("album_title")}
        now_playing = _brief(s.queue[qpos - 1]) if qpos else None
        up_next = [_brief(q) for q in s.queue[qpos:qpos + 5]] if qpos else []
        out[host] = {
            "alive": s.alive,
            "mode": "owner",
            "player_state": s.player_state,
            "current_song_id": s.current_song_id,
            "now_playing": now_playing,
            "up_next": up_next,
            "queue_length": len(ids),
            "queue_position": qpos,
            "label": s.label,
            "kind": s.kind,
            "shuffled": bool(s.shuffled),
            "source": s.source,
            "idle_for_sec": int(time.time() - s.idle_since) if s.idle_since else None,
            "self_heals_recent": len([x for x in s._heal_times
                                      if time.time() - x < HEAL_WINDOW_SEC]),
            "uptime_sec": int(time.time() - s.started_at),
            "last_error": s.last_error,
        }
    return jsonify(out)


def _source_tracks(source):
    """The source album/playlist in its OWN order (not the cast's order)."""
    if not source or source.get("type") not in ("album", "playlist"):
        return None
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        if source["type"] == "album":
            cur.execute(
                """SELECT s.id, s.title, ar.name AS artist_name FROM songs s
                   JOIN artists ar ON ar.id = s.artist_id
                   WHERE s.album_id = %s AND s.source_type = 'local'
                   ORDER BY s.disc_number NULLS FIRST, s.track_number, s.id""",
                (source["id"],))
        else:
            cur.execute(
                """SELECT s.id, s.title, ar.name AS artist_name FROM playlist_songs ps
                   JOIN songs s ON s.id = ps.song_id
                   JOIN artists ar ON ar.id = s.artist_id
                   WHERE ps.playlist_id = %s AND s.source_type = 'local'
                   ORDER BY ps.position""", (source["id"],))
        return [{"position": i + 1, "song_id": r["id"], "title": r["title"],
                 "artist": r["artist_name"]} for i, r in enumerate(cur.fetchall())]
    finally:
        conn.close()


@cast_api.route("/api/cast/queue", methods=["GET"])
def cast_queue_list():
    """The whole cast queue in play order, plus the source album/playlist in
    its own order, so a caller can see at a glance whether it is shuffled
    and what comes when. ?source=0 skips the source list."""
    host = _resolve_host(request.args.get("device"))
    s = _sessions.get(host)
    if not s or not s.alive:
        s = _guest_session(host)
    if not s or not s.alive:
        return jsonify({"error": "no cast running"}), 404
    if s.joined:
        st = s.request_custom({"type": "STATE_REQUEST"}, timeout=4) or {}
        return jsonify({"mode": "guest", "shuffled": None, "source": None,
                        "note": "the phone owns this queue; only up-next is visible",
                        "up_next": [{"song_id": u.get("songId"), "title": u.get("title"),
                                     "artist": u.get("artist")}
                                    for u in (st.get("upNext") or [])]})
    ids = [q["id"] for q in s.queue]
    cur_pos = ids.index(s.current_song_id) + 1 if s.current_song_id in ids else None
    queue = [{"position": i + 1, "song_id": q["id"], "title": q.get("title"),
              "artist": q.get("artist_name"), "album": q.get("album_title"),
              "now": (i + 1) == cur_pos} for i, q in enumerate(s.queue)]
    out = {"mode": "owner", "label": s.label, "kind": s.kind,
           "shuffled": bool(s.shuffled), "source": s.source,
           "queue_position": cur_pos, "queue_length": len(ids), "queue": queue}
    if request.args.get("source", "1") != "0":
        src = _source_tracks(s.source)
        if src is not None:
            out["source_tracks"] = src
            src_ids = [x["song_id"] for x in src]
            out["matches_source_order"] = ids == src_ids[:len(ids)] or ids == src_ids[-len(ids):]
    return jsonify(out)
