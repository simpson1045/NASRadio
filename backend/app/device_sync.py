"""
Device Sync Module - Handles multi-device playback coordination via WebSocket.

Supports three modes:
1. Remote Control - Control one device's playback from another
2. Group Session - Multiple devices playing the same music in sync
3. Independent Streams - Each device plays independently (default, no special handling needed)
"""

import uuid
from datetime import datetime, date
from decimal import Decimal
from flask_socketio import emit, join_room, leave_room
from app.extensions import socketio, safe_emit
from app.models import Database
from app.config import Config


config = Config()

def get_db():
    return Database(config.DATABASE_URL)

# In-memory state (no Redis needed at 1-5 devices)
connected_devices = {}  # device_id -> {sid, device_name}
remote_sessions = {}    # target_device_id -> controller_device_id
active_groups = {}      # group_id -> {leader, members: [device_ids], name}


def register_handlers():
    """Register all SocketIO event handlers for device sync"""

    @socketio.on('device_connect')
    def handle_device_connect(data):
        """Client announces itself with device_id and device_name"""
        device_id = data.get('device_id')
        device_name = data.get('device_name', 'Unknown Device')

        if not device_id:
            return

        from flask import request
        sid = request.sid

        connected_devices[device_id] = {
            'sid': sid,
            'device_name': device_name,
        }

        # Join a private room for targeted messages
        join_room(f'device:{device_id}')

        print(f'📱 Device connected: {device_name} ({device_id[:8]}...)')
        # DIAG (temp): full id + sid so remote-control routing can be correlated.
        print(f"🎮[remote] connect: name='{device_name}' device_id={device_id} sid={sid}", flush=True)

        # App just opened → warm the NAS file for this device's restored song NOW,
        # in the background, so the first play/cast doesn't eat the ~7s cold-open
        # (a cast TV won't wait that long and would just fail to play).
        try:
            from app.routes import _prewarm_device_song
            socketio.start_background_task(_prewarm_device_song, device_id)
        except Exception as e:
            print(f"⚠️ [prewarm] could not schedule connect-warm: {e}")

        # Broadcast updated device list to all connected clients
        _broadcast_device_list()

    @socketio.on('disconnect')
    def handle_disconnect():
        """Clean up when a client disconnects"""
        from flask import request
        sid = request.sid

        # Find which device disconnected
        disconnected_device = None
        for device_id, info in list(connected_devices.items()):
            if info['sid'] == sid:
                disconnected_device = device_id
                break

        if not disconnected_device:
            return

        device_name = connected_devices[disconnected_device]['device_name']
        del connected_devices[disconnected_device]

        print(f'📱 Device disconnected: {device_name} ({disconnected_device[:8]}...)')

        # Clean up remote control sessions
        _cleanup_remote_sessions(disconnected_device)

        # Clean up group memberships
        _cleanup_group_memberships(disconnected_device)

        # Broadcast updated device list
        _broadcast_device_list()

    # ==================
    # Remote Control
    # ==================

    @socketio.on('remote_control_start')
    def handle_remote_control_start(data):
        """Controller wants to control a target device"""
        from flask import request
        controller_id = _get_device_id_by_sid(request.sid)
        target_id = data.get('target_device_id')

        if not controller_id or not target_id:
            emit('remote_control_error', {'error': 'Missing device IDs'})
            return

        if target_id not in connected_devices:
            emit('remote_control_error', {'error': 'Target device is not connected'})
            return

        # Capture display names BEFORE any DB/socket call below. _update_device_role,
        # _get_playback_state and emit() all yield under eventlet+psycogreen; if the
        # controller or target socket drops during a yield it gets removed from
        # connected_devices, and a later connected_devices[id] lookup would raise
        # KeyError mid-handler. That's exactly what was happening: the start aborted
        # on a KeyError, so the controller never received remote_control_state, never
        # entered controller mode, and every transport button silently no-op'd.
        controller_name = connected_devices.get(controller_id, {}).get('device_name', 'Unknown Device')
        target_name = connected_devices.get(target_id, {}).get('device_name', 'Unknown Device')

        # If target is already being controlled, kick the old controller
        if target_id in remote_sessions:
            old_controller = remote_sessions[target_id]
            if old_controller in connected_devices:
                socketio.emit('remote_control_ended', {
                    'reason': 'Another device took control',
                }, room=f'device:{old_controller}')

        # Establish remote control session
        remote_sessions[target_id] = controller_id

        # Notify target that it's being controlled
        socketio.emit('remote_control_started', {
            'controller_id': controller_id,
            'controller_name': controller_name,
        }, room=f'device:{target_id}')

        # Send target's current playback state to controller
        target_state = _get_playback_state(target_id)
        emit('remote_control_state', {
            'target_device_id': target_id,
            'target_name': target_name,
            'state': target_state,
        })

        # Persist the role LAST — it's a DB write that yields, so doing it after the
        # handshake emits means a socket drop during it can't abort remote control.
        _update_device_role(target_id, 'remote_target', controlled_by=controller_id)

        print(f'🎮[remote] START ok: {controller_name} -> {target_name}', flush=True)

    @socketio.on('remote_control_stop')
    def handle_remote_control_stop(data):
        """Controller releases control of target device"""
        from flask import request
        controller_id = _get_device_id_by_sid(request.sid)
        target_id = data.get('target_device_id')

        if not target_id or target_id not in remote_sessions:
            return

        # Verify this controller owns the session
        if remote_sessions.get(target_id) != controller_id:
            return

        del remote_sessions[target_id]
        _update_device_role(target_id, 'independent', controlled_by=None)

        # Notify target
        socketio.emit('remote_control_ended', {
            'reason': 'Controller disconnected',
        }, room=f'device:{target_id}')

        print(f'🎮 Remote control ended for {target_id[:8]}...')

    @socketio.on('remote_command')
    def handle_remote_command(data):
        """Controller sends a playback command to target device"""
        from flask import request
        controller_id = _get_device_id_by_sid(request.sid)
        target_id = data.get('target_device_id')
        command = data.get('command')
        args = data.get('args', {})

        # DIAG (temp): trace exactly where a remote command dies. Grep 🎮[remote].
        print(
            f"🎮[remote] cmd='{command}' sid={request.sid} "
            f"controller={controller_id} target={target_id} "
            f"session_owner={remote_sessions.get(target_id)} "
            f"target_connected={target_id in connected_devices}",
            flush=True,
        )

        if not target_id or not command:
            print("🎮[remote] DROP: missing target_id or command", flush=True)
            return

        # Verify this controller owns the session
        if remote_sessions.get(target_id) != controller_id:
            print(
                f"🎮[remote] DROP: not authorized "
                f"(session_owner={remote_sessions.get(target_id)} != controller={controller_id})",
                flush=True,
            )
            emit('remote_control_error', {'error': 'Not authorized to control this device'})
            return

        # Forward command to target device
        print(f"🎮[remote] RELAY '{command}' -> room device:{target_id}", flush=True)
        socketio.emit('remote_command', {
            'command': command,
            'args': args,
        }, room=f'device:{target_id}')

    @socketio.on('remote_state_update')
    def handle_remote_state_update(data):
        """Target device reports its current state (relayed to controller)"""
        from flask import request
        target_id = _get_device_id_by_sid(request.sid)

        if not target_id or target_id not in remote_sessions:
            return

        controller_id = remote_sessions[target_id]
        if controller_id in connected_devices:
            socketio.emit('remote_state_update', {
                'target_device_id': target_id,
                'state': data,
            }, room=f'device:{controller_id}')

    # ==================
    # Group Session
    # ==================

    @socketio.on('group_create')
    def handle_group_create(data):
        """Create a new sync group with this device as leader"""
        from flask import request
        device_id = _get_device_id_by_sid(request.sid)
        group_name = data.get('name', 'Sync Group')

        if not device_id:
            return

        # Leave any existing group first
        _remove_from_group(device_id)

        group_id = str(uuid.uuid4())[:8]
        active_groups[group_id] = {
            'leader': device_id,
            'members': [device_id],
            'name': group_name,
        }

        join_room(f'group:{group_id}')

        # Update DB
        _update_device_role(device_id, 'leader', group_id=group_id)

        print(f'👥 Group created: "{group_name}" ({group_id}) by {connected_devices[device_id]["device_name"]}')

        emit('group_created', {
            'group_id': group_id,
            'group_name': group_name,
            'role': 'leader',
        })

        _broadcast_device_list()

    @socketio.on('group_join')
    def handle_group_join(data):
        """Join an existing sync group as a follower"""
        from flask import request
        device_id = _get_device_id_by_sid(request.sid)
        group_id = data.get('group_id')

        if not device_id or not group_id:
            return

        if group_id not in active_groups:
            emit('group_error', {'error': 'Group not found'})
            return

        # Leave any existing group first
        _remove_from_group(device_id)

        group = active_groups[group_id]
        group['members'].append(device_id)

        join_room(f'group:{group_id}')

        # Update DB
        _update_device_role(device_id, 'follower', group_id=group_id)

        device_name = connected_devices.get(device_id, {}).get('device_name', 'Unknown')
        print(f'👥 {device_name} joined group "{group["name"]}" ({group_id})')

        # Get leader's current state so follower can sync
        leader_state = _get_playback_state(group['leader'])

        emit('group_joined', {
            'group_id': group_id,
            'group_name': group['name'],
            'role': 'follower',
            'leader_state': leader_state,
        })

        # Notify group that a new member joined
        socketio.emit('group_member_changed', {
            'group_id': group_id,
            'members': _get_group_member_info(group_id),
            'event': 'joined',
            'device_name': device_name,
        }, room=f'group:{group_id}')

        _broadcast_device_list()

    @socketio.on('group_leave')
    def handle_group_leave(data):
        """Leave the current sync group"""
        from flask import request
        device_id = _get_device_id_by_sid(request.sid)

        if not device_id:
            return

        _remove_from_group(device_id)
        _broadcast_device_list()

    @socketio.on('group_command')
    def handle_group_command(data):
        """Leader sends a playback command to all followers"""
        from flask import request
        device_id = _get_device_id_by_sid(request.sid)
        group_id = data.get('group_id')
        command = data.get('command')
        args = data.get('args', {})

        if not device_id or not group_id or not command:
            return

        group = active_groups.get(group_id)
        if not group or group['leader'] != device_id:
            emit('group_error', {'error': 'Only the leader can send commands'})
            return

        # Broadcast command to all group members (including leader for UI sync)
        socketio.emit('group_command', {
            'command': command,
            'args': args,
            'from_leader': True,
        }, room=f'group:{group_id}')

    @socketio.on('group_sync_tick')
    def handle_group_sync_tick(data):
        """Leader sends position update for drift correction"""
        from flask import request
        device_id = _get_device_id_by_sid(request.sid)
        group_id = data.get('group_id')

        if not device_id or not group_id:
            return

        group = active_groups.get(group_id)
        if not group or group['leader'] != device_id:
            return

        # Relay tick to followers (skip sending back to leader)
        socketio.emit('group_sync_tick', {
            'song_id': data.get('song_id'),
            'position_ms': data.get('position_ms'),
            'is_playing': data.get('is_playing'),
            'timestamp': data.get('timestamp'),
        }, room=f'group:{group_id}', skip_sid=request.sid)

    # ==================
    # Utility: Active groups list
    # ==================

    @socketio.on('get_active_groups')
    def handle_get_active_groups():
        """Return list of active groups that can be joined"""
        groups = []
        for gid, group in active_groups.items():
            leader_name = connected_devices.get(group['leader'], {}).get('device_name', 'Unknown')
            groups.append({
                'group_id': gid,
                'name': group['name'],
                'leader_name': leader_name,
                'member_count': len(group['members']),
            })
        emit('active_groups', {'groups': groups})


