"""Cast sessions for NASRadio players that aren't Chromecasts.

The NASRadio TV app on ELKO shows the same receiver page the C2 casts
(served as /cast/tv.html, with caf_local.js standing in for Google's CAF
SDK). Instead of Google's TLS socket it talks to us over Socket.IO, on the
/castdev namespace, carrying the very same Cast messages (receiver, media,
heartbeat and our custom namespace). RelayCastSession is a
HeadlessCastSession with only the transport swapped, so queues, UP_NEXT,
lyrics, repeat, resume and house_music work on ELKO exactly as on the TV.

Address a player by name as the cast "device": {"device": "elko"}.
"""

import os
import secrets
import time

import eventlet
import requests
from flask import request
from flask_socketio import emit

from app import cast_sender as cs
from app.extensions import socketio

NAMESPACE = "/castdev"
RELAY_PLAYERS = {"ELKO"}
# ADMS flips the living room into music mode for a cast to ELKO (TV HDMI_2,
# Denon 8K, ELKO's display DENON-AVR only at 120 Hz) and starts NASRadio TV.
# Its address comes from NASRADIO_ADMS_ROOM_URL or the adms_room_url file next
# to adms_room_key in the data dir; installs without ADMS have neither and
# skip the room setup.

_players = {}  # name -> {"sid": socket.io sid, "since": time}
_live = {}     # name -> the RelayCastSession its frames go to
_key = None


def relay_name(host):
    """The player's canonical name when `host` names a relay player."""
    name = (host or "").strip().upper()
    return name if name in RELAY_PLAYERS else None


def _player_key():
    """Shared secret the TV app presents on connect. Generated once and kept
    on the data volume next to the cast state."""
    global _key
    if _key:
        return _key
    path = os.path.join(os.path.dirname(cs.CAST_STATE_PATH), "tv_player_key")
    try:
        with open(path) as f:
            _key = f.read().strip()
    except OSError:
        _key = ""
    if not _key:
        _key = secrets.token_urlsafe(24)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(_key)
    return _key


def _adms_room_url():
    url = os.environ.get("NASRADIO_ADMS_ROOM_URL", "").strip()
    if url:
        return url
    try:
        with open(os.path.join(os.path.dirname(cs.CAST_STATE_PATH), "adms_room_url")) as f:
            return f.read().strip()
    except OSError:
        return ""


def _adms_room_key():
    try:
        with open(os.path.join(os.path.dirname(cs.CAST_STATE_PATH), "adms_room_key")) as f:
            return f.read().strip()
    except OSError:
        return ""


def _pause_desktop_app(name):
    """The desktop NASRadio app on the same PC would play over the TV app
    (Oct 30: two songs at once on ELKO). Pause it through the app-to-app
    remote control (device_sync). The app only obeys while it believes it's
    being controlled, so wrap the pause in start/end, unless a real
    controller (Matt's phone) already holds it."""
    from app import device_sync as ds
    for device_id, d in list(ds.connected_devices.items()):
        if (d.get("device_name") or "").strip().upper() != name:
            continue
        room = f"device:{device_id}"
        held = device_id in ds.remote_sessions
        if not held:
            socketio.emit("remote_control_started",
                          {"controller_id": "nasradio-tv", "controller_name": f"NASRadio TV ({name})"},
                          room=room)
            eventlet.sleep(0.3)
        socketio.emit("remote_command", {"command": "pause", "args": {}}, room=room)
        if not held:
            eventlet.sleep(0.5)
            socketio.emit("remote_control_ended", {"reason": f"NASRadio TV on {name} took over"}, room=room)
        print(f"🖥️ [cast-relay] paused the desktop NASRadio app on {name}")


def prepare_room(name):
    """Before a fresh cast to a relay player: music mode + NASRadio TV running
    (ADMS /room/elko), the desktop app on that PC paused, and the TV app's
    link up. Best effort: logged, and the cast goes ahead either way."""
    key = _adms_room_key()
    url = _adms_room_url()
    if key and url:
        try:
            r = requests.post(url, json={"mode": "music"},
                              headers={"X-Room-Key": key}, timeout=180)
            print(f"🖥️ [cast-relay] {name} room: HTTP {r.status_code} {r.text[:300]}")
        except requests.RequestException as e:
            print(f"🖥️ [cast-relay] {name} room: ADMS unreachable ({e})")
    else:
        print(f"🖥️ [cast-relay] {name} room: no ADMS room key/url, skipping music mode")
    try:
        _pause_desktop_app(name)
    except Exception as e:
        print(f"🖥️ [cast-relay] couldn't pause the desktop app on {name}: {e}")
    deadline = time.time() + 40  # a just-started TV app needs a moment to connect
    while name not in _players and time.time() < deadline:
        eventlet.sleep(0.5)


