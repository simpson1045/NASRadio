import 'dart:async';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import '../widgets/mouse_back_button_wrapper.dart';
import 'missing_album_detail_screen.dart';
import 'prowlarr_search_screen.dart';

class MissingAlbumsScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;

  const MissingAlbumsScreen({super.key, required this.audioPlayerService});

  @override
  State<MissingAlbumsScreen> createState() => _MissingAlbumsScreenState();
}

class _MissingAlbumsScreenState extends State<MissingAlbumsScreen> {
  final ApiService _apiService = ApiService();

  bool _isLoading = true;
  bool _isRelinking = false;
  String? _error;
  List<Map<String, dynamic>> _missingAlbums = [];
  Map<String, dynamic> _stats = {};
  String _searchQuery = '';
  String _sortBy = 'artist'; // 'artist', 'album', 'tracks'

  List<Map<String, dynamic>> get _filteredAlbums {
    var albums = _missingAlbums;

    // Filter by search query
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      albums = albums.where((album) {
        final artistMatch = (album['artist_name'] ?? '')
            .toString()
            .toLowerCase()
            .contains(query);
        final albumMatch = (album['album_name'] ?? '')
            .toString()
            .toLowerCase()
            .contains(query);
        return artistMatch || albumMatch;
      }).toList();
    }

    // Sort
    albums = List.from(albums);
    switch (_sortBy) {
      case 'artist':
        albums.sort(
          (a, b) => (a['artist_name'] ?? '').toString().compareTo(
            (b['artist_name'] ?? '').toString(),
          ),
        );
        break;
      case 'album':
        albums.sort(
          (a, b) => (a['album_name'] ?? '').toString().compareTo(
            (b['album_name'] ?? '').toString(),
          ),
        );
        break;
      case 'tracks':
        albums.sort(
          (a, b) => (b['track_count'] ?? 0).compareTo(a['track_count'] ?? 0),
        );
        break;
    }

