import 'package:flutter/material.dart';
import 'dart:io' show Platform;
import '../models/album.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import '../widgets/breadcrumb_bar.dart';
import '../widgets/music_context_menu.dart';
import 'album_detail_screen.dart';
import 'package:cached_network_image/cached_network_image.dart';

class YearDetailScreen extends StatefulWidget {
  final int year;
  final bool isDecade; // true = show all albums from decade (e.g. 1990-1999)
  final AudioPlayerService audioPlayerService;
  final String? parentLabel;

  const YearDetailScreen({
    super.key,
    required this.year,
    required this.audioPlayerService,
    this.isDecade = false,
    this.parentLabel,
  });

  @override
  State<YearDetailScreen> createState() => _YearDetailScreenState();
}

class _YearDetailScreenState extends State<YearDetailScreen> {
  final ApiService _apiService = ApiService();
  List<Album> _albums = [];
  bool _isLoading = true;

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  String get _title {
    if (widget.isDecade) {
      return '${widget.year}s';
    }
    return widget.year.toString();
  }

  @override
  void initState() {
    super.initState();
    _loadAlbums();
  }

  Future<void> _loadAlbums() async {
    try {
      List<Album> albums;
      if (widget.isDecade) {
        albums = await _apiService.getAlbumsByDecade(widget.year);
      } else {
        albums = await _apiService.getAlbumsByYear(widget.year);
      }

      if (!mounted) return;
      setState(() {
        _albums = albums;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 180,
            pinned: true,
            backgroundColor: const Color(0xFF0d1b2a),
            title: BreadcrumbBar(items: [
              BreadcrumbItem(
                label: widget.parentLabel ?? 'Years',
                onTap: () => Navigator.pop(context),
              ),
              BreadcrumbItem(label: _title),
            ]),
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      _decadeColor.withOpacity(0.5),
                      const Color(0xFF0a0e27),
                    ],
                  ),
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(height: 40),
                      Text(
                        _title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 48,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _isLoading
                            ? 'Loading...'
                            : '${_albums.length} albums',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.7),
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Albums grid
          if (_isLoading)
            const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_albums.isEmpty)
            const SliverFillRemaining(
              child: Center(
                child: Text(
                  'No albums found',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: _isMobile ? 2 : 4,
                  childAspectRatio: 0.75,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final album = _albums[index];
                    return _buildAlbumCard(album);
                  },
                  childCount: _albums.length,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAlbumCard(Album album) {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => AlbumDetailScreen(
              albumId: album.id,
              audioPlayerService: widget.audioPlayerService,
              artistName: album.artistName,
              parentLabel: _title,
            ),
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Album artwork
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: album.artworkPath != null && album.artworkPath!.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: _apiService.getArtworkUrl(album.id),
                      width: double.infinity,
                      fit: BoxFit.cover,
                      placeholder: (context, url) => Container(
                        color: const Color(0xFF1a2332),
                        child: const Center(
                          child: Icon(
                            Icons.album,
                            color: Color(0xFF00d4ff),
                            size: 40,
                          ),
                        ),
                      ),
                      errorWidget: (context, url, error) => Container(
                        color: const Color(0xFF1a2332),
                        child: const Center(
                          child: Icon(
                            Icons.album,
                            color: Color(0xFF00d4ff),
                            size: 40,
                          ),
                        ),
                      ),
                    )
                  : Container(
                      color: const Color(0xFF1a2332),
                      child: const Center(
                        child: Icon(
                          Icons.album,
                          color: Color(0xFF00d4ff),
                          size: 40,
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 6),
          // Album title
          Text(
            album.title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          // Artist name
          Text(
            album.artistName,
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withOpacity(0.6),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  /// Color tint based on decade
  Color get _decadeColor {
    final decade = (widget.year ~/ 10) * 10;
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
}
