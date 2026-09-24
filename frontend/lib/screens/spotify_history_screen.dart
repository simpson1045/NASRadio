import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import 'missing_album_detail_screen.dart';

class SpotifyHistoryScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;

  const SpotifyHistoryScreen({super.key, required this.audioPlayerService});

  @override
  State<SpotifyHistoryScreen> createState() => _SpotifyHistoryScreenState();
}

class _SpotifyHistoryScreenState extends State<SpotifyHistoryScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final ApiService _apiService = ApiService();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Spotify History'),
        backgroundColor: const Color(0xFF0d1b2a),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF1DB954),
          labelColor: const Color(0xFF1DB954),
          unselectedLabelColor: Colors.grey,
          tabs: const [
            Tab(text: 'Stats', icon: Icon(Icons.bar_chart)),
            Tab(text: 'Missing', icon: Icon(Icons.album)),
            Tab(text: 'History', icon: Icon(Icons.history)),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _StatsTab(apiService: _apiService),
                _MissingAlbumsTab(
                  apiService: _apiService,
                  audioPlayerService: widget.audioPlayerService,
                ),
                _HistoryTab(apiService: _apiService),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =====================
// Stats Tab
// =====================

class _StatsTab extends StatefulWidget {
  final ApiService apiService;

  const _StatsTab({required this.apiService});

  @override
  State<_StatsTab> createState() => _StatsTabState();
}

class _StatsTabState extends State<_StatsTab> {
  Map<String, dynamic>? _stats;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final response = await widget.apiService.getSpotifyStats();
      setState(() {
        _stats = response;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Error: $_error', style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _loadStats, child: const Text('Retry')),
          ],
        ),
      );
    }

    if (_stats == null) {
      return const Center(child: Text('No data'));
    }

    return RefreshIndicator(
      onRefresh: _loadStats,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Spotify Listening History',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1DB954),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${_stats!['date_range']?['start']?.substring(0, 10) ?? 'N/A'} to ${_stats!['date_range']?['end']?.substring(0, 10) ?? 'N/A'}',
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            _buildStatCard(
              icon: Icons.play_circle_filled,
              label: 'Total Plays',
              value: _formatNumber(_stats!['total_plays'] ?? 0),
              color: const Color(0xFF1DB954),
            ),
            const SizedBox(height: 12),
            _buildStatCard(
              icon: Icons.access_time,
              label: 'Total Listen Time',
              value:
                  '${_formatNumber(_stats!['total_listen_hours'] ?? 0)} hours',
              subtitle:
                  '${((_stats!['total_listen_hours'] ?? 0) / 24).toStringAsFixed(1)} days',
              color: const Color(0xFF00d4ff),
            ),
            const SizedBox(height: 12),
            _buildStatCard(
              icon: Icons.check_circle,
              label: 'Matched to Library',
              value: '${_stats!['match_rate'] ?? 0}%',
              subtitle:
                  '${_formatNumber(_stats!['matched_plays'] ?? 0)} of ${_formatNumber(_stats!['total_plays'] ?? 0)} plays',
              color: Colors.green,
            ),
            const SizedBox(height: 12),
            _buildStatCard(
              icon: Icons.help_outline,
              label: 'Unmatched Tracks',
              value: _formatNumber(_stats!['unmatched_unique_tracks'] ?? 0),
              subtitle: 'Unique songs not in your library',
              color: Colors.orange,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatCard({
    required IconData icon,
    required String label,
    required String value,
    String? subtitle,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1a2332),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: color.withOpacity(0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(color: Colors.grey, fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatNumber(int number) {
    if (number >= 1000000) {
      return '${(number / 1000000).toStringAsFixed(1)}M';
    } else if (number >= 1000) {
      return '${(number / 1000).toStringAsFixed(1)}K';
    }
    return number.toString();
  }
}

// =====================
// Missing Albums Tab
// =====================

class _MissingAlbumsTab extends StatefulWidget {
  final ApiService apiService;
  final AudioPlayerService audioPlayerService;

  const _MissingAlbumsTab({
    required this.apiService,
    required this.audioPlayerService,
  });

  @override
  State<_MissingAlbumsTab> createState() => _MissingAlbumsTabState();
}

class _MissingAlbumsTabState extends State<_MissingAlbumsTab> {
  List<dynamic> _albums = [];
  bool _isLoading = true;
  String? _error;
  int _currentPage = 1;
  int _totalPages = 1;
  int _totalCount = 0;
  bool _loadingMore = false;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadAlbums();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  Future<void> _loadAlbums() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _currentPage = 1;
    });

    try {
      final response = await widget.apiService.getMissingAlbums(page: 1);
      setState(() {
        _albums = response['albums'] ?? [];
        _totalPages = response['total_pages'] ?? 1;
        _totalCount = response['total'] ?? 0;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _currentPage >= _totalPages) return;

    setState(() {
      _loadingMore = true;
    });

    try {
      final response = await widget.apiService.getMissingAlbums(
        page: _currentPage + 1,
      );
      setState(() {
        _albums.addAll(response['albums'] ?? []);
        _currentPage++;
        _loadingMore = false;
      });
    } catch (e) {
      setState(() {
        _loadingMore = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Error: $_error', style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _loadAlbums, child: const Text('Retry')),
          ],
        ),
      );
    }

    if (_albums.isEmpty) {
      return const Center(
        child: Text(
          'All your Spotify plays are matched!\nGreat library coverage.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey, fontSize: 16),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadAlbums,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            width: double.infinity,
            color: const Color(0xFF0d1b2a),
            child: Text(
              '$_totalCount missing albums',
              style: const TextStyle(color: Colors.grey, fontSize: 14),
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: _albums.length + (_loadingMore ? 1 : 0),
              itemBuilder: (context, index) {
                if (index == _albums.length) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }

                final album = _albums[index];
                return _MissingAlbumTile(
                  rank: index + 1,
                  artist: album['artist'] ?? 'Unknown',
                  albumName: album['album'] ?? 'Unknown Album',
                  listenTime: album['listen_time'] ?? '0m',
                  playCount: album['play_count'] ?? 0,
                  trackCount: album['track_count'] ?? 0,
                  audioPlayerService: widget.audioPlayerService,
                  onLinked: _loadAlbums,
                  onDismissed: _loadAlbums,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _MissingAlbumTile extends StatefulWidget {
  final int rank;
  final String artist;
  final String albumName;
  final String listenTime;
  final int playCount;
  final int trackCount;
  final AudioPlayerService audioPlayerService;
  final VoidCallback? onLinked;
  final VoidCallback? onDismissed;

  const _MissingAlbumTile({
    required this.rank,
    required this.artist,
    required this.albumName,
    required this.listenTime,
    required this.playCount,
    required this.trackCount,
    required this.audioPlayerService,
    this.onLinked,
    this.onDismissed,
  });

  @override
  State<_MissingAlbumTile> createState() => _MissingAlbumTileState();
}

class _MissingAlbumTileState extends State<_MissingAlbumTile> {
  final ApiService _apiService = ApiService();
  String? _coverUrl;
  bool _loadedCover = false;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadCoverArt();
  }

  Future<void> _loadCoverArt() async {
    if (_loadedCover || _isLoading) return;

    setState(() => _isLoading = true);

    // Stagger requests based on rank to avoid rate limiting
    await Future.delayed(Duration(milliseconds: widget.rank * 200));

    if (!mounted) return;

    try {
      final results = await _apiService.searchMusicBrainz(
        widget.artist,
        widget.albumName,
      );

      final matches = results['results'] as List? ?? [];
      if (matches.isNotEmpty && mounted) {
        setState(() {
          _coverUrl = matches[0]['cover_url'];
          _loadedCover = true;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 32,
            child: Text(
              '${widget.rank}',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: widget.rank <= 10
                    ? const Color(0xFF1DB954)
                    : Colors.grey,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: const Color(0xFF1a2332),
              borderRadius: BorderRadius.circular(4),
            ),
            child: _coverUrl != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.network(
                      _coverUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Icon(
                        Icons.album,
                        color: Color(0xFF1DB954),
                        size: 28,
                      ),
                    ),
                  )
                : const Icon(Icons.album, color: Color(0xFF1DB954), size: 28),
          ),
        ],
      ),
      title: Text(
        widget.albumName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        widget.artist,
        style: const TextStyle(color: Colors.grey),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                widget.listenTime,
                style: const TextStyle(
                  color: Color(0xFF1DB954),
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                '${widget.playCount} plays · ${widget.trackCount} tracks',
                style: const TextStyle(color: Colors.grey, fontSize: 11),
              ),
            ],
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.grey),
            color: const Color(0xFF1a2332),
            onSelected: (value) {
              if (value == 'link') {
                _showLinkDialog(context);
              } else if (value == 'dismiss') {
                _showDismissDialog(context);
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'link',
                child: Row(
                  children: [
                    Icon(Icons.link, color: Color(0xFF1DB954), size: 20),
                    SizedBox(width: 12),
                    Text('Link to Library Album'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'dismiss',
                child: Row(
                  children: [
                    Icon(Icons.visibility_off, color: Colors.orange, size: 20),
                    SizedBox(width: 12),
                    Text('Dismiss'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => MissingAlbumDetailScreen(
              artist: widget.artist,
              albumName: widget.albumName,
              audioPlayerService: widget.audioPlayerService,
            ),
          ),
        );
      },
    );
  }

  Future<void> _showLinkDialog(BuildContext context) async {
    final result = await showDialog<int>(
      context: context,
      builder: (context) =>
          _AlbumLinkDialog(artist: widget.artist, albumName: widget.albumName),
    );

    if (result != null && context.mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );

      try {
        final response = await _apiService.linkSpotifyAlbum(
          spotifyArtist: widget.artist,
          spotifyAlbum: widget.albumName == 'Unknown Album'
              ? null
              : widget.albumName,
          libraryAlbumId: result,
        );

        if (!context.mounted) return;
        Navigator.pop(context);

        if (response['success'] == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(response['message'] ?? 'Album linked successfully'),
              backgroundColor: Colors.green,
            ),
          );
          widget.onLinked?.call();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(response['error'] ?? 'Failed to link album'),
              backgroundColor: Colors.red,
            ),
          );
        }
      } catch (e) {
        if (!context.mounted) return;
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _showDismissDialog(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: const Text('Dismiss Album?'),
        content: Text(
          'This will hide "${widget.albumName}" by ${widget.artist} from the missing albums list.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.orange),
            child: const Text('Dismiss'),
          ),
        ],
      ),
    );

    if (confirm == true && context.mounted) {
      try {
        final response = await _apiService.dismissSpotifyAlbum(
          spotifyArtist: widget.artist,
          spotifyAlbum: widget.albumName == 'Unknown Album'
              ? null
              : widget.albumName,
        );

        if (!context.mounted) return;

        if (response['success'] == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(response['message'] ?? 'Album dismissed'),
              backgroundColor: Colors.orange,
            ),
          );
          widget.onDismissed?.call();
        }
      } catch (e) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _showMusicBrainzResults(BuildContext context) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final results = await _apiService.searchMusicBrainz(
        widget.artist,
        widget.albumName,
      );

      if (!context.mounted) return;
      Navigator.pop(context); // Dismiss loading

      final matches = results['results'] as List? ?? [];

      if (matches.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No MusicBrainz results found')),
        );
        return;
      }

      // Update cover art if we found a match
      if (!_loadedCover && matches.isNotEmpty) {
        setState(() {
          _coverUrl = matches[0]['cover_url'];
          _loadedCover = true;
        });
      }

      showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF1a2332),
        isScrollControlled: true,
        builder: (context) => DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) => Column(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'MusicBrainz Results',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF00d4ff),
                      ),
                    ),
                    Text(
                      '${widget.artist} - ${widget.albumName}',
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  itemCount: matches.length,
                  itemBuilder: (context, index) {
                    final match = matches[index];
                    return ListTile(
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Image.network(
                          match['cover_url'] ?? '',
                          width: 50,
                          height: 50,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            width: 50,
                            height: 50,
                            color: const Color(0xFF0d1b2a),
                            child: const Icon(Icons.album, color: Colors.grey),
                          ),
                        ),
                      ),
                      title: Text(match['title'] ?? 'Unknown'),
                      subtitle: Text(
                        '${match['artist']} • ${match['type'] ?? 'Album'}',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                        ),
                      ),
                      trailing: const Icon(
                        Icons.open_in_new,
                        color: Color(0xFF00d4ff),
                      ),
                      onTap: () async {
                        final url = match['url'];
                        if (url != null) {
                          await launchUrlExternal(url);
                        }
                      },
                      onLongPress: () {
                        Clipboard.setData(
                          ClipboardData(text: match['mbid'] ?? ''),
                        );
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Copied MBID: ${match['mbid']}'),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      Navigator.pop(context); // Dismiss loading
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }
}

Future<void> launchUrlExternal(String url) async {
  // Use url_launcher or fallback to process
  try {
    await Process.run('cmd', ['/c', 'start', url]);
  } catch (e) {
    print('Could not launch $url: $e');
  }
}

// =====================
// History Tab
// =====================

class _HistoryTab extends StatefulWidget {
  final ApiService apiService;

  const _HistoryTab({required this.apiService});

  @override
  State<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<_HistoryTab> {
  List<dynamic> _plays = [];
  bool _isLoading = true;
  String? _error;
  String? _selectedYear;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final response = await widget.apiService.getSpotifyHistory(
        limit: 100,
        year: _selectedYear,
      );
      setState(() {
        _plays = response;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Year filter
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildYearChip(null, 'All'),
                ...List.generate(
                  11,
                  (i) => 2025 - i,
                ).map((year) => _buildYearChip(year.toString(), '$year')),
              ],
            ),
          ),
        ),
        Expanded(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Error: $_error',
                        style: const TextStyle(color: Colors.red),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _loadHistory,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : _plays.isEmpty
              ? const Center(
                  child: Text(
                    'No plays found for this period.',
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadHistory,
                  child: ListView.builder(
                    itemCount: _plays.length,
                    itemBuilder: (context, index) {
                      final play = _plays[index];
                      return _HistoryTile(
                        track: play['track'] ?? 'Unknown',
                        artist: play['artist'] ?? 'Unknown',
                        album: play['album'] ?? 'Unknown',
                        timestamp: play['timestamp'] ?? '',
                        duration: play['duration'] ?? '0:00',
                        matched: play['matched'] ?? false,
                        artworkPath: play['artwork_path'],
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildYearChip(String? year, String label) {
    final isSelected = _selectedYear == year;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(label),
        selected: isSelected,
        onSelected: (selected) {
          setState(() {
            _selectedYear = selected ? year : null;
          });
          _loadHistory();
        },
        backgroundColor: const Color(0xFF1a2332),
        selectedColor: const Color(0xFF1DB954),
        labelStyle: TextStyle(color: isSelected ? Colors.black : Colors.white),
        checkmarkColor: Colors.black,
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final String track;
  final String artist;
  final String album;
  final String timestamp;
  final String duration;
  final bool matched;
  final String? artworkPath;

  const _HistoryTile({
    required this.track,
    required this.artist,
    required this.album,
    required this.timestamp,
    required this.duration,
    required this.matched,
    this.artworkPath,
  });

  String _formatTimestamp(String ts) {
    try {
      final dt = DateTime.parse(ts);
      return '${dt.month}/${dt.day}/${dt.year} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (e) {
      return ts;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        width: 50,
        height: 50,
        decoration: BoxDecoration(
          color: const Color(0xFF1a2332),
          borderRadius: BorderRadius.circular(4),
        ),
        child: matched && artworkPath != null
            ? ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.network(
                  '${ApiService.baseUrl}/artwork/${Uri.encodeComponent(artworkPath!)}',
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      const Icon(Icons.music_note, color: Color(0xFF1DB954)),
                ),
              )
            : Icon(
                matched ? Icons.check_circle : Icons.music_note,
                color: matched ? const Color(0xFF1DB954) : Colors.grey,
              ),
      ),
      title: Text(track, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '$artist • $album',
        style: const TextStyle(color: Colors.grey, fontSize: 12),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            duration,
            style: const TextStyle(color: Color(0xFF00d4ff), fontSize: 12),
          ),
          Text(
            _formatTimestamp(timestamp),
            style: const TextStyle(color: Colors.grey, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

// =====================
// Album Link Dialog
// =====================

class _AlbumLinkDialog extends StatefulWidget {
  final String artist;
  final String albumName;

  const _AlbumLinkDialog({required this.artist, required this.albumName});

  @override
  State<_AlbumLinkDialog> createState() => _AlbumLinkDialogState();
}

class _AlbumLinkDialogState extends State<_AlbumLinkDialog> {
  final ApiService _apiService = ApiService();
  final TextEditingController _searchController = TextEditingController();
  List<dynamic> _searchResults = [];
  bool _isLoading = true;
  List<dynamic> _allAlbums = [];

  @override
  void initState() {
    super.initState();
    _loadAllAlbums();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadAllAlbums() async {
    try {
      final albums = await _apiService.getAlbums();
      if (mounted) {
        setState(() {
          _allAlbums = albums
              .map(
                (a) => {
                  'id': a.id,
                  'title': a.title,
                  'artist_name': a.artistName,
                  'artwork_path': a.artworkPath,
                  'song_count': a.songCount,
                },
              )
              .toList();
          _filterAlbums(widget.artist);
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _filterAlbums(String query) {
    if (query.isEmpty) {
      setState(() => _searchResults = _allAlbums);
      return;
    }

    final lowerQuery = query.toLowerCase();
    setState(() {
      _searchResults = _allAlbums.where((album) {
        final title = (album['title'] ?? '').toString().toLowerCase();
        final artist = (album['artist_name'] ?? '').toString().toLowerCase();
        return title.contains(lowerQuery) || artist.contains(lowerQuery);
      }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1a2332),
      child: Container(
        width: 500,
        height: 600,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.link, color: Color(0xFF1DB954)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Link to Library Album',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '${widget.artist} - ${widget.albumName}',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search your library...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: const Color(0xFF0d1b2a),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: _filterAlbums,
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _searchResults.isEmpty
                  ? const Center(
                      child: Text(
                        'No albums found',
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _searchResults.length,
                      itemBuilder: (context, index) {
                        final album = _searchResults[index];
                        return ListTile(
                          leading: Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              color: const Color(0xFF0d1b2a),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: album['artwork_path'] != null
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: Image.network(
                                      '${ApiService.baseUrl}/artwork/${Uri.encodeComponent(album['artwork_path'])}',
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => const Icon(
                                        Icons.album,
                                        color: Color(0xFF1DB954),
                                      ),
                                    ),
                                  )
                                : const Icon(
                                    Icons.album,
                                    color: Color(0xFF1DB954),
                                  ),
                          ),
                          title: Text(
                            album['title'] ?? 'Unknown',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            album['artist_name'] ?? 'Unknown Artist',
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 12,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Text(
                            '${album['song_count'] ?? 0} tracks',
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 11,
                            ),
                          ),
                          onTap: () => Navigator.pop(context, album['id']),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
