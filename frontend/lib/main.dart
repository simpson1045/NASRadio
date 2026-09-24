import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:media_kit/media_kit.dart';
import 'dart:async' show runZonedGuarded;
import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;
import 'package:smtc_windows/smtc_windows.dart';
import 'package:audio_service/audio_service.dart';
import 'package:windows_taskbar/windows_taskbar.dart';
import 'package:window_manager/window_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/api_service.dart';
import 'layout_context.dart';
import 'services/audio_player_service.dart';
import 'services/audio_handler.dart';
import 'services/cast_service.dart';
import 'models/song.dart';
import 'services/device_sync_service.dart';
import 'services/weather_service.dart';
import 'services/app_logger.dart';
import 'screens/main_navigation_screen.dart';
import 'widgets/app_back_navigator.dart';
import 'screens/tv/tv_main_navigation_screen.dart';
import 'screens/login_screen.dart';
import 'screens/connect_server_screen.dart';
import 'screens/setup_admin_screen.dart';
import 'screens/setup_wizard_screen.dart';
import 'services/admin_settings_service.dart';
import 'services/auth_service.dart';

/// Heuristic: Android device with a TV-class screen. Empirically Fire
/// TV / Android TV report widely varying logical-pixel sizes — older
/// sticks at density 1.0 give 1920×1080 dp, newer 4K sticks at density
/// 2.0 give 960×540 dp, and some report even smaller. The shortest
/// side, however, is always ≥540 dp and no phone has a `shortestSide`
/// above ~411 dp, so a single `shortestSide >= 540` check catches every
/// TV-class device without flipping any practical phone. (Tablets land
/// in the same bucket as TVs, but simpson1045 doesn't run NASRadio on tablets.
/// Worth revisiting if anyone ever does.) Cached once by `_RootRouter`.
bool isFireTvLike(BuildContext context) {
  if (!Platform.isAndroid) return false;
  return MediaQuery.of(context).size.shortestSide >= 540;
}

late AudioPlayerService globalAudioPlayerService;
late CastService globalCastService;
late DeviceSyncService globalDeviceSyncService;
late WeatherService globalWeatherService;
AudioHandler? globalAudioHandler;

void main() async {
  // Install crash handlers BEFORE anything else so an exception during
  // service init still leaves a forensic trail. Three sources of
  // uncaught errors in Flutter:
  //
  //   1. Framework errors during build/layout/paint → FlutterError.onError
  //   2. Top-level async errors that escape the framework's zone →
  //      PlatformDispatcher.instance.onError
  //   3. Synchronous errors in main() / async errors inside the zone
  //      we explicitly wrap → runZonedGuarded handler
  //
  // All three funnel into AppLogger.recordCrash, which writes to a
  // flush:true file (nasradio_crash.log). On the NEXT successful
  // boot, AppLogger.init() reads that file and ships its contents to
  // the backend at error-level (which forces immediate ship). Net
  // result: even "black screen → bounced to home" early-init crashes
  // leave a breadcrumb in combined.log instead of vanishing without
  // a trace.
  FlutterError.onError = (FlutterErrorDetails details) {
    // Still let the framework print its usual report to console.
    FlutterError.presentError(details);
    // Don't await — onError shouldn't block the engine's error
    // pipeline. The recordCrash write itself flushes synchronously.
    AppLogger.instance.recordCrash(
      details.exception,
      details.stack ?? StackTrace.current,
      where: 'FlutterError',
    );
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    AppLogger.instance.recordCrash(error, stack, where: 'PlatformDispatcher');
    // Return true to indicate we handled it; otherwise Flutter would
    // also print a fatal log and (on some platforms) terminate the
    // engine. We'd rather keep the app alive on a stray async throw.
    return true;
  };

  // Everything else runs inside a guarded zone so synchronous /
  // zone-local async errors that the above two handlers don't see
  // are also caught. Note: this REPLACES `await` semantics at the
  // top level — keep `await`s inside the body so init order is
  // preserved.
  runZonedGuarded<Future<void>>(() async {
    await _mainGuarded();
  }, (error, stack) {
    AppLogger.instance.recordCrash(error, stack, where: 'runZonedGuarded');
  });
}

