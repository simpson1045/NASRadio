import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'api_service.dart';
import 'audio_player_service.dart';
import '../models/song.dart';

/// Device sync modes
enum DeviceSyncMode {
  independent,       // Default — playing independently
  remoteController,  // Controlling another device
  remoteTarget,      // Being controlled by another device
  groupLeader,       // Leading a sync group
  groupFollower,     // Following a sync group leader
}

/// Info about a connected device
class DeviceInfo {
  final String deviceId;
  final String deviceName;
  final bool isConnected;

  DeviceInfo({
    required this.deviceId,
    required this.deviceName,
    this.isConnected = true,
  });
}

/// Service that manages multi-device sync via WebSocket.
/// Separate from AudioPlayerService to keep concerns clean.
class DeviceSyncService extends ChangeNotifier {
  final AudioPlayerService _audioPlayer;
  io.Socket? _socket;

  // Current mode
  DeviceSyncMode _mode = DeviceSyncMode.independent;
  DeviceSyncMode get mode => _mode;

  // Remote control state
  String? _targetDeviceId;    // Who we're controlling
  String? _targetDeviceName;
  String? _controllerDeviceId; // Who's controlling us
  String? _controllerDeviceName;
  Map<String, dynamic> _targetState = {}; // Remote device's playback state
  DateTime _targetStateAt = DateTime.now(); // when _targetState last arrived
  Timer? _targetTickTimer; // 1Hz push of our own state while being controlled

  // Last remote-control error, surfaced to the UI (previously only print()'d,
  // which is why a failed Control looked like "nothing happened").
  String? lastError;

  String? get targetDeviceId => _targetDeviceId;
  String? get targetDeviceName => _targetDeviceName;
  String? get controllerDeviceId => _controllerDeviceId;
  String? get controllerDeviceName => _controllerDeviceName;
  Map<String, dynamic> get targetState => _targetState;

  // ---- Controller-side view of the TARGET's playback (for the takeover UI) ----
  // The target pushes remote_state_update ~1Hz; between pushes we interpolate the
  // position locally so the controller's scrubber stays smooth (mirrors how Cast
  // advances position 1s/tick between receiver syncs).
  String get targetSongTitle =>
      (_targetState['song_title'] as String?) ?? (_targetDeviceName ?? '');
  String get targetArtistName => (_targetState['artist_name'] as String?) ?? '';
  int? get targetSongId => (_targetState['song_id'] as num?)?.toInt();
  int? get targetAlbumId => (_targetState['album_id'] as num?)?.toInt();
  bool get targetIsPlaying =>
      _targetState['is_playing'] == true || _targetState['is_playing'] == 1;
  Duration get targetDuration =>
      Duration(milliseconds: (_targetState['duration_ms'] as num?)?.toInt() ?? 0);
  Duration get targetPosition {
    var ms = (_targetState['position_ms'] as num?)?.toInt() ?? 0;
    if (targetIsPlaying) {
      ms += DateTime.now().difference(_targetStateAt).inMilliseconds;
    }
    final durMs = targetDuration.inMilliseconds;
    if (durMs > 0 && ms > durMs) ms = durMs;
    return Duration(milliseconds: ms < 0 ? 0 : ms);
  }

  bool get targetIsShuffled =>
      _targetState['is_shuffled'] == true || _targetState['is_shuffled'] == 1;
  RepeatMode get targetRepeatMode {
    switch (_targetState['repeat_mode']) {
      case 'all':
        return RepeatMode.all;
      case 'one':
        return RepeatMode.one;
      default:
        return RepeatMode.off;
    }
  }

  // Full Song for the target's current track, fetched by id so the controller's
  // Now Playing has everything (artwork, format/explicit/HDCD badges, favorite,
  // lyrics) — not just the title/artist the target relays inline. Falls back to
  // the relayed fields until the fetch lands.
  Song? _targetSong;
  int? _targetSongFetchedId;
  final ApiService _api = ApiService();

  /// Full fetched Song when available, else a lightweight Song built from the
  /// relayed fields so the controller's Now Playing has something to show the
  /// instant control starts (upgraded to the full record when the fetch lands).
  /// True once the full Song has been fetched (vs the lightweight relayed
  /// fallback). The now-playing screen watches this to rebuild when the real
  /// record lands (so the format badge / full metadata fill in).
  bool get hasFullTargetSong => _targetSong != null;

  Song? get targetSong {
    if (_targetSong != null) return _targetSong;
    final id = targetSongId;
    if (id == null) return null;
    return Song.fromJson({
      'id': id,
      'title': targetSongTitle, // never null (falls back to device name)
      'artist_name': targetArtistName,
      'album_id': targetAlbumId,
      'duration': targetDuration.inSeconds,
    });
  }

