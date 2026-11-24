import '../utils/balanced_shuffle.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../main.dart' show globalAudioPlayerService;
import '../models/song.dart';
import '../screens/alarm_ringing_screen.dart';
import '../widgets/app_back_navigator.dart';
import 'api_service.dart';
import 'app_logger.dart';

/// One wake-up alarm. [days] is a bitmask, Mon=1 ... Sun=64; 0 = one-time.
///
/// What it plays is [sourceType] ('playlist' | 'album' | 'station' |
/// 'shuffle', or null for the alarm tone only). The resolved song list
/// ("queue") lives in [extra] with the server addresses ("hosts"): the
/// Android ringer plays it on its own at ring time, so it's rebuilt ahead of
/// time (on save and on every app start) and never needs the app running.
class WakeAlarm {
  final int id;
  int hour;
  int minute;
  int days;
  bool enabled;
  String label;
  String? sourceType;
  int? sourceId;
  String? sourceName;
  bool shuffle;
  int volume; // 0-100, alarm-stream level while it rings
  int fadeSeconds; // 0 = start at full volume
  final Map<String, dynamic> extra;

  WakeAlarm({
    required this.id,
    required this.hour,
    required this.minute,
    this.days = 0,
    this.enabled = true,
    this.label = 'Alarm',
    this.sourceType,
    this.sourceId,
    this.sourceName,
    this.shuffle = true,
    this.volume = 50,
    this.fadeSeconds = 60,
    Map<String, dynamic>? extra,
  }) : extra = extra ?? {};

  static const _known = {
    'id', 'hour', 'minute', 'days', 'enabled', 'label', 'sourceType',
    'sourceId', 'sourceName', 'shuffle', 'volume', 'fadeSeconds',
  };
  static const dayLetters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
  static const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  factory WakeAlarm.fromJson(Map<String, dynamic> j) => WakeAlarm(
        id: j['id'] as int,
        hour: j['hour'] as int,
        minute: j['minute'] as int,
        days: (j['days'] ?? 0) as int,
        enabled: (j['enabled'] ?? true) as bool,
        label: (j['label'] ?? 'Alarm') as String,
        sourceType: j['sourceType'] as String?,
        sourceId: j['sourceId'] as int?,
        sourceName: j['sourceName'] as String?,
        shuffle: (j['shuffle'] ?? true) as bool,
        volume: (j['volume'] ?? 50) as int,
        fadeSeconds: (j['fadeSeconds'] ?? 60) as int,
        extra: Map.of(j)..removeWhere((k, _) => _known.contains(k)),
      );

  Map<String, dynamic> toJson() => {
        ...extra,
        'id': id,
        'hour': hour,
        'minute': minute,
        'days': days,
        'enabled': enabled,
        'label': label,
        'sourceType': sourceType,
        'sourceId': sourceId,
        'sourceName': sourceName,
        'shuffle': shuffle,
        'volume': volume,
        'fadeSeconds': fadeSeconds,
      };

  WakeAlarm copy() => WakeAlarm.fromJson(
      jsonDecode(jsonEncode(toJson())) as Map<String, dynamic>);

  bool hasDay(int i) => days & (1 << i) != 0;

  String get daysLabel {
    if (days == 0) return 'Once';
    if (days == 0x7f) return 'Every day';
    if (days == 0x1f) return 'Weekdays';
    if (days == 0x60) return 'Weekends';
    return [for (var i = 0; i < 7; i++) if (hasDay(i)) dayNames[i]].join(', ');
  }

  String get sourceLabel {
    switch (sourceType) {
      case 'playlist':
        return 'Playlist: ${sourceName ?? ''}';
      case 'album':
        return 'Album: ${sourceName ?? ''}';
      case 'station':
        return 'Station: ${sourceName ?? ''}';
      case 'shuffle':
        return 'Shuffle my library';
      default:
        return 'Alarm tone';
    }
  }

  int get queueLength => (extra['queue'] as List?)?.length ?? 0;
}

/// Wake-up alarms, Android only. Scheduling, storage and the ringing itself
/// (music, volume, fade, fallback tone) live in Kotlin (AlarmScheduler /
/// AlarmRingService) so they work even when Flutter isn't running. This
/// class edits the list, prepares each alarm's songs, and shows the ringing
/// screen.
class AlarmService {
  AlarmService._();
  static final AlarmService instance = AlarmService._();

  static const _channel = MethodChannel('com.nasradio/alarm');
  static const _queueMax = 60;