Future<void> _mainGuarded() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize persistent frontend logger
  await AppLogger.instance.init();

  // Cold-start marker. Logged once per process launch — so when
  // diagnosing "cast dropped at time X" and combined.log shows
  // 🚀 [App] Cold start between two cast sessions, we know the
  // OS killed our process (OOM, force-stop, system reclaim) and
  // the cast socket died with it. If only ONE 🚀 line spans the
  // drop, the process stayed alive and the disconnect came from
  // somewhere else (network, receiver-side, etc.). Includes
  // wall-clock ms-since-epoch as a session UUID surrogate — pairs
  // up cleanly with subsequent logs from the same run.
  final coldStartMs = DateTime.now().millisecondsSinceEpoch;
  AppLogger.instance.info(
    '🚀 [App] Cold start session=$coldStartMs platform=${Platform.operatingSystem}',
  );

  // Only initialize MediaKit on desktop (not needed for Android/iOS with just_audio)
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    MediaKit.ensureInitialized();
  }

  // Initialize window manager for desktop platforms
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();

    // Load saved window settings
    final prefs = await SharedPreferences.getInstance();
    final width = prefs.getDouble('window_width') ?? 1280;
    final height = prefs.getDouble('window_height') ?? 800;
    final x = prefs.getDouble('window_x');
    final y = prefs.getDouble('window_y');
    final isMaximized = prefs.getBool('window_maximized') ?? false;

    WindowOptions windowOptions = WindowOptions(
      size: Size(width, height),
      minimumSize: const Size(800, 600),
      center: x == null || y == null,
      backgroundColor: Colors.transparent,
      titleBarStyle: TitleBarStyle.normal,
      title: 'NASRadio',
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      // Set position if saved
      if (x != null && y != null) {
        await windowManager.setPosition(Offset(x, y));
      }

      // Restore maximized state
      if (isMaximized) {
        await windowManager.maximize();
      }

      await windowManager.show();
      await windowManager.focus();
    });
  }

  // Apply any user-configured server addresses, then detect the network
  // before anything else makes a request.
  await ApiService.loadServerConfig();
  await ApiService.detectNetwork();

  // Create the audio player service first
  globalAudioPlayerService = AudioPlayerService();

  // Create cast service and wire it up (mobile only)
  globalCastService = CastService();
  globalAudioPlayerService.castService = globalCastService;

  // When Chromecast finishes a song, advance the queue.
  // Intentionally global — this callback lives for the app's lifetime
  // and does not need cleanup since both services are app-scoped singletons.
  globalCastService.onMediaFinished = () {
    globalAudioPlayerService.next();
  };

  // Auto-reconnect plumbing. When the cast device unexpectedly kills
  // the session (LG webOS app killer, network blip, etc.),
  // CastService re-establishes the session on the same device, then
  // fires this callback. We respond by triggering startCasting() which
  // re-LOADs the current song with the cached resume position
  // (preserved across the disconnect by the _onCastStateChanged gate).
  // Net effect: a momentary audio gap, then playback continues
  // automatically — user doesn't have to manually re-cast.
  globalCastService.onAutoReconnect = () {
    // With UP_NEXT the receiver may have kept the queue going by itself
    // during the outage. If it's mid-song, follow it; only re-LOAD (old
    // resume behavior) when the receiver is actually idle.
    final rxSong = globalCastService.receiverSongId;
    final state = globalCastService.playerState;
    if (rxSong != null && (state == 'PLAYING' || state == 'BUFFERING')) {
      globalAudioPlayerService.adoptCastSong(rxSong);
    } else {
      globalAudioPlayerService.startCasting();
    }
  };

  // Feed the receiver its self-advance list (next ~10 music tracks).
  globalCastService.upNextProvider =
      () => globalAudioPlayerService.upcomingCastQueue;

  // Guest queueing: Claude (through the backend) joins a cast this phone
  // started and asks, via the receiver, for tracks in THIS queue. Insert
  // them for real, refresh the TV's self-advance list, report the length.
  globalCastService.onRemoteQueueInsert = (ids, playNext, by) async {
    final api = ApiService();
    final songs = <Song>[];
    for (final id in ids) {
      try {
        songs.add(await api.getSongById(id));
      } catch (e) {
        AppLogger.instance.warning('📥 [Cast] guest queue: song $id lookup failed: $e');
      }
    }
    if (songs.isEmpty) return null;
    if (playNext) {
      globalAudioPlayerService.addMultipleToQueueNext(songs);
    } else {
      globalAudioPlayerService.addMultipleToQueue(songs);
    }
    globalCastService.refreshUpNext();
    return globalAudioPlayerService.queue.length;
  };

  // Same relay for next/previous asked by a guest.
  globalCastService.onRemoteSkip = (direction) async {
    if (direction == 'previous') {
      await globalAudioPlayerService.previous();
    } else {
      await globalAudioPlayerService.next();
    }
    return true;
  };

  // Stand-down check: with the reconnect window now ~30 min (it used to
  // give up in ~5), a late reconnect could land after simpson1045 has shrugged
  // and hit play on the phone speakers — snatching the audio back to the
  // TV. If local playback is actively running, abandon the reconnect.
  globalCastService.shouldAutoReconnect = () {
    final p = globalAudioPlayerService;
    return !(p.isPlaying && !p.isCasting);
  };

  // Swipe-away survival: the receiver keeps playing when the app is
  // swiped from recents (by design). If a cast session was live within
  // the last 12h, silently rejoin it so the app comes back as the
  // remote instead of starting a parallel local session. Cheap when
  // there's nothing to rejoin (no marker / TV off / receiver gone).
  // After rejoining, sync to whichever song the receiver self-advanced
  // to while we were away.
  globalCastService.tryResumeSession().then((resumed) async {
    if (!resumed) return;
    await Future.delayed(const Duration(seconds: 2));
    final sid = globalCastService.receiverSongId;
    if (sid != null) globalAudioPlayerService.adoptCastSong(sid);
  });

  // Create device sync service and wire it up
  globalDeviceSyncService = DeviceSyncService(globalAudioPlayerService);
  globalAudioPlayerService.syncService = globalDeviceSyncService;
  globalDeviceSyncService.connect();

  // Create weather service and initialize
  globalWeatherService = WeatherService();
  globalWeatherService.audioPlayerService = globalAudioPlayerService;
  globalWeatherService.initialize();

  runApp(const NASRadioApp());
}

