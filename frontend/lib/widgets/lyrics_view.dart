import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import '../models/lyric_line.dart';
import '../services/api_service.dart';
import '../services/app_logger.dart';
import '../services/audio_player_service.dart';
import '../services/auth_http_client.dart';

class LyricsView extends StatefulWidget {
  final AudioPlayerService audioPlayerService;
  final int? songId;

  const LyricsView({
    super.key,
    required this.audioPlayerService,
    required this.songId,
  });

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> with TickerProviderStateMixin {
  final ApiService _apiService = ApiService();
  final ScrollController _scrollController = ScrollController();

  List<LyricLine> _lyrics = [];
  String? _plainLyrics;
  bool _isLoading = true;
  String? _error;
  int _currentLineIndex = -1;
  bool _userScrolling = false;
  Timer? _scrollResumeTimer;
  // "Lyrics service is busy" (the backend says retry: true when LRCLIB is
  // down): quietly try again every minute while this screen is open, so the
  // lyrics just appear once it's back (Nov 3: no more tapping Try Again).
  Timer? _retryTimer;
  static const _retryEvery = Duration(seconds: 60);

  // Drift (Nov 3, same idea as the TV's cast screen): the lyrics never park
  // and jump. Between one line's time and the next they slide at a constant
  // speed, so each line reaches the centre as it starts; a frame ticker
  // drives it from the playhead, smoothed between the player's position
  // updates. Every line keeps the same font size and weight (the current
  // one is scaled, recoloured and glows), so line heights never change and
  // the list can't shift under the scroll the way it did when the current
  // line grew from 18 to 26 px.
  late final Ticker _driftTicker;
  final GlobalKey _contentKey = GlobalKey();
  List<GlobalKey> _lineKeys = [];
  List<double>? _lineCenters; // scroll offset that centres each line
  Size? _layoutSize;
  Duration _lastPos = Duration.zero;
  DateTime _lastPosAt = DateTime.now();
  // After a manual scroll, ease back into the drift instead of snapping.
  double? _blendFrom;
  DateTime? _blendStart;
  static const _blendDuration = Duration(milliseconds: 700);

  // Cancellable HTTP client for the current lyrics fetch. Closed
  // on song change or dispose so the backend's LRCLIB request
  // aborts and its DB connection returns to the pool.
  http.Client? _lyricsClient;

  // Glow on the current line. Held steady: a pulse would draw a new frame
  // every vsync even while paused (Nov 4: FRAMEWORK ran hot behind it).
  late AnimationController _glowController;
  late Animation<double> _glowAnimation;

  @override
  void initState() {
    super.initState();

    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
      value: 0.6,
    );

    _glowAnimation = Tween<double>(begin: 0.3, end: 0.8).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
    );

    // Started only while music plays (see _syncDriftTicker): a running ticker
    // means a new frame every vsync, even when nothing moves.
    _driftTicker = createTicker(_onDriftTick);