  /// {id, label, since, track?, tone?} while an alarm rings, else null.
  final ValueNotifier<Map<String, dynamic>?> ringing = ValueNotifier(null);
  bool _screenOpen = false;

  bool get supported => Platform.isAndroid;

  Future<void> init() async {
    if (!supported) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'ringing':
          _onRinging(_asMap(call.arguments));
          break;
        case 'stopped':
          AppLogger.instance.info('⏰ [alarm] ended (${call.arguments})');
          ringing.value = null;
          break;
      }
    });
    // Launched BY the alarm (cold start): the "ringing" event fired before
    // Dart was listening, so ask.
    try {
      final r = await _channel.invokeMethod('getRinging');
      if (r != null) _onRinging(_asMap(r));
    } catch (e) {
      AppLogger.instance.info('⏰ [alarm] getRinging failed: $e');
    }
    unawaited(_refreshWhenLoggedIn());
  }

  /// Stream links carry the media token, which only exists after login:
  /// wait for it (up to a minute), then refresh every alarm's song list.
  Future<void> _refreshWhenLoggedIn() async {
    for (var i = 0; i < 30 && ApiService.mediaToken == null; i++) {
      await Future.delayed(const Duration(seconds: 2));
    }
    if (ApiService.mediaToken == null) return;
    try {
      final alarms = await load();
      if (alarms.any((a) => a.sourceType != null)) {
        await save(alarms);
        AppLogger.instance.info('⏰ [alarm] song lists refreshed');
      }
    } catch (e) {
      AppLogger.instance.info('⏰ [alarm] refresh failed: $e');
    }
  }

  static Map<String, dynamic> _asMap(dynamic m) => jsonDecode(jsonEncode(m))
      as Map<String, dynamic>; // deep-converts platform maps

  void _onRinging(Map<String, dynamic> info, [int attempt = 0]) {
    ringing.value = info;
    if (_screenOpen) return;
    final nav = NavBackController.navigatorKey.currentState;
    if (nav == null) {
      // App still starting up: try again on the next frames.
      if (attempt < 50) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _onRinging(info, attempt + 1));
      }
      return;
    }
    AppLogger.instance.info('⏰ [alarm] ringing: ${info['label']}');
    _screenOpen = true;
    nav
        .push(MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => const AlarmRingingScreen(),
        ))
        .whenComplete(() => _screenOpen = false);
  }

  Future<List<WakeAlarm>> load() async {
    final raw = await _channel.invokeMethod<String>('getAlarms') ?? '[]';
    return [
      for (final j in jsonDecode(raw) as List)
        WakeAlarm.fromJson(Map<String, dynamic>.from(j as Map))
    ];
  }

  /// Rebuilds each enabled alarm's song list (best effort: on failure the
  /// previous list is kept), saves the whole list and re-arms. Returns the
  /// next ring time.
  Future<DateTime?> save(List<WakeAlarm> alarms) async {
    for (final a in alarms) {
      if (!a.enabled) continue;
      try {
        await _buildQueue(a);
      } catch (e) {
        AppLogger.instance.info('⏰ [alarm] song list for ${a.label} failed: $e');
      }
    }
    final next = await _channel.invokeMethod<int>(
        'saveAlarms', jsonEncode([for (final a in alarms) a.toJson()]));
    return next == null ? null : DateTime.fromMillisecondsSinceEpoch(next);
  }

  /// Resolve what the alarm plays into a list the Android ringer can stream
  /// directly: {path, title, artist, album, albumId, song} per track, or
  /// {url, station} for a radio station. Paths are joined to "hosts"
  /// (home LAN first, then outside) at ring time.
  Future<void> _buildQueue(WakeAlarm a) async {
    final api = ApiService();
    if (a.sourceType == null) {
      a.extra.remove('queue');
      return;
    }
    if (a.sourceType == 'station') {
      final stations = await api.getStations();
      final s = stations.firstWhere(
          (s) => s['id'] == a.sourceId,
          orElse: () => throw Exception('station ${a.sourceId} not found'));
      a.extra['queue'] = [
        {
          'url': s['url'],
          'title': s['name'] ?? 'Radio',
          'artist': s['genre'] ?? 'Live radio',
          'album': '',
          'albumId': 0,
          'art': s['favicon'] ?? '',
          'station': true,
        }
      ];
      a.extra['queueBuiltAt'] = DateTime.now().millisecondsSinceEpoch;
      return;
    }

    List<dynamic> songs;
    switch (a.sourceType) {
      case 'playlist':
        songs = (await api.getPlaylist(a.sourceId!))['songs'] as List? ?? [];
        break;
      case 'album':
        songs = (await api.getAlbum(a.sourceId!))['songs'] as List? ?? [];
        break;
      case 'shuffle':
        songs = await api.getRandomSongs(_queueMax);
        break;
      default:
        songs = [];
    }
    final list = [for (final s in songs) Map<String, dynamic>.from(s as Map)];
    if (a.shuffle && a.sourceType != 'shuffle') {
      balancedShuffleInPlace(
          list, (m) => '${m['artist_name'] ?? m['artist'] ?? ''}');
    }
    if (list.isEmpty) throw Exception('nothing to play');

    final base = ApiService.baseUrl;
    a.extra['hosts'] = [
      '${ApiService.lanHost}/api',
      '${ApiService.wanHost}/api',
    ];
    a.extra['queue'] = [
      for (final s in list.take(_queueMax))
        {
          // '/stream/123?quality=high&token=...' (host-independent)
          'path': api
              .getStreamUrl(s['id'] as int, quality: 'high')
              .substring(base.length),
          'title': s['title'] ?? '',
          'artist': s['artist_name'] ?? '',
          'album': s['album_title'] ?? '',
          'albumId': s['album_id'] ?? 0,
          'song': s,
        }
    ];
    a.extra['queueBuiltAt'] = DateTime.now().millisecondsSinceEpoch;
  }

  Future<DateTime?> nextAlarmAt() async {
    final next = await _channel.invokeMethod<int>('nextAlarmAt');
    return next == null ? null : DateTime.fromMillisecondsSinceEpoch(next);
  }

  /// Ring this alarm (its music, volume, fade) in [seconds].
  Future<void> testIn(int alarmId, int seconds) =>
      _channel.invokeMethod('testIn', {'id': alarmId, 'seconds': seconds});
  Future<void> stop() => _channel.invokeMethod('stop');
  Future<void> snooze() => _channel.invokeMethod('snooze');
  Future<void> preview(int volume) => _channel.invokeMethod('preview', volume);
  Future<void> stopPreview() => _channel.invokeMethod('stopPreview');

  /// "I'm up, keep playing": end the alarm and carry its music over to the
  /// normal player (media volume), from the same song and position.
  Future<void> keepPlaying() async {
    final state = await _channel.invokeMethod<Map>('keepPlaying');
    if (state == null || state['playing'] != true) return;
    final alarms = await load();
    final alarm = alarms.where((a) => a.id == state['alarmId']).firstOrNull;
    final queue = (alarm?.extra['queue'] as List?) ?? const [];
    if (alarm == null || queue.isEmpty) return;
    final index = (state['index'] as int).clamp(0, queue.length - 1);
    final position = Duration(milliseconds: state['positionMs'] as int? ?? 0);
    final player = globalAudioPlayerService;

    final first = Map<String, dynamic>.from(queue.first as Map);
    if (first['station'] == true) {
      await player.playSong(Song(
        id: -(alarm.sourceId ?? 1),
        title: first['title'] as String? ?? 'Radio',
        artistId: 0,
        artistName: first['artist'] as String? ?? 'Live radio',
        albumId: 0,
        albumTitle: 'Stations',
        trackNumber: 0,
        discNumber: 1,
        duration: 0,
        filePath: first['url'] as String? ?? '',
        fileSize: 0,
        bitrate: 0,
        sourceType: 'station',
        stationArtworkUrl: first['art'] as String? ?? '',
      ));
      return;
    }
    final songs = [
      for (final e in queue)
        Song.fromJson(Map<String, dynamic>.from((e as Map)['song'] as Map))
    ];
    player.setQueue(songs, index,
        sourceType: alarm.sourceType,
        sourceId: alarm.sourceId,
        sourceName: alarm.sourceName ?? alarm.label);
    await player.playFromQueue(index);
    if (position > const Duration(seconds: 2)) await player.seek(position);
  }

  /// {exact, fullScreen, notifications}: false = Android is blocking it.
  Future<Map<String, bool>> permissions() async {
    final m = await _channel.invokeMethod<Map>('permissions') ?? {};
    return {for (final e in m.entries) e.key as String: e.value as bool};
  }

  /// Ask for notification permission; if Android won't ask again, open
  /// NASRadio's settings page instead.
  Future<void> requestNotifications() async {
    final status = await Permission.notification.request();
    if (status.isPermanentlyDenied) await openAppSettings();
  }

  Future<void> openFullScreenSettings() =>
      _channel.invokeMethod('openFullScreenSettings');
  Future<void> openExactAlarmSettings() =>
      _channel.invokeMethod('openExactAlarmSettings');
}