class NASRadioApp extends StatefulWidget {
  const NASRadioApp({super.key});

  @override
  State<NASRadioApp> createState() => _NASRadioAppState();
}

class _NASRadioAppState extends State<NASRadioApp>
    with WidgetsBindingObserver, WindowListener {
  SMTCWindows? _smtc;
  bool _audioServiceInitialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupMediaKeys();

    // Add window listener for desktop
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      windowManager.addListener(this);
    }

    // Initialize audio service after first frame on Android
    if (Platform.isAndroid || Platform.isIOS) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _initAudioService();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Log every lifecycle transition. Diagnostic value: when cast drops
    // and the log shows the app went `paused` (screen off / app
    // backgrounded) just before the drop, Android Doze most likely
    // killed our TCP sockets. When the log shows the app stayed
    // `resumed` throughout, the drop was network- or receiver-side and
    // not driven by the OS putting us to sleep. Also lets us correlate
    // `inactive` (transient — incoming call, pull-down notification
    // tray) with cast hiccups.
    AppLogger.instance.info('📱 [App] Lifecycle → ${state.name}');
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      // App going to background — save state immediately so resume is accurate
      globalAudioPlayerService.savePlaybackState();
    } else if (state == AppLifecycleState.detached) {
      // App is being closed - stop playback
      globalAudioPlayerService.stop();
    }
  }

  Future<void> _initAudioService() async {
    if (_audioServiceInitialized) return;
    _audioServiceInitialized = true;

    try {
      final handler = NASRadioAudioHandler(globalAudioPlayerService);
      globalAudioHandler = await AudioService.init(
        builder: () => handler,
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.nasradio.audio',
          androidNotificationChannelName: 'NASRadio',
          androidNotificationOngoing: false,
          androidStopForegroundOnPause: true,
          androidShowNotificationBadge: true,
          androidNotificationIcon: 'mipmap/ic_launcher',
        ),
      );

      // Direct stream listener for reliable updates
      globalAudioPlayerService.playingStream.listen((_) {
        handler.updateMediaSessionPublic();
      });
    } catch (e, stack) {
      print('⚠️ Failed to initialize audio service: $e');
      print('⚠️ Stack trace: $stack');
    }
  }

  void _setupMediaKeys() {
    if (Platform.isWindows) {
      _smtc = SMTCWindows(
        config: const SMTCConfig(
          fastForwardEnabled: false,
          rewindEnabled: false,
          prevEnabled: true,
          nextEnabled: true,
          playEnabled: true,
          pauseEnabled: true,
          stopEnabled: true,
        ),
      );

      // Listen to button press events
      _smtc!.buttonPressStream.listen((event) {
        switch (event) {
          case PressedButton.play:
            globalAudioPlayerService.togglePlayPause();
            break;
          case PressedButton.pause:
            globalAudioPlayerService.togglePlayPause();
            break;
          case PressedButton.next:
            globalAudioPlayerService.next();
            break;
          case PressedButton.previous:
            globalAudioPlayerService.previous();
            break;
          case PressedButton.stop:
            globalAudioPlayerService.stop();
            break;
          default:
            break;
        }
      });

      _smtc!.setPlaybackStatus(PlaybackStatus.Stopped);

      // Listen to player state changes to update SMTC
      globalAudioPlayerService.addListener(_updateSmtcState);

      // Setup taskbar thumbnail buttons
      _setupTaskbarButtons();
    }
  }

  bool _taskbarShowingPlay = true; // Track current icon state to avoid redundant updates

  void _setupTaskbarButtons() async {
    // Delay to ensure window is fully registered with Windows taskbar
    await Future.delayed(const Duration(milliseconds: 500));
    _updateTaskbarButtons(isPlaying: false);
  }

  void _updateTaskbarButtons({required bool isPlaying}) async {
    // Skip if the state hasn't changed
    if (isPlaying == !_taskbarShowingPlay && !_taskbarShowingPlay) return;

    final playPauseIcon = isPlaying ? 'assets/icons/pause.ico' : 'assets/icons/play.ico';
    final playPauseLabel = isPlaying ? 'Pause' : 'Play';

    try {
      await WindowsTaskbar.setThumbnailToolbar([
        ThumbnailToolbarButton(
          ThumbnailToolbarAssetIcon('assets/icons/previous.ico'),
          'Previous',
          () => globalAudioPlayerService.previous(),
        ),
        ThumbnailToolbarButton(
          ThumbnailToolbarAssetIcon(playPauseIcon),
          playPauseLabel,
          () => globalAudioPlayerService.togglePlayPause(),
        ),
        ThumbnailToolbarButton(
          ThumbnailToolbarAssetIcon('assets/icons/next.ico'),
          'Next',
          () => globalAudioPlayerService.next(),
        ),
      ]);
      _taskbarShowingPlay = !isPlaying;
    } catch (e) {
      print('🖥️ Taskbar button error: $e');
    }
  }

  void _updateSmtcState() {
    if (_smtc == null) return;

    final song = globalAudioPlayerService.currentSong;
    if (song != null) {
      _smtc!.updateMetadata(
        MusicMetadata(
          title: globalAudioPlayerService.displayTitle,
          artist: globalAudioPlayerService.displayArtist,
          album: song.albumTitle,
        ),
      );
    }

    final isPlaying = globalAudioPlayerService.isPlaying;
    if (isPlaying) {
      _smtc!.setPlaybackStatus(PlaybackStatus.Playing);
    } else if (globalAudioPlayerService.currentSong != null) {
      _smtc!.setPlaybackStatus(PlaybackStatus.Paused);
    } else {
      _smtc!.setPlaybackStatus(PlaybackStatus.Stopped);
    }

    // Update taskbar thumbnail buttons to show play/pause
    _updateTaskbarButtons(isPlaying: isPlaying);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      windowManager.removeListener(this);
    }
    globalAudioPlayerService.removeListener(_updateSmtcState);
    _smtc?.dispose();
    globalDeviceSyncService.dispose();
    globalAudioPlayerService.dispose();
    super.dispose();
  }

  // Window listener methods for saving window state
  @override
  void onWindowResized() async {
    await _saveWindowState();
  }

  @override
  void onWindowMoved() async {
    await _saveWindowState();
  }

  @override
  void onWindowMaximize() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('window_maximized', true);
  }

  @override
  void onWindowUnmaximize() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('window_maximized', false);
    await _saveWindowState();
  }

  @override
  void onWindowFocus() {}
  @override
  void onWindowBlur() {}
  @override
  void onWindowMinimize() {}
  @override
  void onWindowRestore() {}
  @override
  void onWindowEnterFullScreen() {}
  @override
  void onWindowLeaveFullScreen() {}
  @override
  void onWindowEvent(String eventName) {}

  Future<void> _saveWindowState() async {
    final isMaximized = await windowManager.isMaximized();
    if (isMaximized) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final size = await windowManager.getSize();
    final position = await windowManager.getPosition();

    await prefs.setDouble('window_width', size.width);
    await prefs.setDouble('window_height', size.height);
    await prefs.setDouble('window_x', position.dx);
    await prefs.setDouble('window_y', position.dy);
  }

  @override
  Widget build(BuildContext context) {
    return AppBackNavigator(
      child: MaterialApp(
      navigatorKey: NavBackController.navigatorKey,
      title: 'NASRadio',
      debugShowCheckedModeBanner: false,
      // Fire TV / Android TV remote's d-pad center sends KEYCODE_DPAD_CENTER
      // which Flutter maps to LogicalKeyboardKey.select. Flutter's default
      // ActivateIntent shortcut map binds Enter, Space, and gameButtonA but
      // NOT select (Flutter Issue #43719, still open). Without this binding,
      // pressing OK on the Fire TV remote on a focused button does nothing.
      // We OR in WidgetsApp.defaultShortcuts so we don't lose the regular
      // bindings.
      shortcuts: <ShortcutActivator, Intent>{
        ...WidgetsApp.defaultShortcuts,
        const SingleActivator(LogicalKeyboardKey.select): const ActivateIntent(),
      },
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0a0e27),
        primaryColor: const Color(0xFF00d4ff),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00d4ff),
          secondary: Color(0xFF0099ff),
          surface: Color(0xFF1a1f3a),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0d1b2a),
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF282828),
          elevation: 4,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      // THE desktop/mobile layout verdict (DESKTOP_UX_SPEC.md §3) is
      // made HERE, wrapping the Navigator itself — so pushed routes
      // (Now Playing, Import Album, every detail screen) inherit
      // LayoutScope. It originally lived inside the shell, where
      // pushed routes couldn't see it and silently fell back to the
      // phone layout.
      builder: (context, child) => LayoutBuilder(
        builder: (context, constraints) => LayoutScope(
          layout: constraints.maxWidth >= LayoutScope.desktopBreakpoint
              ? AppLayout.desktop
              : AppLayout.mobile,
          child: child!,
        ),
      ),
      home: _AuthGate(audioPlayerService: globalAudioPlayerService),
      // No global TV font-scaling builder anymore. v1.0.27 added a
      // 1.25× MediaQuery textScaler for Android-on-TV-class-screens
      // because the PHONE-LAYOUT-ON-TV had text too small to read at
      // 10 ft. With the new dedicated TV screens (`screens/tv/...`)
      // sizing their text explicitly for TV viewing distance, the
      // 1.25× was double-counting — and on a 540dp Firestick it was
      // overflowing the dashboard so badly that the section headers
      // scrolled off the top no matter what. Removing the scaler lets
      // the new TV layouts render at their designed sizes; phone is
      // unaffected (phone never had the bump in the first place).
      ),
    );
  }
}

