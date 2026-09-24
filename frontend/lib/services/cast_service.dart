import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, Socket;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:bonsoir/bonsoir.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'cast/cast_session.dart';
import 'cast/cast_device.dart';
import 'cast/cast_session_manager.dart';
import 'cast_keepalive.dart';
import '../models/saved_cast_device.dart';
import '../models/song.dart';
import 'api_service.dart';
import 'auth_http_client.dart';
import 'app_logger.dart';

/// Manages Chromecast device discovery, connection, and media playback.
/// Uses bonsoir directly for mDNS discovery (cast package's discovery is broken
/// with bonsoir v6) and cast package for CASTV2 session/messaging.
class CastService extends ChangeNotifier {
  // Cast session state
  CastSession? _session;
  CastDevice? _connectedDevice;
  bool _isConnected = false;
  bool _isDiscovering = false;
  List<CastDevice> _devices = [];

  // Media state (reported by Chromecast)
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  int? _mediaSessionId;
  String _playerState = 'IDLE'; // IDLE, BUFFERING, PLAYING, PAUSED
  bool _usingCustomReceiver = false; // Track which receiver we're using

  // Receiver volume (0.0–1.0) — kept in sync with RECEIVER_STATUS messages
  // so the Android MediaSession can mirror it onto the lock-screen volume
  // slider via RemoteAndroidPlaybackInfo.
  double _castVolume = 1.0;
  bool _castMuted = false;
  // Receiver-reported volume capabilities. controlType is one of
  // 'attenuation' (Chromecast attenuates its own output — SET_VOLUME works),
  // 'master' (Chromecast forwards volume via HDMI-CEC to the connected
  // amp/TV — SET_VOLUME may or may not survive the eARC chain), or
  // 'fixed' (volume is not controllable — SET_VOLUME is silently ignored,
  // which is what most Chromecast → TV → AVR/eARC setups land in).
  // Logged on change so a quick `combined.log` look tells us why a volume
  // key press did nothing.
  String? _castVolumeControlType;
  num? _castVolumeStepInterval;

  // Callback for when a song finishes on Chromecast
  VoidCallback? onMediaFinished;

  /// Supplies the upcoming queue (next ~10 music songs) for the
  /// receiver's self-advance list. Wired in main.dart to the audio
  /// player's queue. The receiver uses it ONLY when no sender drives
  /// the next LOAD (app swiped away / phone off the LAN) — so music
  /// keeps flowing through the queue instead of stopping.
  List<Song> Function()? upNextProvider;

  // Song id currently loaded on the RECEIVER, from MEDIA_STATUS
  // media.customData.songId. The receiver can self-advance while we're
  // gone; on rejoin/reconnect this tells the app which song to sync to.
  int? _receiverSongId;
  int? get receiverSongId => _receiverSongId;

  // ── Joined mode ─────────────────────────────────────────────────────
  // connectToDevice() asks the TV what's running BEFORE launching. If our
  // receiver is already up (a Claude/headless cast, or a session left
  // playing by another phone) we attach to it instead of LAUNCH+LOAD,
  // which used to stomp whatever was playing. While joined:
  //   • the app follows the receiver's song (onReceiverSongChanged),
  //   • it never pushes UP_NEXT or auto-advances (the receiver's owner
  //     drives the queue — for a headless cast that's cast_sender.py),
  //   • next/previous go through the backend's /api/cast/* endpoints,
  //   • disconnect() leaves the TV playing (no STOP).
  // takeOver() drops back to normal sender mode: the phone LOADs its own
  // queue and owns the session again.
  bool _joinedExisting = false;
  bool get joinedExisting => _joinedExisting;
  // True when the media currently loaded on the receiver came from the
  // backend's headless sender (customData.headlessSender in the LOAD).
  bool _receiverHeadless = false;
  bool get receiverHeadless => _receiverHeadless;
  // Fired when the receiver reports a different songId than last time
  // (its own self-advance, or the headless queue moving on).
  void Function(int songId)? onReceiverSongChanged;

  /// A guest sender (Claude through the backend) asked the receiver to put
  /// tracks into the queue this phone owns. The receiver relays it here as
  /// QUEUE_INSERT; we insert into the real queue, re-send UP_NEXT, and
  /// answer QUEUE_INSERT_RESULT so the guest gets an honest yes/no.
  /// Return the new queue length, or null to refuse.
  Future<int?> Function(List<int> songIds, bool playNext, String by)?
      onRemoteQueueInsert;

  /// Same relay for next/previous from a guest. Return false to refuse.
  Future<bool> Function(String direction)? onRemoteSkip;

  /// Leave joined mode and let the phone own the session again. Caller
  /// then LOADs its queue (AudioPlayerService.takeOverCast).
  void takeOver() {
    _joinedExisting = false;
    _receiverHeadless = false;
    notifyListeners();
  }

  // Quality of the most recent LOAD — reused for UP_NEXT item URLs.
  String _lastQuality = 'lossless';

  // Auto-reconnect state. When a cast session drops unexpectedly (cast
  // device kills the receiver app, network hiccup between cast device
  // and Google's infra, etc.), we attempt to re-establish the session
  // on the same device and have the audio_player_service resume from
  // the last known position. The user might hear a few seconds of gap
  // but playback continues automatically — no manual re-cast needed.
  //
  // We only auto-reconnect when the disconnect was NOT user-initiated
  // (intentional disconnect() call → flag set → don't reconnect).
  // Capped at 3 attempts with 2/4/8 second backoff so a genuinely-off
  // cast device doesn't get spammed with connect attempts forever.
  /// Called when an auto-reconnect succeeds. Hook it up in main.dart
  /// to trigger `audio_player_service.startCasting()` — that picks up
  /// the cached `_position` and re-LOADs the song with `currentTime`
  /// set to where we left off.
  VoidCallback? onAutoReconnect;

  CastDevice? _lastConnectedDevice;
  bool _intentionalDisconnect = false;
  int _reconnectAttempt = 0;
  // The phone losing its LAN (Samsung adaptive Wi-Fi hopping to cellular,
  // AP flake) is THE observed drop cause: both the TV and the local backend
  // go unreachable at once. Aug 12 incident: LAN out for ~12 min, but the
  // old "8 attempts" gave up after ~5.5 min — worse, a double-scheduling
  // bug (attempt failure scheduled a retry from BOTH _handleDisconnect and
  // _attemptReconnect) burned two attempt slots per real attempt. Now:
  // time-based window instead of a count, and a cheap TCP probe before
  // each launch attempt (4s to fail instead of ~60s of TCP timeouts), so
  // the cast self-heals whenever the LAN returns within the window.
  static const Duration _reconnectWindow = Duration(minutes: 30);
  static const List<int> _reconnectBackoffSeconds = [2, 4, 8, 15, 30];
  DateTime? _reconnectStartedAt;
  // True while an auto-reconnect connectToDevice() is in flight. Its
  // failure path runs _handleDisconnect, which must NOT schedule another
  // retry on top of the one _attemptReconnect itself schedules — that
  // was the double-scheduling bug above.
  bool _reconnectInProgress = false;
  Timer? _reconnectTimer;

  /// Consulted before each auto-reconnect attempt. Return false to stand
  /// down (e.g. the user gave up on the TV and started playing locally —
  /// a surprise re-cast minutes later would yank the audio back).
  bool Function()? shouldAutoReconnect;

  // Tracks when the receiver fired DIAG_RECEIVER_SHUTDOWN on its way out
  // (cast.framework.system.EventType.SHUTDOWN or beforeunload). The
  // sender then treats the upcoming state.closed as intentional and
  // skips auto-reconnect — the user killed the cast app from the TV
  // remote and the app should stay killed. If the message loses the
  // race against the underlying socket tear-down, _handleDisconnect
  // fires before we get this signal and the auto-reconnect does its
  // thing (one extra cast launch the user has to dismiss — worse than
  // ideal but still better than two kills-to-kill).
  DateTime? _receiverShutdownAt;
  static const Duration _shutdownGrace = Duration(seconds: 3);

  // ── Drop-incident telemetry ──────────────────────────────────────
  // Goal: every disconnect emits ONE consolidated log line with all the
  // correlatable state, so we don't have to grep + stitch combined.log
  // to figure out why cast dropped. The receiver pushes a DIAG_HEARTBEAT
  // every 5 seconds with its internal state; we stash the latest one
  // and dump it at disconnect time. Receiver-side events that bear on
  // drops (SENDER_DISCONNECTED, STUCK_BUFFERING, SHUTDOWN) flip flags
  // here so the dump can say "stuck buffering = yes, SHUTDOWN = no" etc.
  DateTime? _lastReceiverHeartbeatAt;
  int? _lastReceiverTick;
  String? _lastReceiverState;
  double? _lastReceiverCurrentTime;
  int? _lastReceiverBufferingMs;
  int? _lastReceiverTimeUpdateAgoMs;
  Map<String, dynamic>? _lastReceiverDiagCounters;
  bool _senderDisconnectedSeen = false;
  int? _stuckBufferingMaxSec;

  // Position polling timer (Chromecast doesn't push position updates)
  Timer? _positionTimer;

  // Stuck detection: force-advance if Chromecast silently stalls at end of track
  DateTime? _lastPlayStartTime;
  int _stuckCount = 0;

  // Deferred waveform/lyrics: wait for media load before sending to receiver
  Song? _pendingCustomDataSong;

  // Waveform "generating" re-poll. When a song has no cached waveform the
  // backend kicks off generation and answers with a flat placeholder
  // (status='generating'). We used to send that placeholder to the TV once
  // and never follow up — the receiver saw "I have a waveform" and stopped
  // asking, so uncached songs kept the flat bar forever. Now we re-poll
  // every 5s (up to ~2 min) while the song is still the loaded one and
  // push the real waveform when it's ready.
  int? _lastLoadedSongId;
  Timer? _waveformRetryTimer;
  int _waveformRetryCount = 0;
  static const int _maxWaveformRetries = 24;

  // Cancellable HTTP client for the current song's waveform+lyrics fetch.
  // On song change or disconnect we close it — this aborts any in-flight
  // request so the backend can release its DB connection immediately
  // (the lyrics endpoint can otherwise hold a pooled conn across a 10s
  // LRCLIB call, draining the pool during rapid Chromecast skipping).
  http.Client? _mediaDataClient;

