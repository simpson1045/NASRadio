import 'package:flutter/material.dart';
import 'dart:io' show Platform;
import '../models/artist.dart';
import '../models/album.dart';
import '../models/song.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import 'now_playing_screen.dart';
import 'album_detail_screen.dart';
import 'artist_detail_screen.dart';
import 'genre_detail_screen.dart';
import 'year_detail_screen.dart';
import '../widgets/alphabet_scroll_bar.dart';
import '../widgets/music_context_menu.dart';
import '../widgets/settings_dialog.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'rss_feeds_screen.dart';

class LibraryScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;
  final bool showMiniPlayer;

  const LibraryScreen({
    super.key,
    required this.audioPlayerService,
    this.showMiniPlayer = true,
  });

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen>
    with SingleTickerProviderStateMixin {
  final ApiService _apiService = ApiService();
  late TabController _tabController;

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  List<Artist> _artists = [];
  List<Album> _albums = [];
  List<Song> _songs = [];
  bool _isLoading = true;
  String? _error;

  // Lazy loading for songs tab
  bool _songsLoading = false;
  bool _songsLoaded = false;
  int _songsPage = 1;
  int _songsTotalPages = 1;
  bool _songsHasMore = true;
  final ScrollController _songsScrollController = ScrollController();

  // Lazy loading for genres tab
  List<Map<String, dynamic>> _genres = [];
  bool _genresLoading = false;
  bool _genresLoaded = false;

  // Lazy loading for years tab
  List<Map<String, dynamic>> _decades = [];
  List<Map<String, dynamic>> _years = [];
  bool _yearsLoading = false;
  bool _yearsLoaded = false;
  bool _showDecades = true; // Toggle between decades and individual years

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
    _tabController.addListener(_onTabChanged);
    _songsScrollController.addListener(_onSongsScroll);
    _loadData();
  }

  void _onTabChanged() {
    // Load songs only when Songs tab is selected (index 2)
    if (_tabController.index == 2 && !_songsLoaded && !_songsLoading) {
      _loadSongs();
    }
    // Load genres when Genres tab is selected (index 3)
    if (_tabController.index == 3 && !_genresLoaded && !_genresLoading) {
      _loadGenres();
    }
    // Load years when Years tab is selected (index 4)
    if (_tabController.index == 4 && !_yearsLoaded && !_yearsLoading) {
      _loadYears();
    }
  }

  void _onSongsScroll() {
    if (_songsScrollController.position.pixels >=
        _songsScrollController.position.maxScrollExtent - 500) {
      _loadMoreSongs();
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _songsScrollController.removeListener(_onSongsScroll);
    _songsScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    try {
      final artists = await _apiService.getArtists();
      final albums = await _apiService.getAlbums();

      if (!mounted) return;
      setState(() {
        _artists = artists;
        _albums = albums;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _loadSongs() async {
    setState(() {
      _songsLoading = true;
      _songsPage = 1;
      _songs = [];
    });

    try {
      final result = await _apiService.getSongsPaginated(page: 1, perPage: 50);

      if (!mounted) return;
      setState(() {
        _songs = result['songs'] as List<Song>;
        _songsTotalPages = result['total_pages'] as int;
        _songsHasMore = _songsPage < _songsTotalPages;
        _songsLoaded = true;
        _songsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _songsLoading = false;
        print('❌ Failed to load songs: $e');
      });
    }
  }

  Future<void> _loadMoreSongs() async {
    if (_songsLoading || !_songsHasMore) return;

    setState(() {
      _songsLoading = true;
    });

    try {
      final result = await _apiService.getSongsPaginated(
        page: _songsPage + 1,
        perPage: 50,
      );

      if (!mounted) return;
      setState(() {
        _songs.addAll(result['songs'] as List<Song>);
        _songsPage++;
        _songsHasMore = _songsPage < _songsTotalPages;
        _songsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _songsLoading = false;
        print('❌ Failed to load more songs: $e');
      });
    }
  }

  Future<void> _loadGenres() async {
    setState(() {
      _genresLoading = true;
    });

    try {
      final genres = await _apiService.getGenres();

      if (!mounted) return;
      setState(() {
        _genres = genres;
        _genresLoaded = true;
        _genresLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _genresLoading = false;
        print('❌ Failed to load genres: $e');
      });
    }
  }

  Future<void> _loadYears() async {
    setState(() {
      _yearsLoading = true;
    });

    try {
      final futures = await Future.wait([
        _apiService.getDecades(),
        _apiService.getYears(),
      ]);

      if (!mounted) return;
      setState(() {
        _decades = futures[0];
        _years = futures[1];
        _yearsLoaded = true;
        _yearsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _yearsLoading = false;
        print('❌ Failed to load years: $e');
      });
    }
  }

  void _playSong(Song song, int index) {
    widget.audioPlayerService.setQueue(_songs, index, sourceType: 'all_songs');
    NowPlayingScreen.open(
      context,
      audioPlayerService: widget.audioPlayerService,
    );
  }

  /// Clean up Essentia genre format for display
  String _formatGenreName(String genre) {
    if (genre.contains('---')) {
      return genre.split('---').last;
    }
    return genre;
  }

  /// Get parent genre category
  String? _getGenreCategory(String genre) {
    if (genre.contains('---')) {
      return genre.split('---').first;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        backgroundColor: const Color(0xFF0d1b2a),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              _showSettingsDialog();
            },
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          indicatorColor: const Color(0xFF00d4ff),
          labelColor: const Color(0xFF00d4ff),
          unselectedLabelColor: Colors.white70,
          tabAlignment: TabAlignment.center,
          labelPadding: const EdgeInsets.symmetric(horizontal: 12),
          padding: EdgeInsets.zero,
          tabs: const [
            Tab(text: 'Artists'),
            Tab(text: 'Albums'),
            Tab(text: 'Songs'),
            Tab(text: 'Genres'),
            Tab(text: 'Years'),
            Tab(text: 'Pods'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text('Error: $_error'))
          : TabBarView(
              controller: _tabController,
              children: [
                _buildArtistsList(),
                _buildAlbumsList(),
                _buildSongsList(),
                _buildGenresList(),
                _buildYearsList(),
                RssFeedsScreen(
                  audioPlayerService: widget.audioPlayerService,
                  showMiniPlayer: false,
                ),
              ],
            ),
    );
  }

  Widget _buildArtistsList() {
    final scrollController = ScrollController();

    return Stack(
      children: [
        ListView.builder(
          controller: scrollController,
          itemCount: _artists.length,
          itemBuilder: (context, index) {
            final artist = _artists[index];
            return ListTile(
              leading: artist.imagePath != null && artist.imagePath!.isNotEmpty
                  ? ClipOval(
                      child: CachedNetworkImage(
                        imageUrl: _apiService.getArtistImageUrl(artist.id),
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                        placeholder: (context, url) => Container(
                          width: 40,
                          height: 40,
                          color: const Color(0xFF1a2332),
                        ),
                        errorWidget: (context, url, error) => const Icon(
                          Icons.person,
                          size: 40,
                          color: Color(0xFF00d4ff),
                        ),
                      ),
                    )
                  : const Icon(
                      Icons.person,
                      size: 40,
                      color: Color(0xFF00d4ff),
                    ),
              title: Text(artist.name),
              subtitle: Text(
                '${artist.albumCount} albums • ${artist.songCount} songs',
              ),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => ArtistDetailScreen(
                      artistId: artist.id,
                      audioPlayerService: widget.audioPlayerService,
                      parentLabel: 'Library',
                    ),
                  ),
                );
              },
            );
          },
        ),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          child: AlphabetScrollBar(
            scrollController: scrollController,
            items: _artists.map((a) => a.name).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildAlbumsList() {
    final scrollController = ScrollController();

    return Stack(
      children: [
        ListView.builder(
          controller: scrollController,
          itemCount: _albums.length,
          itemBuilder: (context, index) {
            final album = _albums[index];
            return ListTile(
              leading:
                  album.artworkPath != null && album.artworkPath!.isNotEmpty
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: CachedNetworkImage(
                        imageUrl: _apiService.getArtworkUrl(album.id),
                        width: 50,
                        height: 50,
                        fit: BoxFit.cover,
                        placeholder: (context, url) => Container(
                          width: 50,
                          height: 50,
                          color: const Color(0xFF1a2332),
                        ),
                        errorWidget: (context, url, error) => const Icon(
                          Icons.album,
                          size: 40,
                          color: Color(0xFF00d4ff),
                        ),
                      ),
                    )
                  : const Icon(Icons.album, size: 40, color: Color(0xFF00d4ff)),
              title: Text(album.title),
              subtitle: Text(
                '${album.artistName} • ${album.year ?? "Unknown"} • ${album.songCount} songs',
              ),
              trailing: MusicContextMenu(
                itemType: 'album',
                itemId: album.id,
                itemName: album.title,
                audioPlayerService: widget.audioPlayerService,
              ),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => AlbumDetailScreen(
                      albumId: album.id,
                      audioPlayerService: widget.audioPlayerService,
                      artistName: album.artistName,
                      parentLabel: 'Library',
                    ),
                  ),
                );
              },
            );
          },
        ),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          child: AlphabetScrollBar(
            scrollController: scrollController,
            items: _albums.map((a) => a.title).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildSongsList() {
    if (_songsLoading && _songs.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!_songsLoaded && _songs.isEmpty) {
      return Center(
        child: GestureDetector(
          onTap: _loadSongs,
          child: const Padding(
            padding: EdgeInsets.all(8),
            child: Text(
              'Tap to load songs',
              style: TextStyle(color: Colors.grey),
            ),
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _songsScrollController,
      itemCount: _songs.length + (_songsHasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _songs.length) {
          return const Padding(
            padding: EdgeInsets.all(16.0),
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final song = _songs[index];
        return ListTile(
          contentPadding: EdgeInsets.symmetric(
            horizontal: _isMobile ? 12 : 16,
            vertical: _isMobile ? 2 : 0,
          ),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: CachedNetworkImage(
              imageUrl: _apiService.getArtworkUrl(song.albumId),
              width: _isMobile ? 45 : 50,
              height: _isMobile ? 45 : 50,
              fit: BoxFit.cover,
              placeholder: (context, url) => Container(
                width: _isMobile ? 45 : 50,
                height: _isMobile ? 45 : 50,
                color: const Color(0xFF1a2332),
              ),
              errorWidget: (context, url, error) => Container(
                width: _isMobile ? 45 : 50,
                height: _isMobile ? 45 : 50,
                decoration: BoxDecoration(
                  color: const Color(0xFF0d1b2a),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Icon(
                  Icons.music_note,
                  color: Color(0xFF00d4ff),
                  size: 24,
                ),
              ),
            ),
          ),
          title: Text(
            song.title,
            style: TextStyle(fontSize: _isMobile ? 14 : 16),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${song.artistName} • ${song.albumTitle}',
            style: TextStyle(color: Colors.grey, fontSize: _isMobile ? 12 : 14),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: _isMobile
              ? MusicContextMenu(
                  itemType: 'song',
                  itemId: song.id,
                  itemName: song.title,
                  audioPlayerService: widget.audioPlayerService,
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(song.durationFormatted),
                    MusicContextMenu(
                      itemType: 'song',
                      itemId: song.id,
                      itemName: song.title,
                      audioPlayerService: widget.audioPlayerService,
                    ),
                  ],
                ),
          onTap: () => _playSong(song, index),
        );
      },
    );
  }

  // ─── Genres Tab ───────────────────────────────────────────────

  Widget _buildGenresList() {
    if (_genresLoading && _genres.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!_genresLoaded && _genres.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.library_music, size: 48, color: Colors.white.withOpacity(0.3)),
            const SizedBox(height: 12),
            Text(
              'Genres require Essentia audio analysis',
              style: TextStyle(color: Colors.white.withOpacity(0.5)),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _loadGenres,
              child: const Text(
                'Load Genres',
                style: TextStyle(color: Color(0xFF00d4ff)),
              ),
            ),
          ],
        ),
      );
    }

    if (_genres.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.library_music, size: 48, color: Colors.white.withOpacity(0.3)),
            const SizedBox(height: 12),
            Text(
              'No genres found',
              style: TextStyle(color: Colors.white.withOpacity(0.5)),
            ),
            const SizedBox(height: 4),
            Text(
              'Run audio analysis in Settings to detect genres',
              style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 12),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _genres.length,
      itemBuilder: (context, index) {
        final genre = _genres[index];
        final genreName = genre['genre'] as String;
        final count = genre['count'] as int;
        final displayName = _formatGenreName(genreName);
        final category = _getGenreCategory(genreName);

        return ListTile(
          leading: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: _genreColor(genreName).withOpacity(0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              _genreIcon(genreName),
              color: _genreColor(genreName),
              size: 22,
            ),
          ),
          title: Text(
            displayName,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            category != null
                ? '$category • $count songs'
                : '$count songs',
            style: TextStyle(
              color: Colors.white.withOpacity(0.5),
              fontSize: 12,
            ),
          ),
          trailing: const Icon(
            Icons.chevron_right,
            color: Colors.white38,
          ),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => GenreDetailScreen(
                  genre: genreName,
                  songCount: count,
                  audioPlayerService: widget.audioPlayerService,
                  parentLabel: 'Library',
                ),
              ),
            );
          },
        );
      },
    );
  }

  Color _genreColor(String genre) {
    final g = genre.toLowerCase();
    if (g.contains('rock')) return Colors.red;
    if (g.contains('pop')) return Colors.pink;
    if (g.contains('hip') || g.contains('rap')) return Colors.orange;
    if (g.contains('electronic') || g.contains('edm') || g.contains('dance')) {
      return Colors.cyan;
    }
    if (g.contains('jazz')) return Colors.amber;
    if (g.contains('blues')) return Colors.indigo;
    if (g.contains('metal')) return Colors.grey;
    if (g.contains('classical')) return Colors.brown;
    if (g.contains('country')) return Colors.lime;
    if (g.contains('r&b') || g.contains('soul') || g.contains('rnb')) {
      return Colors.purple;
    }
    if (g.contains('reggae')) return Colors.green;
    if (g.contains('folk')) return Colors.teal;
    if (g.contains('punk')) return Colors.deepOrange;
    if (g.contains('latin')) return Colors.yellow;
    return const Color(0xFF00d4ff);
  }

  IconData _genreIcon(String genre) {
    final g = genre.toLowerCase();
    if (g.contains('rock') || g.contains('metal') || g.contains('punk')) {
      return Icons.electric_bolt;
    }
    if (g.contains('electronic') || g.contains('edm') || g.contains('dance')) {
      return Icons.graphic_eq;
    }
    if (g.contains('classical')) return Icons.piano;
    if (g.contains('jazz') || g.contains('blues')) return Icons.music_note;
    if (g.contains('hip') || g.contains('rap')) return Icons.mic;
    if (g.contains('country') || g.contains('folk')) return Icons.nature;
    if (g.contains('reggae')) return Icons.wb_sunny;
    return Icons.library_music;
  }

  // ─── Years Tab ────────────────────────────────────────────────

  Widget _buildYearsList() {
    if (_yearsLoading && _decades.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (!_yearsLoaded && _decades.isEmpty) {
      return Center(
        child: TextButton(
          onPressed: _loadYears,
          child: const Text(
            'Load Years',
            style: TextStyle(color: Color(0xFF00d4ff)),
          ),
        ),
      );
    }

    return Column(
      children: [
        // Decades/Years toggle
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              _buildToggleChip('Decades', _showDecades, () {
                setState(() => _showDecades = true);
              }),
              const SizedBox(width: 8),
              _buildToggleChip('Years', !_showDecades, () {
                setState(() => _showDecades = false);
              }),
            ],
          ),
        ),
        // List
        Expanded(
          child: _showDecades ? _buildDecadesList() : _buildIndividualYearsList(),
        ),
      ],
    );
  }

  Widget _buildToggleChip(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF00d4ff).withOpacity(0.2)
              : Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? const Color(0xFF00d4ff)
                : Colors.white.withOpacity(0.1),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? const Color(0xFF00d4ff) : Colors.white70,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  Widget _buildDecadesList() {
    if (_decades.isEmpty) {
      return Center(
        child: Text(
          'No year data available',
          style: TextStyle(color: Colors.white.withOpacity(0.5)),
        ),
      );
    }

    return ListView.builder(
      itemCount: _decades.length,
      itemBuilder: (context, index) {
        final decade = _decades[index];
        final decadeYear = decade['decade'] as int;
        final albumCount = decade['album_count'] as int;
        final songCount = (decade['song_count'] ?? 0) as int;

        return ListTile(
          leading: Container(
            width: 56,
            height: 44,
            decoration: BoxDecoration(
              color: _decadeColor(decadeYear).withOpacity(0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: Text(
                '${decadeYear}s',
                style: TextStyle(
                  color: _decadeColor(decadeYear),
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),
          ),
          title: Text(
            '${decadeYear}s',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            '$albumCount albums • $songCount songs',
            style: TextStyle(
              color: Colors.white.withOpacity(0.5),
              fontSize: 12,
            ),
          ),
          trailing: const Icon(
            Icons.chevron_right,
            color: Colors.white38,
          ),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => YearDetailScreen(
                  year: decadeYear,
                  isDecade: true,
                  audioPlayerService: widget.audioPlayerService,
                  parentLabel: 'Library',
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildIndividualYearsList() {
    if (_years.isEmpty) {
      return Center(
        child: Text(
          'No year data available',
          style: TextStyle(color: Colors.white.withOpacity(0.5)),
        ),
      );
    }

    return ListView.builder(
      itemCount: _years.length,
      itemBuilder: (context, index) {
        final yearData = _years[index];
        final year = yearData['year'] as int;
        final albumCount = yearData['album_count'] as int;
        final songCount = (yearData['song_count'] ?? 0) as int;

        return ListTile(
          leading: Container(
            width: 56,
            height: 44,
            decoration: BoxDecoration(
              color: _decadeColor((year ~/ 10) * 10).withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: Text(
                '$year',
                style: TextStyle(
                  color: _decadeColor((year ~/ 10) * 10),
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),
          ),
          title: Text(
            '$year',
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            '$albumCount albums • $songCount songs',
            style: TextStyle(
              color: Colors.white.withOpacity(0.5),
              fontSize: 12,
            ),
          ),
          trailing: const Icon(
            Icons.chevron_right,
            color: Colors.white38,
          ),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => YearDetailScreen(
                  year: year,
                  isDecade: false,
                  audioPlayerService: widget.audioPlayerService,
                  parentLabel: 'Library',
                ),
              ),
            );
          },
        );
      },
    );
  }

  Color _decadeColor(int decade) {
    switch (decade) {
      case 2020: return const Color(0xFF00d4ff);
      case 2010: return Colors.purple;
      case 2000: return Colors.blue;
      case 1990: return Colors.teal;
      case 1980: return Colors.pink;
      case 1970: return Colors.orange;
      case 1960: return Colors.amber;
      case 1950: return Colors.brown;
      default: return Colors.grey;
    }
  }

  void _showSettingsDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return SettingsDialog(
          apiService: _apiService,
          onRescanComplete: _loadData,
          audioPlayerService: widget.audioPlayerService,
        );
      },
    );
  }
}
