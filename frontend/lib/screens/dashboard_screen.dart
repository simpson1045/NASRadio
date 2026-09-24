import '../layout_context.dart';
import 'package:flutter/material.dart';
import 'dart:io' show Platform;
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import '../models/song.dart';
import '../models/album.dart';
import 'album_detail_screen.dart';
import 'now_playing_screen.dart';
import 'recently_played_screen.dart';
import 'most_played_screen.dart';
import 'recently_added_screen.dart';
import 'favorites_screen.dart';
import '../screens/queue_screen.dart';
import 'playlists_screen.dart';
import 'rss_feeds_screen.dart';
import 'podcast_discovery_screen.dart';
import 'spotify_history_screen.dart';
import 'prowlarr_search_screen.dart';
import 'all_releases_screen.dart';
import 'downloads_screen.dart';
import 'stations_screen.dart';
import 'import_queue_screen.dart';
import 'release_preview_screen.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../widgets/explicit_badge.dart';
import '../widgets/hdcd_badge.dart';
import '../widgets/surround_badge.dart';
import '../widgets/design_system.dart';
import '../services/song_recognition_service.dart';
import '../widgets/song_recognition_sheet.dart';
import 'system_logs_screen.dart';
import 'frontend_logs_screen.dart';
import '../main.dart' show globalWeatherService;
import '../services/weather_service.dart';

class DashboardScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;
  final bool showMiniPlayer;

  const DashboardScreen({
    super.key,
    required this.audioPlayerService,
    this.showMiniPlayer = true,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  // Desktop restoration (DESKTOP_UX_SPEC.md, screen #2): tile + rail
  // sizes read the shell-level LayoutScope instead of hardcoding
  // phone dimensions. 5K panels get real tiles, phones keep 140.
  bool get _desktopLayout => LayoutScope.maybeOf(context)?.isDesktop ?? false;
  double get _tile => _desktopLayout ? 200.0 : 140.0;
  double get _railH => _desktopLayout ? 268.0 : 200.0;

  final ApiService _apiService = ApiService();
  final SongRecognitionService _recognitionService = SongRecognitionService();
  bool _weatherExpanded = false;

  Map<String, dynamic>? _stats;
  Map<String, dynamic>? _libraryStats;
  List<Song> _recentlyPlayed = [];
  List<Song> _mostPlayed = [];
  List<Album> _recentlyAdded = [];
  Map<String, dynamic>? _favoritesCounts;
  int _playlistCount = 0;
  List<Map<String, dynamic>> _upcomingReleases = [];
  List<Map<String, dynamic>> _recentReleases = [];
  bool _isLoading = true;
  String? _error;
  int? _lastKnownSongId;
  bool? _lastKnownIsPlaying;

  @override
  void initState() {
    super.initState();
    _loadDashboardData();
    _lastKnownSongId = widget.audioPlayerService.currentSong?.id;
    widget.audioPlayerService.addListener(_updateState);
  }

  // The audio service notifies on every position tick (~1Hz during
  // playback). Without gating, this triggered a full dashboard rebuild
  // every second. We only setState when something the dashboard actually
  // displays has changed: the current song or whether it's playing.
  // Position changes have no visible effect on the dashboard so we drop
  // those entirely.
  void _updateState() {
    if (!mounted) return;
    final currentSongId = widget.audioPlayerService.currentSong?.id;
    final isPlaying = widget.audioPlayerService.isPlaying;
    final songChanged = currentSongId != _lastKnownSongId;
    final playStateChanged = isPlaying != _lastKnownIsPlaying;
    if (!songChanged && !playStateChanged) return;
    if (songChanged && currentSongId != null) {
      // Delay to allow backend to update last_played before refetching
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) _refreshRecentlyPlayed();
      });
    }
    _lastKnownSongId = currentSongId;
    _lastKnownIsPlaying = isPlaying;
    setState(() {});
  }

  Future<void> _refreshRecentlyPlayed() async {
    try {
      final songs = await _apiService.getRecentlyPlayed(limit: 20);
      if (mounted) {
        setState(() {
          _recentlyPlayed = songs;
        });
      }
    } catch (e) {
      print('Error refreshing recently played: $e');
    }
  }

  @override
  void dispose() {
    widget.audioPlayerService.removeListener(_updateState);
    super.dispose();
  }

  Future<void> _loadDashboardData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Load all dashboard data in parallel.
      // Limits bumped from 5/10/10 to 20/30/30 so ultrawide screens
      // don't show a row of 5-10 tiles spanning ~1500px out of 2500px+
      // and feel half-empty. Horizontal scroll handles the overflow
      // on any screen size.
      final results = await Future.wait([
        _apiService.getAnalyticsStats(),
        _apiService.getRecentlyPlayed(limit: 20),
        _apiService.getMostPlayed(limit: 30),
        _apiService.getFavoritesCounts(),
        _apiService.getRecentlyAdded(days: 30, limit: 30),
        _apiService.getStats(),
        _apiService.getPlaylists(),
        _apiService.getWhatsHappening(),
      ]);

      final recentlyAddedData = results[4] as Map<String, dynamic>;
      final recentlyAddedAlbums = (recentlyAddedData['albums'] as List)
          .map((json) => Album.fromJson(json))
          .toList();

      setState(() {
        _stats = results[0] as Map<String, dynamic>;
        _recentlyPlayed = results[1] as List<Song>;
        _mostPlayed = results[2] as List<Song>;
        _favoritesCounts = results[3] as Map<String, dynamic>;
        _recentlyAdded = recentlyAddedAlbums;
        _libraryStats = results[5] as Map<String, dynamic>;
        _playlistCount = (results[6] as List).length;
        final whatsHappening = results[7] as Map<String, dynamic>;
        _upcomingReleases = List<Map<String, dynamic>>.from(
          whatsHappening['upcoming'] ?? [],
        );
        _recentReleases = List<Map<String, dynamic>>.from(
          whatsHappening['recent'] ?? [],
        );
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _playSong(Song song) async {
    // Fetch the full album to play
    try {
      final albumData = await _apiService.getAlbum(song.albumId);
      final albumSongs = (albumData['songs'] as List).map((json) {
        json['artist_name'] = albumData['artist_name'];
        json['album_title'] = albumData['title'];
        return Song.fromJson(json);
      }).toList();

      // Find the song's position in the album
      final songIndex = albumSongs.indexWhere((s) => s.id == song.id);

      // Set queue with full album starting from this song
      widget.audioPlayerService.setQueue(
        albumSongs,
        songIndex >= 0 ? songIndex : 0,
        sourceType: 'album',
        sourceId: song.albumId,
        sourceName: albumData['title'],
      );

      NowPlayingScreen.open(
        context,
        audioPlayerService: widget.audioPlayerService,
      );
    } catch (e) {
      // Fallback to single song if album fetch fails
      widget.audioPlayerService.setQueue([song], 0, sourceType: 'single');
      NowPlayingScreen.open(
        context,
        audioPlayerService: widget.audioPlayerService,
      );
    }
  }

  String _getGreeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) {
      return 'Good morning';
    } else if (hour < 17) {
      return 'Good afternoon';
    } else {
      return 'Good evening';
    }
  }

  IconData _getGreetingIcon() {
    final hour = DateTime.now().hour;
    if (hour < 6) {
      return Icons.nightlight_round;
    } else if (hour < 12) {
      return Icons.wb_sunny;
    } else if (hour < 17) {
      return Icons.wb_sunny;
    } else if (hour < 20) {
      return Icons.wb_twilight;
    } else {
      return Icons.nightlight_round;
    }
  }

  Color _getGreetingColor() {
    final hour = DateTime.now().hour;
    if (hour < 6) {
      return const Color(0xFF7B68EE); // Purple for late night
    } else if (hour < 12) {
      return const Color(0xFFFFD700); // Gold for morning
    } else if (hour < 17) {
      return const Color(0xFFFFA500); // Orange for afternoon
    } else if (hour < 20) {
      return const Color(0xFFFF6347); // Sunset orange-red
    } else {
      return const Color(0xFF7B68EE); // Purple for night
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.audioPlayerService,
      builder: (context, child) {
        return Scaffold(
          appBar: AppBar(
            title: Row(
              children: [
                Text(
                  _getGreeting(),
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 8),
                Icon(_getGreetingIcon(), color: _getGreetingColor(), size: 24),
              ],
            ),
            backgroundColor: const Color(0xFF0d1b2a),
            actions: [
              IconButton(
                icon: const Icon(Icons.mic, color: Color(0xFF00d4ff)),
                tooltip: 'Identify song',
                onPressed: () async {
                  final result = await showSongRecognitionSheet(context, _recognitionService, audioPlayerService: widget.audioPlayerService);
                  if (result != null && mounted) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => ProwlarrSearchScreen(
                          audioPlayerService: widget.audioPlayerService,
                          initialQuery: result.prowlarrQuery,
                        ),
                      ),
                    );
                  }
                },
              ),
              GestureDetector(
                onLongPress: () {
                  showModalBottomSheet(
                    context: context,
                    backgroundColor: const Color(0xFF0d1b2a),
                    builder: (context) => SafeArea(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ListTile(
                            leading: const Icon(Icons.dns, color: Color(0xFF00d4ff)),
                            title: const Text('Backend Logs', style: TextStyle(color: Colors.white)),
                            subtitle: const Text('Flask server logs', style: TextStyle(color: Colors.grey)),
                            onTap: () {
                              Navigator.pop(context);
                              Navigator.push(context, MaterialPageRoute(
                                builder: (context) => const SystemLogsScreen(),
                              ));
                            },
                          ),
                          ListTile(
                            leading: const Icon(Icons.phone_android, color: Colors.orange),
                            title: const Text('Frontend Logs', style: TextStyle(color: Colors.white)),
                            subtitle: const Text('Flutter app logs (persists across sessions)', style: TextStyle(color: Colors.grey)),
                            onTap: () {
                              Navigator.pop(context);
                              Navigator.push(context, MaterialPageRoute(
                                builder: (context) => const FrontendLogsScreen(),
                              ));
                            },
                          ),
                        ],
                      ),
                    ),
                  );
                },
                child: IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _loadDashboardData,
                ),
              ),
            ],
          ),
          body: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('Error: $_error'),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _loadDashboardData,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadDashboardData,
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Weather Widget
                        _buildWeatherWidget(),

                        // Stats Header
                        _buildStatsHeader(),

                        // Quick Access Row
                        _buildQuickAccessRow(),

                        const SizedBox(height: 16),

                        // What's Happening - Coming Soon
                        if (_upcomingReleases.isNotEmpty) ...[
                          _buildSectionHeader(
                            'Coming Soon',
                            onViewAll: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => AllReleasesScreen(
                                    audioPlayerService:
                                        widget.audioPlayerService,
                                    upcomingReleases: _upcomingReleases,
                                    recentReleases: _recentReleases,
                                    initialTab: 0,
                                  ),
                                ),
                              );
                            },
                          ),
                          _buildReleaseRow(_upcomingReleases, isUpcoming: true),
                          const SizedBox(height: 24),
                        ],

                        // What's Happening - Recently Released
                        if (_recentReleases.isNotEmpty) ...[
                          _buildSectionHeader(
                            'Recently Released',
                            onViewAll: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => AllReleasesScreen(
                                    audioPlayerService:
                                        widget.audioPlayerService,
                                    upcomingReleases: _upcomingReleases,
                                    recentReleases: _recentReleases,
                                    initialTab: 1,
                                  ),
                                ),
                              );
                            },
                          ),
                          _buildReleaseRow(_recentReleases, isUpcoming: false),
                          const SizedBox(height: 24),
                        ],

                        // Continue Listening
                        if (_recentlyPlayed.isNotEmpty) ...[
                          _buildSectionHeader(
                            'Continue Listening',
                            onViewAll: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => RecentlyPlayedScreen(
                                    audioPlayerService:
                                        widget.audioPlayerService,
                                  ),
                                ),
                              );
                            },
                          ),
                          _buildRecentlyPlayed(),
                          const SizedBox(height: 24),
                        ],

                        // Most Played
                        if (_mostPlayed.isNotEmpty) ...[
                          _buildSectionHeader(
                            'Most Played',
                            onViewAll: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => MostPlayedScreen(
                                    audioPlayerService:
                                        widget.audioPlayerService,
                                  ),
                                ),
                              );
                            },
                          ),
                          _buildMostPlayed(),
                          const SizedBox(height: 24),
                        ],

                        // Recently Added
                        if (_recentlyAdded.isNotEmpty) ...[
                          _buildSectionHeader(
                            'Recently Added',
                            onViewAll: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => RecentlyAddedScreen(
                                    audioPlayerService:
                                        widget.audioPlayerService,
                                  ),
                                ),
                              );
                            },
                          ),
                          _buildRecentlyAdded(),
                        ],
                      ],
                    ),
                  ),
                ),
          floatingActionButton:
              widget.audioPlayerService.currentSong == null &&
                  widget.audioPlayerService.queue.isNotEmpty
              ? FloatingActionButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => QueueScreen(
                          audioPlayerService: widget.audioPlayerService,
                        ),
                      ),
                    );
                  },
                  backgroundColor: const Color(0xFF00d4ff),
                  child: Badge(
                    label: Text('${widget.audioPlayerService.queue.length}'),
                    child: const Icon(Icons.queue_music, color: Colors.black),
                  ),
                )
              : null,
        );
      },
    );
  }

  Widget _buildWeatherWidget() {
    return ListenableBuilder(
      listenable: globalWeatherService,
      builder: (context, child) {
        final weather = globalWeatherService.currentWeather;
        if (!globalWeatherService.enabled) {
          return const SizedBox.shrink();
        }

        // Show error/loading state
        if (weather == null) {
          final error = globalWeatherService.error;
          if (error != null) {
            return Container(
              margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF1a2332),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.cloud_off,
                      color: Colors.white38, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      error.contains('Location')
                          ? 'Set location in Settings to see weather'
                          : error,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 13),
                    ),
                  ),
                ],
              ),
            );
          }
          return const SizedBox.shrink();
        }

        return GestureDetector(
          onTap: () {
            setState(() {
              _weatherExpanded = !_weatherExpanded;
            });
          },
          child: Container(
            margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF1a2332), Color(0xFF0d1b2a)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: const Color(0xFF00d4ff).withOpacity(0.3),
                width: 1,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      Text(
                        weather.emoji,
                        style: const TextStyle(fontSize: 36),
                      ),
                      const SizedBox(width: 12),
                      if (weather.temperatureF != null)
                        Text(
                          '${weather.temperatureF!.round()}\u00b0F',
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              weather.locationName,
                              style: const TextStyle(
                                fontSize: 14,
                                color: Colors.white70,
                              ),
                              textAlign: TextAlign.right,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              weather.description,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.white54,
                              ),
                              textAlign: TextAlign.right,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  // Expanded details
                  if (_weatherExpanded) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.only(top: 12),
                      decoration: const BoxDecoration(
                        border: Border(
                          top: BorderSide(
                            color: Colors.white12,
                            width: 1,
                          ),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          if (weather.feelsLikeF != null)
                            _buildWeatherDetail(
                              'Feels Like',
                              '${weather.feelsLikeF!.round()}\u00b0F',
                            ),
                          if (weather.humidity != null)
                            _buildWeatherDetail(
                              'Humidity',
                              '${weather.humidity!.round()}%',
                            ),
                          if (weather.windSpeedMph != null)
                            _buildWeatherDetail(
                              'Wind',
                              '${weather.windSpeedMph!.round()} mph${weather.windDirection != null ? ' ${weather.windDirection}' : ''}',
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildWeatherDetail(String label, String value) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            color: Colors.white54,
          ),
        ),
      ],
    );
  }

  Widget _buildStatsHeader() {
    final totalPlays = _stats?['total_plays'] ?? 0;
    final completionRate = _stats?['completion_rate'] ?? 0.0;
    final mostPlayedArtist = _stats?['most_played_artist'];

    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1a2332), Color(0xFF0d1b2a)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFF00d4ff).withOpacity(0.3),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00d4ff).withOpacity(0.1),
            blurRadius: 20,
            spreadRadius: 0,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            // Library Stats
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.library_music,
                        color: const Color(0xFF00d4ff),
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        'LIBRARY',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF00d4ff),
                          letterSpacing: 1.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildStatChip(
                        Icons.music_note,
                        _formatNumber(_libraryStats?['songs'] ?? 0),
                        'songs',
                      ),
                      _buildStatChip(
                        Icons.album,
                        _formatNumber(_libraryStats?['albums'] ?? 0),
                        'albums',
                      ),
                      _buildStatChip(
                        Icons.person,
                        _formatNumber(_libraryStats?['artists'] ?? 0),
                        'artists',
                      ),
                      _buildStatChip(
                        Icons.schedule,
                        _formatDuration(_libraryStats?['total_duration'] ?? 0),
                        '',
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Divider
            Container(
              width: 1,
              height: 60,
              margin: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    const Color(0xFF00d4ff).withOpacity(0),
                    const Color(0xFF00d4ff).withOpacity(0.5),
                    const Color(0xFF00d4ff).withOpacity(0),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
            // Listening Stats
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.headphones,
                        color: const Color(0xFF00d4ff),
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        'LISTENING',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF00d4ff),
                          letterSpacing: 1.5,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildStatChip(Icons.play_arrow, '$totalPlays', 'plays'),
                      _buildStatChip(
                        Icons.check_circle_outline,
                        '${completionRate.toStringAsFixed(0)}%',
                        'done',
                      ),
                      if (mostPlayedArtist != null)
                        _buildStatChip(
                          Icons.star,
                          mostPlayedArtist['name'],
                          '',
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatChip(IconData icon, String value, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF0d1b2a).withOpacity(0.8),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFF00d4ff).withOpacity(0.2),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: const Color(0xFF00d4ff), size: 14),
          const SizedBox(width: 6),
          Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          if (label.isNotEmpty) ...[
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(fontSize: 11, color: Colors.grey[400]),
            ),
          ],
        ],
      ),
    );
  }

  String _formatNumber(dynamic number) {
    final num = number is int ? number : int.tryParse(number.toString()) ?? 0;
    if (num >= 1000) {
      return '${(num / 1000).toStringAsFixed(1)}k';
    }
    return num.toString();
  }

  String _formatDuration(int totalSeconds) {
    int remaining = totalSeconds;

    final months = remaining ~/ (86400 * 30);
    remaining %= (86400 * 30);

    final weeks = remaining ~/ (86400 * 7);
    remaining %= (86400 * 7);

    final days = remaining ~/ 86400;
    remaining %= 86400;

    final hours = remaining ~/ 3600;

    final parts = <String>[];
    if (months > 0) parts.add('$months mo');
    if (weeks > 0) parts.add('$weeks wk');
    if (days > 0) parts.add('$days d');
    if (hours > 0) parts.add('$hours hr');

    if (parts.isEmpty) return '0 hr';
    if (parts.length == 1) return parts.first;
    return '${parts[0]}, ${parts[1]}';
  }

  Widget _buildStatCard({
    required IconData icon,
    required String label,
    required String value,
    bool isText = false,
  }) {
    return Column(
      children: [
        Icon(icon, color: const Color(0xFF00d4ff), size: 32),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: isText ? 14 : 20,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  // Thin wrapper around the shared SectionHeader so existing call sites
  // ("_buildSectionHeader('Coming Soon', onViewAll: ...)") work without
  // edits. Migration target: replace _buildSectionHeader calls with
  // direct SectionHeader(...) over time; until then this keeps the
  // visual style consistent across every section on the dashboard.
  Widget _buildSectionHeader(String title, {VoidCallback? onViewAll}) {
    return SectionHeader(title, onViewAll: onViewAll);
  }

  Widget _buildRecentlyPlayed() {
    return SizedBox(
      height: _railH,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _recentlyPlayed.length,
        itemBuilder: (context, index) {
          final song = _recentlyPlayed[index];
          return GestureDetector(
            onTap: () => _playSong(song),
            child: Container(
              width: _tile,
              margin: const EdgeInsets.only(right: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF1a2332),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Album artwork
                  ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(8),
                    ),
                    child: CachedNetworkImage(
                      imageUrl: _apiService.getArtworkUrl(song.albumId),
                      width: _tile,
                      height: _tile,
                      fit: BoxFit.cover,
                      placeholder: (context, url) => Container(
                        width: _tile,
                        height: _tile,
                        color: const Color(0xFF1a2332),
                      ),
                      errorWidget: (context, url, error) => Container(
                        width: _tile,
                        height: _tile,
                        color: const Color(0xFF0d1b2a),
                        child: const Icon(
                          Icons.music_note,
                          color: Color(0xFF00d4ff),
                          size: 60,
                        ),
                      ),
                    ),
                  ),
                  // Song info
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  song.title,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (song.isExplicit) ...[
                                const SizedBox(width: 4),
                                const ExplicitBadge(fontSize: 8),
                              ],
                              if (song.isAtmos || song.isSurround) ...[
                                const SizedBox(width: 4),
                                SpatialBadge(song: song, fontSize: 8),
                              ],
                              if (song.isHdcd) ...[
                                const SizedBox(width: 4),
                                const HdcdBadge(fontSize: 8),
                              ],
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            song.artistName,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.grey,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildMostPlayed() {
    return SizedBox(
      height: _railH,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _mostPlayed.length,
        itemBuilder: (context, index) {
          final song = _mostPlayed[index];
          return GestureDetector(
            onTap: () => _playSong(song),
            child: Container(
              width: _tile,
              margin: const EdgeInsets.only(right: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF1a2332),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Album artwork with rank badge
                  Stack(
                    children: [
                      ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(8),
                        ),
                        child: CachedNetworkImage(
                          imageUrl: _apiService.getArtworkUrl(song.albumId),
                          width: _tile,
                          height: _tile,
                          fit: BoxFit.cover,
                          placeholder: (context, url) => Container(
                            width: _tile,
                            height: _tile,
                            color: const Color(0xFF1a2332),
                          ),
                          errorWidget: (context, url, error) => Container(
                            width: _tile,
                            height: _tile,
                            color: const Color(0xFF0d1b2a),
                            child: const Icon(
                              Icons.music_note,
                              color: Color(0xFF00d4ff),
                              size: 60,
                            ),
                          ),
                        ),
                      ),
                      // Rank badge - medal style
                      Positioned(
                        top: 6,
                        left: 6,
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: index == 0
                                  ? [
                                      const Color(0xFFFFD700),
                                      const Color(0xFFB8860B),
                                    ] // Gold
                                  : index == 1
                                  ? [
                                      const Color(0xFFC0C0C0),
                                      const Color(0xFF808080),
                                    ] // Silver
                                  : index == 2
                                  ? [
                                      const Color(0xFFCD7F32),
                                      const Color(0xFF8B4513),
                                    ] // Bronze
                                  : [
                                      const Color(0xFF3a4a5c),
                                      const Color(0xFF2a3a4c),
                                    ], // Default
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: index == 0
                                  ? const Color(0xFFFFD700).withOpacity(0.5)
                                  : index == 1
                                  ? const Color(0xFFC0C0C0).withOpacity(0.5)
                                  : index == 2
                                  ? const Color(0xFFCD7F32).withOpacity(0.5)
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                          child: Center(
                            child: Text(
                              '${index + 1}',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: index < 3 ? Colors.black : Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                      // Play count badge
                      Positioned(
                        bottom: 6,
                        right: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.7),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${song.playCount} plays',
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF00d4ff),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  // Song info
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  song.title,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (song.isExplicit) ...[
                                const SizedBox(width: 4),
                                const ExplicitBadge(fontSize: 8),
                              ],
                              if (song.isAtmos || song.isSurround) ...[
                                const SizedBox(width: 4),
                                SpatialBadge(song: song, fontSize: 8),
                              ],
                              if (song.isHdcd) ...[
                                const SizedBox(width: 4),
                                const HdcdBadge(fontSize: 8),
                              ],
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            song.artistName,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.grey,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  Widget _buildQuickAccessRow() {
    final songCount = _favoritesCounts?['songs'] ?? 0;
    final albumCount = _favoritesCounts?['albums'] ?? 0;
    final artistCount = _favoritesCounts?['artists'] ?? 0;
    final totalFavorites = songCount + albumCount + artistCount;

    final tiles = [
      _buildQuickAccessTile(
        icon: Icons.favorite,
        iconColor: Colors.red,
        title: 'Favorites',
        subtitle: totalFavorites > 0 ? '$totalFavorites items' : 'None yet',
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => FavoritesScreen(
                audioPlayerService: widget.audioPlayerService,
              ),
            ),
          );
        },
      ),
      _buildQuickAccessTile(
        icon: Icons.radio,
        iconColor: const Color(0xFFff4081),
        title: 'Stations',
        subtitle: 'Live internet radio',
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => StationsScreen(
                audioPlayerService: widget.audioPlayerService,
              ),
            ),
          );
        },
      ),
      _buildQuickAccessTile(
        icon: Icons.cloud_download,
        iconColor: const Color(0xFF00d4ff),
        title: 'Get Music',
        subtitle: 'Search & download',
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ProwlarrSearchScreen(
                audioPlayerService: widget.audioPlayerService,
              ),
            ),
          );
        },
      ),
      _buildQuickAccessTile(
        icon: Icons.downloading,
        iconColor: Colors.orange,
        title: 'Downloads',
        subtitle: 'Transmission queue',
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => DownloadsScreen(
                audioPlayerService: widget.audioPlayerService,
              ),
            ),
          );
        },
      ),
      _buildQuickAccessTile(
        icon: Icons.inbox,
        iconColor: Colors.purple,
        title: 'Import',
        subtitle: 'Pending albums',
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ImportQueueScreen(
                audioPlayerService: widget.audioPlayerService,
              ),
            ),
          );
        },
      ),
      _buildQuickAccessTile(
        imagePath: 'assets/images/spotify_logo.png',
        iconColor: const Color(0xFF1DB954),
        title: 'Spotify History',
        subtitle: '10 years',
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => SpotifyHistoryScreen(
                audioPlayerService: widget.audioPlayerService,
              ),
            ),
          );
        },
      ),
      _buildQuickAccessTile(
        icon: Icons.playlist_play,
        iconColor: const Color(0xFF9c27b0),
        title: 'Playlists',
        subtitle: '$_playlistCount playlists',
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => PlaylistsScreen(
                audioPlayerService: widget.audioPlayerService,
              ),
            ),
          );
        },
      ),
      _buildQuickAccessTile(
        icon: Icons.podcasts,
        iconColor: Colors.orange,
        title: 'Podcasts',
        subtitle: 'Discover & listen',
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => PodcastDiscoveryScreen(
                audioPlayerService: widget.audioPlayerService,
              ),
            ),
          );
        },
      ),
    ];

    // On mobile, use a column layout
    if (_isMobile) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          children: [
            for (int i = 0; i < tiles.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              tiles[i],
            ],
          ],
        ),
      );
    }

    // On desktop, use grid layout — columns scale with viewport width.
    // 3 columns at <1400px (16:9 1080p / 1440p), 4 at 1400-2000px (4K),
    // 5 at >2000px (ultrawide). Without this, ultrawides showed three
    // tiles spanning ~2500px each and the dashboard felt very empty.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          int columns;
          if (w > 2000) {
            columns = 5;
          } else if (w > 1400) {
            columns = 4;
          } else {
            columns = 3;
          }

          final rows = <Widget>[];
          for (int i = 0; i < tiles.length; i += columns) {
            final rowTiles = tiles.sublist(
              i,
              (i + columns).clamp(0, tiles.length),
            );
            rows.add(Row(
              children: [
                for (int j = 0; j < rowTiles.length; j++) ...[
                  if (j > 0) const SizedBox(width: 12),
                  Expanded(child: rowTiles[j]),
                ],
                // Fill remaining slots in incomplete trailing row.
                for (int j = rowTiles.length; j < columns; j++) ...[
                  const SizedBox(width: 12),
                  const Expanded(child: SizedBox()),
                ],
              ],
            ));
          }

          return Column(
            children: [
              for (int i = 0; i < rows.length; i++) ...[
                if (i > 0) const SizedBox(height: 12),
                rows[i],
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _buildQuickAccessTile({
    IconData? icon,
    String? imagePath,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                iconColor.withOpacity(0.15),
                iconColor.withOpacity(0.05),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: iconColor.withOpacity(0.3), width: 1),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: imagePath != null
                    ? Padding(
                        padding: const EdgeInsets.all(8),
                        child: Image.asset(imagePath, fit: BoxFit.contain),
                      )
                    : Icon(icon, color: iconColor, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: iconColor.withOpacity(0.7),
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatReleaseDate(String dateStr) {
    if (dateStr.isEmpty) return '';
    try {
      final parts = dateStr.split('-');
      if (parts.length == 3) {
        const months = [
          '',
          'Jan',
          'Feb',
          'Mar',
          'Apr',
          'May',
          'Jun',
          'Jul',
          'Aug',
          'Sep',
          'Oct',
          'Nov',
          'Dec',
        ];
        final month = int.parse(parts[1]);
        final day = int.parse(parts[2]);
        final year = parts[0];
        return '${months[month]} $day, $year';
      }
      return dateStr;
    } catch (_) {
      return dateStr;
    }
  }

  Widget _buildReleaseRow(
    List<Map<String, dynamic>> releases, {
    required bool isUpcoming,
  }) {
    // Was capped at 8 — fine on a phone, leaves a wide chunk of dead
    // space on the right of an ultrawide desktop where 12-15 tiles
    // would comfortably fit. ListView is horizontal-scrollable so a
    // generous cap doesn't hurt either form factor; user scrolls if
    // there's more than what's on screen. Cap of 30 keeps memory in
    // check while removing the "wasted space" feeling.
    final displayReleases = releases.length > 30
        ? releases.sublist(0, 30)
        : releases;
    final isDesktop = !Platform.isAndroid && !Platform.isIOS;

    return SizedBox(
      height: _railH + 10,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: displayReleases.length,
        itemBuilder: (context, index) {
          final release = displayReleases[index];
          final mbid = release['mbid'] ?? '';
          final releaseDate = release['release_date'] ?? '';
          final inLibrary = release['in_library'] == true;
          final releaseType = release['release_type'] ?? '';

          // Cover Art Archive URL from release group MBID
          final artworkUrl = mbid.isNotEmpty
              ? 'https://coverartarchive.org/release-group/$mbid/front-250'
              : '';

          return GestureDetector(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => ReleasePreviewScreen(
                    audioPlayerService: widget.audioPlayerService,
                    release: release,
                  ),
                ),
              );
            },
            child: Container(
              width: _tile,
              margin: const EdgeInsets.only(right: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF1a2332),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: artworkUrl.isNotEmpty
                            ? CachedNetworkImage(
                                imageUrl: artworkUrl,
                                width: _tile,
                                height: _tile,
                                fit: BoxFit.cover,
                                placeholder: (context, url) => Container(
                                  width: _tile,
                                  height: _tile,
                                  color: const Color(0xFF1a2332),
                                  child: const Icon(
                                    Icons.album,
                                    color: Color(0xFF00d4ff),
                                    size: 48,
                                  ),
                                ),
                                errorWidget: (context, url, error) => Container(
                                  width: _tile,
                                  height: _tile,
                                  color: const Color(0xFF1a2332),
                                  child: const Icon(
                                    Icons.album,
                                    color: Color(0xFF00d4ff),
                                    size: 48,
                                  ),
                                ),
                              )
                            : Container(
                                width: _tile,
                                height: _tile,
                                color: const Color(0xFF1a2332),
                                child: const Icon(
                                  Icons.album,
                                  color: Color(0xFF00d4ff),
                                  size: 48,
                                ),
                              ),
                      ),
                      if (inLibrary)
                        Positioned(
                          top: 6,
                          left: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.green.withValues(alpha: 0.9),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'IN LIBRARY',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          release['release_title'] ?? 'Unknown',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w500,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          release['artist_name'] ?? 'Unknown',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 11,
                          ),
                        ),
                        Text(
                          [
                            if (releaseType.isNotEmpty) releaseType,
                            if (releaseDate.isNotEmpty)
                              _formatReleaseDate(releaseDate),
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildRecentlyAdded() {
    return SizedBox(
      height: _railH + 40,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _recentlyAdded.length,
        itemBuilder: (context, index) {
          final album = _recentlyAdded[index];
          return GestureDetector(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => AlbumDetailScreen(
                    albumId: album.id,
                    audioPlayerService: widget.audioPlayerService,
                    parentLabel: 'Dashboard',
                  ),
                ),
              );
            },
            child: Container(
              width: _tile,
              margin: const EdgeInsets.only(right: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: CachedNetworkImage(
                      imageUrl: _apiService.getArtworkUrl(album.id),
                      width: _tile,
                      height: _tile,
                      fit: BoxFit.cover,
                      placeholder: (context, url) => Container(
                        width: _tile,
                        height: _tile,
                        color: const Color(0xFF1a2332),
                      ),
                      errorWidget: (context, url, error) => Container(
                        width: _tile,
                        height: _tile,
                        color: const Color(0xFF1a2332),
                        child: const Icon(
                          Icons.album,
                          color: Color(0xFF00d4ff),
                          size: 48,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    album.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w500,
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    album.artistName ?? 'Unknown Artist',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
