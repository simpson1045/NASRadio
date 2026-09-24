import 'package:flutter/material.dart';
import '../models/album.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import '../widgets/mouse_back_button_wrapper.dart';
import 'album_detail_screen.dart';
import 'package:cached_network_image/cached_network_image.dart';

class RecentlyAddedScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;

  const RecentlyAddedScreen({super.key, required this.audioPlayerService});

  @override
  State<RecentlyAddedScreen> createState() => _RecentlyAddedScreenState();
}

class _RecentlyAddedScreenState extends State<RecentlyAddedScreen> {
  final ApiService _apiService = ApiService();
  List<Album> _albums = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadRecentlyAdded();
  }

  Future<void> _loadRecentlyAdded() async {
    try {
      final response = await _apiService.getRecentlyAdded(days: 30, limit: 100);
      final albumsData = response['albums'] as List;

      setState(() {
        _albums = albumsData.map((json) => Album.fromJson(json)).toList();
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  String _formatDate(String? dateStr) {
    if (dateStr == null) return '';
    try {
      final date = DateTime.parse(dateStr);
      final now = DateTime.now();
      final diff = now.difference(date);

      if (diff.inDays == 0) {
        return 'Today';
      } else if (diff.inDays == 1) {
        return 'Yesterday';
      } else if (diff.inDays < 7) {
        return '${diff.inDays} days ago';
      } else if (diff.inDays < 14) {
        return '1 week ago';
      } else if (diff.inDays < 30) {
        return '${(diff.inDays / 7).floor()} weeks ago';
      } else {
        return '${date.month}/${date.day}/${date.year}';
      }
    } catch (e) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseBackButtonWrapper(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Recently Added'),
          backgroundColor: const Color(0xFF0d1b2a),
        ),
        body: Column(
          children: [
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(child: Text('Error: $_error'))
                  : _albums.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.library_music,
                            size: 64,
                            color: Colors.grey,
                          ),
                          SizedBox(height: 16),
                          Text(
                            'No albums added in the last 30 days',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.all(16),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 4,
                            childAspectRatio: 0.75,
                            crossAxisSpacing: 16,
                            mainAxisSpacing: 16,
                          ),
                      itemCount: _albums.length,
                      itemBuilder: (context, index) {
                        final album = _albums[index];
                        return GestureDetector(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => AlbumDetailScreen(
                                  albumId: album.id,
                                  audioPlayerService: widget.audioPlayerService,
                                  parentLabel: 'Recently Added',
                                ),
                              ),
                            );
                          },
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AspectRatio(
                                aspectRatio: 1,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: album.artworkPath != null
                                      ? CachedNetworkImage(
                                          imageUrl: _apiService.getArtworkUrl(
                                            album.id,
                                          ),
                                          fit: BoxFit.cover,
                                          width: double.infinity,
                                          placeholder: (context, url) =>
                                              Container(
                                                color: const Color(0xFF1a2332),
                                              ),
                                          errorWidget: (context, url, error) =>
                                              Container(
                                                color: const Color(0xFF1a2332),
                                                child: const Icon(
                                                  Icons.album,
                                                  size: 48,
                                                  color: Color(0xFF00d4ff),
                                                ),
                                              ),
                                        )
                                      : Container(
                                          color: const Color(0xFF1a2332),
                                          child: const Icon(
                                            Icons.album,
                                            size: 48,
                                            color: Color(0xFF00d4ff),
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
                                ),
                              ),
                              Text(
                                album.artistName ?? 'Unknown Artist',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.grey,
                                  fontSize: 12,
                                ),
                              ),
                              Text(
                                _formatDate(album.createdAt),
                                style: TextStyle(
                                  color: Colors.grey.shade600,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
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