# ==================
# Helper Functions
# ==================

def _get_device_id_by_sid(sid):
    """Find device_id from SocketIO session ID"""
    for device_id, info in connected_devices.items():
        if info['sid'] == sid:
            return device_id
    return None


def _cleanup_remote_sessions(device_id):
    """Clean up remote control sessions when a device disconnects"""
    # If this device was being controlled, notify the controller
    if device_id in remote_sessions:
        controller_id = remote_sessions[device_id]
        del remote_sessions[device_id]
        if controller_id in connected_devices:
            socketio.emit('remote_control_ended', {
                'reason': 'Target device disconnected',
            }, room=f'device:{controller_id}')

    # If this device was controlling another, release the target
    targets_to_release = [
        tid for tid, cid in remote_sessions.items() if cid == device_id
    ]
    for target_id in targets_to_release:
        del remote_sessions[target_id]
        _update_device_role(target_id, 'independent', controlled_by=None)
        if target_id in connected_devices:
            socketio.emit('remote_control_ended', {
                'reason': 'Controller disconnected',
            }, room=f'device:{target_id}')


def _cleanup_group_memberships(device_id):
    """Clean up group memberships when a device disconnects"""
    _remove_from_group(device_id)


def _remove_from_group(device_id):
    """Remove a device from its group, handling leader promotion/dissolution"""
    for group_id, group in list(active_groups.items()):
        if device_id in group['members']:
            group['members'].remove(device_id)
            leave_room(f'group:{group_id}')
            _update_device_role(device_id, 'independent', group_id=None)

            device_name = connected_devices.get(device_id, {}).get('device_name', 'Unknown')

            if not group['members']:
                # Last member left — dissolve group
                del active_groups[group_id]
                print(f'👥 Group "{group["name"]}" dissolved (empty)')
            elif group['leader'] == device_id:
                # Leader left — promote next member
                new_leader = group['members'][0]
                group['leader'] = new_leader
                _update_device_role(new_leader, 'leader', group_id=group_id)

                new_leader_name = connected_devices.get(new_leader, {}).get('device_name', 'Unknown')
                print(f'👥 {new_leader_name} promoted to leader of "{group["name"]}"')

                socketio.emit('group_leader_changed', {
                    'group_id': group_id,
                    'new_leader': new_leader,
                    'new_leader_name': new_leader_name,
                }, room=f'group:{group_id}')

            # Notify remaining members
            if group_id in active_groups:
                socketio.emit('group_member_changed', {
                    'group_id': group_id,
                    'members': _get_group_member_info(group_id),
                    'event': 'left',
                    'device_name': device_name,
                }, room=f'group:{group_id}')

            break  # Device can only be in one group