/// Gates the entire app behind server setup + authentication:
///
///   no server configured      → ConnectServerScreen
///   server has no users yet   → SetupAdminScreen (first run)
///   signed out                → LoginScreen
///   admin, setup not finished → SetupWizardScreen (once per server)
///   signed in                 → the app
///
/// Listens to AuthService (login/logout, expired token via the 401 handler)
/// and to ApiService.serverConfigChanged (address saved/cleared) so every
/// transition happens without manual navigation.
class _AuthGate extends StatefulWidget {
  final AudioPlayerService audioPlayerService;
  const _AuthGate({required this.audioPlayerService});

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  // The setup-status probe is keyed on the server config version so a new
  // address gets a fresh answer, while address-less rebuilds reuse the last.
  Future<bool?>? _needsSetup;
  int _needsSetupFor = -1;
  // Wizard check: once per signed-in admin user id; cleared when they finish.
  Future<bool>? _wizardNeeded;
  int? _wizardFor;

  @override
  void initState() {
    super.initState();
    if (!AuthService.instance.initialized) {
      AuthService.instance.init();
    }
  }

  Future<bool> _wizardProbe(int userId) {
    if (_wizardNeeded == null || _wizardFor != userId) {
      _wizardFor = userId;
      _wizardNeeded = AdminSettingsService.instance
          .getServices()
          .then((d) => d['setup_completed'] != true)
          .catchError((_) => false); // can't tell → don't block the app
    }
    return _wizardNeeded!;
  }