  // Persisted "Recent devices" list, loaded lazily from SharedPreferences.
  // Devices you successfully connect to get auto-saved. The picker sheet
  // reads this and shows a live online/offline dot based on whether the
  // device turned up in the current scan.
  static const _savedDevicesPrefsKey = 'cast_saved_devices_v1';
  List<SavedCastDevice> _savedDevices = [];
  bool _savedDevicesLoaded = false;

  List<SavedCastDevice> get savedDevices => List.unmodifiable(_savedDevices);

  Future<void> _ensureSavedDevicesLoaded() async {
    if (_savedDevicesLoaded) return;
    _savedDevicesLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_savedDevicesPrefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = json.decode(raw) as List<dynamic>;
      _savedDevices = decoded
          .map((e) => SavedCastDevice.fromJson(e as Map<String, dynamic>))
          .toList();
      notifyListeners();
    } catch (e) {
      print('⚠️ [Cast] Failed to load saved devices: $e');
    }
  }

  Future<void> loadSavedDevices() => _ensureSavedDevicesLoaded();

  Future<void> _persistSavedDevices() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded =
          json.encode(_savedDevices.map((d) => d.toJson()).toList());
      await prefs.setString(_savedDevicesPrefsKey, encoded);
    } catch (e) {
      print('⚠️ [Cast] Failed to persist saved devices: $e');
    }
  }

  Future<void> _rememberDevice(CastDevice device) async {
    await _ensureSavedDevicesLoaded();
    final now = DateTime.now().millisecondsSinceEpoch;
    final existingIndex =
        _savedDevices.indexWhere((s) => s.serviceName == device.serviceName);
    if (existingIndex >= 0) {
      final prior = _savedDevices[existingIndex];
      _savedDevices[existingIndex] = prior.copyWith(
        originalName: device.name,
        modelHint: device.extras['md'] ?? prior.modelHint,
        lastSeenMillis: now,
        host: device.host,
        port: device.port,
      );
    } else {
      _savedDevices = [
        ..._savedDevices,
        SavedCastDevice(
          serviceName: device.serviceName,
          originalName: device.name,
          modelHint: device.extras['md'],
          lastSeenMillis: now,
          host: device.host,
          port: device.port,
        ),
      ];
    }
    notifyListeners();
    await _persistSavedDevices();
  }

  Future<void> renameSavedDevice(String serviceName, String? newName) async {
    await _ensureSavedDevicesLoaded();
    final i = _savedDevices.indexWhere((s) => s.serviceName == serviceName);
    if (i < 0) return;
    final trimmed = newName?.trim();
    _savedDevices[i] = _savedDevices[i].copyWith(
      customName: (trimmed == null || trimmed.isEmpty) ? null : trimmed,
      clearCustomName: trimmed == null || trimmed.isEmpty,
    );
    notifyListeners();
    await _persistSavedDevices();
  }

  Future<void> removeSavedDevice(String serviceName) async {
    await _ensureSavedDevicesLoaded();
    _savedDevices =
        _savedDevices.where((s) => s.serviceName != serviceName).toList();
    notifyListeners();
    await _persistSavedDevices();
  }

  // ── Swipe-away survival ──────────────────────────────────────────
  // The receiver keeps playing when the app is swiped away (by design —
  // disableIdleTimeout). This marker records the device of the live
  // session so a fresh app launch can silently REJOIN it instead of
  // starting over. Written on connect + every LOAD (fresh timestamp);
  // cleared on user disconnect, TV-remote kill, or a failed rejoin.
  static const _activeCastPrefsKey = 'cast_active_session_v1';
  static const _activeCastMaxAge = Duration(hours: 12);

  Future<void> _saveActiveCastMarker(CastDevice device) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _activeCastPrefsKey,
          json.encode({
            'serviceName': device.serviceName,
            'name': device.name,
            'host': device.host,
            'port': device.port,
            'ts': DateTime.now().millisecondsSinceEpoch,
          }));
    } catch (_) {}
  }

  Future<void> _clearActiveCastMarker() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_activeCastPrefsKey);
    } catch (_) {}
  }

  /// True from app launch until the rejoin attempt resolves. The player
  /// service treats this like isCasting for its automatic-playback
  /// paths — during the launch window isCasting is still false (the
  /// join takes seconds), and that gap let startup-time triggers start
  /// LOCAL playback on top of a live cast (the app-open hiss).
  bool _resumePending = false;
  bool get resumePending => _resumePending;

  /// Rejoin a cast session that survived the app being swiped away.
  /// Called once at app startup. Cheap when there's nothing to do:
  /// no marker → false; TV unreachable (3s probe) → false; receiver
  /// no longer running our app → clear marker, false. On success the
  /// sender adopts the receiver's live media session — position, state,
  /// and mediaSessionId flow in through the normal MEDIA_STATUS path,
  /// and the receiver re-requests waveform/lyrics itself if it needs to.
  Future<bool> tryResumeSession() async {
    if (_isConnected) return true;
    _resumePending = true;
    try {
      final resumed = await _tryResumeSessionInner();
      return resumed;
    } finally {
      _resumePending = false;
      notifyListeners();
    }
  }

  Future<bool> _tryResumeSessionInner() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_activeCastPrefsKey);
      if (raw == null || raw.isEmpty) return false;
      final data = json.decode(raw) as Map<String, dynamic>;
      final ts = (data['ts'] as num?)?.toInt() ?? 0;
      final age = DateTime.now().millisecondsSinceEpoch - ts;
      if (age > _activeCastMaxAge.inMilliseconds) {
        await prefs.remove(_activeCastPrefsKey);
        return false;
      }
      final device = CastDevice(
        serviceName: (data['serviceName'] as String?) ?? '',
        name: (data['name'] as String?) ?? 'TV',
        host: (data['host'] as String?) ?? '',
        port: (data['port'] as num?)?.toInt() ?? 8009,
        extras: const {},
      );
      if (device.host.isEmpty) return false;

      // Fast reachability probe so a powered-off TV doesn't stall startup.
      try {
        final probe = await Socket.connect(device.host, device.port,
            timeout: const Duration(seconds: 3));
        probe.destroy();
      } catch (_) {
        AppLogger.instance
            .info('📺 [Cast] Resume: ${device.name} unreachable — skipping');
        return false;
      }

      AppLogger.instance.info(
          '📺 [Cast] Resume: trying to rejoin session on ${device.name}...');
      final ok = await _tryLaunchApp(device, customAppId, join: true);
      if (!ok) {
        AppLogger.instance.info(
            '📺 [Cast] Resume: receiver not running — marker cleared');
        await _clearActiveCastMarker();
        return false;
      }
      _usingCustomReceiver = hasCustomReceiver;
      await _rememberDevice(device);
      CastKeepAlive.acquire();
      // Adopt whatever the receiver is doing right now. A bare GET_STATUS
      // (no mediaSessionId) returns all media sessions; the MEDIA_STATUS
      // handler picks up mediaSessionId/position/playerState from it.
      _session?.sendMessage(
          CastSession.kNamespaceMedia, {'type': 'GET_STATUS'});
      AppLogger.instance
          .info('📺 [Cast] Resume: rejoined ${device.name} successfully');
      notifyListeners();
      return true;
    } catch (e) {
      AppLogger.instance.warning('📺 [Cast] Resume attempt failed: $e');
      return false;
    }
  }

  /// Look up a currently-scanned device by its saved service name.
  /// Returns null if the device isn't online in the current scan.
  CastDevice? scannedDeviceFor(String serviceName) {
    for (final d in _devices) {
      if (d.serviceName == serviceName) return d;
    }
    return null;
  }

  // Message stream subscription
  StreamSubscription? _messageSubscription;
  StreamSubscription? _stateSubscription;

  // Getters
  bool get isConnected => _isConnected;
  bool get isDiscovering => _isDiscovering;
  bool get isPlaying => _isPlaying;
  Duration get position => _position;
  Duration get duration => _duration;
  String get playerState => _playerState;
  CastDevice? get connectedDevice => _connectedDevice;
  List<CastDevice> get devices => _devices;
  String get deviceName => _connectedDevice?.name ?? '';
  double get castVolume => _castVolume;
  bool get castMuted => _castMuted;
  String? get castVolumeControlType => _castVolumeControlType;

  /// Discover Chromecast devices on the local network via mDNS.
  /// Uses bonsoir directly since cast package's CastDiscoveryService
  /// is incompatible with bonsoir v6.
  ///
  /// Each device is pushed into [devices] and emitted via
  /// [notifyListeners] the moment its mDNS record resolves — callers
  /// listening as a [ChangeNotifier] see the list populate live
  /// instead of waiting for the full timeout. Discovery keeps running
  /// in the background for the remainder of [timeout] to pick up
  /// slower devices.
  Future<List<CastDevice>> discoverDevices({Duration timeout = const Duration(seconds: 12)}) async {
    if (_isDiscovering) return _devices;

    _isDiscovering = true;
    _devices = [];
    notifyListeners();

    try {
      // Android 13+ requires NEARBY_WIFI_DEVICES for mDNS discovery
      if (Platform.isAndroid) {
        final status = await Permission.nearbyWifiDevices.request();
        print('📡 [Cast] NEARBY_WIFI_DEVICES permission: $status');
        if (!status.isGranted) {
          print('❌ [Cast] Permission denied — cannot discover devices');
          _isDiscovering = false;
          notifyListeners();
          return _devices;
        }
      }

      print('📡 [Cast] Starting mDNS discovery for _googlecast._tcp...');

      final discovery = BonsoirDiscovery(type: '_googlecast._tcp');

      // CRITICAL: Must call initialize() before start() — this sets up
      // the EventChannel and makes eventStream non-null.
      // Without this, eventStream is null and we silently get no events.
      await discovery.initialize();
      print('📡 [Cast] Discovery initialized, isReady=${discovery.isReady}');

      // Subscribe to eventStream BEFORE calling start()
      // to avoid missing early events
      final completer = Completer<void>();
      Timer(timeout, () {
        if (!completer.isCompleted) completer.complete();
      });

      final stream = discovery.eventStream;
      print('📡 [Cast] eventStream is ${stream == null ? "NULL" : "available"}');

      final sub = stream?.listen((event) {
        print('📡 [Cast] Event: ${event.runtimeType}');

        // bonsoir v6: use sealed class pattern matching
        if (event is BonsoirDiscoveryServiceResolvedEvent) {
          final service = event.service;
          final name = service.attributes['fn'] ?? service.name;
          final host = service.host ?? '';
          final port = service.port;
          print('📡 [Cast] Resolved: $name at $host:$port (attrs: ${service.attributes})');

          if (host.isNotEmpty && !_devices.any((d) => d.serviceName == service.name)) {
            _devices = [
              ..._devices,
              CastDevice(
                serviceName: service.name,
                name: name,
                host: host,
                port: port,
                extras: Map<String, String>.from(service.attributes),
              ),
            ];
            notifyListeners();
            print('📡 [Cast] ✅ Added device: $name ($host:$port) — live push');
          }
        } else if (event is BonsoirDiscoveryServiceFoundEvent) {
          print('📡 [Cast] Found (unresolved): ${event.service.name} type=${event.service.type}');
          // Must explicitly resolve to get host/port
          try {
            discovery.serviceResolver.resolveService(event.service);
            print('📡 [Cast] Resolving ${event.service.name}...');
          } catch (e) {
            print('❌ [Cast] Failed to resolve: $e');
          }
        } else if (event is BonsoirDiscoveryServiceResolveFailedEvent) {
          print('📡 [Cast] ⚠️ Service found but RESOLVE FAILED');
        } else if (event is BonsoirDiscoveryServiceLostEvent) {
          print('📡 [Cast] Service lost: ${event.service.name}');
        } else if (event is BonsoirDiscoveryStartedEvent) {
          print('📡 [Cast] Discovery started event received');
        } else {
          print('📡 [Cast] Other event: ${event.runtimeType}');
        }
      }, onError: (e) {
        print('❌ [Cast] eventStream error: $e');
      }, onDone: () {
        print('📡 [Cast] eventStream done');
      });

      // Now start discovery AFTER subscribing
      await discovery.start();
      print('📡 [Cast] Discovery started, waiting ${timeout.inSeconds}s for responses...');

      await completer.future;
      await sub?.cancel();
      await discovery.stop();

      print('📡 [Cast] Discovery complete: ${_devices.length} device(s)');
    } catch (e) {
      print('❌ [Cast] Discovery failed: $e');
      _devices = [];
    }

    _isDiscovering = false;
    notifyListeners();
    return _devices;
  }

  /// Cast receiver to launch. The server tells us its registered custom
  /// receiver app ID (Settings → Integrations → Cast device); with none set
  /// we use Google's Default Media Receiver, which plays audio but has no
  /// NASRadio screen or custom messaging.
  static const defaultAppId = 'CC1AD845'; // Default Media Receiver
  static bool get hasCustomReceiver => ApiService.castReceiverAppId.isNotEmpty;
  static String get customAppId =>
      hasCustomReceiver ? ApiService.castReceiverAppId : defaultAppId;

  int? get mediaSessionId => _mediaSessionId;

  /// Connect to a Chromecast device and launch the receiver app.
  /// Tries NASRadio Custom Receiver first, falls back to Default Media Receiver.
  Future<bool> connectToDevice(CastDevice device) async {
    // Something already casting there? Join it rather than replace it.
    // Fails fast (one RECEIVER_STATUS round-trip) when nothing is running.
    _joinedExisting = false;
    _receiverHeadless = false;
    final joined = await _tryLaunchApp(device, customAppId, join: true);
    if (joined) {
      _usingCustomReceiver = hasCustomReceiver;
      _joinedExisting = true;
      await _rememberDevice(device);
      CastKeepAlive.acquire();
      // Bare GET_STATUS on the media namespace returns the live media
      // session; the MEDIA_STATUS handler picks up mediaSessionId, the
      // receiver's songId and whether a headless sender loaded it.
      _session?.sendMessage(
          CastSession.kNamespaceMedia, {'type': 'GET_STATUS'});
      AppLogger.instance
          .info('🔌 [Cast] Joined the running cast on ${device.name}');
      notifyListeners();
      return true;
    }

    var success = false;
    if (hasCustomReceiver) {
      success = await _tryLaunchApp(device, customAppId);
      if (success) _usingCustomReceiver = true;
    }
    if (!success) {
      if (hasCustomReceiver) {
        print('🔌 [Cast] Custom receiver failed, trying Default Media Receiver...');
      }
      success = await _tryLaunchApp(device, defaultAppId);
      if (success) _usingCustomReceiver = false;
    }

    if (!success) {
      print('❌ [Cast] Both receivers failed');
      _handleDisconnect();
    } else {
      // Auto-remember devices we actually reached — so they show up
      // in the "Recent" section the next time the picker opens.
      await _rememberDevice(device);
      // Keep Wi-Fi + CPU awake so locking the phone doesn't drop the cast.
      // Idempotent — also covers the auto-reconnect path.
      CastKeepAlive.acquire();
    }

    return success;
  }

  /// Attempt to connect to a device and launch a specific app ID.
  /// Returns true if the session reaches connected state within the timeout.
  ///
  /// [join]: instead of LAUNCHing a fresh receiver, GET_STATUS the device
  /// and attach to an ALREADY-RUNNING instance of [appId] (used to rejoin
  /// a cast that kept playing after the app was swiped away). Fails fast
  /// if the app isn't running.
  Future<bool> _tryLaunchApp(CastDevice device, String appId,
      {bool join = false}) async {
    try {
      AppLogger.instance.info(
          '🔌 [Cast] Connecting to ${device.name} with appId=$appId${join ? " (join)" : ""}...');

      // Clean up any existing session first
      await _cleanupSession();

      _session = await CastSessionManager().startSession(device);
      _session!.expectedAppId = join ? appId : null;

      // Create a completer that resolves when we get a definitive result
      final connectCompleter = Completer<bool>();

      // Listen for connection state changes
      _stateSubscription = _session!.stateStream.listen((state) {
        print('🔌 [Cast] Session state: $state');
        if (state == CastSessionState.connected) {
          _isConnected = true;
          _connectedDevice = device;
          _saveActiveCastMarker(device);
          // Remember the device for potential auto-reconnect later.
          // Cleared in user-initiated disconnect() so we don't try to
          // auto-reconnect after the user explicitly disconnected.
          _lastConnectedDevice = device;
          _intentionalDisconnect = false;
          _reconnectAttempt = 0;
          _reconnectStartedAt = null;
          _resetDropTelemetry();
          _cancelPendingReconnect();
          _startPositionPolling();
          notifyListeners();
          if (!connectCompleter.isCompleted) connectCompleter.complete(true);
        } else if (state == CastSessionState.closed) {
          if (!connectCompleter.isCompleted) connectCompleter.complete(false);
          _handleDisconnect();
        }
      });

      // Listen for messages — watch for LAUNCH_ERROR
      _messageSubscription = _session!.messageStream.listen((message) {
        final type = message['type'];
        if (type == 'LAUNCH_ERROR') {
          AppLogger.instance.error('❌ [Cast] LAUNCH_ERROR for appId=$appId: ${message['reason']}');
          if (!connectCompleter.isCompleted) connectCompleter.complete(false);
        }
        if (join &&
            type == 'RECEIVER_STATUS' &&
            !connectCompleter.isCompleted) {
          // Join mode: a status without our app running is a definitive
          // "nothing to rejoin" — fail fast instead of waiting out the
          // timeout. (The session only connects when it finds our appId.)
          final apps = (message['status']?['applications'] as List?) ?? const [];
          final running = apps.any((a) => a is Map && a['appId'] == appId);
          if (!running) {
            AppLogger.instance.info(
                '🔌 [Cast] Join: $appId not running on ${device.name}');
            connectCompleter.complete(false);
          }
        }
        _handleCastMessage(message);
      });

      // Join = ask what's running and latch on; Launch = start our app.
      _session!.sendMessage(CastSession.kNamespaceReceiver,
          join ? {'type': 'GET_STATUS'} : {'type': 'LAUNCH', 'appId': appId});
      print('🔌 [Cast] ${join ? "GET_STATUS (join)" : "LAUNCH"} sent for appId=$appId');

      // Wait for result with timeout
      final result = await connectCompleter.future
          .timeout(Duration(seconds: join ? 8 : 15), onTimeout: () {
        AppLogger.instance.warning('⚠️ [Cast] Timeout waiting for ${join ? "join" : "LAUNCH"} response (appId=$appId)');
        return false;
      });

      if (!result) {
        await _cleanupSession();
      }

      return result;
    } catch (e) {
      AppLogger.instance.error('❌ [Cast] Connection failed for appId=$appId: $e');
      await _cleanupSession();
      return false;
    }
  }

  /// Clean up current session without full state reset
  Future<void> _cleanupSession() async {
    _messageSubscription?.cancel();
    _stateSubscription?.cancel();
    _messageSubscription = null;
    _stateSubscription = null;
    try {
      await _session?.close();
    } catch (_) {}
    _session = null;
  }

  /// Disconnect from the current Chromecast device
  Future<void> disconnect() async {
    AppLogger.instance.info('🔌 [Cast] disconnect() called by app');
    // User-initiated disconnect — do NOT auto-reconnect on the
    // resulting state.closed event. The flag is consumed in
    // _handleDisconnect and reset to false at the next successful
    // connect.
    _intentionalDisconnect = true;
    _lastConnectedDevice = null;
    _receiverShutdownAt = null;
    _reconnectAttempt = 0;
    _reconnectStartedAt = null;
    _clearActiveCastMarker(); // user ended the session — nothing to rejoin
    _cancelPendingReconnect();
    _stopPositionPolling();
    // Cast session is truly ending — drop the Wi-Fi/CPU locks.
    CastKeepAlive.release();

    try {
      if (_session != null) {
        // Stop media first — unless we merely joined someone else's
        // session, in which case leaving must not kill their playback.
        if (_mediaSessionId != null && !_joinedExisting) {
          _session!.sendMessage(CastSession.kNamespaceMedia, {
            'type': 'STOP',
            'mediaSessionId': _mediaSessionId,
          });
        }

        await _session!.close();
      }
    } catch (e) {
      AppLogger.instance.warning('⚠️ [Cast] Error during disconnect: $e');
    }

    _handleDisconnect();
  }

  void _resetDropTelemetry() {
    _lastReceiverHeartbeatAt = null;
    _lastReceiverTick = null;
    _lastReceiverState = null;
    _lastReceiverCurrentTime = null;
    _lastReceiverBufferingMs = null;
    _lastReceiverTimeUpdateAgoMs = null;
    _lastReceiverDiagCounters = null;
    _senderDisconnectedSeen = false;
    _stuckBufferingMaxSec = null;
  }

  // Emit a single consolidated line on every disconnect. Goal: when
  // simpson1045 sees cast drop, he can grep `🚨 [Cast] DROP` in combined.log
  // and the immediately-following line tells the whole story without
  // having to stitch together heartbeat + state + diag messages from
  // the surrounding 60 seconds of log. Includes:
  //   - session uptime (when did we connect, how long alive)
  //   - heartbeat tx/rx (was the sender's PING flow still working?)
  //   - lost heartbeats (tx − rx ≈ how many PONGs went missing
  //     before the drop — a non-zero number means the receiver was
  //     unresponsive on the heartbeat channel before the socket died)
  //   - last DIAG_HEARTBEAT age + receiver state at that point
  //     (was the receiver JS still alive? was it stuck in BUFFERING?
  //     was the audio element making forward progress?)
  //   - flags: was SENDER_DISCONNECTED seen, was SHUTDOWN seen, was
  //     STUCK_BUFFERING reported before the drop
  void _logDropIncident(bool wasIntentional) {
    final session = _session;
    final now = DateTime.now();

    final uptimeSec = session != null
        ? now.difference(session.openedAt).inSeconds
        : null;
    final hbTx = session?.heartbeatsSent;
    final hbRx = session?.heartbeatsReceived;
    final hbLost = (hbTx != null && hbRx != null) ? (hbTx - hbRx) : null;

    final lastHb = _lastReceiverHeartbeatAt;
    final lastHbAgoMs = lastHb != null
        ? now.difference(lastHb).inMilliseconds
        : null;

    final shutdownSeen = _receiverShutdownAt != null;

    final buf = StringBuffer()
      ..write('🚨 [Cast] DROP intentional=$wasIntentional')
      ..write(' uptime=${uptimeSec ?? "?"}s')
      ..write(' hbTx=${hbTx ?? "?"} hbRx=${hbRx ?? "?"}')
      ..write(' hbLost=${hbLost ?? "?"}')
      ..write(' lastRxHb=${lastHbAgoMs != null ? "${lastHbAgoMs}ms ago" : "never"}')
      ..write(' rxState=${_lastReceiverState ?? "?"}')
      ..write(' rxTick=${_lastReceiverTick ?? "?"}')
      ..write(' rxCurTime=${_lastReceiverCurrentTime?.toStringAsFixed(1) ?? "?"}s')
      ..write(' rxTimeUpdateAgo=${_lastReceiverTimeUpdateAgoMs ?? "?"}ms')
      ..write(' rxBufferingMs=${_lastReceiverBufferingMs ?? "n/a"}')
      ..write(' senderDisc=${_senderDisconnectedSeen ? "yes" : "no"}')
      ..write(' shutdown=${shutdownSeen ? "yes" : "no"}')
      ..write(' stuckBufMaxSec=${_stuckBufferingMaxSec ?? "n/a"}')
      ..write(' rxCounters=${_lastReceiverDiagCounters ?? "n/a"}');

    if (wasIntentional || shutdownSeen) {
      // Expected disconnect path — log as info.
      AppLogger.instance.info(buf.toString());
    } else {
      // Unexpected drop — this is the line you actually want to read.
      AppLogger.instance.warning(buf.toString());
    }
  }

  void _handleDisconnect() {
    // Snapshot the intent flag BEFORE we clear anything else. Reset so
    // the next disconnect starts from a clean slate.
    final wasIntentional = _intentionalDisconnect;
    _intentionalDisconnect = false;

    // Drop-incident report FIRST, while _session is still readable.
    _logDropIncident(wasIntentional);

    _session = null;
    _connectedDevice = null;
    _isConnected = false;
    _isPlaying = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _mediaSessionId = null;
    _receiverSongId = null;
    _joinedExisting = false;
    _receiverHeadless = false;
    _playerState = 'IDLE';
    _stopPositionPolling();
    _messageSubscription?.cancel();
    _stateSubscription?.cancel();
    _messageSubscription = null;
    _stateSubscription = null;
    _mediaDataClient?.close();
    _mediaDataClient = null;
    _waveformRetryTimer?.cancel();
    _waveformRetryTimer = null;
    _lastLoadedSongId = null;
    notifyListeners();

    // If the disconnect was unexpected AND we have a device we'd
    // previously connected to, try to reconnect. The cast device
    // killing the receiver app mid-playback (memory pressure, app
    // lifecycle, etc.) is the scenario this targets — user wants
    // playback to continue without manually re-casting.
    // audio_player_service has retained the last playback position
    // (the _onCastStateChanged gate prevents the new-session
    // 0-position from clobbering it), so once the reconnect succeeds
    // onAutoReconnect fires startCasting() which re-LOADs at that
    // position.
    //
    // TV-remote-kill suppression: when the user kills the cast app
    // from the TV remote, the receiver fires DIAG_RECEIVER_SHUTDOWN
    // before going down. If that message arrived in the last few
    // seconds, treat THIS disconnect as intentional and skip the
    // reconnect. If the message lost the race against the socket
    // tear-down (receiver got killed too fast), we fall through and
    // reconnect anyway — user has to dismiss the relaunch but isn't
    // stuck in a kill-twice loop.
    final shutdownFresh = _receiverShutdownAt != null &&
        DateTime.now().difference(_receiverShutdownAt!) < _shutdownGrace;
    if (!wasIntentional && shutdownFresh) {
      AppLogger.instance.info(
        '🛑 [Cast] Receiver fired SHUTDOWN before drop — user killed cast '
        'from TV, skipping auto-reconnect',
      );
      _receiverShutdownAt = null;
      _lastConnectedDevice = null;
      _reconnectAttempt = 0;
      _reconnectStartedAt = null;
      _clearActiveCastMarker(); // receiver is gone — nothing to rejoin
      CastKeepAlive.release(); // user killed cast from the TV — session over
      return;
    }
    // NOT while a reconnect attempt is in flight: connectToDevice()'s
    // failure path lands here, and _attemptReconnect already schedules
    // the next try itself. Scheduling from both spots double-counted
    // attempts (each real failure burned two slots).
    if (!wasIntentional && _lastConnectedDevice != null && !_reconnectInProgress) {
      _scheduleReconnect();
    }
  }

  void _cancelPendingReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  void _abandonReconnect(String why) {
    AppLogger.instance.warning(
      '🔄 [Cast] Auto-reconnect to ${_lastConnectedDevice?.name} '
      'abandoned — $why',
    );
    _reconnectAttempt = 0;
    _reconnectStartedAt = null;
    _lastConnectedDevice = null;
    _cancelPendingReconnect();
    CastKeepAlive.release(); // stop holding the radio awake
  }

  void _scheduleReconnect() {
    if (_lastConnectedDevice == null) return;
    final started = _reconnectStartedAt ??= DateTime.now();
    if (DateTime.now().difference(started) > _reconnectWindow) {
      _abandonReconnect(
          'window of ${_reconnectWindow.inMinutes} min exhausted');
      return;
    }
    final delaySec = _reconnectAttempt < _reconnectBackoffSeconds.length
        ? _reconnectBackoffSeconds[_reconnectAttempt]
        : 30;
    _reconnectAttempt++;
    AppLogger.instance.info(
      '🔄 [Cast] Auto-reconnecting to ${_lastConnectedDevice!.name} '
      'in ${delaySec}s (attempt $_reconnectAttempt, '
      '${DateTime.now().difference(started).inSeconds}s since drop)',
    );
    _cancelPendingReconnect();
    _reconnectTimer = Timer(Duration(seconds: delaySec), _attemptReconnect);
  }

  Future<void> _attemptReconnect() async {
    final device = _lastConnectedDevice;
    if (device == null) return;

    // The user moved on (started local playback) — a surprise re-cast
    // now would yank their audio back to the TV. Stand down for good.
    if (shouldAutoReconnect?.call() == false) {
      _abandonReconnect('user resumed local playback');
      return;
    }

    // Cheap reachability probe before the real launch. A full launch
    // attempt against an unreachable TV burns ~60s in TCP timeouts
    // (~30s × 2 app IDs); the probe fails in 4s, so the retry cadence
    // holds at ~30s while the phone is off the LAN.
    try {
      final probe = await Socket.connect(device.host, device.port,
          timeout: const Duration(seconds: 4));
      probe.destroy();
    } catch (_) {
      AppLogger.instance.info(
        '🔄 [Cast] Probe: ${device.host}:${device.port} unreachable — '
        'deferring attempt $_reconnectAttempt',
      );
      _scheduleReconnect();
      return;
    }

    AppLogger.instance.info('🔄 [Cast] Attempting auto-reconnect to ${device.name}...');
    _reconnectInProgress = true;
    try {
      final success = await connectToDevice(device);
      if (success) {
        AppLogger.instance.info(
          '🔄 [Cast] Auto-reconnect succeeded — invoking onAutoReconnect '
          'to resume playback',
        );
        _reconnectAttempt = 0;
        _reconnectStartedAt = null;
        // Ask what the receiver is doing BEFORE resuming: with UP_NEXT it
        // may have self-advanced through the queue during the outage and
        // still be playing. The MEDIA_STATUS lands within ~a second and
        // populates receiverSongId/playerState; onAutoReconnect (main.dart)
        // then decides adopt-vs-reLOAD from that.
        _session?.sendMessage(
            CastSession.kNamespaceMedia, {'type': 'GET_STATUS'});
        Future.delayed(const Duration(milliseconds: 1800),
            () => onAutoReconnect?.call());
      } else {
        AppLogger.instance.warning(
          '🔄 [Cast] Auto-reconnect attempt $_reconnectAttempt failed — '
          'scheduling next attempt',
        );
        _scheduleReconnect();
      }
    } catch (e) {
      AppLogger.instance.warning(
        '🔄 [Cast] Auto-reconnect attempt $_reconnectAttempt threw: $e',
      );
      _scheduleReconnect();
    } finally {
      _reconnectInProgress = false;
    }
  }

  /// Load and play a song on the connected Chromecast.
  /// [startPosition] allows resuming from a specific position (e.g., when casting
  /// mid-song from the phone player).
  Future<void> loadAndPlay(Song song, {String quality = 'lossless', Duration? startPosition, String? podcastArtworkUrl}) async {
    if (_session == null || !_isConnected) {
      print('❌ [Cast] Cannot play — not connected');
      return;
    }

    // Custom receiver page loads over HTTPS, so media URLs must also be HTTPS
    // to avoid mixed content. Default Media Receiver has special privileges for HTTP.
    // Both use FLAC lossless — the <cast-media-player> element uses the native
    // hardware decoder pipeline, not the HTML5 audio element.
    final host = _usingCustomReceiver
        ? ApiService.wanHost   // HTTPS for custom receiver
        : ApiService.lanHost;  // LAN for default receiver
    // For podcasts, stream via the legacy RSS proxy. podcastEpisodeId is the
    // real episode id (the negative song.id was a legacy encoding of it).
    final isPodcast = song.isPodcast;
    final isStation = song.isStation;
    // Chromecast fetches these URLs itself and can't send an auth header, so
    // the read-only media token rides in the URL (only for our own backend
    // URLs — never an external podcast artwork URL or a station stream).
    final mt = ApiService.mediaToken;
    String tok(String url) => (mt == null || mt.isEmpty)
        ? url
        : '$url${url.contains('?') ? '&' : '?'}token=$mt';
    final streamUrl = isStation
        // ALL stations ride the backend's station relay when casting to
        // the custom receiver. Two reasons, both measured on the LG:
        // (1) plain-http streams are mixed content on the HTTPS receiver
        // page — Chrome blocks them and the TV plays silence; (2) the
        // receiver's Chrome demands a large audio cushion before it
        // starts a live stream, and burst-less stations (Radio Art)
        // never provide one — the relay's ring buffer does. Direct URL
        // only for the Default Media Receiver fallback.
        ? (_usingCustomReceiver
            ? tok('$host/api/station-proxy?url=${Uri.encodeQueryComponent(song.filePath)}')
            : song.filePath)
        : isPodcast
            ? tok('$host/api/rss/stream/${song.podcastEpisodeId ?? -song.id}')
            : tok('$host/api/stream/${song.id}?quality=$quality');
    final artworkUrl = isStation
        ? (song.stationArtworkUrl?.isNotEmpty == true
            ? song.stationArtworkUrl
            : null)
        : (isPodcast && podcastArtworkUrl != null)
            ? podcastArtworkUrl
            : tok('$host/api/artwork/${song.albumId}');
    final artistImageUrl = isStation
        ? null
        : isPodcast
            ? artworkUrl
            : tok('$host/api/artist-image/${song.artistId}');

    // Pick the right MIME type. Chromecast's CAF receiver routes to
    // different hardware decoders based on contentType — hardcoding
    // 'audio/flac' for everything meant podcast MP3s (and transcoded
    // music) silently failed to play on the TV even though metadata
    // arrived correctly.
    // Stations: resolve the REAL content type instead of assuming MP3.
    // Hardcoded audio/mpeg silently broke AAC+ stations on the TV (the
    // receiver routes to a decoder based on contentType). URL extension
    // first, else a header probe of the stream itself.
    final contentType = isStation
        ? await _stationContentType(song.filePath)
        : _mimeForStream(song, quality, isPodcast);
    final streamType = isStation ? 'LIVE' : 'BUFFERED';

    print('🎵 [Cast] Loading: ${song.title} → $streamUrl (type=$contentType)');

    // Freshen the rejoin marker — its timestamp is "when did we last
    // actively cast," and every LOAD proves the session is alive.
    if (_connectedDevice != null) _saveActiveCastMarker(_connectedDevice!);

    // New song — retire any waveform re-poll for the previous one.
    _lastLoadedSongId = song.id;
    _waveformRetryTimer?.cancel();
    _waveformRetryTimer = null;
    _waveformRetryCount = 0;

    // Reset position tracking
    _position = Duration.zero;
    _duration = song.duration > 0 ? Duration(seconds: song.duration) : Duration.zero;

    final message = {
      'contentId': streamUrl,
      'contentType': contentType,
      'streamType': streamType,
      'metadata': {
        'type': 3, // MusicTrackMediaMetadata
        'metadataType': 3,
        'title': song.title,
        'songName': song.title,
        'artist': song.artistName,
        'albumName': song.albumTitle,
        'albumArtist': song.artistName,
        'trackNumber': song.trackNumber,
        'images': artworkUrl != null
            ? [
                {'url': artworkUrl},
              ]
            : const [],
      },
      // Custom fields for the custom receiver (not part of standard Cast metadata)
      'customData': {
        'artistImageUrl': artistImageUrl,
        'specialWaveform': _detectSpecialWaveform(song),
        'fileFormat': song.fileFormat,
        'isHdcd': song.isHdcd,
        'isExplicit': song.isExplicit,
        // Track the song id on the receiver so it can ask us to
        // re-send waveform/lyrics if the deferred-send race causes
        // them to be dropped (PLAYING state transition missed,
        // sender restart mid-cast, etc).
        'songId': song.id,
      },
    };

    _lastQuality = quality;
    final startSeconds = startPosition != null ? startPosition.inMilliseconds / 1000.0 : 0;
    AppLogger.instance.info(
      '📺 [Cast] LOAD song=${song.id} ("${song.title}") '
      'currentTime=${startSeconds}s contentId=$streamUrl',
    );
    _session!.sendMessage(CastSession.kNamespaceMedia, {
      'type': 'LOAD',
      'autoPlay': true,
      'currentTime': startSeconds,
      'media': message,
    });

    // Defer waveform, lyrics, and badge info until the receiver confirms media loaded.
    // Sending immediately after LOAD causes messages to be dropped on subsequent songs
    // because the receiver is still processing the new LOAD.
    if (_usingCustomReceiver) {
      _pendingCustomDataSong = song;
      // Safety fallback: if we don't detect the state transition within 3 seconds,
      // send the data anyway (better late than never)
      Future.delayed(const Duration(seconds: 3), () {
        if (_pendingCustomDataSong != null && _pendingCustomDataSong!.id == song.id) {
          print('⚠️ [Cast] Sending deferred custom data via timeout fallback');
          final pending = _pendingCustomDataSong!;
          _pendingCustomDataSong = null;
          _sendBadgeInfo(pending);
          _sendWaveformAndLyrics(pending.id);
          _maybeSendUpNext(pending);
        }
      });
    }
  }

  /// Resolve a live station's contentType for the cast LOAD.
  /// Extension when the URL has a real one; otherwise probe the stream's
  /// response headers (Icecast/Shoutcast answer these instantly — we ask
  /// for 2 bytes and close). Falls back to audio/mpeg, which is the old
  /// hardcoded behavior. Shoutcast v1's raw "ICY 200 OK" status line
  /// makes Dart's HTTP client throw — that lands in the catch and falls
  /// back, same as before, so nothing regresses.
  Future<String> _stationContentType(String url) async {
    const byExt = {
      'mp3': 'audio/mpeg',
      'aac': 'audio/aac',
      'aacp': 'audio/aac',
      'ogg': 'audio/ogg',
      'opus': 'audio/ogg',
      'm4a': 'audio/mp4',
      'flac': 'audio/flac',
    };
    final path = Uri.tryParse(url)?.path ?? '';
    final dot = path.lastIndexOf('.');
    final ext = dot >= 0 ? path.substring(dot + 1).toLowerCase() : '';
    if (byExt.containsKey(ext)) return byExt[ext]!;

    // Bare client on purpose — this hits the EXTERNAL station server,
    // not our backend, so no auth token is wanted (or safe) here.
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(url))
        ..headers['Icy-MetaData'] = '0'
        ..headers['Range'] = 'bytes=0-1';
      final resp =
          await client.send(req).timeout(const Duration(seconds: 4));
      final ct = (resp.headers['content-type'] ?? '').toLowerCase();
      AppLogger.instance.info('📻 [Cast] Station probe: $url → "$ct"');
      if (ct.contains('aac')) return 'audio/aac';
      if (ct.contains('ogg') || ct.contains('opus')) return 'audio/ogg';
      if (ct.contains('mp4')) return 'audio/mp4';
      if (ct.contains('mpeg') || ct.contains('mp3')) return 'audio/mpeg';
    } catch (e) {
      AppLogger.instance
          .warning('📻 [Cast] Station probe failed for $url: $e');
    } finally {
      client.close();
    }
    return 'audio/mpeg';
  }

  // Pick the Chromecast contentType for a given stream.
  //
  //  - Podcasts → audio/mpeg. The vast majority are MP3; even if
  //    a particular feed serves M4A, audio/mpeg is what the
  //    receiver-side CAF SDK copes best with as a fallback.
  //  - Music at non-lossless quality → audio/mpeg (backend transcodes
  //    to MP3 for anything other than 'lossless').
  //  - Music at lossless quality → MIME derived from the original
  //    file extension, defaulting to audio/flac.
  String _mimeForStream(Song song, String quality, bool isPodcast) {
    if (song.isStation) return 'audio/mpeg'; // most Icecast/Shoutcast = MP3
    if (isPodcast) return 'audio/mpeg';
    if (quality != 'lossless') return 'audio/mpeg';
    switch (song.fileFormat) {
      case 'FLAC':
        return 'audio/flac';
      case 'MP3':
        return 'audio/mpeg';
      case 'M4A':
      case 'AAC':
        return 'audio/mp4';
      case 'WAV':
      case 'WAVE':
        return 'audio/wav';
      case 'OGG':
        return 'audio/ogg';
      case 'OPUS':
        return 'audio/opus';
      case 'AIFF':
      case 'AIF':
        return 'audio/aiff';
      default:
        return 'audio/flac';
    }
  }

  /// Detect special waveform mode based on artist/album
  String? _detectSpecialWaveform(Song song) {
    final artistLower = song.artistName.toLowerCase();
    final albumLower = song.albumTitle.toLowerCase();
    final titleLower = song.title.toLowerCase();

    if (artistLower == 'van halen' || artistLower.contains('van halen')) {
      return 'evh';
    }
    if (albumLower.contains('jurassic park') || albumLower.contains('jurassic world')) {
      return 'dna';
    }
    if (albumLower.contains('star wars') || titleLower.contains('star wars')) {
      // Determine lightsaber color based on track title
      final redKeywords = ['imperial', 'vader', 'duel of the fates', 'sith', 'dark side',
        'dark lord', 'emperor', 'palpatine', 'anakin\'s dark deeds', 'order 66', 'grievous',
        'dooku', 'battle of the heroes', 'immolation', 'kylo', 'snoke', 'first order', 'darth'];
      final greenKeywords = ['yoda', 'dagobah', 'jedi council', 'qui-gon', 'qui gon'];
      final purpleKeywords = ['mace windu'];

      for (final k in redKeywords) {
        if (titleLower.contains(k)) return 'lightsaber:red';
      }
      for (final k in greenKeywords) {
        if (titleLower.contains(k)) return 'lightsaber:green';
      }
      for (final k in purpleKeywords) {
        if (titleLower.contains(k)) return 'lightsaber:purple';
      }
      return 'lightsaber:blue';
    }
    return null;
  }

  /// Custom namespace for NASRadio receiver messages (waveform, lyrics, badges, toggle)
  static const kNamespaceNasradio = 'urn:x-cast:com.nasradio.custom';

  /// Send sleep timer countdown to the TV display
  void sendSleepTimer(int remainingSeconds) {
    if (_session == null || !_isConnected || !_usingCustomReceiver) return;
    _session!.sendMessage(kNamespaceNasradio, {
      'type': 'SLEEP_TIMER',
      'remaining': remainingSeconds,
    });
    print('🌙 [Cast] Sleep timer: ${remainingSeconds}s');
  }

  /// Toggle black screen mode on the TV (for sleep/bedtime — OLED pixels off)
  void setBlackScreen(bool active) {
    if (_session == null || !_isConnected || !_usingCustomReceiver) return;
    _session!.sendMessage(kNamespaceNasradio, {
      'type': 'BLACK_SCREEN',
      'active': active,
    });
    print('🌙 [Cast] Black screen: $active');
  }

  /// Push a live "now playing" track to the custom receiver when a station's
  /// broadcast track changes. Updates title/artist (and per-track artwork,
  /// when the broadcaster provides one) on-screen — no stream reload, so
  /// audio never gaps. No-op on the default receiver.
  void updateStationNowPlaying(String title, String? artist,
      {String? artworkUrl}) {
    if (_session == null || !_isConnected || !_usingCustomReceiver) return;
    _session!.sendMessage(kNamespaceNasradio, {
      'type': 'NOW_PLAYING',
      'title': title,
      'artist': artist ?? '',
      if (artworkUrl != null && artworkUrl.isNotEmpty) 'artwork': artworkUrl,
    });
    print('📻 [Cast] Now playing: $title — $artist');
  }

  /// Toggle lyrics view on the TV (called when user taps lyrics button in app)
  void toggleLyrics(bool show) {
    if (_session == null || !_isConnected || !_usingCustomReceiver) return;
    _session!.sendMessage(kNamespaceNasradio, {
      'type': 'TOGGLE_LYRICS',
      'show': show,
    });
    print('🎤 [Cast] Toggle lyrics: $show');
  }

  String _tokenizedUrl(String url) {
    final mt = ApiService.mediaToken;
    if (mt == null || mt.isEmpty) return url;
    return '$url${url.contains('?') ? '&' : '?'}token=$mt';
  }

  /// One UP_NEXT item — a complete, receiver-loadable description of a
  /// MUSIC song (stations/podcasts never enter the self-advance list).
  Map<String, dynamic> _upNextItem(Song song) {
    final host =
        _usingCustomReceiver ? ApiService.wanHost : ApiService.lanHost;
    return {
      'contentId': _tokenizedUrl(
          '$host/api/stream/${song.id}?quality=$_lastQuality'),
      'contentType': _mimeForStream(song, _lastQuality, false),
      'metadata': {
        'type': 3,
        'metadataType': 3,
        'title': song.title,
        'songName': song.title,
        'artist': song.artistName,
        'albumName': song.albumTitle,
        'albumArtist': song.artistName,
        'trackNumber': song.trackNumber,
        'images': [
          {'url': _tokenizedUrl('$host/api/artwork/${song.albumId}')},
        ],
      },
      'customData': {
        'artistImageUrl':
            _tokenizedUrl('$host/api/artist-image/${song.artistId}'),
        'specialWaveform': _detectSpecialWaveform(song),
        'fileFormat': song.fileFormat,
        'isHdcd': song.isHdcd,
        'isExplicit': song.isExplicit,
        'songId': song.id,
      },
    };
  }

  /// Push the upcoming queue to the receiver's self-advance list.
  /// Sent with every song's deferred custom data — always fresh relative
  /// to the song that just loaded. An empty list is sent explicitly so
  /// a stale list from earlier can't resurrect removed queue items.
  /// Media-finished → the app advances its queue. Not while joined to a
  /// headless cast: the receiver self-advances through the UP_NEXT list
  /// its owner gave it, and a phone-side LOAD here would hijack it.
  void _fireMediaFinished() {
    if (_joinedExisting && _receiverHeadless) {
      AppLogger.instance.info(
          '📜 [Cast] Media finished on a joined headless cast — receiver advances itself');
      return;
    }
    onMediaFinished?.call();
  }

  void _maybeSendUpNext(Song justLoaded) {
    if (_session == null || !_isConnected || !_usingCustomReceiver) return;
    if (_joinedExisting && _receiverHeadless) return; // not our queue
    if (justLoaded.isStation) return; // live radio has no queue
    final upcoming = (upNextProvider?.call() ?? const [])
        .where((s) => !s.isStation && !s.isPodcast)
        .take(10)
        .map(_upNextItem)
        .toList();
    _session!.sendMessage(kNamespaceNasradio, {
      'type': 'UP_NEXT',
      'items': upcoming,
    });
    AppLogger.instance
        .info('📜 [Cast] Sent UP_NEXT (${upcoming.length} items)');
  }

  /// Re-push the self-advance list outside the normal post-LOAD flow —
  /// e.g. a party guest just added a track and the TV's stored list is
  /// stale, or the queue got reordered mid-song.
  void refreshUpNext() {
    if (_session == null || !_isConnected || !_usingCustomReceiver) return;
    if (_joinedExisting && _receiverHeadless) return; // not our queue
    final upcoming = (upNextProvider?.call() ?? const [])
        .where((s) => !s.isStation && !s.isPodcast)
        .take(10)
        .map(_upNextItem)
        .toList();
    _session!.sendMessage(kNamespaceNasradio, {
      'type': 'UP_NEXT',
      'items': upcoming,
    });
    AppLogger.instance
        .info('📜 [Cast] Refreshed UP_NEXT (${upcoming.length} items)');
  }

  /// Show/hide the party QR overlay on the TV.
  void sendPartyMode({required bool active, String? qrUrl, String? code}) {
    if (_session == null || !_isConnected || !_usingCustomReceiver) return;
    _session!.sendMessage(kNamespaceNasradio, {
      'type': 'PARTY_MODE',
      'active': active,
      if (qrUrl != null) 'qrUrl': qrUrl,
      if (code != null) 'code': code,
    });
    AppLogger.instance.info('🎉 [Cast] PARTY_MODE active=$active code=$code');
  }

  /// Send badge info (file format + HDCD status) to the custom receiver
  void _sendBadgeInfo(Song song) {
    if (_session == null || !_isConnected || !_usingCustomReceiver) return;
    _session!.sendMessage(kNamespaceNasradio, {
      'type': 'BADGES',
      'format': song.fileFormat,
      'isHdcd': song.isHdcd,
      'isExplicit': song.isExplicit,
    });
    print('🏷️ [Cast] Sent badges: ${song.fileFormat}${song.isHdcd ? " +HDCD" : ""}${song.isExplicit ? " +E" : ""}');
  }

  /// Fetch waveform and lyrics from the API and send to the custom receiver.
  /// Runs async so it doesn't block media loading.
  ///
  /// Any previous in-flight fetch is cancelled before starting — this
  /// aborts the backend HTTP calls so pooled DB connections aren't held
  /// waiting on LRCLIB while the user skips to the next track.
  Future<void> _sendWaveformAndLyrics(int songId) async {
    _mediaDataClient?.close();
    // Auth-injecting per-fetch client (seeded with the current token) so the
    // waveform + lyrics calls are authenticated yet still independently
    // closeable for cancellation. A bare http.Client() gets 401'd.
    final client = AuthHttpClient()..setToken(appHttpClient.token);
    _mediaDataClient = client;

    bool stillCurrent() => identical(_mediaDataClient, client);

    final overallStart = DateTime.now();
    AppLogger.instance.info('📊 [Cast] _sendWaveformAndLyrics START song=$songId');

    try {
      final wfStart = DateTime.now();
      final wf = await ApiService().getWaveformStatus(songId, client: client);
      final wfMs = DateTime.now().difference(wfStart).inMilliseconds;
      if (!stillCurrent()) {
        AppLogger.instance.info('📊 [Cast] Waveform song=$songId aborted (superseded) after ${wfMs}ms');
        return;
      }
      if (wf.waveform.isNotEmpty && _session != null && _isConnected) {
        _session!.sendMessage(kNamespaceNasradio, {
          'type': 'WAVEFORM',
          'data': wf.waveform,
        });
        AppLogger.instance.info(
          '🎨 [Cast] Sent ${wf.waveform.length} waveform samples to receiver '
          '(fetch=${wfMs}ms, song=$songId, status=${wf.status})',
        );
        if (wf.status == 'generating') {
          // Placeholder went out — keep polling and replace it with the
          // real waveform once the backend finishes decoding.
          _waveformRetryCount = 0;
          _scheduleWaveformRetry(songId);
        }
      } else {
        AppLogger.instance.warning(
          '🎨 [Cast] Waveform empty or session gone — empty=${wf.waveform.isEmpty} '
          'session=${_session != null} connected=$_isConnected (fetch=${wfMs}ms)',
        );
      }
    } catch (e) {
      if (!stillCurrent()) return;
      AppLogger.instance.warning('⚠️ [Cast] Waveform fetch failed for song=$songId: $e');
    }

    if (!stillCurrent()) return;

    try {
      final lyStart = DateTime.now();
      final lyricsData = await ApiService().getLyrics(songId, client: client);
      final lyMs = DateTime.now().difference(lyStart).inMilliseconds;
      if (!stillCurrent()) {
        AppLogger.instance.info('📊 [Cast] Lyrics song=$songId aborted (superseded) after ${lyMs}ms');
        return;
      }
      if (_session != null && _isConnected) {
        final synced = (lyricsData['synced_lyrics'] as String?) ?? '';
        final plain = (lyricsData['plain_lyrics'] as String?) ?? '';
        _session!.sendMessage(kNamespaceNasradio, {
          'type': 'LYRICS',
          'synced': lyricsData['synced_lyrics'],
          'plain': lyricsData['plain_lyrics'],
        });
        AppLogger.instance.info(
          '🎤 [Cast] Sent lyrics to receiver (fetch=${lyMs}ms, '
          'syncedChars=${synced.length}, plainChars=${plain.length}, song=$songId)',
        );
      }
    } catch (e) {
      if (!stillCurrent()) return;
      AppLogger.instance.warning('⚠️ [Cast] Lyrics fetch failed for song=$songId: $e');
    }

    final totalMs = DateTime.now().difference(overallStart).inMilliseconds;
    AppLogger.instance.info('📊 [Cast] _sendWaveformAndLyrics END song=$songId total=${totalMs}ms');

    if (stillCurrent()) {
      client.close();
      _mediaDataClient = null;
    }
  }

  /// Re-poll a 'generating' waveform and push the real one when ready.
  /// Cancelled by song change (id mismatch), disconnect, or giving up
  /// after [_maxWaveformRetries] × 5s (~2 min — plenty for one decode).
  void _scheduleWaveformRetry(int songId) {
    _waveformRetryTimer?.cancel();
    if (_waveformRetryCount >= _maxWaveformRetries) {
      AppLogger.instance.warning(
        '🎨 [Cast] Waveform still generating after '
        '$_maxWaveformRetries polls — giving up (song=$songId)',
      );
      return;
    }
    _waveformRetryCount++;
    _waveformRetryTimer = Timer(const Duration(seconds: 5), () async {
      if (!_isConnected || songId != _lastLoadedSongId) return;
      try {
        final wf = await ApiService().getWaveformStatus(songId);
        if (!_isConnected || songId != _lastLoadedSongId) return;
        if (wf.status == 'ready' && wf.waveform.isNotEmpty) {
          _session?.sendMessage(kNamespaceNasradio, {
            'type': 'WAVEFORM',
            'data': wf.waveform,
          });
          AppLogger.instance.info(
            '🎨 [Cast] Generated waveform ready — pushed to receiver '
            '(song=$songId, poll $_waveformRetryCount)',
          );
        } else if (wf.status == 'generating') {
          _scheduleWaveformRetry(songId);
        }
        // status=='error' → stop; the flat placeholder is the best we get.
      } catch (_) {
        _scheduleWaveformRetry(songId); // transient fetch error — keep going
      }
    });
  }

  /// Play (resume) current media
  void play() {
    if (_session == null || _mediaSessionId == null) return;
    _session!.sendMessage(CastSession.kNamespaceMedia, {
      'type': 'PLAY',
      'mediaSessionId': _mediaSessionId,
    });
  }

  /// Pause current media
  void pause() {
    if (_session == null || _mediaSessionId == null) return;
    _session!.sendMessage(CastSession.kNamespaceMedia, {
      'type': 'PAUSE',
      'mediaSessionId': _mediaSessionId,
    });
  }

  /// Seek to position
  void seekTo(Duration position) {
    if (_session == null || _mediaSessionId == null) return;
    _session!.sendMessage(CastSession.kNamespaceMedia, {
      'type': 'SEEK',
      'mediaSessionId': _mediaSessionId,
      'currentTime': position.inMilliseconds / 1000.0,
    });
    _position = position;
    notifyListeners();
  }

  /// Set volume (0.0 to 1.0). When the receiver reports controlType='fixed'
  /// (typical for Chromecast → TV → AVR/eARC chains where the AVR is the
  /// master volume controller), SET_VOLUME messages are silently ignored
  /// by the receiver — so we skip the send entirely rather than lying to
  /// our own UI with optimistic updates that don't reflect physical reality.
  void setCastVolume(double volume) {
    if (_session == null) return;
    if (_castVolumeControlType == 'fixed') {
      // No log line per call site — this can fire repeatedly per volume
      // keypress, and the controlType=fixed line printed once at connect
      // already explains why nothing happens.
      return;
    }
    final clamped = volume.clamp(0.0, 1.0);
    AppLogger.instance.info('🔊 [Cast] SET_VOLUME → level=${clamped.toStringAsFixed(3)} (controlType=${_castVolumeControlType ?? "unknown"})');
    _session!.sendMessage(CastSession.kNamespaceReceiver, {
      'type': 'SET_VOLUME',
      'volume': {
        'level': clamped,
      },
    });
  }

  Future<void> _handleRemoteQueueInsert(Map<String, dynamic> message) async {
    final requestId = message['requestId'];
    final items = (message['items'] as List?) ?? const [];
    final ids = <int>[];
    for (final it in items) {
      final c = (it is Map) ? it['customData'] : null;
      if (c is Map && c['songId'] is num) ids.add((c['songId'] as num).toInt());
    }
    final playNext = message['mode'] == 'next';
    final by = (message['by'] as String?) ?? 'someone';
    int? queueLength;
    String? error;
    if (_joinedExisting && _receiverHeadless) {
      error = 'this phone is only following the cast, not driving it';
    } else if (ids.isEmpty) {
      error = 'no song ids in the request';
    } else if (onRemoteQueueInsert == null) {
      error = 'app has no queue handler';
    } else {
      try {
        queueLength = await onRemoteQueueInsert!(ids, playNext, by);
        if (queueLength == null) error = 'queue insert refused';
      } catch (e) {
        error = 'queue insert failed: $e';
      }
    }
    AppLogger.instance.info(
      '📥 [Cast] Remote queue insert by $by: ${ids.length} track(s) '
      '${playNext ? "next" : "end"} -> ${error ?? "ok (queue $queueLength)"}',
    );
    if (_session == null || !_isConnected) return;
    _session!.sendMessage(kNamespaceNasradio, {
      'type': 'QUEUE_INSERT_RESULT',
      'requestId': requestId,
      'ok': error == null,
      if (error != null) 'error': error,
      'handledBy': 'phone',
      if (queueLength != null) 'queueLength': queueLength,
    });
  }

  Future<void> _handleRemoteSkip(Map<String, dynamic> message) async {
    final requestId = message['requestId'];
    final direction = (message['direction'] as String?) ?? 'next';
    bool ok = false;
    String? error;
    if (_joinedExisting && _receiverHeadless) {
      error = 'this phone is only following the cast, not driving it';
    } else if (onRemoteSkip == null) {
      error = 'app has no skip handler';
    } else {
      try {
        ok = await onRemoteSkip!(direction);
        if (!ok) error = 'skip refused';
      } catch (e) {
        error = 'skip failed: $e';
      }
    }
    AppLogger.instance.info('⏭️ [Cast] Remote skip $direction -> ${error ?? "ok"}');
    if (_session == null || !_isConnected) return;
    _session!.sendMessage(kNamespaceNasradio, {
      'type': 'SKIP_RESULT',
      'requestId': requestId,
      'ok': ok,
      if (error != null) 'error': error,
    });
  }

  /// Handle incoming messages from the Chromecast
  void _handleCastMessage(Map<String, dynamic> message) {
    final type = message['type'];

    if (type == 'MEDIA_STATUS') {
      final statuses = message['status'] as List?;
      if (statuses != null && statuses.isNotEmpty) {
        final status = statuses[0] as Map<String, dynamic>;
        _mediaSessionId = status['mediaSessionId'] as int?;

        final newState = status['playerState'] as String? ?? 'IDLE';
        final oldState = _playerState;
        _playerState = newState;

        // Update position and duration from status
        final currentTime = status['currentTime'];
        if (currentTime != null) {
          _position = Duration(milliseconds: ((currentTime as num) * 1000).round());
        }

        final media = status['media'] as Map<String, dynamic>?;
        if (media != null) {
          final dur = media['duration'];
          if (dur != null) {
            _duration = Duration(milliseconds: ((dur as num) * 1000).round());
          }
          // Which song does the RECEIVER think it's playing? Rides in the
          // LOAD's customData (both sender LOADs and self-advance items
          // carry songId). Used to re-sync the app after rejoin/reconnect
          // when the receiver self-advanced through UP_NEXT without us.
          final mCustom = media['customData'];
          if (mCustom is Map && mCustom['songId'] is num) {
            final sid = (mCustom['songId'] as num).toInt();
            final changed = sid != _receiverSongId;
            _receiverSongId = sid;
            _receiverHeadless = mCustom['headlessSender'] == true;
            if (changed) onReceiverSongChanged?.call(sid);
          }
        }

        // Update playing state
        _isPlaying = newState == 'PLAYING';

        // Detect when media finishes — handle all idle reasons, not just FINISHED.
        // Chromecast can go PLAYING → BUFFERING → IDLE, so also check for
        // IDLE after BUFFERING. Without this, playback gets stuck after 1-2 songs
        // if an error or interruption occurs.
        //
        // INTERRUPTED is special: it means another sender or the OS preempted
        // playback (e.g. another phone took over the cast session, or the
        // receiver lost audio focus). We do NOT auto-advance the queue here —
        // the user didn't intend to skip — but we try a single PLAY to resume
        // if the media session is still alive. If the receiver session is
        // gone, the PLAY is a harmless no-op.
        if (newState == 'IDLE' && (oldState == 'PLAYING' || oldState == 'BUFFERING')) {
          final idleReason = status['idleReason'] as String?;
          print('🎵 [Cast] Media idle — reason: $idleReason (was $oldState)');
          if (idleReason == 'FINISHED' || idleReason == 'ERROR' || idleReason == 'CANCELLED') {
            if (idleReason == 'ERROR') {
              AppLogger.instance.warning('⚠️ [Cast] Media ended with error — advancing anyway');
            }
            _fireMediaFinished();
          } else if (idleReason == 'INTERRUPTED') {
            AppLogger.instance.info('↩️ [Cast] Attempting to resume after INTERRUPTED');
            play();
          }
        }

        // Track when playback starts for timeout detection
        if (newState == 'PLAYING' && oldState != 'PLAYING') {
          _lastPlayStartTime = DateTime.now();
        }

        // Send deferred waveform/lyrics/badges once receiver confirms media loaded.
        // This ensures the LOAD has been processed before we send custom data.
        // Check for any transition INTO PLAYING/BUFFERING (not just from IDLE,
        // since subsequent songs may go PLAYING→BUFFERING→PLAYING without IDLE).
        if (_pendingCustomDataSong != null &&
            (newState == 'PLAYING' || newState == 'BUFFERING')) {
          final song = _pendingCustomDataSong!;
          _pendingCustomDataSong = null;
          _sendBadgeInfo(song);
          _sendWaveformAndLyrics(song.id);
          _maybeSendUpNext(song);
        }

        notifyListeners();
      }
    } else if (type == 'QUEUE_INSERT') {
      _handleRemoteQueueInsert(message);
    } else if (type == 'SKIP') {
      _handleRemoteSkip(message);
    } else if (type == 'DIAG_RECEIVER_SHUTDOWN') {
      // Receiver fired CAF SHUTDOWN or beforeunload — almost always
      // means the user killed the cast app from the TV remote (Home /
      // Back / picked a different cast app). Stamp the time so the
      // imminent state.closed event in _handleDisconnect treats this
      // disconnect as intentional and skips auto-reconnect.
      AppLogger.instance.info(
        '🛑 [Cast] Receiver SHUTDOWN signal: reason=${message['reason']}',
      );
      _receiverShutdownAt = DateTime.now();
    } else if (type == 'DIAG_HEARTBEAT') {
      // Receiver-side state snapshot pushed every ~5s. We stash the
      // latest so the drop-incident report can include "what was the
      // receiver doing at the last tick before the drop?" No log line
      // per heartbeat — too noisy. The data shows up in the
      // _handleDisconnect dump.
      _lastReceiverHeartbeatAt = DateTime.now();
      final tick = message['tick'];
      if (tick is num) _lastReceiverTick = tick.toInt();
      final st = message['playerState'];
      if (st is String) _lastReceiverState = st;
      final ct = message['currentTime'];
      if (ct is num) _lastReceiverCurrentTime = ct.toDouble();
      final bms = message['bufferingMs'];
      _lastReceiverBufferingMs = bms is num ? bms.toInt() : null;
      final tuams = message['timeUpdateAgoMs'];
      if (tuams is num) _lastReceiverTimeUpdateAgoMs = tuams.toInt();
      final counters = message['counters'];
      if (counters is Map) {
        _lastReceiverDiagCounters = Map<String, dynamic>.from(counters);
      }
    } else if (type == 'DIAG_STUCK_BUFFERING') {
      // Receiver reports it's been stuck in BUFFERING for N seconds.
      // Means the cast device's audio HTTP fetch is hung — either the
      // backend is unresponsive, the network blipped during media
      // load, or something else interrupted the audio element. CAF
      // SDK doesn't auto-retry, so we log this as a warning. Recovery
      // (re-LOAD with current position) is a follow-up; first iteration
      // is just data-gathering.
      final seconds = message['seconds'];
      AppLogger.instance.warning(
        '🛟 [Cast] Receiver stuck in BUFFERING for ${seconds}s',
      );
      if (seconds is num) {
        final s = seconds.toInt();
        if (_stuckBufferingMaxSec == null || s > _stuckBufferingMaxSec!) {
          _stuckBufferingMaxSec = s;
        }
      }
    } else if (type == 'DIAG_SENDER_DISCONNECTED') {
      _senderDisconnectedSeen = true;
      // Cast device fired SENDER_DISCONNECTED on the receiver — if
      // this lands just before a `🔌 Socket stream onDone`, the
      // disconnect was an SDK-level event (cast device initiated
      // tear-down via the standard path). If we see a Socket onDone
      // with NO preceding SENDER_DISCONNECTED, the cast device killed
      // the underlying TCP socket without firing the SDK event —
      // ungraceful tear-down, probably resource/system event.
      AppLogger.instance.warning(
        '👋 [Cast] Receiver SENDER_DISCONNECTED: '
        'senderId=${message['senderId']} reason=${message['reason']}',
      );
    } else if (type == 'WAVEFORM_REQUEST') {
      // Receiver noticed it has no waveform for the current track and
      // is asking us to re-send. Happens when the deferred-send timer
      // and the PLAYING/BUFFERING state-transition send both miss
      // (race conditions on subsequent track loads), or when the
      // receiver booted into an active cast session (sender restart)
      // and has no cached waveform.
      final reqSongId = message['songId'];
      AppLogger.instance.info(
        '🎨 [Cast] Receiver requested waveform refresh for song=$reqSongId',
      );
      if (reqSongId is int) {
        _sendWaveformAndLyrics(reqSongId);
      } else if (reqSongId is num) {
        _sendWaveformAndLyrics(reqSongId.toInt());
      }
    } else if (type == 'DIAG_PLAYER_STATE') {
      // Player state transition observed on the receiver. Lets us
      // correlate cast drops with playback state changes — e.g. if
      // state goes IDLE just before a drop, the song likely finished
      // and the receiver was torn down for being idle.
      AppLogger.instance.info(
        '🎵 [Cast] Receiver player state → ${message['state']}',
      );
    } else if (type == 'DIAG_BOOT') {
      // Receiver loaded and fired its SENDER_CONNECTED event — definitive
      // proof of which receiver.js version is actually running on the
      // cast device. If you don't see this line in combined.log when
      // you start a cast session, the device is serving a cached
      // older receiver and the cache buster needs harder treatment.
      AppLogger.instance.info(
        '🚀 [Cast] Receiver booted: ${message['version']}',
      );
    } else if (type == 'DIAG_MSG') {
      // Cast protocol message that hit the receiver's playerManager —
      // PLAY / PAUSE / STOP / SEEK. The webOS remote routes its media
      // keys to the receiver through this path (NOT as raw keydown
      // events, hence the empty DIAG_KEY relay). If we see PLAY /
      // PAUSE arrive here when the user presses their LG remote's
      // play/pause key, we know the message reaches us but something
      // downstream (audio focus, custom receiver behaviour) is
      // swallowing the pause. If we see SEEK arrive on skip presses
      // but never PLAY/PAUSE, webOS is filtering certain message
      // types before forwarding.
      AppLogger.instance.info(
        '🎮 [Cast] Receiver msg: ${message['msgType']} '
        'currentTime=${message['currentTime']} '
        'sender=${message['senderId']}',
      );
    } else if (type == 'DIAG_KEY') {
      // Receiver-side keydown relayed from the cast device so we can see
      // in combined.log which remote keys reach the receiver at all.
      // If the user reports "I pressed PLAY/PAUSE on my LG remote and
      // nothing happened" and we DON'T see a matching DIAG_KEY line,
      // webOS intercepted the key before our keydown listener fired —
      // not fixable from receiver-side code. If we DO see the line, the
      // key reached us and the issue is in our handling logic.
      AppLogger.instance.info(
        '🎮 [Cast] Receiver keydown: key="${message['key']}" '
        'code="${message['code']}" keyCode=${message['keyCode']}',
      );
    } else if (type == 'RECEIVER_STATUS') {
      // Receiver-level state — we currently care about volume so Android's
      // MediaSession can mirror the TV's level onto the lock-screen slider.
      final status = message['status'] as Map<String, dynamic>?;
      final volume = status?['volume'] as Map<String, dynamic>?;
      if (volume != null) {
        final level = volume['level'];
        final muted = volume['muted'];
        final controlType = volume['controlType'];
        final stepInterval = volume['stepInterval'];
        bool changed = false;
        if (level is num) {
          final newVol = level.toDouble().clamp(0.0, 1.0);
          if ((newVol - _castVolume).abs() > 0.001) {
            _castVolume = newVol;
            changed = true;
          }
        }
        if (muted is bool && muted != _castMuted) {
          _castMuted = muted;
          changed = true;
        }
        // Diagnostic: log controlType / stepInterval whenever they change.
        // Most useful right after a volume key press — if the receiver
        // reports controlType='fixed', SET_VOLUME is silently ignored
        // and there's nothing app-side that can change that (typical
        // for Chromecast → TV → eARC AVR chains where the AVR is the
        // master volume controller).
        if (controlType is String && controlType != _castVolumeControlType) {
          _castVolumeControlType = controlType;
          AppLogger.instance.info('🔊 [Cast] Receiver volume controlType=$controlType, stepInterval=$stepInterval');
          // controlType changes mean the audio handler needs to republish
          // AndroidPlaybackInfo with the matching volume-control type
          // (fixed vs absolute) — flag this as a change so notifyListeners
          // fires below.
          changed = true;
        }
        if (stepInterval is num && stepInterval != _castVolumeStepInterval) {
          _castVolumeStepInterval = stepInterval;
        }
        if (changed) {
          AppLogger.instance.info('🔊 [Cast] RECEIVER_STATUS volume: level=${_castVolume.toStringAsFixed(3)} muted=$_castMuted controlType=$_castVolumeControlType');
          notifyListeners();
        }
      }
    }
  }

  /// Bump the receiver volume by [delta] (e.g. ±0.05). Used by the lock-screen
  /// volume keys via RemoteAndroidPlaybackInfo's onAdjustVolume callback.
  ///
  /// No-op when the receiver reports controlType='fixed' — see setCastVolume.
  /// In practice Android's MediaSession won't even invoke our volume callbacks
  /// once we publish RemoteAndroidPlaybackInfo with volumeControlType=fixed,
  /// but defense-in-depth.
  void adjustCastVolume(double delta) {
    if (_session == null || !_isConnected) return;
    if (_castVolumeControlType == 'fixed') return;
    final next = (_castVolume + delta).clamp(0.0, 1.0);
    setCastVolume(next);
    // Optimistic local update so the slider doesn't lag a round-trip behind.
    if ((next - _castVolume).abs() > 0.001) {
      _castVolume = next;
      notifyListeners();
    }
  }

  /// Poll for position updates (Chromecast only pushes status on state changes)
  void _startPositionPolling() {
    _stopPositionPolling();
    _stuckCount = 0;
    _positionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_isConnected && _isPlaying) {
        // Increment position locally for smooth UI updates
        _position += const Duration(seconds: 1);
        if (_duration.inSeconds > 0 && _position > _duration) {
          _position = _duration;
        }
        notifyListeners();

        // Also request actual status from Chromecast periodically
        _requestMediaStatus();
      }

      // End-of-track safety: if our local position has passed the duration
      // and Chromecast never sent IDLE/FINISHED, force-advance after a grace period.
      // This handles missed status messages or silent Chromecast stalls.
      if (_isConnected && _duration.inSeconds > 0 && _position >= _duration) {
        _stuckCount++;
        if (_stuckCount >= 5) {
          AppLogger.instance.warning('⚠️ [Cast] Position past duration for ${_stuckCount}s — forcing advance');
          _stuckCount = 0;
          _isPlaying = false;
          _fireMediaFinished();
        }
      } else {
        _stuckCount = 0;
      }
    });
  }

  void _stopPositionPolling() {
    _positionTimer?.cancel();
    _positionTimer = null;
  }

  /// Request current media status from Chromecast
  void _requestMediaStatus() {
    if (_session == null || _mediaSessionId == null) return;
    _session!.sendMessage(CastSession.kNamespaceMedia, {
      'type': 'GET_STATUS',
      'mediaSessionId': _mediaSessionId,
    });
  }

  @override
  void dispose() {
    _stopPositionPolling();
    _cancelPendingReconnect();
    _waveformRetryTimer?.cancel();
    _messageSubscription?.cancel();
    _stateSubscription?.cancel();
    _session?.close();
    super.dispose();
  }
}