def _auto_rejoin(name):
    """The TV app (re)connected: a backend restart or a dropped link. If its
    cast was playing, re-join and reclaim it the way the TV's post-restart
    auto-resume does, so lyrics, waveforms and UP_NEXT keep flowing (Oct 31:
    after a restart they stopped until some /api/cast call re-joined)."""
    s = cs._sessions.get(name)
    if s is not None and s.alive:
        return
    st = cs._load_state(name)
    if not st or st.get("stopped") or st.get("player_state") not in ("PLAYING", "BUFFERING", "PAUSED"):
        return
    # Same limit as the TV's auto-resume: a cast whose state hasn't moved in
    # 15 min ended without a clean stop (ELKO slept, the app was closed...).
    # Without this, every reconnect (ELKO booting, the TV app restarting)
    # re-attached to a cast that had been over for hours or days.
    age = time.time() - float(st.get("updated_at") or 0)
    if age > cs.AUTO_RESUME_MAX_AGE_SEC:
        print(f"🖥️ [cast-relay] {name}: saved cast is {int(age // 60)} min old, "
              f"not re-attaching")
        return
    try:
        s = cs._guest_session(name)
    except Exception as e:
        print(f"🖥️ [cast-relay] {name}: re-attach failed: {e}")
        return
    if s:
        print(f"🖥️ [cast-relay] {name}: re-attached after reconnect ({'guest' if s.joined else 'owner'})")


class RelayCastSession(cs.HeadlessCastSession):
    def __init__(self, host):
        super().__init__(relay_name(host) or host)
        self.name = self.host

    def _open_transport(self):
        if self.name not in _players:
            self.last_error = f"{self.name}: the NASRadio TV app isn't connected"
            return False
        self.alive = True
        _live[self.name] = self
        self._send(cs.NS_CONNECTION, {"type": "CONNECT"}, dest="receiver-0")
        return True

    def _send(self, ns, payload, dest=None):
        p = _players.get(self.name)
        if not p:
            raise OSError(f"{self.name}: the NASRadio TV app isn't connected")
        socketio.emit("cast_frame",
                      {"ns": ns, "payload": payload,
                       "dest": dest or self.transport_id or "receiver-0"},
                      namespace=NAMESPACE, to=p["sid"])

    def close(self):
        self._closing = True
        self.alive = False
        if _live.get(self.name) is self:
            _live.pop(self.name, None)


def register_handlers():
    @socketio.on("connect", namespace=NAMESPACE)
    def _connect(auth=None):
        auth = auth if isinstance(auth, dict) else {}
        name = relay_name(auth.get("player"))
        if not name or not secrets.compare_digest(str(auth.get("key") or ""), _player_key()):
            print(f"🖥️ [cast-relay] refused a player connection ({auth.get('player')!r})")
            return False
        replacing = name in _players
        _players[name] = {"sid": request.sid, "since": time.time()}
        print(f"🖥️ [cast-relay] {name} connected" + (" (replacing its old connection)" if replacing else ""))
        emit("castdev_welcome", {"player": name, "appId": cs.config.CAST_RECEIVER_APP_ID or ""})
        eventlet.spawn_after(3, _auto_rejoin, name)

    @socketio.on("disconnect", namespace=NAMESPACE)
    def _disconnect():
        for name, p in list(_players.items()):
            if p["sid"] == request.sid:
                _players.pop(name, None)
                s = _live.get(name)
                if s is not None:
                    s.alive = False  # the next command re-joins via _guest_session
                print(f"🖥️ [cast-relay] {name} disconnected")

    @socketio.on("cast_frame", namespace=NAMESPACE)
    def _frame(data):
        name = next((n for n, p in _players.items() if p["sid"] == request.sid), None)
        s = _live.get(name) if name else None
        if s is None or not isinstance(data, dict):
            return
        try:
            s._on_frame(data.get("ns"), data.get("payload"))
        except Exception as e:
            print(f"🖥️ [cast-relay] {name}: frame handling failed: {e}")