  void _maybeFetchTargetSong() {
    final id = targetSongId;
    if (id == null) {
      _targetSong = null;
      _targetSongFetchedId = null;
      return;
    }
    if (id == _targetSongFetchedId) return; // already fetched (or fetching)
    _targetSongFetchedId = id;
    _api.getSongDetails(id).then((json) {
      if (_targetSongFetchedId == id) {
        _targetSong = Song.fromJson(json);
        notifyListeners();
      }
    }).catchError((_) {/* keep relayed title/artist fallback */});
  }

  // Group session state
  String? _groupId;
  String? _groupName;
  List<Map<String, dynamic>> _groupMembers = [];

  String? get groupId => _groupId;
  String? get groupName => _groupName;
  List<Map<String, dynamic>> get groupMembers => _groupMembers;

  // Connected devices
  List<DeviceInfo> _connectedDevices = [];
  List<DeviceInfo> get connectedDevices => _connectedDevices;

  // Podcast episode update callbacks (for cross-device sync). Multi-
  // listener: Discovery's Continue Listening row needs to update
  // alongside any open Feed Detail screen when another device advances
  // an episode. Legacy single-assignment setter preserved below for
  // existing callers; internally it maps to add/remove on the Set.
  final Set<void Function(int, int, bool?)> _episodeUpdatedListeners = {};
  void Function(int, int, bool?)? _legacyEpisodeUpdatedCallback;

  set onPodcastEpisodeUpdated(void Function(int, int, bool?)? cb) {
    // Mirror the single-assignment semantics the old callers expect.
    if (_legacyEpisodeUpdatedCallback != null) {
      _episodeUpdatedListeners.remove(_legacyEpisodeUpdatedCallback);
    }
    _legacyEpisodeUpdatedCallback = cb;
    if (cb != null) _episodeUpdatedListeners.add(cb);
  }

  void Function(int, int, bool?)? get onPodcastEpisodeUpdated =>
      _legacyEpisodeUpdatedCallback;

  /// Preferred API for multiple listeners — any screen that wants cross-
  /// device episode update events calls this in initState and the return
  /// value should be invoked in dispose.
  VoidCallback addPodcastEpisodeListener(void Function(int, int, bool?) cb) {
    _episodeUpdatedListeners.add(cb);
    return () => _episodeUpdatedListeners.remove(cb);
  }

  // Podcast download lifecycle callbacks. Fired from the backend when a
  // per-episode download completes or fails. Any screen showing download
  // buttons should wire these to flip UI state without polling.
  void Function(int episodeId, String path)? onPodcastDownloadComplete;
  void Function(int episodeId, String error)? onPodcastDownloadFailed;
  void Function(int episodeId, int downloaded, int total)? onPodcastDownloadProgress;

  // Convenience getters
  bool get isController => _mode == DeviceSyncMode.remoteController;
  bool get isBeingControlled => _mode == DeviceSyncMode.remoteTarget;
  bool get isInGroup => _mode == DeviceSyncMode.groupLeader || _mode == DeviceSyncMode.groupFollower;
  bool get isGroupLeader => _mode == DeviceSyncMode.groupLeader;
  bool get isGroupFollower => _mode == DeviceSyncMode.groupFollower;
  bool get isConnected => _socket?.connected ?? false;

  // Group sync tick timer (leader only)
  Timer? _syncTickTimer;

  DeviceSyncService(this._audioPlayer);

  /// Connect to the WebSocket server and register this device
  void connect() {
    if (_socket?.connected == true) return;

    _socket = io.io(
      ApiService.baseHost,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .enableForceNew()
          .build(),
    );

    _socket!.onConnect((_) {
      print('🔌 DeviceSync connected');
      // Announce ourselves
      _socket!.emit('device_connect', {
        'device_id': _audioPlayer.deviceId,
        'device_name': _audioPlayer.deviceName,
      });
      notifyListeners();
    });

    _socket!.onDisconnect((_) {
      print('🔌 DeviceSync disconnected');
      notifyListeners();
    });

    // Listen for events
    _setupEventListeners();

    _socket!.connect();
  }

