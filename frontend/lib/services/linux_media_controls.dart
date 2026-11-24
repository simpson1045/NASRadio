import 'dart:async';

import 'package:dbus/dbus.dart';

import 'api_service.dart';
import 'app_logger.dart';
import 'audio_player_service.dart';

/// Linux media keys and the desktop's sound menu, over MPRIS 2 (D-Bus).
///
/// Nov 23, 2026: on Linux Mint the keyboard's media keys popped up "Not
/// Available": a Linux desktop only routes them to a player that has
/// registered on the session bus as org.mpris.MediaPlayer2.<name>. Windows
/// has the same thing through smtc_windows (main.dart); this is the Linux
/// side. Pure Dart (package:dbus), no native code.
///
/// In: Play, Pause, PlayPause, Stop, Next, Previous, Seek, SetPosition,
/// Volume, Raise. Out: PlaybackStatus + Metadata (title, artist, album,
/// cover, length) when they change; Position is read live when asked.
class LinuxMediaControls extends DBusObject {
  LinuxMediaControls(this._svc, {this.onRaise})
      : super(DBusObjectPath('/org/mpris/MediaPlayer2'));

  final AudioPlayerService _svc;

  /// Bring the window forward (the sound menu's player name / "Raise").
  final void Function()? onRaise;

  static const _busName = 'org.mpris.MediaPlayer2.nasradio';
  static const _rootIface = 'org.mpris.MediaPlayer2';
  static const _playerIface = 'org.mpris.MediaPlayer2.Player';

  DBusClient? _client;
  Object? _sent; // what the desktop was last told (song / status / text)

  Future<void> start() async {
    try {
      _client = DBusClient.session();
      await _client!.registerObject(this);
      final reply = await _client!
          .requestName(_busName, flags: {DBusRequestNameFlag.doNotQueue});
      AppLogger.instance.info('🎹 [mpris] media keys + sound menu: $reply');
      _svc.addListener(_onPlayerChanged);
      _onPlayerChanged();
    } catch (e) {
      // No session bus (headless, Flatpak without the portal): the app
      // works, the media keys just don't.
      AppLogger.instance.warning('🎹 [mpris] not available: $e');
    }
  }

  Future<void> dispose() async {
    _svc.removeListener(_onPlayerChanged);
    await _client?.close();
    _client = null;
  }

  // ---- what the desktop sees ----

  String get _status {
    if (_svc.isPlaying) return 'Playing';
    return _svc.currentSong != null ? 'Paused' : 'Stopped';
  }

  Map<String, DBusValue> get _metadata {
    final song = _svc.currentSong;
    if (song == null) {
      return {'mpris:trackid': DBusObjectPath('/org/mpris/MediaPlayer2/TrackList/NoTrack')};
    }
    final length = _svc.duration > Duration.zero
        ? _svc.duration
        : Duration(seconds: song.duration);
    final albumId = song.albumId;
    return {
      'mpris:trackid': DBusObjectPath('/org/nasradio/track/${song.id < 0 ? 'x${-song.id}' : song.id}'),
      'mpris:length': DBusInt64(length.inMicroseconds),
      if (albumId > 0 && !song.isStation)
        'mpris:artUrl': DBusString(ApiService().getArtworkThumbUrl(albumId)),
      'xesam:title': DBusString(_svc.displayTitle),
      'xesam:artist': DBusArray.string([_svc.displayArtist]),
      'xesam:album': DBusString(song.albumTitle),
    };
  }

  Map<String, DBusValue> get _rootProps => {
        'CanQuit': const DBusBoolean(false),
        'CanRaise': DBusBoolean(onRaise != null),
        'HasTrackList': const DBusBoolean(false),
        'Identity': const DBusString('NASRadio'),
        'DesktopEntry': const DBusString('nasradio'),
        'SupportedUriSchemes': DBusArray.string(const []),
        'SupportedMimeTypes': DBusArray.string(const []),
      };