  Future<bool?> _setupProbe() {
    final v = ApiService.serverConfigChanged.value;
    if (_needsSetup == null || _needsSetupFor != v) {
      _needsSetupFor = v;
      _needsSetup = ApiService.needsSetup();
    }
    return _needsSetup!;
  }

  static const _loader = Scaffold(
    backgroundColor: Color(0xFF0a0e27),
    body: Center(child: CircularProgressIndicator()),
  );

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(
          [AuthService.instance, ApiService.serverConfigChanged]),
      builder: (context, _) {
        final auth = AuthService.instance;
        if (!ApiService.isConfigured) {
          return const ConnectServerScreen();
        }
        if (!auth.initialized) {
          return _loader;
        }
        if (auth.isLoggedIn) {
          final uid = auth.user?['id'];
          if (auth.isAdmin && uid is int) {
            return FutureBuilder<bool>(
              future: _wizardProbe(uid),
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return _loader;
                }
                if (snapshot.data == true) {
                  return SetupWizardScreen(
                    onFinished: () => setState(() {
                      _wizardNeeded = Future.value(false);
                    }),
                  );
                }
                return _RootRouter(audioPlayerService: widget.audioPlayerService);
              },
            );
          }
          return _RootRouter(audioPlayerService: widget.audioPlayerService);
        }
        // Signed out: first run on this server shows create-admin instead of
        // login. Unreachable server (null) falls through to login, which has
        // the gear icon to fix the address.
        return FutureBuilder<bool?>(
          future: _setupProbe(),
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return _loader;
            }
            if (snapshot.data == true) {
              return const SetupAdminScreen();
            }
            return const LoginScreen();
          },
        );
      },
    );
  }
}

