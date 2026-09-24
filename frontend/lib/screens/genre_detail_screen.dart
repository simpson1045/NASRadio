import 'package:flutter/material.dart';
import 'dart:io' show Platform;
import '../models/song.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import '../widgets/breadcrumb_bar.dart';
import '../widgets/music_context_menu.dart';
import 'now_playing_screen.dart';
import 'package:cached_network_image/cached_network_image.dart';

class GenreDetailScreen extends StatefulWidget {
  final String genre;
  final int songCount;
  final AudioPlayerService audioPlayerService;
  final String? parentLabel;

  const GenreDetailScreen({
    super.key,
    required this.genre,
    required this.songCount,
    required this.audioPlayerService,
    this.parentLabel,
  });

  @override
  State<GenreDetailScreen> createState() => _GenreDetailScreenState();
}

class _GenreDetailScreenState extends State<GenreDetailScreen> {
  final ApiService _apiService = ApiService();
  List<Song> _songs = [];
  bool _isLoading = true;
  int _total = 0;
  bool _hasMore = true;
  int _offset = 0;
  final int _limit = 100;
  final ScrollController _scrollController = ScrollController();

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  /// Clean up Essentia genre format: "Rock---Alternative Rock" → "Alternative Rock"
  String get _displayGenre {
    if (widget.genre.contains('---')) {
      return widget.genre.split('---').last;
    }
    return widget.genre;
  }

  /// Get the parent genre if sub-genre exists
  String? get _parentGenre {
    if (widget.genre.contains('---')) {
      return widget.genre.split('---').first;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadSongs();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 500) {
      _loadMoreSongs();
    }
  }

  Future<void> _loadSongs() async {
    try {
      final result = await _apiService.getGenreSongs(
        widget.genre,
        limit: _limit,
        offset: 0,
      );

      if (!mounted) return;
      setState(() {
        _songs = result['songs'] as List<Song>;
        _total = result['total'] as int;
        _offset = _songs.length;
        _hasMore = _offset < _total;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _loadMoreSongs() async {
    if (_isLoading || !_hasMore) return;

    try {
      final result = await _apiService.getGenreSongs(
        widget.genre,
        limit: _limit,
        offset: _offset,
      );

      if (!mounted) return;
      setState(() {
        _songs.addAll(result['songs'] as List<Song>);
        _offset = _songs.length;
        _hasMore = _offset < _total;
      });
    } catch (e) {
      // Silently fail on pagination errors
    }
  }

  void _playSong(int index) {
    widget.audioPlayerService.setQueue(_songs, index, sourceType: 'genre');
    NowPlayingScreen.open(
      context,
      audioPlayerService: widget.audioPlayerService,
    );
  }

  void _shuffleAll() {
    if (_songs.isEmpty) return;
    final shuffled = List<Song>.from(_songs)..shuffle();
    widget.audioPlayerService.setQueue(shuffled, 0, sourceType: 'genre');
    NowPlayingScreen.open(
      context,
      audioPlayerService: widget.audioPlayerService,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        controller: _scrollController,
        slivers: [
          SliverAppBar(
            expandedHeight: 200,
            pinned: true,
            backgroundColor: const Color(0xFF0d1b2a),
            title: BreadcrumbBar(items: [
              BreadcrumbItem(
                label: widget.parentLabel ?? 'Genres',
                onTap: () => Navigator.pop(context),
              ),
              BreadcrumbItem(label: _displayGenre),
            ]),
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      _genreColor.withOpacity(0.6),
                      const Color(0xFF0a0e27),
                    ],
                  ),
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(height: 40),
                      Icon(
                        _genreIcon,
                        size: 48,
                        color: Colors.white.withOpacity(0.9),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _displayGenre,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (_parentGenre != null)
                        Text(
                          _parentGenre!,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.6),
                            fontSize: 14,
                          ),
                        ),
                      const SizedBox(height: 4),
                      Text(
                        '$_total songs',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.7),
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Shuffle button
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ElevatedButton.icon(
                onPressed: _shuffleAll,
                icon: const Icon(Icons.shuffle, size: 20),
                label: const Text('Shuffle All'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00d4ff),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ),

          // Songs list
          if (_isLoading)
            const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator()),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  if (index >= _songs.length) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
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
                      style: TextStyle(
                        color: Colors.grey,
                        fontSize: _isMobile ? 12 : 14,
                      ),
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
                    onTap: () => _playSong(index),
                  );
                },
                childCount: _songs.length + (_hasMore ? 1 : 0),
              ),
            ),
        ],
      ),
    );
  }

  /// Pick a color based on the parent genre
  Color get _genreColor {
    final genre = widget.genre.toLowerCase();
    if (genre.contains('rock')) return Colors.red;
    if (genre.contains('pop')) return Colors.pink;
    if (genre.contains('hip') || genre.contains('rap')) return Colors.orange;
    if (genre.contains('electronic') || genre.contains('edm') || genre.contains('dance')) {
      return Colors.cyan;
    }
    if (genre.contains('jazz')) return Colors.amber;
    if (genre.contains('blues')) return Colors.indigo;
    if (genre.contains('metal')) return Colors.grey;
    if (genre.contains('classical')) return Colors.brown;
    if (genre.contains('country')) return Colors.lime;
    if (genre.contains('r&b') || genre.contains('soul') || genre.contains('rnb')) {
      return Colors.purple;
    }
    if (genre.contains('reggae')) return Colors.green;
    if (genre.contains('folk')) return Colors.teal;
    if (genre.contains('punk')) return Colors.deepOrange;
    if (genre.contains('latin')) return Colors.yellow;
    return const Color(0xFF00d4ff);
  }

  /// Pick an icon based on the parent genre
  IconData get _genreIcon {
    final genre = widget.genre.toLowerCase();
    if (genre.contains('rock') || genre.contains('metal') || genre.contains('punk')) {
      return Icons.electric_bolt;
    }
    if (genre.contains('electronic') || genre.contains('edm') || genre.contains('dance')) {
      return Icons.graphic_eq;
    }
    if (genre.contains('classical')) return Icons.piano;
    if (genre.contains('jazz') || genre.contains('blues')) return Icons.music_note;
    if (genre.contains('hip') || genre.contains('rap')) return Icons.mic;
    if (genre.contains('country') || genre.contains('folk')) return Icons.nature;
    if (genre.contains('reggae')) return Icons.wb_sunny;
    return Icons.library_music;
  }
}
