import 'package:flutter/material.dart';
import 'dart:io' show Platform;
import '../models/song.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import 'now_playing_screen.dart';
import '../widgets/music_context_menu.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../widgets/explicit_badge.dart';
import '../widgets/hdcd_badge.dart';
import '../widgets/surround_badge.dart';

class RecentlyPlayedScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;

  const RecentlyPlayedScreen({super.key, required this.audioPlayerService});

  @override
  State<RecentlyPlayedScreen> createState() => _RecentlyPlayedScreenState();
}

class _RecentlyPlayedScreenState extends State<RecentlyPlayedScreen> {
  final ApiService _apiService = ApiService();
  List<Song> _songs = [];
  bool _isLoading = true;
  String? _error;

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    _loadSongs();
  }

  Future<void> _loadSongs() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final songs = await _apiService.getRecentlyPlayed(limit: 100);
      setState(() {
        _songs = songs;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _playSong(Song song) {
    widget.audioPlayerService.setQueue(
      _songs,
      _songs.indexOf(song),
      sourceType: 'recently_played',
    );
    NowPlayingScreen.open(
      context,
      audioPlayerService: widget.audioPlayerService,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recently Played'),
        backgroundColor: const Color(0xFF0d1b2a),
      ),
      body: Column(
        children: [
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('Error: $_error'),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: _loadSongs,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  )
                : _songs.isEmpty
                ? const Center(
                    child: Text(
                      'No recently played songs yet.\nStart listening to see your history!',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 16),
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _loadSongs,
                    child: ListView.builder(
                      itemCount: _songs.length,
                      itemBuilder: (context, index) {
                        final song = _songs[index];
                        return Container(
                          margin: EdgeInsets.symmetric(
                            horizontal: _isMobile ? 0 : 4,
                          ),
                          child: ListTile(
                            contentPadding: EdgeInsets.only(
                              left: 16,
                              right: _isMobile ? 4 : 16,
                            ),
                            dense: _isMobile,
                            leading: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: CachedNetworkImage(
                                imageUrl: _apiService.getArtworkUrl(
                                  song.albumId,
                                ),
                                width: 50,
                                height: 50,
                                fit: BoxFit.cover,
                                placeholder: (context, url) => Container(
                                  width: 50,
                                  height: 50,
                                  color: const Color(0xFF1a2332),
                                ),
                                errorWidget: (context, url, error) => Container(
                                  width: 50,
                                  height: 50,
                                  color: const Color(0xFF0d1b2a),
                                  child: const Icon(
                                    Icons.music_note,
                                    color: Color(0xFF00d4ff),
                                    size: 24,
                                  ),
                                ),
                              ),
                            ),
                            title: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    song.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (song.isExplicit) ...[                                  const SizedBox(width: 6),
                                  const ExplicitBadge(fontSize: 10),
                                ],
                                if (song.isAtmos || song.isSurround) ...[
                                  const SizedBox(width: 6),
                                  SpatialBadge(song: song, fontSize: 10),
                                ],
                                if (song.isHdcd) ...[
                                  const SizedBox(width: 6),
                                  const HdcdBadge(fontSize: 10),
                                ],
                              ],
                            ),
                            subtitle: Text(
                              '${song.artistName} • ${song.albumTitle}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.grey),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (!_isMobile) ...[
                                  Text(
                                    song.durationFormatted,
                                    style: const TextStyle(color: Colors.grey),
                                  ),
                                  const SizedBox(width: 8),
                                ],
                                MusicContextMenu(
                                  itemType: 'song',
                                  itemId: song.id,
                                  itemName: song.title,
                                  audioPlayerService: widget.audioPlayerService,
                                ),
                              ],
                            ),
                            onTap: () => _playSong(song),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