  void _setupEventListeners() {
    // ---- Party Mode Events ----
    // Guest adds arrive as a broadcast; the player service filters on its
    // active party code (house scale — no rooms needed).
    _socket!.on('party_track_added', (data) {
      if (data is Map) {
        _audioPlayer
            .handlePartyTrackAdded(Map<String, dynamic>.from(data));
      }
    });
    _socket!.on('party_guest_joined', (data) {
      if (data is Map && _audioPlayer.partyActive) {
        final guest = (data['guest'] as String?) ?? 'Someone';
        print('🎉 [Party] Guest joined: $guest');
        _audioPlayer.onPartyGuestJoined?.call(guest);
      }
    });

    // Device list updates
    _socket!.on('device_list_updated', (data) {
      final devices = (data['devices'] as List?)?.map((d) => DeviceInfo(
        deviceId: d['device_id'],
        deviceName: d['device_name'],
        isConnected: d['connected'] ?? true,
      )).toList() ?? [];
      _connectedDevices = devices;
      notifyListeners();
    });

    // ---- Remote Control Events ----

    _socket!.on('remote_control_state', (data) {
      // We successfully started controlling a device
      _mode = DeviceSyncMode.remoteController;
      _targetDeviceId = data['target_device_id'];
      _targetDeviceName = data['target_name'];
      _targetState = Map<String, dynamic>.from(data['state'] ?? {});
      _targetStateAt = DateTime.now();
      _maybeFetchTargetSong();
      print('🎮 Now controlling: $_targetDeviceName');
      notifyListeners();
    });

    _socket!.on('remote_control_started', (data) {
      // Another device is now controlling us
      _mode = DeviceSyncMode.remoteTarget;
      _controllerDeviceId = data['controller_id'];
      _controllerDeviceName = data['controller_name'];
      _startTargetTick();
      print('🎮 Being controlled by: $_controllerDeviceName');
      notifyListeners();
    });

    _socket!.on('remote_control_ended', (data) {
      final reason = data['reason'] ?? 'unknown';
      print('🎮 Remote control ended: $reason');
      _stopTargetTick();

      if (_mode == DeviceSyncMode.remoteController) {
        _targetDeviceId = null;
        _targetDeviceName = null;
        _targetState = {};
      } else if (_mode == DeviceSyncMode.remoteTarget) {
        _controllerDeviceId = null;
        _controllerDeviceName = null;
      }
      _mode = DeviceSyncMode.independent;
      notifyListeners();
    });

    _socket!.on('remote_control_error', (data) {
      print('🎮 Remote control error: ${data['error']}');
      lastError = (data['error'] ?? 'Remote control failed').toString();
      // Reset state on error
      _mode = DeviceSyncMode.independent;
      _targetDeviceId = null;
      _targetDeviceName = null;
      notifyListeners();
    });

    _socket!.on('remote_command', (data) {
      // We're being told to execute a command
      if (_mode == DeviceSyncMode.remoteTarget) {
        final command = data['command'] as String;
        final args = Map<String, dynamic>.from(data['args'] ?? {});
        _audioPlayer.executeRemoteCommand(command, args);
      }
    });

    _socket!.on('remote_state_update', (data) {
      // Target device state update (when we're the controller)
      if (_mode == DeviceSyncMode.remoteController) {
        _targetState = Map<String, dynamic>.from(data['state'] ?? {});
        _targetStateAt = DateTime.now();
        _maybeFetchTargetSong();
        notifyListeners();
      }
    });

    // ---- Group Session Events ----

    _socket!.on('group_created', (data) {
      _mode = DeviceSyncMode.groupLeader;
      _groupId = data['group_id'];
      _groupName = data['group_name'];
      print('👥 Created group: $_groupName ($_groupId)');
      _startSyncTick();
      notifyListeners();
    });

    _socket!.on('group_joined', (data) {
      _mode = DeviceSyncMode.groupFollower;
      _groupId = data['group_id'];
      _groupName = data['group_name'];

      // Sync to leader's state
      final leaderState = data['leader_state'] as Map<String, dynamic>?;
      if (leaderState != null && leaderState.isNotEmpty) {
        _syncToLeaderState(leaderState);
      }

      print('👥 Joined group: $_groupName ($_groupId)');
      notifyListeners();
    });

    _socket!.on('group_member_changed', (data) {
      _groupMembers = List<Map<String, dynamic>>.from(data['members'] ?? []);
      notifyListeners();
    });

    _socket!.on('group_leader_changed', (data) {
      final newLeader = data['new_leader'];
      if (newLeader == _audioPlayer.deviceId) {
        _mode = DeviceSyncMode.groupLeader;
        print('👥 Promoted to group leader!');
        _startSyncTick();
      }
      notifyListeners();
    });

    _socket!.on('group_command', (data) {
      if (_mode == DeviceSyncMode.groupFollower) {
        final command = data['command'] as String;
        final args = Map<String, dynamic>.from(data['args'] ?? {});
        _audioPlayer.executeRemoteCommand(command, args);
      }
    });

    _socket!.on('group_sync_tick', (data) {
      if (_mode == DeviceSyncMode.groupFollower) {
        _handleSyncTick(data);
      }
    });

    _socket!.on('group_error', (data) {
      print('👥 Group error: ${data['error']}');
    });

    _socket!.on('active_groups', (data) {
      // Response to get_active_groups request — handled by caller
    });

    // Podcast episode progress sync from other devices
    _socket!.on('podcast_episode_updated', (data) {
      if (data is! Map) return;
      final episodeId = (data['episode_id'] is num) ? (data['episode_id'] as num).toInt() : null;
      final position = (data['position'] is num) ? (data['position'] as num).toInt() : 0;
      final isCompleted = data['is_completed'] as bool?;
      if (episodeId != null) {
        print('🎙️ Podcast sync: episode $episodeId pos=$position completed=$isCompleted');
        // Snapshot the set first — a listener that removes itself during
        // iteration would throw ConcurrentModificationError otherwise.
        for (final cb in _episodeUpdatedListeners.toList()) {
          try {
            cb(episodeId, position, isCompleted);
          } catch (e) {
            print('Podcast episode listener threw: $e');
          }
        }
      }
    });

    _socket!.on('podcast_download_complete', (data) {
      if (data is! Map) return;
      final episodeId = (data['episode_id'] is num) ? (data['episode_id'] as num).toInt() : null;
      final path = data['path'] as String? ?? '';
      if (episodeId != null) {
        print('🎙️ Podcast download complete: episode $episodeId -> $path');
        onPodcastDownloadComplete?.call(episodeId, path);
      }
    });

    _socket!.on('podcast_download_progress', (data) {
      if (data is! Map) return;
      final episodeId = (data['episode_id'] is num) ? (data['episode_id'] as num).toInt() : null;
      final downloaded = (data['downloaded'] is num) ? (data['downloaded'] as num).toInt() : 0;
      final total = (data['total'] is num) ? (data['total'] as num).toInt() : 0;
      if (episodeId != null) {
        onPodcastDownloadProgress?.call(episodeId, downloaded, total);
      }
    });

    _socket!.on('podcast_download_failed', (data) {
      if (data is! Map) return;
      final episodeId = (data['episode_id'] is num) ? (data['episode_id'] as num).toInt() : null;
      final error = data['error'] as String? ?? 'Unknown error';
      if (episodeId != null) {
        print('🎙️ Podcast download FAILED: episode $episodeId — $error');
        onPodcastDownloadFailed?.call(episodeId, error);
      }
    });
  }

