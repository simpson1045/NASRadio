import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/auth_http_client.dart';
import 'dart:convert';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';

class DuplicateReviewScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;

  const DuplicateReviewScreen({super.key, required this.audioPlayerService});

  @override
  State<DuplicateReviewScreen> createState() => _DuplicateReviewScreenState();
}

class _DuplicateReviewScreenState extends State<DuplicateReviewScreen> {
  final ApiService _apiService = ApiService();
  List<Map<String, dynamic>> _duplicates = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDuplicates();
  }

  Future<void> _loadDuplicates() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final response = await appHttpClient.get(
        Uri.parse('${ApiService.baseUrl}/find-duplicate-albums'),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _duplicates = List<Map<String, dynamic>>.from(
            data['duplicates'] ?? [],
          );
          _isLoading = false;
        });
      } else {
        throw Exception('Failed to load duplicates');
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _markNotDuplicates(List<int> albumIds) async {
    try {
      final response = await appHttpClient.post(
        Uri.parse('${ApiService.baseUrl}/not-duplicate-albums'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'album_ids': albumIds}),
      );
      if (response.statusCode == 200) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Marked as not duplicates'),
              backgroundColor: Colors.green,
            ),
          );
          _loadDuplicates();
        }
      } else {
        throw Exception('Failed to mark as not duplicates');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _deleteAlbum(int albumId, String albumTitle) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Album'),
        content: Text(
          'Are you sure you want to delete "$albumTitle"?\n\nThis will remove all songs from your library.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _apiService.deleteAlbum(albumId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Deleted "$albumTitle"'),
              backgroundColor: Colors.green,
            ),
          );
          _loadDuplicates();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0a0e27),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0d1b2a),
        title: const Text('Duplicate Albums'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadDuplicates,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Error: $_error', style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadDuplicates,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    if (_duplicates.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle, size: 64, color: Colors.green),
            SizedBox(height: 16),
            Text(
              'No duplicate albums found!',
              style: TextStyle(fontSize: 18, color: Colors.white),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _duplicates.length,
      itemBuilder: (context, index) => _buildDuplicateGroup(_duplicates[index]),
    );
  }

  Widget _buildDuplicateGroup(Map<String, dynamic> group) {
    final albums = List<Map<String, dynamic>>.from(group['albums'] ?? []);
    final artistName = group['artist_name'] ?? 'Unknown Artist';
    final baseTitle = group['title'] ?? 'Unknown Album';

    return Card(
      color: const Color(0xFF1a2332),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.library_music, color: Color(0xFF00d4ff)),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        artistName,
                        style: const TextStyle(
                          color: Color(0xFF00d4ff),
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        baseTitle,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${albums.length} versions',
                    style: const TextStyle(
                      color: Colors.orange,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ...albums.map((album) => _buildAlbumCard(album)),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => _markNotDuplicates(
                  albums.map((a) => a['id'] as int).toList(),
                ),
                icon: const Icon(Icons.link_off, size: 16),
                label: const Text('Not Duplicates'),
                style: TextButton.styleFrom(foregroundColor: Colors.grey),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlbumCard(Map<String, dynamic> album) {
    final albumId = album['id'] as int;
    final title = album['title'] ?? 'Unknown';
    final year = album['year'];
    final songCount = album['song_count'] ?? 0;
    final artworkPath = album['artwork_path'];
    final createdAt = album['created_at'] ?? '';
    final songs = List<Map<String, dynamic>>.from(album['songs'] ?? []);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0d1b2a),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF2a3a4a)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: artworkPath != null
                    ? CachedNetworkImage(
                        imageUrl: _apiService.getArtworkUrl(albumId),
                        width: 60,
                        height: 60,
                        fit: BoxFit.cover,
                        placeholder: (context, url) => Container(
                          width: 60,
                          height: 60,
                          color: const Color(0xFF1a2332),
                          child: const Icon(Icons.album, color: Colors.grey),
                        ),
                        errorWidget: (context, url, error) => Container(
                          width: 60,
                          height: 60,
                          color: const Color(0xFF1a2332),
                          child: const Icon(Icons.album, color: Colors.grey),
                        ),
                      )
                    : Container(
                        width: 60,
                        height: 60,
                        color: const Color(0xFF1a2332),
                        child: const Icon(Icons.album, color: Colors.grey),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (year != null) ...[
                          Text(
                            '$year',
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 12,
                            ),
                          ),
                          const Text(
                            ' • ',
                            style: TextStyle(color: Colors.grey, fontSize: 12),
                          ),
                        ],
                        Text(
                          '$songCount songs',
                          style: TextStyle(
                            color: songCount > 0
                                ? const Color(0xFF00d4ff)
                                : Colors.red,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    _buildQualityInfo(album),
                    if (createdAt.isNotEmpty)
                      Text(
                        'Added: ${_formatDate(createdAt)}',
                        style: const TextStyle(
                          color: Colors.grey,
                          fontSize: 10,
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                onPressed: () => _deleteAlbum(albumId, title),
              ),
            ],
          ),
          if (songs.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF1a2332),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: songs.take(10).map((song) {
                  final disc = song['disc_number'] ?? 1;
                  final track = song['track_number'] ?? 0;
                  final songTitle = song['title'] ?? 'Unknown';
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '$disc-$track. $songTitle',
                      style: const TextStyle(color: Colors.grey, fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }).toList(),
              ),
            ),
            if (songs.length > 10)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '... and ${songs.length - 10} more',
                  style: const TextStyle(
                    color: Colors.grey,
                    fontSize: 10,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildQualityInfo(Map<String, dynamic> album) {
    final formats = List<String>.from(album['formats'] ?? []);
    final avgBitrate = album['avg_bitrate'];

    if (formats.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: formats.map((format) {
        final color = _getFormatColor(format);
        String label = format;
        // Add bitrate for lossy formats
        if (avgBitrate != null &&
            ['MP3', 'M4A', 'AAC', 'OGG', 'OPUS'].contains(format)) {
          label = '$format ${avgBitrate}k';
        }
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: color.withOpacity(0.2),
            border: Border.all(color: color, width: 1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.bold,
              color: color,
              letterSpacing: 0.5,
            ),
          ),
        );
      }).toList(),
    );
  }

  Color _getFormatColor(String format) {
    switch (format) {
      case 'FLAC':
        return const Color(0xFF00d4ff);
      case 'MP3':
        return Colors.orange;
      case 'WAV':
      case 'WAVE':
        return Colors.blue;
      case 'M4A':
      case 'AAC':
        return Colors.purple;
      case 'OGG':
      case 'OPUS':
        return Colors.green;
      case 'WV':
        return const Color(0xFF9C27B0);
      case 'APE':
        return const Color(0xFF8BC34A);
      case 'AIFF':
      case 'AIF':
        return const Color(0xFF03A9F4);
      case 'DSF':
      case 'DFF':
        return const Color(0xFFFFD700);
      default:
        return Colors.grey;
    }
  }

  String _formatDate(String dateStr) {
    try {
      final date = DateTime.parse(dateStr);
      return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    } catch (e) {
      return dateStr;
    }
  }
}
