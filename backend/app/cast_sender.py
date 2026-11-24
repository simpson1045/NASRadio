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
  POST /api/cast/play   {query, type?, device?, wake?, with_album?}  → resolve + cast
                        (type "song" = that one track; with_album adds its album tail)
  POST /api/cast/party  {wake?}                          → party + shuffle
  POST /api/cast/queue  {query, next?, by?, type?}  → add to live queue
  POST /api/cast/queue/remove {query | position | song_id, all?} → drop upcoming track(s)
  POST /api/cast/repeat {mode: off|one|all}   → repeat this song / the whole queue
  POST /api/cast/pause | /resume | /next | /previous
  POST /api/cast/resume {previous: true|N} → put back what a later play replaced
  GET  /api/cast/history                 → what 'previous' would bring back
  POST /api/cast/seek   {position}
  POST /api/cast/volume {level 0-85 | action up/down/mute/unmute} → Denon
  POST /api/cast/lyrics {show?}          → push synced lyrics + toggle view
  POST /api/cast/sleep  {minutes | seconds}   (0 cancels)
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

from app.balanced_shuffle import balanced_shuffle
import json
import os
import random
import re
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
    # Non-Chromecast players (the NASRadio TV app on ELKO) go by name; their
    # sessions run over Socket.IO (cast_relay).
    return _relay_host(host) or host


def _relay_host(host):
    """Canonical name when `host` is a cast_relay player, else None."""
    from app.cast_relay import relay_name
    return relay_name(host)


