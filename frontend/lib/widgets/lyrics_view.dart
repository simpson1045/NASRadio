import 'package:flutter/material.dart';
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

class _LyricsViewState extends State<LyricsView>
    with SingleTickerProviderStateMixin {
  final ApiService _apiService = ApiService();
  final ScrollController _scrollController = ScrollController();

  List<LyricLine> _lyrics = [];
  String? _plainLyrics;
  final GlobalKey _currentLineKey = GlobalKey();
  bool _isLoading = true;
  String? _error;
  int _currentLineIndex = -1;
  bool _userScrolling = false;
  Timer? _scrollResumeTimer;

  // Cancellable HTTP client for the current lyrics fetch. Closed
  // on song change or dispose so the backend's LRCLIB request
  // aborts and its DB connection returns to the pool.
  http.Client? _lyricsClient;

  // Animation for current line glow effect
  late AnimationController _glowController;
  late Animation<double> _glowAnimation;

  @override
  void initState() {
    super.initState();

    // Setup glow animation
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _glowAnimation = Tween<double>(begin: 0.3, end: 0.8).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
    );

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
    _scrollController.dispose();
    _scrollResumeTimer?.cancel();
    _glowController.dispose();
    _lyricsClient?.close();
    _lyricsClient = null;
    super.dispose();
  }

  void _listenToPosition() {
    // Listen to audio player service changes
    widget.audioPlayerService.addListener(_onPositionChanged);
  }

  void _onPositionChanged() {
    if (_lyrics.isEmpty) return;

    final position = widget.audioPlayerService.position;

    // Find the current line
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

      // Auto-scroll to current line if user isn't manually scrolling
      if (!_userScrolling && newIndex >= 0 && _scrollController.hasClients) {
        _scrollToLine(newIndex);
      }
    }
  }

  void _scrollToLine(int index) {
    // Wait for the frame to build so the key is attached to the new current line
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _currentLineKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.4, // 40% from top = roughly centered
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  Future<void> _loadLyrics() async {
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

    setState(() {
      _isLoading = true;
      _error = null;
      _lyrics = [];
      _plainLyrics = null;
      _currentLineIndex = -1;
    });

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
            _isLoading = false;
          });
          // Scroll to current position immediately after lyrics load
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _onPositionChanged();
          });
        } else if (plainLyrics != null && plainLyrics.isNotEmpty) {
          setState(() {
            _plainLyrics = plainLyrics;
            _isLoading = false;
          });
        } else {
          setState(() {
            _error = 'No lyrics found';
            _isLoading = false;
          });
        }
      } else {
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
      _userScrolling = false;
      // Resume auto-scroll
      if (_currentLineIndex >= 0) {
        _scrollToLine(_currentLineIndex);
      }
    });
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
      return Stack(
        children: [
          // Gradient overlay at top
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 100,
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
          // Gradient overlay at bottom
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: 100,
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
          // Lyrics list
          NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is UserScrollNotification) {
                _onUserScroll();
              }
              return false;
            },
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(vertical: 200),
              itemCount: _lyrics.length,
              itemBuilder: (context, index) {
                final line = _lyrics[index];
                final isCurrent = index == _currentLineIndex;
                final isPast = index < _currentLineIndex;
                final distanceFromCurrent = (index - _currentLineIndex).abs();

                return GestureDetector(
                  key: isCurrent ? _currentLineKey : null,
                  onTap: () {
                    // Tap to seek to this line
                    widget.audioPlayerService.seek(line.timestamp);
                  },
                  child: AnimatedBuilder(
                    animation: _glowAnimation,
                    builder: (context, child) {
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                        child: AnimatedScale(
                          scale: isCurrent ? 1.05 : 1.0,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOutCubic,
                          child: AnimatedOpacity(
                            opacity: isCurrent
                                ? 1.0
                                : isPast
                                ? 0.4
                                : math.max(
                                    0.3,
                                    1.0 - (distanceFromCurrent * 0.15),
                                  ),
                            duration: const Duration(milliseconds: 300),
                            child: Container(
                              decoration: isCurrent
                                  ? BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      boxShadow: [
                                        BoxShadow(
                                          color: const Color(0xFF00d4ff)
                                              .withOpacity(
                                                _glowAnimation.value * 0.5,
                                              ),
                                          blurRadius: 20,
                                          spreadRadius: 2,
                                        ),
                                      ],
                                    )
                                  : null,
                              child: ShaderMask(
                                shaderCallback: (bounds) {
                                  if (isCurrent) {
                                    return const LinearGradient(
                                      colors: [
                                        Color(0xFF00d4ff),
                                        Color(0xFF00ffcc),
                                        Color(0xFF00d4ff),
                                      ],
                                    ).createShader(bounds);
                                  }
                                  return LinearGradient(
                                    colors: [Colors.white, Colors.white],
                                  ).createShader(bounds);
                                },
                                child: AnimatedDefaultTextStyle(
                                  duration: const Duration(milliseconds: 300),
                                  style: TextStyle(
                                    fontSize: isCurrent ? 26 : 18,
                                    fontWeight: isCurrent
                                        ? FontWeight.bold
                                        : FontWeight.w400,
                                    color: isCurrent
                                        ? Colors.white
                                        : isPast
                                        ? Colors.grey.shade600
                                        : Colors.white70,
                                    height: 1.5,
                                    letterSpacing: isCurrent ? 0.5 : 0,
                                  ),
                                  textAlign: TextAlign.center,
                                  child: Text(
                                    line.text,
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
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