  Map<String, DBusValue> get _playerProps => {
        'PlaybackStatus': DBusString(_status),
        'LoopStatus': const DBusString('None'),
        'Rate': const DBusDouble(1.0),
        'Shuffle': const DBusBoolean(false),
        'Metadata': DBusDict.stringVariant(_metadata),
        'Volume': DBusDouble(_svc.getVolume()),
        'Position': DBusInt64(_svc.position.inMicroseconds),
        'MinimumRate': const DBusDouble(1.0),
        'MaximumRate': const DBusDouble(1.0),
        'CanGoNext': const DBusBoolean(true),
        'CanGoPrevious': const DBusBoolean(true),
        'CanPlay': const DBusBoolean(true),
        'CanPause': const DBusBoolean(true),
        'CanSeek': DBusBoolean(!(_svc.currentSong?.isStation ?? false)),
        'CanControl': const DBusBoolean(true),
      };

  /// The player notifies ~4x/s for position alone: only tell the desktop
  /// when the song, its text or play/pause actually changed.
  void _onPlayerChanged() {
    final now = (_svc.currentSong?.id, _svc.displayTitle, _svc.displayArtist,
        _svc.currentSong?.albumTitle, _status);
    if (now == _sent || _client == null) return;
    _sent = now;
    unawaited(emitPropertiesChanged(_playerIface, changedProperties: {
      'PlaybackStatus': DBusString(_status),
      'Metadata': DBusDict.stringVariant(_metadata),
      'CanSeek': DBusBoolean(!(_svc.currentSong?.isStation ?? false)),
    }).catchError((Object e) {
      AppLogger.instance.warning('🎹 [mpris] update failed: $e');
    }));
  }

  // ---- what the desktop asks for ----

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface == _rootIface) {
      if (call.name == 'Raise') onRaise?.call();
      return DBusMethodSuccessResponse();
    }
    if (call.interface != _playerIface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    switch (call.name) {
      case 'Play':
        if (!_svc.isPlaying) await _svc.togglePlayPause();
        break;
      case 'Pause':
        if (_svc.isPlaying) await _svc.togglePlayPause();
        break;
      case 'PlayPause':
        await _svc.togglePlayPause();
        break;
      case 'Stop':
        await _svc.stop();
        break;
      case 'Next':
        await _svc.next();
        break;
      case 'Previous':
        await _svc.previous();
        break;
      case 'Seek':
        final offset = Duration(microseconds: (call.values[0] as DBusInt64).value);
        await _seekTo(_svc.position + offset);
        break;
      case 'SetPosition':
        await _seekTo(Duration(microseconds: (call.values[1] as DBusInt64).value));
        break;
      case 'OpenUri':
        break;
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
    return DBusMethodSuccessResponse();
  }

  Future<void> _seekTo(Duration to) async {
    if (to < Duration.zero) to = Duration.zero;
    final end = _svc.duration;
    if (end > Duration.zero && to > end) to = end;
    await _svc.seek(to);
    await emitSignal(_playerIface, 'Seeked', [DBusInt64(to.inMicroseconds)]);
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final props = interface == _rootIface
        ? _rootProps
        : interface == _playerIface
            ? _playerProps
            : null;
    if (props == null) return DBusMethodErrorResponse.unknownInterface();
    final value = props[name];
    if (value == null) return DBusMethodErrorResponse.unknownProperty();
    return DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async {
    if (interface == _rootIface) return DBusGetAllPropertiesResponse(_rootProps);
    if (interface == _playerIface) return DBusGetAllPropertiesResponse(_playerProps);
    return DBusMethodErrorResponse.unknownInterface();
  }

  @override
  Future<DBusMethodResponse> setProperty(
      String interface, String name, DBusValue value) async {
    if (interface == _playerIface && name == 'Volume' && value is DBusDouble) {
      await _svc.setVolume(value.value.clamp(0.0, 1.0));
      return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.propertyReadOnly();
  }
}