def _new_session(host):
    """Google Cast for the TV; the Socket.IO relay for named players."""
    if _relay_host(host):
        from app.cast_relay import RelayCastSession
        return RelayCastSession(host)
    return HeadlessCastSession(host)


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
        # Repeat: "off" | "one" (this song again and again) | "all" (wrap the
        # queue). Applied through what we feed the TV's UP_NEXT list.
        self.repeat = "off"
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
        self._heal_song = None        # song the last self-heal reloaded
        self.capabilities = {}        # the receiver's CAPABILITIES message
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
        if not self._open_transport():
            return False
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

    def _open_transport(self):
        """TLS socket to the Cast device plus its reader. RelayCastSession
        (cast_relay) swaps in its Socket.IO link."""
        ctx = ssl._create_unverified_context()
        raw = socket.create_connection((self.host, self.port), timeout=8)
        self.sock = ctx.wrap_socket(raw)
        self.alive = True
        self._send(NS_CONNECTION, {"type": "CONNECT"}, dest="receiver-0")
        eventlet.spawn_n(self._pump)
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
            prev_position = self.position
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
                        eventlet.spawn_n(self._prefetch_next_lyrics)
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
                    elif (self.repeat == "one" and self.current_song_id == prev
                          and prev_position > 15 and self.position < 5):
                        # Repeat-one replay: same song started over, so the
                        # copy we put in UP_NEXT was used. Arm the next one.
                        eventlet.spawn_n(self._refill_up_next)
        elif ns == NASRADIO_NS and t in ("QUEUE_INSERT_RESULT", "SKIP_RESULT", "STATE"):
            slot = self._pending.get(payload.get("requestId"))
            if slot is not None:
                slot[1] = payload
                if not slot[0].ready():
                    slot[0].send(True)
        elif ns == NASRADIO_NS and t == "DIAG_ERROR":
            # A receiver UI exception (receiver.js _reportUiError): the TV
            # screen froze or glitched while audio kept going; this names it.
            print(f"📺 [receiver] UI error on {self.host} in {payload.get('where')}: "
                  f"{payload.get('message')} (song {payload.get('songId')}, "
                  f"{payload.get('playerState')} @ {payload.get('currentTime')}s) "
                  f"{payload.get('stack') or ''}")
        elif ns == NASRADIO_NS and t == "DIAG_FPS":
            # receiver.js measures its requestAnimationFrame rate once per
            # launch: is 120 Hz available to the Cast app at all?
            print(f"📺 [receiver] frame rate on {self.host} [{payload.get('variant') or 'startup'}]: "
                  f"{payload.get('fps')} fps (screen {payload.get('screen')}, dpr {payload.get('dpr')})")
        elif ns == NASRADIO_NS and t == "CAPABILITIES":
            # What the TV's Cast runtime says it can play (Dolby Atmos /
            # DD+ passthrough), sent by the receiver on every connect.
            print(f"📺 [receiver] capabilities from {self.host}: {json.dumps(payload)}")
            self.capabilities = payload
            _capabilities_by_host[self.host] = payload
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
            if self.current_song_id not in ids:
                return  # TV is on something we didn't queue
            tail = _up_next_tail(self)
            if not tail:
                return  # genuinely the last track
            token = _media_token()
            self.send_custom({
                "type": "UP_NEXT",
                "items": [_song_media_message(s, token, self) for s in tail],
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

    def _push_lyrics(self, song_id, attempt=0):
        """Send cached synced lyrics (or a clear) for a track. The
        receiver stores them hidden until TOGGLE_LYRICS.

        An LRCLIB error is retried (LYRICS_RETRY_S) while the song is still
        playing instead of being sent as "no lyrics" and marked done
        (Oct 30: "Hitch A Ride" lost its lyrics to a 503 burst; the same
        lookup worked two minutes later)."""
        if song_id == self._lyrics_sent_for:
            return
        if attempt and self.current_song_id != song_id:
            return  # the song moved on before the retry
        try:
            synced = _synced_lyrics_for(song_id)
        except LyricsLookupFailed as e:
            if attempt < len(LYRICS_RETRY_S):
                delay = LYRICS_RETRY_S[attempt]
                print(f"📺 [cast-sender] lyrics for song {song_id}: {e}, retrying in {delay}s")
                eventlet.spawn_after(delay, self._push_lyrics, song_id, attempt + 1)
            else:
                print(f"📺 [cast-sender] lyrics for song {song_id}: {e}, giving up (backfill later)")
                note_lyrics_failure(song_id)
            return
        except Exception as e:
            print(f"📺 [cast-sender] lyrics lookup for song {song_id} failed: {e}")
            return
        try:
            self._lyrics_sent_for = song_id
            self.send_custom({"type": "LYRICS", "synced": synced})
        except Exception as e:
            self._lyrics_sent_for = None  # not delivered: let the next push retry
            print(f"📺 [cast-sender] lyrics push for song {song_id} failed: {e}")

    def _prefetch_next_lyrics(self, attempt=0):
        """Warm the lyrics cache for the next track while this one plays, so
        the song change reads the DB instead of racing a live LRCLIB lookup."""
        try:
            tail = _up_next_tail(self)
        except Exception:
            return
        if not tail or tail[0]["id"] == self.current_song_id:
            return  # nothing next, or repeat-one
        nxt = tail[0]["id"]
        try:
            _synced_lyrics_for(nxt)
        except LyricsLookupFailed as e:
            if attempt < 2:
                print(f"📺 [cast-sender] lyrics prefetch for song {nxt}: {e}, retrying")
                eventlet.spawn_after(30 * (attempt + 1), self._prefetch_next_lyrics, attempt + 1)
            else:
                note_lyrics_failure(nxt)
        except Exception as e:
            print(f"📺 [cast-sender] lyrics prefetch for song {nxt} failed: {e}")

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


def _state_dict(s, stopped=False):
    """Where a session is: queue, track, second (or station). None if idle."""
    if s.kind == "station":
        if not s.station_query:
            return None
        state = {"kind": "station", "station_query": s.station_query}
    else:
        if not s.queue:
            return None
        state = {"kind": s.kind or "songs",
                 "queue": [q["id"] for q in s.queue],
                 "current_song_id": s.current_song_id,
                 "position": round(max(0.0, s.position_now()), 1)}
    state.update({"host": s.host, "label": s.label,
                  "source": s.source, "shuffled": bool(s.shuffled),
                  "repeat": s.repeat,
                  "player_state": s.player_state,
                  "stopped": bool(stopped), "updated_at": time.time()})
    return state


def _save_state(s, stopped=False):
    """Persist a session we own. Guests and idle sessions write nothing."""
    try:
        if s.joined:
            return
        state = _state_dict(s, stopped)
        if not state:
            return
        if stopped:
            _write_state(state)  # explicit stop: resume must see it at once
        else:
            _queue_state_write(state)
    except Exception as e:
        print(f"📺 [cast-sender] state save failed: {e}")


# Background state writes. A plain write here blocked the whole eventlet hub
# when the pool was stalled (Oct 30: the SMR drive at 90% busy), the 5 s
# heartbeat to the TV missed, and the TV dropped the cast at a song change.
# Now the newest state is handed to one writer greenlet that does the disk
# I/O in a real thread (tpool); rapid saves coalesce into one write.
_state_pending = {}   # state file -> latest state waiting to be written
_state_writer_busy = False


def _state_path(host=None):
    """The TV keeps the original file; a relay player (ELKO) gets its own,
    so one can't overwrite the other's place in a queue."""
    name = _relay_host(host) if host else None
    if name:
        return os.path.join(os.path.dirname(CAST_STATE_PATH), f"cast_state_{name.lower()}.json")
    return CAST_STATE_PATH


def _write_state(state):
    path = _state_path(state.get("host"))
    tmp = path + ".tmp"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, path)


def _queue_state_write(state):
    global _state_writer_busy
    _state_pending[_state_path(state.get("host"))] = state
    if not _state_writer_busy:
        _state_writer_busy = True
        eventlet.spawn_n(_state_writer)


def _state_writer():
    global _state_writer_busy
    import eventlet.tpool
    try:
        while _state_pending:
            _, state = _state_pending.popitem()
            try:
                eventlet.tpool.execute(_write_state, state)
            except Exception as e:
                print(f"📺 [cast-sender] state save failed: {e}")
    finally:
        _state_writer_busy = False


def _load_state(host=None):
    try:
        with open(_state_path(host)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


# What was playing before a new play replaced it, newest first, per player.
# Nov 14, 2026: testing a one-song play meant losing Matt's Mix (806 tracks,
# shuffled) - the state file only remembers the current cast. Now anything
# that throws a queue away stashes it here first, and /api/cast/resume
# {"previous": true} puts it back: same queue, track and second. Kept to 5
# so two test plays in a row don't push the real queue out.
PREV_KEEP = 5


def _prev_path(host=None):
    return _state_path(host)[:-len(".json")] + "_prev.json"


def _load_prev(host=None):
    try:
        with open(_prev_path(host)) as f:
            stack = json.load(f)
        return stack if isinstance(stack, list) else []
    except (OSError, ValueError):
        return []


def _write_prev(host, stack):
    path = _prev_path(host)
    tmp = path + ".tmp"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(tmp, "w") as f:
        json.dump(stack[:PREV_KEEP], f)
    os.replace(tmp, path)


def _stash_previous(host):
    """Before something replaces what's on `host`, keep it for 'previous'.
    The live session if we own it (freshest place), else the last cast we
    owned from the state file. The same queue again only refreshes its place."""
    try:
        host = _resolve_host(host)
        s = _sessions.get(host)
        st = _state_dict(s) if (s and s.alive and not s.joined) else None
        if st is None:
            st = _load_state(host)
        if not st:
            return
        st["stashed_at"] = time.time()
        stack = _load_prev(host)
        top = stack[0] if stack else None
        if (top and top.get("queue") == st.get("queue")
                and top.get("station_query") == st.get("station_query")):
            stack[0] = st
        else:
            stack.insert(0, st)
        import eventlet.tpool
        eventlet.tpool.execute(_write_prev, host, stack)
    except Exception as e:
        print(f"📺 [cast-sender] previous-queue stash failed: {e}")


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


def _restore_cast(host, wake=True, state=None):
    """Bring back the last cast we owned (or `state`, e.g. one from the
    previous stack): same queue, same track, same second. Returns a summary
    dict; raises RuntimeError when there is nothing to restore or the TV
    can't be reached."""
    st = state or _load_state(_resolve_host(host) if host else None)
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
    session.repeat = st.get("repeat") or "off"
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
        return s
    if s is not None:
        try:
            s.close()
        except Exception:
            pass
        _sessions.pop(host, None)
    if wake and not _relay_host(host):
        _wake_the_room(host)
    elif wake:  # ELKO: music mode via ADMS, desktop app paused (cast_relay)
        from app.cast_relay import prepare_room
        prepare_room(_relay_host(host))
    s = _new_session(host)
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
    s = _new_session(host)
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
    st = _load_state(s.host)
    if (not st or st.get("kind") == "station" or not s.remote_headless
            or s.current_song_id not in (st.get("queue") or [])):
        return False
    songs = _songs_by_ids(st["queue"])
    if not songs:
        return False
    s.queue = songs
    s.kind, s.label = st.get("kind"), st.get("label")
    s.source, s.shuffled = st.get("source"), bool(st.get("shuffled"))
    s.repeat = st.get("repeat") or "off"
    s.joined = False
    s._our_session_id = s.session_id
    print(f"📺 [cast-sender] reclaimed our cast on {s.host}: "
          f"{s.label or 'queue'}, {len(songs)} tracks, on song {s.current_song_id}")
    eventlet.spawn_n(s._refill_up_next)
    # The song may have changed while we were detached (Oct 30: the TV
    # dropped the socket at a song change and was left with no lyrics):
    # push the current track's lyrics again.
    if s.current_song_id and s.current_song_id > 0:
        s._lyrics_sent_for = None
        eventlet.spawn_n(s._push_lyrics, s.current_song_id)
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


# ── Self-heal for a stalled queue ───────────────────────────────────────
# If a queue we own sits IDLE mid-queue for 45 s, reload the current track
# at its saved position once. That is all: the 2026-09-23 "wedge" turned out
# to be a Postgres lock convoy in the backend (fixed in models.py), not the
# receiver, so there is no relaunching or closing of the cast here. One
# reload per 10 minutes; it never acts on a pause, the end of the queue, a
# user stop, a station, a guest session, the TV leaving the cast app, or
# another sender taking over, and it re-checks the TV before acting.
IDLE_HEAL_AFTER_SEC = 45
# The receiver said ERROR: the track can't play (Nov 21, 2026: a Dolby Atmos
# .m4a on ELKO, whose Chromium has no E-AC-3 decoder). No point waiting 45 s.
IDLE_HEAL_AFTER_ERROR_SEC = 8
HEAL_WINDOW_SEC = 600
# Reloads + skips per window. Until Nov 21 it was 1 reload, then nothing:
# an unplayable track sat in silence until someone noticed. More than this
# many fixes in 10 min means something bigger is broken (server, network):
# stop instead of running through the whole queue.
HEAL_MAX_IN_WINDOW = 4


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
    st = _load_state(s.host)
    return bool(st and st.get("stopped"))


def _wedged(s):
    if s.player_state != "IDLE" or s.idle_since is None:
        return False
    wait = IDLE_HEAL_AFTER_ERROR_SEC if s.idle_reason == "ERROR" else IDLE_HEAL_AFTER_SEC
    return time.time() - s.idle_since >= wait and not _legitimately_idle(s)


def _heal(s):
    try:
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
        s._heal_times = [x for x in s._heal_times if now - x < HEAL_WINDOW_SEC]
        if len(s._heal_times) >= HEAL_MAX_IN_WINDOW:
            if not s._heal_gave_up:
                s._heal_gave_up = True
                print(f"📺 [cast-sender] self-heal: {len(s._heal_times)} fixes in the last "
                      f"{HEAL_WINDOW_SEC // 60} min on {s.host} and it is IDLE again - "
                      f"leaving it (something bigger than one track is wrong)")
            return
        s._heal_times.append(now)
        ids = [q["id"] for q in s.queue]
        idx = ids.index(s.current_song_id) if s.current_song_id in ids else 0
        if s._heal_song is not None and s._heal_song == s.current_song_id:
            # This track was already reloaded and went IDLE again: it won't
            # play on this player. Skip it instead of sitting in silence.
            title = (s.queue[idx].get("title") if idx < len(s.queue) else None) or "?"
            s._heal_song = None
            if idx + 1 >= len(ids):
                print(f"📺 [cast-sender] self-heal: last track \"{title}\" won't play on "
                      f"{s.host} ({s.idle_reason}) - end of the queue")
                return
            print(f"📺 [cast-sender] self-heal: track {idx + 1} \"{title}\" won't play on "
                  f"{s.host} (reloaded once, IDLE again: {s.idle_reason}) - "
                  f"skipping to track {idx + 2} of {len(ids)}")
            s.idle_since = None
            _load_queue_index(s, idx + 1)
            s.position, s.position_at = 0.0, time.time()
            _save_state(s)
            return
        s._heal_song = s.current_song_id
        pos = max(0.0, s.position_now() - 2.0)
        print(f"📺 [cast-sender] self-heal: IDLE for {int(now - (s.idle_since or now))}s mid-queue "
              f"on {s.host} - reloading track {idx + 1} of {len(ids)} at {int(pos)}s")
        s.idle_since = None
        _load_queue_index(s, idx, current_time=pos)
        s.position, s.position_at = pos, time.time()
        _save_state(s)
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


class LyricsLookupFailed(Exception):
    """LRCLIB couldn't answer (5xx/429/timeout), as opposed to "this song has
    no lyrics". The caller retries instead of telling the TV there are none."""


# Seconds between retries of a failed lyrics lookup for the playing song.
LYRICS_RETRY_S = (5, 15, 40)

# Songs whose lyrics lookup hit an LRCLIB outage (phone or TV), retried in
# the background until it's back (Nov 3: its API 502'd for hours, and
# "Hammer To Fall" stayed lyric-less until someone tapped Try Again).
_lyrics_retry = {}             # song_id -> first failure time
_lyrics_backfill_running = False
LYRICS_BACKFILL_EVERY = 300    # seconds between passes
LYRICS_BACKFILL_MAX_AGE = 86400


def note_lyrics_failure(song_id):
    global _lyrics_backfill_running
    _lyrics_retry.setdefault(int(song_id), time.time())
    if not _lyrics_backfill_running:
        _lyrics_backfill_running = True
        eventlet.spawn_n(_lyrics_backfill_loop)


def _lyrics_backfill_loop():
    global _lyrics_backfill_running
    try:
        while _lyrics_retry:
            eventlet.sleep(LYRICS_BACKFILL_EVERY)
            now = time.time()
            for sid, since in list(_lyrics_retry.items()):
                if now - since > LYRICS_BACKFILL_MAX_AGE:
                    _lyrics_retry.pop(sid, None)
                    continue
                try:
                    synced = _synced_lyrics_for(sid)
                except LyricsLookupFailed:
                    break  # still down: next pass
                except Exception as e:
                    print(f"🎤 [lyrics] backfill for song {sid} failed: {e}")
                    _lyrics_retry.pop(sid, None)
                    continue
                _lyrics_retry.pop(sid, None)
                print(f"🎤 [lyrics] backfilled song {sid}: {'synced' if synced else 'no synced lyrics'}")
                if synced:  # a cast on that song gets them right away
                    for s in list(_sessions.values()):
                        if s.alive and s.current_song_id == sid:
                            s._lyrics_sent_for = None
                            eventlet.spawn_n(s._push_lyrics, sid)
                eventlet.sleep(2)
    finally:
        _lyrics_backfill_running = False
        if _lyrics_retry:  # one slipped in as we finished
            _lyrics_backfill_running = True
            eventlet.spawn_n(_lyrics_backfill_loop)


def lrclib_lookup(artist, title, duration):
    """LRCLIB's best entry for a song: the exact match, else the closest-length
    synced search hit (the plain exact match as fallback). Returns that entry,
    None when LRCLIB answered and has nothing, and raises LyricsLookupFailed
    when it couldn't answer (5xx/429/timeout). Shared by the TV
    (_synced_lyrics_for) and the phone's GET /api/lyrics (Oct 31: the phone's
    own copy called a 502 "No lyrics found" and never tried search)."""
    import requests
    ua = {"User-Agent": "NASRadio/1.0 (https://github.com/simpson1045/nasradio)"}
    data = None
    trouble = None   # set when LRCLIB errored rather than answered
    try:
        # Exact lookup first (one retry: LRCLIB answers 503 "ServerOverloaded"
        # in bursts), then the fuzzier search, which kept working on Oct 30
        # while /get 503'd: closest length within 8 s, synced lyrics preferred.
        for attempt in (1, 2):
            r = requests.get("https://lrclib.net/api/get", headers=ua, timeout=10,
                             params={"artist_name": artist,
                                     "track_name": title,
                                     "duration": duration})
            if r.status_code == 200:
                data = r.json()
                break
            if r.status_code != 503:
                break
            eventlet.sleep(1.5)
        if r.status_code not in (200, 404):
            trouble = f"/get HTTP {r.status_code}"
        if not (data and data.get("syncedLyrics")):
            # No exact match, or one without timing: search for a synced
            # entry of the same song; the plain exact match is the fallback.
            plain_fallback = data
            for attempt in (1, 2):
                r = requests.get("https://lrclib.net/api/search", headers=ua, timeout=10,
                                 params={"artist_name": artist,
                                         "track_name": title})
                if r.status_code != 503:
                    break
                eventlet.sleep(1.5)
            # The broader search answering is the final word on "none".
            trouble = None if r.status_code == 200 else f"/search HTTP {r.status_code}"
            hits = r.json() if r.status_code == 200 else []
            if isinstance(hits, list):
                dur = duration or 0
                hits = [h for h in hits if h.get("syncedLyrics") or h.get("plainLyrics")]
                if dur:
                    hits = [h for h in hits if abs((h.get("duration") or 0) - dur) <= 8]
                hits.sort(key=lambda h: (not h.get("syncedLyrics"),
                                         abs((h.get("duration") or 0) - dur)))
                data = hits[0] if hits else plain_fallback
            else:
                data = plain_fallback
    except (requests.exceptions.RequestException, ValueError) as e:
        raise LyricsLookupFailed(f"LRCLIB {type(e).__name__}: {e}")
    if not data:
        if trouble:
            raise LyricsLookupFailed(f"LRCLIB {trouble}")
        return None
    return data


def _synced_lyrics_for(song_id):
    """Synced lyrics for a cast track: the DB cache, else fetched from LRCLIB
    and cached (same lookup as the phone's GET /api/lyrics). It used to read
    the cache only, so a song never opened on the phone showed no lyrics on
    the TV (Oct 30: Dokken "The Hunter")."""
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute("SELECT synced_lyrics FROM lyrics WHERE song_id = %s",
                    (song_id,))
        row = cur.fetchone()
        if row and row["synced_lyrics"]:
            return row["synced_lyrics"]
        # No row, or a plain-only row (the TV shows synced lyrics only):
        # look up a synced version and fill it in. Oct 30: Dokken "The
        # Hunter" (song 1956) cached LRCLIB's plain-only exact match while
        # other entries of the same recording had full synced lyrics.
        had_plain_row = bool(row)
        cur.execute("""SELECT songs.title, artists.name AS artist_name, songs.duration
                       FROM songs JOIN artists ON songs.artist_id = artists.id
                       WHERE songs.id = %s""", (song_id,))
        song = cur.fetchone()
    finally:
        conn.close()
    if not song:
        return None

    data = lrclib_lookup(song["artist_name"], song["title"], song["duration"])
    if not data:
        return None
    synced, plain = data.get("syncedLyrics"), data.get("plainLyrics")
    if had_plain_row and not synced:
        return None  # still plain-only: keep the existing row as is
    if not (synced or plain):
        return None
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        if had_plain_row:
            cur.execute("UPDATE lyrics SET synced_lyrics = %s WHERE song_id = %s",
                        (synced, song_id))
        else:
            cur.execute("""INSERT INTO lyrics (song_id, synced_lyrics, plain_lyrics, source)
                           VALUES (%s, %s, %s, 'lrclib') ON CONFLICT DO NOTHING""",
                        (song_id, synced, plain))
        conn.commit()
    finally:
        conn.close()
    return synced


_MIME = {"FLAC": "audio/flac", "MP3": "audio/mpeg", "M4A": "audio/mp4",
         "AAC": "audio/mp4", "WAV": "audio/wav", "WAVE": "audio/wav",
         "OGG": "audio/ogg", "OPUS": "audio/opus",
         "AIFF": "audio/aiff", "AIF": "audio/aiff", "MKA": "audio/x-matroska"}


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


# The latest CAPABILITIES each player sent, by host. A receiver sends them
# once per connect, but every cast makes a new session: ELKO's TrueHD Atmos
# went out as the DD+ sidecar because the new session never heard ELKO say
# 'passthrough: mpv' (Nov 21, 2026).
_capabilities_by_host = {}


def _song_media_message(song, token, session=None):
    tok = f"&token={token}"
    # Dolby bitstreams (eac3/ac3, incl. Atmos) stream as-is — the C2's eARC
    # passes them through to the Denon untouched. Multichannel PCM instead
    # requests quality=cast, which serves the E-AC-3 sidecar if one exists
    # (raw >2ch PCM gets folded to stereo by the TV). Stereo stays lossless.
    # A relay player (the NASRadio TV app on ELKO) always gets the original:
    # its Chromium audio can't decode the E-AC-3 sidecar but plays
    # multichannel FLAC (Oct 31: 5.1 "Time" sat IDLE on ELKO).
    _codec = (song.get("audio_codec") or "").lower()
    _multich = (song.get("audio_channels") or 2) > 2
    _relay = session is not None and bool(_relay_host(session.host))
    _quality = ("cast" if (_multich and not _relay and _codec not in ("eac3", "ac3"))
                else "lossless")
    # Phase 3 (Nov 21, 2026): a relay player that plays through mpv (the
    # NASRadio TV app on ELKO says passthrough "mpv") gets the untouched
    # original for everything: Dolby (incl. Atmos, TrueHD) and DTS go to the
    # Denon as bitstreams. "lossless" would swap TrueHD for the DD+ sidecar.
    _caps = ((getattr(session, "capabilities", None) or None)
             or (_capabilities_by_host.get(session.host) if session is not None else None)
             or {})
    _dev = _caps.get("deviceCapabilities") or {}
    if _relay and _dev.get("passthrough") == "mpv":
        _quality = "bitstream"
    _badge = {"eac3": "DD+", "ac3": "DD", "truehd": "TrueHD", "dts": "DTS"}.get(_codec)
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
            "gain": _cast_gain(song),
            "specialWaveform": _special_waveform(
                song["artist_name"], song["album_title"], song["title"]),
            # Describe what the TV actually receives: sidecar/eac3 casts play
            # DD+, not the library file's container.
            "fileFormat": ("DD+" if _quality == "cast"
                           else _badge if (_badge and (_quality == "bitstream"
                                                       or _codec in ("eac3", "ac3")))
                           else (song.get("file_path") or "").rsplit(".", 1)[-1].upper()),
            "isHdcd": bool(song.get("is_hdcd")),
            # The cast sidecar is plain DD+ 5.1 (no free encoder writes the
            # Atmos layer), so a TrueHD Atmos track isn't Atmos on the TV.
            "isAtmos": bool(song.get("is_atmos")) and _quality != "cast",
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
              "ar.name AS artist_name, al.title AS album_title, "
              "(SELECT sa.integrated_loudness_lufs FROM song_analysis sa "
              " WHERE sa.song_id = s.id LIMIT 1) AS rg_lufs")

# ReplayGain for casts. The receiver sets an <audio> element's volume, which
# tops out at 1, so a cast can only turn loud tracks DOWN: bring them toward
# -14 LUFS (≈3 dB under the library's typical -11) and never boost. Same math
# as the app's CastService._castGain.
CAST_RG_TARGET_LUFS = -14.0


def _cast_gain(song):
    lufs = song.get("rg_lufs")
    if lufs is None or not (-60 < lufs < 0):
        return 1.0  # not analysed yet, or digital silence
    gain_db = max(-12.0, min(0.0, CAST_RG_TARGET_LUFS - lufs))
    return round(10 ** (gain_db / 20), 4)


def _song_with_artist(cur, q):
    """'The Hunter Dokken' / 'Dokken - The Hunter' / 'The Hunter by Dokken':
    when the query names an artist, find the title among THAT artist's songs.
    Nov 14, 2026: title-only matching kept picking Red Hot Chili Peppers'
    'The Hunter' over Dokken's. None when no artist is named or the rest of
    the query isn't one of their songs (the caller falls back to title-only).
    A query that is exactly a song title is left alone, so 'Caribbean Queen'
    never turns into a search of Queen's songs for 'Caribbean'."""
    cur.execute("""SELECT 1 FROM songs WHERE source_type = 'local'
                   AND LOWER(title) = LOWER(%s) LIMIT 1""", (q,))
    if cur.fetchone():
        return None
    low = q.lower()
    cur.execute("""SELECT id, name FROM artists
                   WHERE length(name) >= 2 AND strpos(%s, LOWER(name)) > 0
                   ORDER BY length(name) DESC LIMIT 10""", (low,))
    for art in cur.fetchall():
        name = art["name"].lower()
        m = re.search(r"(?<![a-z0-9])" + re.escape(name) + r"(?![a-z0-9])", low)
        if not m:
            continue
        rest = (q[:m.start()] + " " + q[m.end():]).strip()
        rest = re.sub(r"^(?:\s*(?:by\b|[-–—:,|]))+\s*", "", rest, flags=re.I)
        rest = re.sub(r"\s*(?:(?:\bby|[-–—:,|])\s*)+$", "", rest,
                      flags=re.I).strip(" \"'")
        if not rest:
            continue
        cur.execute(
            f"""SELECT {_SONG_COLS} FROM songs s
                JOIN artists ar ON ar.id = s.artist_id
                JOIN albums al ON al.id = s.album_id
                WHERE s.source_type = 'local' AND s.artist_id = %s
                  AND (s.title ILIKE %s
                       OR similarity(LOWER(s.title), LOWER(%s)) > 0.4)
                ORDER BY (LOWER(s.title) = LOWER(%s)) DESC,
                         similarity(LOWER(s.title), LOWER(%s)) DESC, s.id
                LIMIT 1""", (art["id"], f"%{rest}%", rest, rest, rest))
        hit = cur.fetchone()
        if hit:
            return hit
    return None


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
                        {_ALBUM_REFS_JOIN}
                        WHERE {_ALBUM_REFS_WHERE} AND s.source_type = 'local'
                        ORDER BY {_ALBUM_REFS_ORDER}""",
                    (album["id"], album["id"]))
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
            hit = _song_with_artist(cur, q)
            if not hit:
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

        if kind == "artist":
            # Everything credited to the artist (primary or featured), minus
            # albums flagged exclude_from_shuffle. Explicit only: "Van Halen"
            # on auto still means the 1978 album. Name match ignores
            # punctuation/spacing, so a stray "Van Halen  -" credit folds in.
            cur.execute(
                """SELECT id, name FROM artists
                   WHERE regexp_replace(lower(name), '[^a-z0-9]', '', 'g')
                       = regexp_replace(lower(%s), '[^a-z0-9]', '', 'g')""", (q,))
            artists = cur.fetchall()
            if not artists:
                cur.execute(
                    """SELECT id, name FROM artists
                       WHERE similarity(lower(name), lower(%s)) > 0.5
                       ORDER BY similarity(lower(name), lower(%s)) DESC LIMIT 1""", (q, q))
                artists = cur.fetchall()
            if artists:
                ids = [a["id"] for a in artists]
                cur.execute(
                    f"""SELECT {_SONG_COLS} FROM songs s
                        JOIN artists ar ON ar.id = s.artist_id
                        JOIN albums al ON al.id = s.album_id
                        WHERE s.source_type = 'local'
                          AND NOT COALESCE(al.exclude_from_shuffle, FALSE)
                          AND (s.artist_id = ANY(%s) OR EXISTS (
                                SELECT 1 FROM song_artists sa
                                WHERE sa.song_id = s.id AND sa.artist_id = ANY(%s)))
                        ORDER BY al.year NULLS LAST, al.id, s.disc_number NULLS FIRST,
                                 s.track_number, s.id""", (ids, ids))
                songs = [dict(r) for r in cur.fetchall()]
                if songs:
                    name = min(artists, key=lambda a: len(a["name"]))["name"]
                    return {"kind": "artist",
                            "label": f"{name} — all songs ({len(songs)})",
                            "source": {"type": "artist", "id": ids[0], "name": name},
                            "songs": songs}

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


def _without_held(songs, user_id=None):
    """Drop songs the user is holding back (👎 'Not now' / 'Never play
    this', table song_holds) from a list the server is about to queue. A
    single direct pick isn't touched, and if everything is held the list is
    left alone rather than queueing nothing."""
    if not songs or len(songs) < 2:
        return songs
    try:
        db = _get_db()
        conn = db.get_connection()
        try:
            cur = db.get_cursor(conn)
            cur.execute(
                """SELECT song_id FROM song_holds
                   WHERE user_id = %s AND (until IS NULL OR until > CURRENT_TIMESTAMP)""",
                (user_id or 1,))
            held = {r["song_id"] for r in cur.fetchall()}
        finally:
            conn.close()
    except Exception as e:
        print(f"[cast] holds lookup failed ({e}); queueing as is")
        return songs
    kept = [s for s in songs if s.get("id") not in held]
    return kept or songs


def _request_user_id():
    try:
        return (g.user or {}).get("id")
    except Exception:
        return None


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
        pool = _without_held([dict(r) for r in cur.fetchall()])
        pool = balanced_shuffle(pool)
        return pool[:limit]
    finally:
        conn.close()


# ── Cast operations ────────────────────────────────────────────────────

def _cast_songs(session, songs, label=None, kind=None, source=None, shuffled=False, start=0):
    session.queue = list(songs)
    session.label, session.kind, session.station_query = label, kind, None
    session.source, session.shuffled = source, bool(shuffled)
    session._heal_times, session._heal_gave_up = [], False
    session._heal_song = None
    session._station_poll_gen += 1  # songs playing → any station poll dies
    song = _load_queue_index(session, start)
    _save_state(session)
    return song


def _load_queue_index(session, idx, current_time=0):
    """LOAD queue[idx] + hand the receiver the UP_NEXT tail from there."""
    token = _media_token()
    song = session.queue[idx]
    session.load(_song_media_message(song, token, session), current_time=current_time)
    # Give the receiver a beat to process LOAD before custom messages —
    # same deferred-send lesson the phone sender learned the hard way.
    eventlet.sleep(2)
    up_next = [_song_media_message(s, token, session)
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
    # The TV receiver only holds the read-only media token its artwork URLs
    # carry. Let it through for media paths (just /api/cast/song-info here,
    # see auth.MEDIA_PATH_PREFIXES); everything else needs a full login.
    media_ok = scope == "media" and auth.is_media_request(request.path, request.method)
    if not user or (scope != "full" and not media_ok):
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

    # type:"song" means that one track (Nov 14, 2026: Caribbean Queen queued
    # all 45 tracks of its album). with_album:true opts back into the album
    # tail after it, like tapping a track on an album page. Same trim as
    # /api/cast/queue. type:"auto" landing on a song keeps the album tail.
    if (kind == "song" and resolved.get("kind") == "song"
            and resolved.get("songs") and not data.get("with_album")):
        hit = resolved["songs"][0]
        resolved["songs"] = resolved["songs"][:1]
        resolved["source"] = {"type": "song", "id": hit["id"],
                              "name": hit.get("title"),
                              "artist": hit.get("artist_name")}

    # shuffle:true randomizes the resolved track list (albums/playlists;
    # meaningless for stations, harmless for single-song resolves).
    if resolved.get("songs") and resolved.get("kind") != "song":
        resolved["songs"] = _without_held(resolved["songs"], _request_user_id())
    if data.get("shuffle") and resolved.get("songs"):
        resolved["songs"] = balanced_shuffle(resolved["songs"])

    # start_at: begin at this song (title, exact else contains) with the
    # whole list queued around it, like tapping a track in a playlist.
    start = 0
    start_at = (data.get("start_at") or "").strip().lower()
    if start_at and resolved.get("songs"):
        titles = [(s.get("title") or "").lower() for s in resolved["songs"]]
        start = next((i for i, t in enumerate(titles) if t == start_at), None)
        if start is None:
            start = next((i for i, t in enumerate(titles) if start_at in t), None)
        if start is None:
            return jsonify({"error": f"'{data['start_at']}' isn't in {resolved['label']}"}), 404

    _stash_previous(host)
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
                        shuffled=bool(data.get("shuffle")), start=start)
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

    _stash_previous(host)
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


def _up_next_tail(s):
    """The songs to hand the TV as UP_NEXT from where it is now, honouring
    repeat: "one" = this song again; "all" = wrap to the start of the queue
    when the end is near; "off" = just what follows."""
    ids = [t["id"] for t in s.queue]
    try:
        idx = ids.index(s.current_song_id)
    except ValueError:
        idx = len(ids) - 1
    if s.repeat == "one" and 0 <= idx < len(s.queue):
        return [s.queue[idx]]
    tail = s.queue[idx + 1:idx + 1 + UP_NEXT_COUNT]
    if s.repeat == "all" and len(tail) < UP_NEXT_COUNT and s.queue:
        tail += s.queue[:UP_NEXT_COUNT - len(tail)]
    return tail


def _send_up_next(s):
    token = _media_token()
    s.send_custom({"type": "UP_NEXT",
                   "items": [_song_media_message(t, token, s) for t in _up_next_tail(s)]})


def _clear_upcoming(s):
    """Drop everything after the current track on a queue we own. The
    current song keeps playing; the TV is told there is nothing next.
    Returns how many tracks were removed."""
    ids = [t["id"] for t in s.queue]
    if s.current_song_id in ids:
        keep = ids.index(s.current_song_id) + 1
    else:
        keep = len(ids)  # don't know where the TV is - remove nothing
    removed = len(s.queue) - keep
    del s.queue[keep:]
    s.send_custom({"type": "UP_NEXT", "items": []})
    return removed


@cast_api.route("/api/cast/queue/clear", methods=["POST"])
def cast_queue_clear():
    """Remove every upcoming track from the live cast queue. The song that
    is playing now keeps playing and the cast stays up; queue something
    new afterwards, or use POST /api/cast/queue with "replace": true to
    clear and add in one call."""
    data = request.get_json(silent=True) or {}
    s, err = _live_session_or_error(data)
    if err:
        return err
    if s.joined:
        return jsonify({"error": "this cast's queue belongs to the phone that started it; "
                        "clear it from the phone, or start a new cast with /api/cast/play",
                        "mode": "guest"}), 409
    if not s.queue:
        return jsonify({"error": "no song queue on this cast (station or idle?)"}), 409
    _stash_previous(s.host)
    removed = _clear_upcoming(s)
    _save_state(s)
    print(f"📺 [cast-sender] {(g.user or {}).get('username') or 'someone'} cleared "
          f"{removed} upcoming track(s) on {s.host}")
    return jsonify({"ok": True, "removed": removed, "queue_length": len(s.queue)})


@cast_api.route("/api/cast/queue", methods=["POST"])
def cast_queue():
    """Add a track or album to the live cast queue, optionally as the
    very next item ("play Cabo Wabo next"). The TV shows an attribution
    toast: "«5150» added to the queue by Claude".

    Options: "shuffle": true shuffles what is being added; "replace": true
    first clears everything after the current song (the current song keeps
    playing), so {"query": "80's Pop", "shuffle": true, "replace": true}
    means "after this song, play 80's Pop shuffled instead of what was queued"."""
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

    songs = list(resolved["songs"])
    if resolved["kind"] == "song":
        songs = songs[:1]  # just the matched track, not its album tail
    else:
        songs = _without_held(songs, _request_user_id())
    shuffle = bool(data.get("shuffle"))
    replace = bool(data.get("replace"))
    if shuffle:
        songs = balanced_shuffle(songs)

    if s.joined:
        if replace:
            return jsonify({"error": "can't replace the queue of a cast the phone owns; "
                            "queue without \"replace\", or start a new cast with /api/cast/play",
                            "mode": "guest"}), 409
        return _guest_queue(s, songs, resolved["kind"], play_next, by)

    removed = 0
    if replace:
        _stash_previous(s.host)
        removed = _clear_upcoming(s)
        # What follows is now this source - status/queue report it.
        s.source, s.shuffled = resolved.get("source"), shuffle
        s.label, s.kind = resolved["label"], resolved["kind"]

    ids = [t["id"] for t in s.queue]
    try:
        idx = ids.index(s.current_song_id)
    except ValueError:
        idx = len(ids) - 1
    pos = idx + 1 if play_next else len(s.queue)
    s.queue[pos:pos] = songs

    token = _media_token()
    _send_up_next(s)
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
          f"({'next' if play_next else 'end of queue'}"
          f"{', shuffled' if shuffle else ''}"
          f"{f', replaced {removed} upcoming' if replace else ''}) on {s.host}")
    return jsonify({"ok": True, "added": title, "tracks": len(songs),
                    "position": "next" if play_next else "end",
                    "shuffled": shuffle, "replaced": removed if replace else None,
                    "queue_length": len(s.queue), "by": by})


def _guest_queue(s, songs, kind, play_next, by):
    """Queue into a cast we don't own: hand the resolved tracks to the
    receiver as QUEUE_INSERT. The receiver forwards them to the owning
    sender (the phone inserts into its real queue and re-sends UP_NEXT),
    or, when no other sender is connected (an orphaned headless queue),
    splices them into its own self-advance list. Either way it answers
    QUEUE_INSERT_RESULT and shows the "by Claude" toast."""
    token = _media_token()
    items = [_song_media_message(t, token, s) for t in songs]
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


@cast_api.route("/api/cast/queue/remove", methods=["POST"])
def cast_queue_remove():
    """Take upcoming track(s) out of the live cast queue (Claude queued the
    wrong "Hunter", Oct 30). Pick by "query" (title / artist words),
    "position" (1 = the next song, as in status up_next) or "song_id".
    Removes the first upcoming match unless "all": true. Never touches the
    song that is playing (skip it with /api/cast/next)."""
    data = request.get_json(silent=True) or {}
    s, err = _live_session_or_error(data)
    if err:
        return err
    if s.joined:
        return jsonify({"error": "this cast's queue belongs to the phone that started it; "
                        "remove it from the phone", "mode": "guest"}), 409
    if not s.queue:
        return jsonify({"error": "no song queue on this cast (station or idle?)"}), 409
    ids = [t["id"] for t in s.queue]
    cur = ids.index(s.current_song_id) if s.current_song_id in ids else -1
    upcoming = list(range(cur + 1, len(s.queue)))

    picks = []
    if data.get("position") is not None:
        try:
            n = int(data["position"])
        except (TypeError, ValueError):
            return jsonify({"error": "position must be a number (1 = next song)"}), 400
        if not 1 <= n <= len(upcoming):
            return jsonify({"error": f"position {n} is outside the upcoming queue "
                            f"(1-{len(upcoming)})"}), 400
        picks = [upcoming[n - 1]]
    elif data.get("song_id") is not None:
        try:
            sid = int(data["song_id"])
        except (TypeError, ValueError):
            return jsonify({"error": "song_id must be a number"}), 400
        picks = [i for i in upcoming if s.queue[i]["id"] == sid]
    else:
        q = (data.get("query") or "").strip().lower()
        if not q:
            return jsonify({"error": "query, position or song_id required"}), 400
        words = [w for w in re.findall(r"[a-z0-9']+", q)]
        def hay(t):
            return f"{t.get('title') or ''} {t.get('artist_name') or ''}".lower()
        picks = [i for i in upcoming if all(w in hay(s.queue[i]) for w in words)]
    if not picks:
        return jsonify({"error": "no upcoming track matches that", "removed": []}), 404
    if not data.get("all"):
        picks = picks[:1]

    removed = [{"song_id": s.queue[i]["id"], "title": s.queue[i].get("title"),
                "artist": s.queue[i].get("artist_name")} for i in picks]
    for i in sorted(picks, reverse=True):
        del s.queue[i]
    _send_up_next(s)
    _save_state(s)
    by = ((data.get("by") or "").strip() or (g.user or {}).get("username") or "someone")
    print(f"📺 [cast-sender] {by} removed {', '.join(r['title'] or '?' for r in removed)} "
          f"from the queue on {s.host}")
    return jsonify({"ok": True, "removed": removed, "queue_length": len(s.queue)})


@cast_api.route("/api/cast/fps-probe", methods=["POST"])
def cast_fps_probe():
    """Diagnostic: ask the receiver to measure its frame rate for ~2.5 s with
    one expensive layer off (normal | noblur | nobg | nowave | minimal). The
    result lands in the log as "📺 [receiver] frame rate ... [variant]"."""
    data = request.get_json(silent=True) or {}
    s, err = _live_session_or_error(data)
    if err:
        return err
    variant = (data.get("variant") or "normal").strip().lower()
    if variant not in ("normal", "noblur", "nobg", "nowave", "minimal", "sweep"):
        return jsonify({"error": "variant must be normal, noblur, nobg, nowave, minimal or sweep"}), 400
    msg = {"type": "FPS_PROBE", "variant": variant}
    if variant == "sweep":  # scrubber fill sweeps the bar every 2 s for N s
        try:
            msg["seconds"] = max(4, min(60, int(data.get("seconds") or 15)))
        except (TypeError, ValueError):
            msg["seconds"] = 15
    s.send_custom(msg)
    return jsonify({"ok": True, **msg})


@cast_api.route("/api/cast/scroll-mode", methods=["POST"])
def cast_scroll_mode():
    """Switch the TV's lyrics scroll: 'drift' (the default: slides at a
    constant speed with the song clock, never parks), 'tween' (700 ms ease
    per line change) or 'css' (the same glide as a CSS transition), to
    compare smoothness by eye."""
    data = request.get_json(silent=True) or {}
    s, err = _live_session_or_error(data)
    if err:
        return err
    mode = (data.get("mode") or "").strip().lower()
    if mode not in ("drift", "tween", "css"):
        return jsonify({"error": "mode must be drift, tween or css"}), 400
    s.send_custom({"type": "SCROLL_MODE", "mode": mode})
    return jsonify({"ok": True, "mode": mode})


@cast_api.route("/api/cast/repeat", methods=["POST"])
def cast_repeat():
    """Repeat mode for the live cast: "one" plays the current song again and
    again, "all" wraps back to the start of the queue, "off" stops repeating."""
    data = request.get_json(silent=True) or {}
    s, err = _live_session_or_error(data)
    if err:
        return err
    mode = (data.get("mode") or "").strip().lower()
    mode = {"song": "one", "track": "one", "this": "one", "queue": "all",
            "on": "all", "none": "off", "false": "off"}.get(mode, mode)
    if mode not in ("off", "one", "all"):
        return jsonify({"error": "mode must be off, one or all"}), 400
    if s.joined:
        return jsonify({"error": "this cast's queue belongs to the phone that started it; "
                        "set repeat on the phone", "mode": "guest"}), 409
    if not s.queue:
        return jsonify({"error": "no song queue on this cast (station or idle?)"}), 409
    s.repeat = mode
    _send_up_next(s)
    _save_state(s)
    print(f"📺 [cast-sender] repeat -> {mode} on {s.host}")
    return jsonify({"ok": True, "repeat": mode})


@cast_api.route("/api/cast/pause", methods=["POST"])
def cast_pause():
    s, err = _live_session_or_error(request.get_json(silent=True) or {})
    if err:
        return err
    s.media_command("PAUSE")
    return jsonify({"ok": True})


@cast_api.route("/api/cast/song-info/<int:song_id>", methods=["GET"])
def cast_song_info(song_id):
    """Read-only facts the TV receiver shows about a song: the album's release
    year for now (the album line reads "Rumours · 1977"). Reachable with a
    media token (auth.MEDIA_PATH_PREFIXES) because the receiver only has the
    one its artwork URLs carry. Room to grow into an X-Ray panel."""
    db = _get_db()
    conn = db.get_connection()
    try:
        cur = db.get_cursor(conn)
        cur.execute(
            """SELECT al.year, al.original_year FROM songs s
               JOIN albums al ON al.id = s.album_id
               WHERE s.id = %s""", (song_id,))
        row = cur.fetchone()
    finally:
        conn.close()

    def ok(y):
        return y if y and 1000 < y < 3000 else None

    tagged = ok(row["year"]) if row else None
    original = ok(row["original_year"]) if row else None
    # album_year is what the TV shows: the original release year when
    # MusicBrainz knows it (Reckless (Deluxe) -> 1984, not 2014).
    return jsonify({"song_id": song_id,
                    "album_year": original or tagged,
                    "original_year": original,
                    "release_year": tagged})


@cast_api.route("/api/cast/resume", methods=["POST"])
def cast_resume():
    """Unpause if there's something live to unpause; otherwise bring the
    last cast back from the state file — same queue, track and second —
    whether it ended by stop, a dropped/killed receiver, or a restart.
    {"previous": true} (or N) instead puts back what was playing before the
    last (Nth-last) play replaced it - see GET /api/cast/history."""
    data = request.get_json(silent=True) or {}
    host = _resolve_host(data.get("device"))
    back = data.get("previous")
    if back:
        try:
            n = 1 if back is True else int(back)
        except (TypeError, ValueError):
            return jsonify({"error": "previous must be true or a number"}), 400
        stack = _load_prev(host)
        if not 1 <= n <= len(stack):
            return jsonify({"error": f"nothing that far back - {len(stack)} saved "
                            "(GET /api/cast/history)"}), 409
        try:
            out = _restore_cast(host, wake=data.get("wake", True), state=stack[n - 1])
        except RuntimeError as e:
            return jsonify({"error": str(e)}), 409
        except Exception as e:
            return jsonify({"error": f"resume failed: {e}"}), 502
        # Going back N drops the N newest; what was just replaced is not
        # stashed, so repeated 'previous' keeps walking back, never ping-pongs.
        _write_prev(host, stack[n:])
        return jsonify(dict(out, ok=True, mode="previous", saved_left=len(stack) - n))
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
        return jsonify(dict(_confirm_playing(s), ok=True, mode="unpaused"))
    try:
        out = _restore_cast(host, wake=data.get("wake", True))
    except RuntimeError as e:
        return jsonify({"error": str(e)}), 409
    except Exception as e:
        return jsonify({"error": f"resume failed: {e}"}), 502
    return jsonify(dict(out, **_confirm_playing(_sessions.get(host)), ok=True, mode="restored"))


def _confirm_playing(s, wait=3.0):
    """Ask the receiver itself, not our cached player_state, whether its
    clock is moving. Nov 14, 2026: ELKO reported PLAYING after a resume
    while the room was silent, and 'resume OK' sent Claude off thinking it
    worked. confirmed: True (moving) / False (stuck) / None (can't tell:
    no session, no reply, or a receiver too old to report currentTime)."""
    if s is None or not s.alive:
        return {"confirmed": None}
    try:
        eventlet.sleep(1.0)  # let PLAY land before the first reading
        a = s.request_custom({"type": "STATE_REQUEST"}, timeout=3) or {}
        eventlet.sleep(wait)
        b = s.request_custom({"type": "STATE_REQUEST"}, timeout=3) or {}
    except Exception as e:
        return {"confirmed": None, "check_error": str(e)}
    t0, t1 = a.get("currentTime"), b.get("currentTime")
    if not isinstance(t0, (int, float)) or not isinstance(t1, (int, float)):
        return {"confirmed": None, "receiver_state": b.get("playerState")}
    np = b.get("nowPlaying") or {}
    out = {"confirmed": t1 > t0 + 0.5, "receiver_state": b.get("playerState"),
           "position": int(t1)}
    if np.get("title"):
        out.update({"now_playing": np.get("title"), "artist": np.get("artist")})
    return out


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
    # Warn every connected phone first (the receiver relays CAST_ENDED),
    # or a joined phone reads the close as a crash and relaunches the cast.
    s.send_custom({"type": "SESSION_ENDING", "reason": "stopped"})
    eventlet.sleep(1.0)
    s.stop_media()
    eventlet.sleep(0.5)
    s.stop_receiver()
    s.close()
    _sessions.pop(host, None)
    print(f"📺 [cast-sender] Stopped cast on {host}")
    return jsonify({"ok": True})


@cast_api.route("/api/cast/history", methods=["GET"])
def cast_history():
    """What 'previous' would bring back, newest first (?device=)."""
    host = _resolve_host(request.args.get("device"))
    stack = _load_prev(host)
    ids = [st.get("current_song_id") for st in stack if st.get("current_song_id")]
    titles = {t["id"]: t for t in _songs_by_ids(ids)}
    out = []
    for n, st in enumerate(stack, 1):
        item = {"previous": n, "label": st.get("label"), "kind": st.get("kind"),
                "saved_ago_min": int((time.time() - float(st.get("stashed_at") or 0)) // 60)}
        if st.get("kind") == "station":
            item["station"] = st.get("station_query")
        else:
            q = st.get("queue") or []
            cur = titles.get(st.get("current_song_id"))
            item.update({"tracks": len(q), "shuffled": bool(st.get("shuffled")),
                         "track": (q.index(st["current_song_id"]) + 1
                                   if st.get("current_song_id") in q else None),
                         "song": cur and f"{cur['title']} - {cur['artist_name']}",
                         "position": int(st.get("position") or 0)})
        out.append(item)
    return jsonify({"device": host, "previous": out})


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
            "repeat": s.repeat,
            "source": s.source,
            "idle_for_sec": int(time.time() - s.idle_since) if s.idle_since else None,
            "self_heals_recent": len([x for x in s._heal_times
                                      if time.time() - x < HEAL_WINDOW_SEC]),
            "uptime_sec": int(time.time() - s.started_at),
            "last_error": s.last_error,
        }
    return jsonify(out)


# An album's songs INCLUDING album references (album_track_refs: tracks that
# live on another album but are also listed on this one), in this album's
# own order. Both need the album id twice: (album_id, album_id).
_ALBUM_REFS_JOIN = "LEFT JOIN album_track_refs r ON r.song_id = s.id AND r.album_id = %s"
_ALBUM_REFS_WHERE = "(s.album_id = %s OR r.id IS NOT NULL)"
_ALBUM_REFS_ORDER = ("COALESCE(r.disc_number, s.disc_number) NULLS FIRST, "
                     "COALESCE(r.track_number, s.track_number), s.id")


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
                f"""SELECT s.id, s.title, ar.name AS artist_name FROM songs s
                   JOIN artists ar ON ar.id = s.artist_id
                   {_ALBUM_REFS_JOIN}
                   WHERE {_ALBUM_REFS_WHERE} AND s.source_type = 'local'
                   ORDER BY {_ALBUM_REFS_ORDER}""",
                (source["id"], source["id"]))
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