  // ==================
  // Remote Control API
  // ==================

  /// Start controlling another device
  void startRemoteControl(String targetDeviceId) {
    lastError = null;
    _socket?.emit('remote_control_start', {
      'target_device_id': targetDeviceId,
    });
  }

  /// Clear the last error after the UI has shown it.
  void clearError() {
    lastError = null;
  }

  /// Stop controlling the target device
  void stopRemoteControl() {
    if (_targetDeviceId != null) {
      _socket?.emit('remote_control_stop', {
        'target_device_id': _targetDeviceId,
      });
    }
    _mode = DeviceSyncMode.independent;
    _targetDeviceId = null;
    _targetDeviceName = null;
    _targetState = {};
    notifyListeners();
  }

  /// Send a command to the device we're controlling
  void sendRemoteCommand(String command, {Map<String, dynamic>? args}) {
    if (_mode != DeviceSyncMode.remoteController || _targetDeviceId == null) return;

    _socket?.emit('remote_command', {
      'target_device_id': _targetDeviceId,
      'command': command,
      'args': args ?? {},
    });
  }

  // ==================
  // Group Session API
  // ==================

  /// Create a new sync group with this device as leader
  void createGroup(String name) {
    _socket?.emit('group_create', {'name': name});
  }

  /// Join an existing sync group
  void joinGroup(String groupId) {
    _socket?.emit('group_join', {'group_id': groupId});
  }

  /// Leave the current sync group
  void leaveGroup() {
    if (_groupId != null) {
      _socket?.emit('group_leave', {'group_id': _groupId});
    }
    _stopSyncTick();
    _mode = DeviceSyncMode.independent;
    _groupId = null;
    _groupName = null;
    _groupMembers = [];
    notifyListeners();
  }