def _get_group_member_info(group_id):
    """Get info about all members of a group"""
    group = active_groups.get(group_id)
    if not group:
        return []

    members = []
    for mid in group['members']:
        info = connected_devices.get(mid, {})
        members.append({
            'device_id': mid,
            'device_name': info.get('device_name', 'Unknown'),
            'is_leader': mid == group['leader'],
        })
    return members


def _get_playback_state(device_id):
    """Get playback state from database for a device"""
    try:
        db = get_db()
        conn = db.get_connection()
        cursor = db.get_cursor(conn)
        cursor.execute(
            """
            SELECT ps.*, s.title AS song_title, s.duration AS song_duration,
                   ar.name AS artist_name, al.id AS album_id
            FROM playback_state ps
            LEFT JOIN songs s ON ps.current_song_id = s.id
            LEFT JOIN albums al ON s.album_id = al.id
            LEFT JOIN artists ar ON s.artist_id = ar.id
            WHERE ps.device_id = %s
            """,
            (device_id,),
        )
        row = cursor.fetchone()
        conn.close()
        if not row:
            return {}
        state = dict(row)
        # RealDictCursor hands back DB timestamps as datetime objects and
        # NUMERIC columns as Decimal — both blow up the Socket.IO JSON encoder
        # ("Object of type datetime is not JSON serializable"). That exception
        # aborted the remote_control_state emit, so the controller never entered
        # controller mode and every transport button silently no-op'd. Coerce to
        # JSON-safe primitives before the state leaves this function (also fixes
        # group-session state, which uses the same helper).
        for k, v in list(state.items()):
            if isinstance(v, (datetime, date)):
                state[k] = v.isoformat()
            elif isinstance(v, Decimal):
                state[k] = float(v)
        # Normalize to the SAME shape the live remote_state_update push uses, so
        # the controller's takeover can read this initial snapshot directly. The
        # DB columns are current_song_id / song_duration(sec); the frontend reads
        # song_id / duration_ms / is_shuffled. Without this the controller's
        # targetSong stayed null on control-start and the screen fell back to the
        # CONTROLLER's own song. (position_ms + is_playing already match.)
        state["song_id"] = state.get("current_song_id")
        state["duration_ms"] = int((state.get("song_duration") or 0) * 1000)
        state["is_shuffled"] = bool(state.get("shuffle_mode"))
        return state
    except Exception as e:
        print(f'❌ Failed to get playback state for {device_id}: {e}')
        return {}


def _update_device_role(device_id, role, group_id='_skip', controlled_by='_skip'):
    """Update device role in database"""
    try:
        db = get_db()
        conn = db.get_connection()
        cursor = db.get_cursor(conn)

        updates = ['group_role = %s']
        params = [role]

        if group_id != '_skip':
            updates.append('group_id = %s')
            params.append(group_id)

        if controlled_by != '_skip':
            updates.append('controlled_by = %s')
            params.append(controlled_by)

        params.append(device_id)
        cursor.execute(
            f"UPDATE playback_state SET {', '.join(updates)} WHERE device_id = %s",
            tuple(params),
        )
        conn.commit()
        conn.close()
    except Exception as e:
        print(f'❌ Failed to update device role: {e}')


def _broadcast_device_list():
    """Broadcast updated device list to all connected clients"""
    device_list = []
    for device_id, info in connected_devices.items():
        device_list.append({
            'device_id': device_id,
            'device_name': info['device_name'],
            'connected': True,
        })
    safe_emit('device_list_updated', {'devices': device_list})