    return albums;
  }

  @override
  void initState() {
    super.initState();
    _loadMissingAlbums();
  }

  Future<void> _loadMissingAlbums() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final response = await _apiService.getAggregatedMissingAlbums();

      if (response['success'] == true) {
        setState(() {
          _missingAlbums = List<Map<String, dynamic>>.from(
            response['missing_albums'] ?? [],
          );
          _stats = response['stats'] ?? {};
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = response['error'] ?? 'Failed to load missing albums';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _relinkMissingSongs() async {
    setState(() {
      _isRelinking = true;
    });

    try {
      final response = await _apiService.relinkMissingPlaylistSongs();

      if (mounted) {
        final linked = response['linked'] ?? 0;
        final checked = response['checked'] ?? 0;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              linked > 0
                  ? 'Linked $linked of $checked missing tracks to your library!'
                  : 'No new matches found ($checked tracks checked)',
            ),
            backgroundColor: linked > 0 ? Colors.green : Colors.orange,
            duration: const Duration(seconds: 4),
          ),
        );

        // Refresh the list if any were linked
        if (linked > 0) {
          _loadMissingAlbums();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isRelinking = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseBackButtonWrapper(
      child: Scaffold(
        backgroundColor: const Color(0xFF0d1b2a),
        appBar: AppBar(
          title: const Text('Missing Albums'),
          backgroundColor: const Color(0xFF0d1b2a),
          actions: [
            // Relink button
            IconButton(
              icon: _isRelinking
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF00d4ff),
                      ),
                    )
                  : const Icon(Icons.link),
              onPressed: _isRelinking ? null : _relinkMissingSongs,
              tooltip: 'Re-link downloaded albums',
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _loadMissingAlbums,
              tooltip: 'Refresh',
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.sort),
              tooltip: 'Sort by',
              color: const Color(0xFF1a2332),
              onSelected: (value) {
                setState(() => _sortBy = value);
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'artist',
                  child: Row(
                    children: [
                      Icon(
                        Icons.person,
                        color: _sortBy == 'artist'
                            ? const Color(0xFF00d4ff)
                            : Colors.grey,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Sort by Artist',
                        style: TextStyle(
                          color: _sortBy == 'artist'
                              ? const Color(0xFF00d4ff)
                              : Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'album',
                  child: Row(
                    children: [
                      Icon(
                        Icons.album,
                        color: _sortBy == 'album'
                            ? const Color(0xFF00d4ff)
                            : Colors.grey,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Sort by Album',
                        style: TextStyle(
                          color: _sortBy == 'album'
                              ? const Color(0xFF00d4ff)
                              : Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'tracks',
                  child: Row(
                    children: [
                      Icon(
                        Icons.music_note,
                        color: _sortBy == 'tracks'
                            ? const Color(0xFF00d4ff)
                            : Colors.grey,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Sort by Track Count',
                        style: TextStyle(
                          color: _sortBy == 'tracks'
                              ? const Color(0xFF00d4ff)
                              : Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? _buildErrorView()
                  : _buildContent(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 48),
          const SizedBox(height: 16),
          Text(
            _error ?? 'Unknown error',
            style: const TextStyle(color: Colors.red),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _loadMissingAlbums,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_missingAlbums.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.check_circle_outline,
              size: 80,
              color: Colors.green.shade400,
            ),
            const SizedBox(height: 16),
            const Text(
              'No missing albums!',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'All your Spotify playlist songs are in your library',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // Stats header
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1a2332),
            border: Border(
              bottom: BorderSide(color: Colors.white.withOpacity(0.1)),
            ),
          ),
          child: Column(
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final isNarrow = constraints.maxWidth < 400;
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildStatCard(
                        icon: Icons.album,
                        value: '${_stats['total_albums'] ?? 0}',
                        label: 'Albums',
                        color: Colors.orange,
                        compact: isNarrow,
                      ),
                      _buildStatCard(
                        icon: Icons.music_note,
                        value: '${_stats['total_tracks'] ?? 0}',
                        label: 'Tracks',
                        color: const Color(0xFF1DB954),
                        compact: isNarrow,
                      ),
                      _buildStatCard(
                        icon: Icons.person,
                        value: '${_stats['unique_artists'] ?? 0}',
                        label: 'Artists',
                        color: const Color(0xFF00d4ff),
                        compact: isNarrow,
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),
              // Search bar
              TextField(
                decoration: InputDecoration(
                  hintText: 'Search missing albums...',
                  prefixIcon: const Icon(
                    Icons.search,
                    color: Color(0xFF00d4ff),
                  ),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, color: Colors.grey),
                          onPressed: () {
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: const Color(0xFF0d1b2a),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (value) {
                  setState(() => _searchQuery = value);
                },
              ),
            ],
          ),
        ),
        // Album list
        Expanded(
          child: _filteredAlbums.isEmpty
              ? Center(
                  child: Text(
                    'No albums match "$_searchQuery"',
                    style: const TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  itemCount: _filteredAlbums.length,
                  itemBuilder: (context, index) {
                    final album = _filteredAlbums[index];
                    return _buildAlbumTile(album);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildStatCard({
    required IconData icon,
    required String value,
    required String label,
    required Color color,
    bool compact = false,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 12 : 20,
        vertical: compact ? 8 : 12,
      ),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: compact ? 20 : 24),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: compact ? 18 : 24,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: compact ? 10 : 12,
              color: color.withOpacity(0.8),
            ),
          ),
        ],
      ),
    );
  }

  void _showLinkTrackDialog(Map<String, dynamic> album) {
    final artistName = album['artist_name'] ?? 'Unknown Artist';
    final albumName = album['album_name'] ?? 'Unknown Album';
    final sampleTracks = List<String>.from(album['sample_tracks'] ?? []);

    showDialog(
      context: context,
      builder: (context) => _LinkTrackDialog(
        artistName: artistName,
        albumName: albumName,
        tracks: sampleTracks,
        apiService: _apiService,
        onLinked: () {
          _loadMissingAlbums();
        },
      ),
    );
  }

  Widget _buildAlbumTile(Map<String, dynamic> album) {
    final artistName = album['artist_name'] ?? 'Unknown Artist';
    final albumName = album['album_name'] ?? 'Unknown Album';
    final trackCount = album['track_count'] ?? 0;
    final playlists = album['playlists'] as List? ?? [];
    final sampleTracks = album['sample_tracks'] as List? ?? [];

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: const Color(0xFF1a2332),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            // Album placeholder with icon
            Container(
              width: 70,
              height: 70,
              decoration: BoxDecoration(
                color: const Color(0xFF0d1b2a),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Colors.orange.withOpacity(0.3),
                  width: 2,
                ),
              ),
              child: const Icon(Icons.album, color: Colors.orange, size: 36),
            ),
            const SizedBox(width: 12),
            // Album info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    albumName,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    artistName,
                    style: const TextStyle(
                      fontSize: 14,
                      color: Color(0xFF1DB954),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  // Track count and playlist info
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '$trackCount tracks missing',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.orange,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (playlists.isNotEmpty)
                        Expanded(
                          child: Text(
                            'in ${playlists.length} playlist${playlists.length > 1 ? 's' : ''}',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey.shade500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                  // Sample tracks preview
                  if (sampleTracks.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      sampleTracks.take(3).join(', '),
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey.shade600,
                        fontStyle: FontStyle.italic,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            // Context menu
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: Colors.grey),
              color: const Color(0xFF1a2332),
              onSelected: (value) {
                switch (value) {
                  case 'details':
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => MissingAlbumDetailScreen(
                          artist: artistName,
                          albumName: albumName,
                          audioPlayerService: widget.audioPlayerService,
                        ),
                      ),
                    ).then((_) => _loadMissingAlbums());
                    break;
                  case 'prowlarr':
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => ProwlarrSearchScreen(
                          audioPlayerService: widget.audioPlayerService,
                          initialQuery: '$artistName $albumName',
                        ),
                      ),
                    );
                    break;
                  case 'link':
                    _showLinkTrackDialog(album);
                    break;
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'details',
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.white70, size: 20),
                      SizedBox(width: 12),
                      Text(
                        'View Details',
                        style: TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'prowlarr',
                  child: Row(
                    children: [
                      Icon(Icons.search, color: Colors.white70, size: 20),
                      SizedBox(width: 12),
                      Text(
                        'Search Prowlarr',
                        style: TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'link',
                  child: Row(
                    children: [
                      Icon(Icons.link, color: Color(0xFF00d4ff), size: 20),
                      SizedBox(width: 12),
                      Text(
                        'Link to Library',
                        style: TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// Dialog for linking a track to library
class _LinkTrackDialog extends StatefulWidget {
  final String artistName;
  final String albumName;
  final List<String> tracks;
  final ApiService apiService;
  final VoidCallback onLinked;

  const _LinkTrackDialog({
    required this.artistName,
    required this.albumName,
    required this.tracks,
    required this.apiService,
    required this.onLinked,
  });

  @override
  State<_LinkTrackDialog> createState() => _LinkTrackDialogState();
}

class _LinkTrackDialogState extends State<_LinkTrackDialog> {
  String? _selectedTrack;
  bool _isSearching = false;
  List<Map<String, dynamic>> _searchResults = [];
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  int? _expandedSongIndex;
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    // Auto-select first track if only one
    if (widget.tracks.length == 1) {
      _selectedTrack = widget.tracks.first;
      _searchController.text = _selectedTrack!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _searchLibrary(_selectedTrack!);
      });
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _searchLibrary(String query) async {
    if (query.isEmpty) {
      setState(() => _searchResults = []);
      return;
    }

    setState(() => _isSearching = true);

    try {
      final response = await widget.apiService.searchLibrarySong(query);
      if (mounted) {
        setState(() {
          _searchResults = List<Map<String, dynamic>>.from(
            response['songs'] ?? [],
          );
          _isSearching = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSearching = false);
      }
    }
  }

  Future<void> _linkToSong(Map<String, dynamic> song) async {
    if (_selectedTrack == null) return;

    try {
      await widget.apiService.linkPlaylistSongToLibrary(
        spotifyArtist: widget.artistName,
        spotifyTrack: _selectedTrack!,
        spotifyAlbum: widget.albumName,
        librarySongId: song['id'],
      );

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Linked '$_selectedTrack' to '${song['title']}'"),
            backgroundColor: Colors.green,
          ),
        );
        widget.onLinked();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  String _formatDuration(int? seconds) {
    if (seconds == null) return '';
    final mins = seconds ~/ 60;
    final secs = seconds % 60;
    return '$mins:${secs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isNarrow = screenWidth < 500;

    return Dialog(
      backgroundColor: const Color(0xFF1a2332),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: EdgeInsets.symmetric(
        horizontal: isNarrow ? 16 : 40,
        vertical: 24,
      ),
      child: Container(
        width: isNarrow ? double.infinity : 500,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        padding: EdgeInsets.all(isNarrow ? 16 : 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                const Icon(Icons.link, color: Color(0xFF00d4ff), size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Link to Library',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      Text(
                        'Find the track in your library',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade400,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.grey),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Track selection (if multiple tracks)
            if (widget.tracks.length > 1) ...[
              const Text(
                'Select track to link:',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(maxHeight: 120),
                decoration: BoxDecoration(
                  color: const Color(0xFF0d1b2a),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  itemCount: widget.tracks.length,
                  itemBuilder: (context, index) {
                    final track = widget.tracks[index];
                    final isSelected = _selectedTrack == track;
                    return ListTile(
                      dense: true,
                      selected: isSelected,
                      selectedTileColor: const Color(
                        0xFF00d4ff,
                      ).withOpacity(0.1),
                      leading: Icon(
                        isSelected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        color: isSelected
                            ? const Color(0xFF00d4ff)
                            : Colors.grey,
                        size: 20,
                      ),
                      title: Text(
                        track,
                        style: TextStyle(
                          color: isSelected
                              ? const Color(0xFF00d4ff)
                              : Colors.white,
                          fontSize: 14,
                        ),
                      ),
                      onTap: () {
                        setState(() {
                          _selectedTrack = track;
                          _searchController.text = track;
                          _searchQuery = track;
                        });
                        _searchLibrary(track);
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Search field
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search your library...',
                prefixIcon: const Icon(Icons.search, color: Color(0xFF00d4ff)),
                suffixIcon: _isSearching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : null,
                filled: true,
                fillColor: const Color(0xFF0d1b2a),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
              style: const TextStyle(color: Colors.white),
              onChanged: (value) {
                _searchQuery = value;

                // Cancel previous timer
                _debounceTimer?.cancel();

                // Start new timer (500ms delay)
                _debounceTimer = Timer(const Duration(milliseconds: 500), () {
                  _searchLibrary(value);
                });
              },
              onSubmitted: _searchLibrary,
            ),
            const SizedBox(height: 12),

            // Search results
            Flexible(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF0d1b2a),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _searchResults.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _searchQuery.isEmpty
                                    ? Icons.search
                                    : Icons.music_off,
                                color: Colors.grey.shade600,
                                size: 40,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _searchQuery.isEmpty
                                    ? 'Search for a track'
                                    : 'No matches found',
                                style: TextStyle(color: Colors.grey.shade500),
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: _searchResults.length,
                        itemBuilder: (context, index) {
                          final song = _searchResults[index];
                          final isExpanded = _expandedSongIndex == index;
                          return InkWell(
                            onTap: () {
                              setState(() {
                                _expandedSongIndex = isExpanded ? null : index;
                              });
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: 45,
                                    height: 45,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF1a2332),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: song['artwork_path'] != null
                                        ? ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                            child: Image.network(
                                              '${ApiService.baseUrl}/artwork/${song['album_id']}',
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, __, ___) =>
                                                  const Icon(
                                                    Icons.music_note,
                                                    color: Colors.grey,
                                                  ),
                                            ),
                                          )
                                        : const Icon(
                                            Icons.music_note,
                                            color: Colors.grey,
                                          ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          song['title'] ?? '',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 14,
                                          ),
                                          maxLines: isExpanded ? null : 1,
                                          overflow: isExpanded
                                              ? null
                                              : TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          '${song['artist_name']} • ${song['album_title']}',
                                          style: TextStyle(
                                            color: Colors.grey.shade400,
                                            fontSize: 12,
                                          ),
                                          maxLines: isExpanded ? null : 1,
                                          overflow: isExpanded
                                              ? null
                                              : TextOverflow.ellipsis,
                                        ),
                                        if (isExpanded) ...[
                                          const SizedBox(height: 8),
                                          Row(
                                            children: [
                                              Text(
                                                _formatDuration(
                                                  song['duration'],
                                                ),
                                                style: TextStyle(
                                                  color: Colors.grey.shade500,
                                                  fontSize: 12,
                                                ),
                                              ),
                                              const Spacer(),
                                              TextButton.icon(
                                                onPressed:
                                                    _selectedTrack != null
                                                    ? () => _linkToSong(song)
                                                    : null,
                                                icon: const Icon(
                                                  Icons.add_circle,
                                                  color: Color(0xFF1DB954),
                                                  size: 20,
                                                ),
                                                label: const Text(
                                                  'Link Track',
                                                  style: TextStyle(
                                                    color: Color(0xFF1DB954),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  if (!isExpanded)
                                    Icon(
                                      Icons.expand_more,
                                      color: Colors.grey.shade600,
                                      size: 20,
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