  /// Send a command to all group followers (leader only)
  void sendGroupCommand(String command, {Map<String, dynamic>? args}) {
    if (_mode != DeviceSyncMode.groupLeader || _groupId == null) return;

    _socket?.emit('group_command', {
      'group_id': _groupId,
      'command': command,
      'args': args ?? {},
    });
  }

  /// Request list of active groups
  void requestActiveGroups() {
    _socket?.emit('get_active_groups');
  }

  // ==================
  // State Relay
  // ==================

  /// Called by AudioPlayerService when local state changes.
  /// Sends state updates to controller or broadcasts sync ticks if leader.
  void onLocalStateChanged() {
    if (_mode == DeviceSyncMode.remoteTarget && _socket?.connected == true) {
      _socket!.emit('remote_state_update', {
        'song_id': _audioPlayer.currentSong?.id,
        'song_title': _audioPlayer.currentSong?.title,
        'artist_name': _audioPlayer.currentSong?.artistName,
        'album_id': _audioPlayer.currentSong?.albumId,
        'position_ms': _audioPlayer.position.inMilliseconds,
        'duration_ms': _audioPlayer.duration.inMilliseconds,
        'is_playing': _audioPlayer.isPlaying,
        'is_shuffled': _audioPlayer.isShuffled,
        'repeat_mode': _audioPlayer.repeatMode.name,
      });
    }
  }

  // While THIS device is being controlled, push our state to the controller once
  // a second so its takeover view (now-playing mirror + scrubber) stays live
  // even when nothing changes locally. Stops as soon as we leave target mode.
  void _startTargetTick() {
    _stopTargetTick();
    _targetTickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_mode == DeviceSyncMode.remoteTarget) {
        onLocalStateChanged();
      } else {
        _stopTargetTick();
      }
    });
  }

  void _stopTargetTick() {
    _targetTickTimer?.cancel();
    _targetTickTimer = null;
  }

  // ==================
  // Sync Tick (Group Leader)
  // ==================

  void _startSyncTick() {
    _stopSyncTick();
    _syncTickTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_mode == DeviceSyncMode.groupLeader && _groupId != null) {
        _socket?.emit('group_sync_tick', {
          'group_id': _groupId,
          'song_id': _audioPlayer.currentSong?.id,
          'position_ms': _audioPlayer.position.inMilliseconds,
          'is_playing': _audioPlayer.isPlaying,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
      }
    });
  }

  void _stopSyncTick() {
    _syncTickTimer?.cancel();
    _syncTickTimer = null;
  }

  // ==================
  // Sync to Leader (Group Follower)
  // ==================

  void _syncToLeaderState(Map<String, dynamic> leaderState) {
    // Resume the leader's current playback
    final songId = leaderState['current_song_id'];
    if (songId == null) return;

    // Use resumeFromDevice to load the leader's queue
    final leaderId = leaderState['device_id'];
    if (leaderId != null) {
      _audioPlayer.resumeFromDevice(leaderId as String);
    }
  }

  void _handleSyncTick(Map<String, dynamic> data) {
    final leaderSongId = data['song_id'];
    final leaderPositionMs = data['position_ms'] as int? ?? 0;
    final leaderPlaying = data['is_playing'] == true;

    // Check if we're on the same song
    if (_audioPlayer.currentSong?.id != leaderSongId) {
      // Wrong song — need to resync (leader changed tracks)
      // This will be handled by group_command for next/previous
      return;
    }

    // Check position drift
    final localPositionMs = _audioPlayer.position.inMilliseconds;
    final drift = (localPositionMs - leaderPositionMs).abs();

    if (drift > 3000) {
      // Major drift — reload
      print('👥 Major drift detected (${drift}ms), seeking to leader position');
      _audioPlayer.seek(Duration(milliseconds: leaderPositionMs));
    } else if (drift > 500) {
      // Minor drift — seek
      print('👥 Drift correction (${drift}ms)');
      _audioPlayer.seek(Duration(milliseconds: leaderPositionMs));
    }

    // Sync play/pause state
    if (leaderPlaying && !_audioPlayer.isPlaying) {
      _audioPlayer.executeRemoteCommand('play', {});
    } else if (!leaderPlaying && _audioPlayer.isPlaying) {
      _audioPlayer.executeRemoteCommand('pause', {});
    }
  }

  // ==================
  // Cleanup
  // ==================

  void disconnect() {
    _stopSyncTick();
    _stopTargetTick();
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
    _mode = DeviceSyncMode.independent;
    _targetDeviceId = null;
    _targetDeviceName = null;
    _controllerDeviceId = null;
    _controllerDeviceName = null;
    _groupId = null;
    _groupName = null;
    _groupMembers = [];
    _connectedDevices = [];
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
