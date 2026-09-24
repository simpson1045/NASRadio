import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:io' show Platform;
import '../services/audio_player_service.dart';
import '../services/api_service.dart';
import '../services/weather_service.dart';
import '../services/update_service.dart';
import '../main.dart' show globalWeatherService;
import '../layout_context.dart';
import '../widgets/desktop_nav_rail.dart';
import '../widgets/mini_player.dart';
import '../widgets/update_banner.dart';
import '../widgets/app_back_navigator.dart';
import 'dashboard_screen.dart';
import 'library_screen.dart';
import 'search_screen.dart';
import 'favorites_screen.dart';
import 'playlists_screen.dart';
import 'now_playing_screen.dart';

class MainNavigationScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;

  const MainNavigationScreen({super.key, required this.audioPlayerService});

  @override
  State<MainNavigationScreen> createState() => MainNavigationScreenState();
}

class MainNavigationScreenState extends State<MainNavigationScreen>
    with SingleTickerProviderStateMixin {
  static Function(int)? switchToTab;

  /// Push a route into the currently selected section (used by overlays
  /// like Now Playing, which live on the root navigator above the shell).
  static Function(Route<dynamic>)? pushInCurrentTab;
  int _selectedIndex = 0;
  final List<int> _tabHistory = [0];
  final List<int> _forwardHistory = [];

  // One Navigator per section (Home/Library/Search/Playlists/Favorites).
  // Detail pages push INSIDE their section, so the shared tab bar / rail
  // stays put and each section remembers where you were. Sections are
  // created on first visit so startup only loads Home.
  final List<GlobalKey<NavigatorState>> _navKeys = List.generate(
    5,
    (_) => GlobalKey<NavigatorState>(),
  );
  final Set<int> _visitedTabs = {0};

  // Section switch transition: the stack slides in from the side you're
  // heading (right when moving to a later section, left when going back)
  // and fades. The IndexedStack underneath keeps every section's state.
  late final AnimationController _switchCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: 1,
  );
  double _switchDir = 1; // +1 = from the right, -1 = from the left

  void _animateSwitch(int from, int to) {
    if (from == to) return;
    _switchDir = to > from ? 1 : -1;
    _switchCtrl.forward(from: 0);
  }

  late final FocusNode _focusNode;
  dynamic _smtc; // Windows-only SMTC controller

  // Server health check.
  //
  // The banner only shows after two consecutive failures — one miss
  // is usually just a transient WiFi blip or a slow sidecar probe
  // on the backend. Without this, the banner flickers on/off at
  // random even when everything is working.
  final ApiService _apiService = ApiService();
  bool _isServerOnline = true;
  int _consecutiveHealthFailures = 0;
  bool _isRetryingHealth = false;
  Timer? _healthCheckTimer;
  static const _failuresBeforeBanner = 2;

  // Weather alert banner
  WeatherAlert? _activeAlert;
  Timer? _alertDismissTimer;

  // App update
  UpdateInfo? _updateInfo;

  late final List<Widget> _screens;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _initSMTC();
    _checkServerHealth();
    _healthCheckTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _checkServerHealth(),
    );
    // Check for app updates (non-blocking)
    _checkForUpdate();
    // Listen for weather alerts
    globalWeatherService.onNewAlert = _handleWeatherAlert;
    MainNavigationScreenState.switchToTab = _selectTab;
    MainNavigationScreenState.pushInCurrentTab = _pushInCurrentTab;
    // Mouse/browser back+forward funnel through NavBackController; when there's
    // no pushed route to pop, it walks our bottom-tab history instead.
    NavBackController.onTabBack = () => handleBack();
    NavBackController.onTabForward = _goForwardTab;
    _screens = [
      DashboardScreen(audioPlayerService: widget.audioPlayerService),
      LibraryScreen(
        audioPlayerService: widget.audioPlayerService,
        showMiniPlayer: false,
      ),
      SearchScreen(
        audioPlayerService: widget.audioPlayerService,
        showMiniPlayer: false,
      ),
      PlaylistsScreen(
        audioPlayerService: widget.audioPlayerService,
        showMiniPlayer: false,
      ),
      FavoritesScreen(
        audioPlayerService: widget.audioPlayerService,
        showMiniPlayer: false,
      ),
    ];
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _switchCtrl.dispose();
    _smtc?.dispose();
    _healthCheckTimer?.cancel();
    _alertDismissTimer?.cancel();
    globalWeatherService.onNewAlert = null;
    NavBackController.onTabBack = null;
    NavBackController.onTabForward = null;
    MainNavigationScreenState.switchToTab = null;
    MainNavigationScreenState.pushInCurrentTab = null;
    super.dispose();
  }

  /// THE back function: Android back button, mouse back, browser-back key
  /// all land here (the root navigator handles overlays like Now Playing
  /// first). Order: pop inside the current section → previous section in
  /// history → Home. Returns false when already at Home's root, i.e. the
  /// only thing left to do is leave the app (the caller decides that).
  bool handleBack() {
    final nav = _navKeys[_selectedIndex].currentState;
    if (nav != null && nav.canPop()) {
      nav.pop();
      return true;
    }
    if (_tabHistory.length > 1) {
      _goBackTab();
      return true;
    }
    if (_selectedIndex != 0) {
      setState(() {
        _tabHistory
          ..clear()
          ..add(0);
        _forwardHistory.clear();
        _animateSwitch(_selectedIndex, 0);
        _selectedIndex = 0;
      });
      return true;
    }
    return false;
  }

  void _selectTab(int index) {
    setState(() {
      if (index != _selectedIndex) {
        _animateSwitch(_selectedIndex, index);
        _tabHistory.add(index);
        _forwardHistory.clear();
        _selectedIndex = index;
      }
      _visitedTabs.add(index);
    });
  }

  void _pushInCurrentTab(Route<dynamic> route) {
    _navKeys[_selectedIndex].currentState?.push(route);
  }

  // Walk the bottom-tab history back/forward — used when there's no pushed
  // route to pop. Mirrors the bookkeeping in switchToTab and the nav-bar onTap.
  void _goBackTab() {
    if (_tabHistory.length > 1) {
      setState(() {
        _forwardHistory.add(_tabHistory.removeLast());
        _animateSwitch(_selectedIndex, _tabHistory.last);
        _selectedIndex = _tabHistory.last;
        _visitedTabs.add(_selectedIndex);
      });
    }
  }

  void _goForwardTab() {
    if (_forwardHistory.isNotEmpty) {
      setState(() {
        final nextTab = _forwardHistory.removeLast();
        _tabHistory.add(nextTab);
        _animateSwitch(_selectedIndex, nextTab);
        _selectedIndex = nextTab;
        _visitedTabs.add(nextTab);
      });
    }
  }

  Future<void> _checkServerHealth() async {
    final isOnline = await _apiService.checkServerHealth();
    if (!mounted) return;

    if (isOnline) {
      if (!_isServerOnline || _consecutiveHealthFailures != 0) {
        setState(() {
          _isServerOnline = true;
          _consecutiveHealthFailures = 0;
        });
      }
      return;
    }

    final newFailures = _consecutiveHealthFailures + 1;
    if (newFailures >= _failuresBeforeBanner && _isServerOnline) {
      setState(() {
        _consecutiveHealthFailures = newFailures;
        _isServerOnline = false;
      });
    } else {
      setState(() {
        _consecutiveHealthFailures = newFailures;
      });
    }
  }

  // Retry button on the "Server unreachable" banner. Gives the user
  // immediate visual feedback (spinner on the button + snackbar on
  // failure) so tapping it never feels like it did nothing.
  Future<void> _retryServerHealth() async {
    if (_isRetryingHealth) return;
    setState(() => _isRetryingHealth = true);

    final isOnline = await _apiService.checkServerHealth();
    if (!mounted) return;

    setState(() {
      _isRetryingHealth = false;
      if (isOnline) {
        _isServerOnline = true;
        _consecutiveHealthFailures = 0;
      }
    });

    if (!isOnline) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Still can’t reach the server.'),
          duration: Duration(seconds: 2),
          backgroundColor: Color(0xFFE65100),
        ),
      );
    }
  }

  Future<void> _initSMTC() async {
    // Windows media controls - disabled for cross-platform compatibility
    // TODO: Re-enable with conditional imports for Windows desktop
    if (!Platform.isWindows) return;

    // SMTC (System Media Transport Controls) is Windows-only
    // For now, we rely on keyboard media keys which work cross-platform
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      final keyId = event.logicalKey.keyId;

      // Mouse/browser back+forward are handled globally by NavBackController.
      if (event.logicalKey == LogicalKeyboardKey.mediaPlayPause) {
        widget.audioPlayerService.togglePlayPause();
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.mediaTrackNext ||
          keyId == 176) {
        widget.audioPlayerService.next();
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.mediaTrackPrevious ||
          keyId == 177) {
        widget.audioPlayerService.previous();
        return KeyEventResult.handled;
      } // Spacebar removed - conflicts with text input in search
    }
    return KeyEventResult.ignored;
  }

  void _handleWeatherAlert(WeatherAlert alert) {
    if (!mounted) return;
    final mode = globalWeatherService.alertMode;
    if (mode == 'off') return;

    // Show banner unless voice-only
    if (mode != 'voice_only') {
      setState(() {
        _activeAlert = alert;
      });

      // Auto-dismiss after 15 seconds
      _alertDismissTimer?.cancel();
      _alertDismissTimer = Timer(const Duration(seconds: 15), () {
        if (mounted) {
          setState(() {
            _activeAlert = null;
          });
        }
      });
    }

    // Voice announcement (unless banner-only)
    if (mode != 'banner_only') {
      globalWeatherService.announceAlert(alert);
    }
  }

  Future<void> _checkForUpdate() async {
    final info = await UpdateService.checkForUpdate();
    if (mounted && info != null) {
      setState(() => _updateInfo = info);
    }
  }

  void _dismissAlert() {
    _alertDismissTimer?.cancel();
    setState(() {
      _activeAlert = null;
    });
  }

  Widget _buildHealthBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: const Color(0xFFE65100),
      child: Row(
        children: [
          const Icon(Icons.cloud_off, color: Colors.white, size: 20),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Server unreachable. Check your connection.',
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: _isRetryingHealth ? null : _retryServerHealth,
            child: _isRetryingHealth
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(Colors.white),
                    ),
                  )
                : const Text(
                    'Retry',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildWeatherAlertBanner() {
    final alert = _activeAlert;
    if (alert == null) return const SizedBox.shrink();

    // Color by severity
    Color bannerColor;
    IconData bannerIcon;
    if (alert.severity == 'Extreme') {
      bannerColor = const Color(0xFFB71C1C); // Dark red
      bannerIcon = Icons.warning_amber_rounded;
    } else if (alert.severity == 'Severe') {
      bannerColor = const Color(0xFFD32F2F); // Red
      bannerIcon = Icons.warning_amber_rounded;
    } else if (alert.severity == 'Moderate') {
      bannerColor = const Color(0xFFE65100); // Orange
      bannerIcon = Icons.info_outline;
    } else {
      bannerColor = const Color(0xFFF9A825); // Amber
      bannerIcon = Icons.info_outline;
    }

    return AnimatedSlide(
      offset: Offset.zero,
      duration: const Duration(milliseconds: 300),
      child: AnimatedOpacity(
        opacity: 1.0,
        duration: const Duration(milliseconds: 300),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: bannerColor,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(bannerIcon, color: Colors.white, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      alert.event,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (alert.headline.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        alert.headline,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _dismissAlert,
                child: const Icon(Icons.close, color: Colors.white70, size: 20),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Shared tab-switch bookkeeping for both shells (mirrors switchToTab).
  void _onNavSelect(int index) {
    if (index == 5) {
      NowPlayingScreen.open(
        context,
        audioPlayerService: widget.audioPlayerService,
      );
      return;
    }
    if (index == _selectedIndex) {
      // Re-tapping the current section returns it to its root page.
      _navKeys[index].currentState?.popUntil((r) => r.isFirst);
      return;
    }
    _selectTab(index);
  }

  /// The five sections stacked; only the selected one is visible, the
  /// rest keep their page history and scroll positions.
  Widget _buildTabStack() {
    final stack = IndexedStack(
      index: _selectedIndex,
      children: List.generate(_screens.length, (i) {
        if (!_visitedTabs.contains(i)) return const SizedBox.shrink();
        return Navigator(
          key: _navKeys[i],
          // Nested navigators need their own HeroController or Hero
          // flights between pages inside a section silently don't fly.
          observers: [HeroController()],
          onGenerateRoute: (settings) => MaterialPageRoute(
            settings: settings,
            builder: (_) => _screens[i],
          ),
        );
      }),
    );
    return AnimatedBuilder(
      animation: _switchCtrl,
      child: stack,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_switchCtrl.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset((1 - t) * 40 * _switchDir, 0),
            child: child,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // The layout verdict comes from the app-root LayoutScope (wraps
    // the Navigator in main.dart so pushed routes inherit it too).
    // MediaQuery fallback only for exotic contexts without the scope.
    final layout =
        LayoutScope.maybeOf(context)?.layout ??
        (MediaQuery.of(context).size.width >= LayoutScope.desktopBreakpoint
            ? AppLayout.desktop
            : AppLayout.mobile);
    return PopScope(
      // Android back: walk our own history; only leave the app from Home.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (!handleBack()) SystemNavigator.pop();
      },
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: layout == AppLayout.desktop
            ? _buildDesktopShell()
            : _buildMobileShell(),
      ),
    );
  }

  /// Desktop shell (spec §4): navigation rail beside the content, the
  /// mini-player docked full-width beneath the content area. No bottom
  /// tab bar pretending 27 inches is a phone.
  Widget _buildDesktopShell() {
    return Scaffold(
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DesktopNavRail(
              selectedIndex: _selectedIndex,
              onSelect: _onNavSelect,
              audioPlayerService: widget.audioPlayerService,
            ),
            Expanded(
              child: Column(
                children: [
                  if (!_isServerOnline) _buildHealthBanner(),
                  if (_updateInfo != null) UpdateBanner(info: _updateInfo!),
                  _buildWeatherAlertBanner(),
                  Expanded(child: _buildTabStack()),
                  MiniPlayer(audioPlayerService: widget.audioPlayerService),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Phone shell — the original, untouched.
  Widget _buildMobileShell() {
    return Scaffold(
      body: SafeArea(
        bottom: false, // Let bottom nav bar handle its own safe area
        child: Column(
          children: [
            if (!_isServerOnline) _buildHealthBanner(),
            if (_updateInfo != null) UpdateBanner(info: _updateInfo!),
            _buildWeatherAlertBanner(),
            Expanded(child: _buildTabStack()),
            MiniPlayer(audioPlayerService: widget.audioPlayerService),
          ],
        ),
      ),
      bottomNavigationBar: ListenableBuilder(
        listenable: widget.audioPlayerService,
        builder: (context, child) {
          final isPlaying = widget.audioPlayerService.isPlaying;
          final hasSong = widget.audioPlayerService.currentSong != null;

          return BottomNavigationBar(
            currentIndex: _selectedIndex < 5 ? _selectedIndex : 0,
            type: BottomNavigationBarType.fixed,
            backgroundColor: const Color(0xFF0d1b2a),
            selectedItemColor: const Color(0xFF00d4ff),
            unselectedItemColor: Colors.white54,
            onTap: _onNavSelect,
            items: [
              const BottomNavigationBarItem(
                icon: Icon(Icons.home),
                label: 'Home',
              ),
              const BottomNavigationBarItem(
                icon: Icon(Icons.library_music),
                label: 'Library',
              ),
              const BottomNavigationBarItem(
                icon: Icon(Icons.search),
                label: 'Search',
              ),
              const BottomNavigationBarItem(
                icon: Icon(Icons.playlist_play),
                label: 'Playlists',
              ),
              const BottomNavigationBarItem(
                icon: Icon(Icons.favorite),
                label: 'Favorites',
              ),
              BottomNavigationBarItem(
                icon: Icon(
                  isPlaying
                      ? Icons.pause_circle_filled
                      : hasSong
                      ? Icons.play_circle_filled
                      : Icons.play_circle_outline,
                ),
                label: 'Playing',
              ),
            ],
          );
        },
      ),
    );
  }
}