    _loadLyrics();
    _listenToPosition();
  }

  @override
  void didUpdateWidget(LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.songId != widget.songId) {
      _loadLyrics();
    }
  }

  @override
  void dispose() {
    widget.audioPlayerService.removeListener(_onPositionChanged);
    _driftTicker.dispose();
    _scrollController.dispose();
    _scrollResumeTimer?.cancel();
    _retryTimer?.cancel();
    _glowController.dispose();
    _lyricsClient?.close();
    _lyricsClient = null;
    super.dispose();
  }

  void _listenToPosition() {
    widget.audioPlayerService.addListener(_onPositionChanged);
  }

  void _syncDriftTicker() {
    final run = _lyrics.isNotEmpty && widget.audioPlayerService.isPlaying;
    if (run && !_driftTicker.isActive) {
      _driftTicker.start();
    } else if (!run && _driftTicker.isActive) {
      _driftTicker.stop();
    }
  }

  void _onPositionChanged() {
    final position = widget.audioPlayerService.position;
    final moved = position != _lastPos;
    if (moved) {
      _lastPos = position;
      _lastPosAt = DateTime.now();
    }
    _syncDriftTicker();
    if (_lyrics.isEmpty) return;
    // Paused (ticker stopped) but the playhead moved, e.g. a seek: place the
    // lyrics once rather than running the ticker.
    if (moved && !_driftTicker.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onDriftTick(Duration.zero);
      });
    }

    int newIndex = -1;
    for (int i = 0; i < _lyrics.length; i++) {
      if (_lyrics[i].timestamp <= position) {
        newIndex = i;
      } else {
        break;
      }
    }

    if (newIndex != _currentLineIndex) {
      setState(() {
        _currentLineIndex = newIndex;
      });
    }
  }

  /// The playhead now: the last reported position plus the time since, while
  /// playing (capped, so a stalled player doesn't run the lyrics away).
  Duration _smoothedPosition() {
    if (!widget.audioPlayerService.isPlaying) return _lastPos;
    var dt = DateTime.now().difference(_lastPosAt);
    if (dt > const Duration(seconds: 2)) dt = const Duration(seconds: 2);
    return _lastPos + dt;
  }

  List<double>? _measureLineCenters() {
    final content = _contentKey.currentContext?.findRenderObject() as RenderBox?;
    if (content == null || !_scrollController.hasClients) return null;
    final half = _scrollController.position.viewportDimension / 2;
    final centers = <double>[];
    for (final key in _lineKeys) {
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return null;
      final top = box.localToGlobal(Offset.zero, ancestor: content).dy;
      centers.add(top + box.size.height / 2 - half);
    }
    return centers;
  }

  /// Drift target at song time [t]: line i's centre at its start, sliding
  /// linearly to line i+1's centre by the time line i+1 starts.
  double? _driftOffset(Duration t) {
    final c = _lineCenters;
    if (c == null || c.isEmpty || c.length != _lyrics.length) return null;
    if (t <= _lyrics.first.timestamp) return c.first;
    var i = _lyrics.length - 1;
    while (i > 0 && t < _lyrics[i].timestamp) {
      i--;
    }
    if (i == _lyrics.length - 1) return c[i];
    final span = (_lyrics[i + 1].timestamp - _lyrics[i].timestamp).inMicroseconds;
    final p = span > 0
        ? ((t - _lyrics[i].timestamp).inMicroseconds / span).clamp(0.0, 1.0)
        : 1.0;
    return c[i] + (c[i + 1] - c[i]) * p;
  }

  void _onDriftTick(Duration _) {
    if (_lyrics.isEmpty || _userScrolling || !_scrollController.hasClients) return;
    _lineCenters ??= _measureLineCenters();
    var target = _driftOffset(_smoothedPosition());
    if (target == null) return;
    final pos = _scrollController.position;
    if (_blendStart != null && _blendFrom != null) {
      final t = DateTime.now().difference(_blendStart!).inMicroseconds /
          _blendDuration.inMicroseconds;
      if (t >= 1) {
        _blendStart = null;
        _blendFrom = null;
      } else {
        final e = Curves.easeInOut.transform(t.clamp(0.0, 1.0));
        target = _blendFrom! + (target - _blendFrom!) * e;
      }
    }
    final y = target.clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if ((y - pos.pixels).abs() > 0.05) _scrollController.jumpTo(y);
  }

  /// [quiet]: an automatic retry while the lyrics service is busy. The
  /// "busy" message stays up (no spinner flash) until real lyrics arrive.
  Future<void> _loadLyrics({bool quiet = false}) async {
    _retryTimer?.cancel();
    if (widget.songId == null) {
      setState(() {
        _isLoading = false;
        _error = 'No song playing';
      });
      return;
    }

    // Cancel any previous fetch — aborts the backend LRCLIB call
    // so its DB connection is released right away.
    _lyricsClient?.close();
    // Use a per-fetch auth client (seeded with the current bearer token) so the
    // request is authenticated AND independently closeable for cancellation.
    // A bare http.Client() carries no token and gets 401'd by the auth gate.
    final client = AuthHttpClient()..setToken(appHttpClient.token);
    _lyricsClient = client;

    if (!quiet) {
      setState(() {
        _isLoading = true;
        _error = null;
        _lyrics = [];
        _lineKeys = [];
        _lineCenters = null;
        _plainLyrics = null;
        _currentLineIndex = -1;
      });
    }

    final loadStart = DateTime.now();
    final songId = widget.songId!;
    AppLogger.instance.info('📊 [Lyrics] Fetch START song=$songId');
    try {
      final response =
          await _apiService.getLyrics(songId, client: client);
      final fetchMs = DateTime.now().difference(loadStart).inMilliseconds;

      // A newer fetch (or dispose) has superseded us — bail without
      // touching widget state.
      if (!mounted || !identical(_lyricsClient, client)) {
        AppLogger.instance.info(
          '📊 [Lyrics] Fetch song=$songId aborted (superseded) after ${fetchMs}ms',
        );
        return;
      }

      if (response['success'] == true) {
        final syncedLyrics = response['synced_lyrics'] as String?;
        final plainLyrics = response['plain_lyrics'] as String?;
        AppLogger.instance.info(
          '📊 [Lyrics] Fetch DONE song=$songId (${fetchMs}ms, '
          'syncedChars=${syncedLyrics?.length ?? 0}, '
          'plainChars=${plainLyrics?.length ?? 0})',
        );

        if (syncedLyrics != null && syncedLyrics.isNotEmpty) {
          final parseStart = DateTime.now();
          final parsedLines = LyricLine.parseLrc(syncedLyrics);
          final parseMs =
              DateTime.now().difference(parseStart).inMilliseconds;
          AppLogger.instance.info(
            '📊 [Lyrics] LRC parse song=$songId (${parseMs}ms, '
            'lines=${parsedLines.length})',
          );
          setState(() {
            _lyrics = parsedLines;
            _lineKeys = List.generate(parsedLines.length, (_) => GlobalKey());
            _lineCenters = null;
            _error = null;
            _isLoading = false;
          });
          // Pick the current line straight away; the drift ticker places it.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _onPositionChanged();
          });
        } else if (plainLyrics != null && plainLyrics.isNotEmpty) {
          setState(() {
            _plainLyrics = plainLyrics;
            _error = null;
            _isLoading = false;
          });
        } else {
          setState(() {
            _error = 'No lyrics found';
            _isLoading = false;
          });
        }
      } else {
        if (response['retry'] == true) {
          _retryTimer = Timer(_retryEvery, () {
            if (mounted && widget.songId == songId) _loadLyrics(quiet: true);
          });
        }
        setState(() {
          final rawError = response['error'] ?? 'No lyrics found';
          // Show friendly message instead of raw backend errors
          if (rawError.length > 100 ||
              rawError.contains('Exception') ||
              rawError.contains('Error(')) {
            _error = 'Lyrics service unavailable';
          } else {
            _error = rawError;
          }
          _isLoading = false;
        });
      }
    } catch (e) {
      final ms = DateTime.now().difference(loadStart).inMilliseconds;
      AppLogger.instance.warning(
        '❌ [Lyrics] Fetch FAILED song=$songId after ${ms}ms: $e',
      );
      if (!mounted || !identical(_lyricsClient, client)) return;
      if (quiet) {
        // A quiet retry that couldn't reach the server: keep the "busy"
        // message and try again next minute.
        _retryTimer = Timer(_retryEvery, () {
          if (mounted && widget.songId == songId) _loadLyrics(quiet: true);
        });
        return;
      }
      setState(() {
        _error = 'Failed to load lyrics';
        _isLoading = false;
      });
    } finally {
      if (identical(_lyricsClient, client)) {
        client.close();
        _lyricsClient = null;
      }
    }
  }

  void _onUserScroll() {
    _userScrolling = true;
    _scrollResumeTimer?.cancel();
    _scrollResumeTimer = Timer(const Duration(seconds: 5), () {
      // Resume the drift, easing back from wherever the user left it.
      if (_scrollController.hasClients) {
        _blendFrom = _scrollController.position.pixels;
        _blendStart = DateTime.now();
      }
      _userScrolling = false;
      // Paused: no ticker to blend with, so settle on the spot once.
      if (!_driftTicker.isActive && mounted) {
        _blendStart = null;
        _blendFrom = null;
        _onDriftTick(Duration.zero);
      }
    });
  }

  Widget _buildLine(int index) {
    final line = _lyrics[index];
    final isCurrent = index == _currentLineIndex;
    final isPast = index < _currentLineIndex;
    final distanceFromCurrent = (index - _currentLineIndex).abs();

    // One font size and weight for every line, so no line ever changes
    // height; only the colour differs (a repaint, not a re-layout).
    Widget text = Text(
      line.text,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        height: 1.5,
        color: isCurrent
            ? Colors.white
            : isPast
            ? Colors.grey.shade600
            : Colors.white70,
      ),
    );

    if (isCurrent) {
      text = ShaderMask(
        shaderCallback: (bounds) => const LinearGradient(
          colors: [Color(0xFF00d4ff), Color(0xFF00ffcc), Color(0xFF00d4ff)],
        ).createShader(bounds),
        child: text,
      );
      text = AnimatedBuilder(
        animation: _glowAnimation,
        builder: (context, child) => DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF00d4ff).withOpacity(_glowAnimation.value * 0.5),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ),
          child: child,
        ),
        child: text,
      );
    }

    return GestureDetector(
      key: _lineKeys[index],
      onTap: () {
        // Tap to seek to this line
        widget.audioPlayerService.seek(line.timestamp);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        child: AnimatedScale(
          scale: isCurrent ? 1.08 : 1.0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          child: AnimatedOpacity(
            opacity: isCurrent
                ? 1.0
                : isPast
                ? 0.4
                : math.max(0.3, 1.0 - (distanceFromCurrent * 0.15)),
            duration: const Duration(milliseconds: 300),
            child: text,
          ),
        ),
      ),
    );
  }

  Widget _buildFade({required bool top, required double height}) {
    return Positioned(
      top: top ? 0 : null,
      bottom: top ? null : 0,
      left: 0,
      right: 0,
      height: height,
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: top ? Alignment.topCenter : Alignment.bottomCenter,
              end: top ? Alignment.bottomCenter : Alignment.topCenter,
              colors: [
                const Color(0xFF0d1b2a),
                const Color(0xFF0d1b2a).withOpacity(0),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Color(0xFF00d4ff)),
            SizedBox(height: 16),
            Text('Loading lyrics...', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.lyrics_outlined, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              _error!,
              style: const TextStyle(color: Colors.grey, fontSize: 16),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _loadLyrics,
              child: const Text(
                'Try Again',
                style: TextStyle(color: Color(0xFF00d4ff)),
              ),
            ),
          ],
        ),
      );
    }

    // Show synced lyrics with highlighting
    if (_lyrics.isNotEmpty) {
      return LayoutBuilder(
        builder: (context, constraints) {
          // A new size re-wraps lines: measure the line centres again.
          if (_layoutSize != constraints.biggest) {
            _layoutSize = constraints.biggest;
            _lineCenters = null;
          }
          // Room above the first line and below the last so both can sit
          // in the centre.
          final edge = constraints.maxHeight * 0.45;
          return Stack(
            children: [
              NotificationListener<ScrollNotification>(
                onNotification: (notification) {
                  if (notification is UserScrollNotification &&
                      notification.direction != ScrollDirection.idle) {
                    _onUserScroll();
                  }
                  return false;
                },
                child: SingleChildScrollView(
                  controller: _scrollController,
                  child: Padding(
                    key: _contentKey,
                    padding: EdgeInsets.symmetric(vertical: edge),
                    child: Column(
                      children: [
                        for (int i = 0; i < _lyrics.length; i++) _buildLine(i),
                      ],
                    ),
                  ),
                ),
              ),
              _buildFade(top: true, height: 100),
              _buildFade(top: false, height: 100),
            ],
          );
        },
      );
    }

    // Show plain lyrics (no sync)
    if (_plainLyrics != null) {
      return Stack(
        children: [
          // Gradient overlay at top
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 80,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      const Color(0xFF0d1b2a),
                      const Color(0xFF0d1b2a).withOpacity(0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Gradient overlay at bottom
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: 80,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      const Color(0xFF0d1b2a),
                      const Color(0xFF0d1b2a).withOpacity(0),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Main content
          SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 60),
            child: Center(
              child: Column(
                children: [
                  // "Not synced" indicator
                  AnimatedBuilder(
                    animation: _glowAnimation,
                    builder: (context, child) {
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade800.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.grey.shade600.withOpacity(0.3),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.sync_disabled,
                              size: 14,
                              color: Colors.grey.shade500,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Lyrics not synced',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade500,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 32),
                  // Lyrics text with subtle styling
                  AnimatedBuilder(
                    animation: _glowAnimation,
                    builder: (context, child) {
                      return Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: const Color(
                              0xFF00d4ff,
                            ).withOpacity(_glowAnimation.value * 0.15),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(
                                0xFF00d4ff,
                              ).withOpacity(_glowAnimation.value * 0.08),
                              blurRadius: 30,
                              spreadRadius: 0,
                            ),
                          ],
                        ),
                        child: Text(
                          _plainLyrics!,
                          style: const TextStyle(
                            fontSize: 18,
                            color: Colors.white70,
                            height: 2.0,
                            letterSpacing: 0.3,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return const SizedBox.shrink();
  }
}