/// Picks between the phone shell (`MainNavigationScreen`) and the TV
/// shell (`TvMainNavigationScreen`) on first build, then caches the
/// choice for the rest of the session. Without caching, the entire
/// nav tree would rebuild + remount on rotation if the heuristic ever
/// flipped — losing all in-flight async, scroll positions, and any
/// state held above the navigator.
class _RootRouter extends StatefulWidget {
  final AudioPlayerService audioPlayerService;
  const _RootRouter({required this.audioPlayerService});

  @override
  State<_RootRouter> createState() => _RootRouterState();
}

class _RootRouterState extends State<_RootRouter> {
  bool? _isTvLike;
  bool _logged = false;

  @override
  Widget build(BuildContext context) {
    if (_isTvLike == null) {
      _isTvLike = isFireTvLike(context);
      if (Platform.isAndroid && !_logged) {
        _logged = true;
        final mq = MediaQuery.of(context);
        AppLogger.instance.info(
          '🪜 [_RootRouter] android size=${mq.size.width.toStringAsFixed(0)}x'
          '${mq.size.height.toStringAsFixed(0)} dp, '
          'shortestSide=${mq.size.shortestSide.toStringAsFixed(0)}, '
          'dpr=${mq.devicePixelRatio}, isTvLike=$_isTvLike',
        );
      }
    }
    if (_isTvLike!) {
      return TvMainNavigationScreen(
        audioPlayerService: widget.audioPlayerService,
      );
    }
    return MainNavigationScreen(
      audioPlayerService: widget.audioPlayerService,
    );
  }
}
