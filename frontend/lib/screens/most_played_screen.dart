import 'package:flutter/material.dart';
import '../models/song.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import 'now_playing_screen.dart';
import 'artist_detail_screen.dart';
import 'album_detail_screen.dart';
import '../widgets/music_context_menu.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../widgets/explicit_badge.dart';
import '../widgets/hdcd_badge.dart';
import '../widgets/surround_badge.dart';

class MostPlayedScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;

  const MostPlayedScreen({super.key, required this.audioPlayerService});

  @override
  State<MostPlayedScreen> createState() => _MostPlayedScreenState();
}

class _MostPlayedScreenState extends State<MostPlayedScreen> {
  final ApiService _apiService = ApiService();
  List<Song> _songs = [];
  bool _isLoading = true;
  String? _error;

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
      final songs = await _apiService.getMostPlayed(limit: 100);
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
      widget.audioPlayerService.setQueue([song], 0, sourceType: 'most_played');
      NowPlayingScreen.open(
        context,
        audioPlayerService: widget.audioPlayerService,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Most Played'),
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
                      'No plays tracked yet.\nListen to some songs to see your top tracks!',
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
                        return ListTile(
                          leading: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 24,
                                child: Text(
                                  '${index + 1}',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF00d4ff),
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                              const SizedBox(width: 12),
                              ClipRRect(
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
                                  errorWidget: (context, url, error) =>
                                      Container(
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
                            ],
                          ),
                          title: Row(
                            children: [
                              Flexible(
                                child: Text(song.title),
                              ),
                              if (song.isExplicit) ...[                                const SizedBox(width: 6),
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
                          subtitle: Row(
                            children: [
                              Flexible(
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (song.artists.isNotEmpty)
                                      ...song.artists.asMap().entries.map((
                                        entry,
                                      ) {
                                        final index = entry.key;
                                        final artist = entry.value;
                                        return Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            GestureDetector(
                                              onTap: () {
                                                Navigator.push(
                                                  context,
                                                  MaterialPageRoute(
                                                    builder: (context) =>
                                                        ArtistDetailScreen(
                                                          artistId: artist.id,
                                                          audioPlayerService: widget
                                                              .audioPlayerService,
                                                          parentLabel: 'Most Played',
                                                        ),
                                                  ),
                                                );
                                              },
                                              child: Text(
                                                artist.name,
                                                style: const TextStyle(
                                                  color: Colors.grey,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ),
                                            if (index < song.artists.length - 1)
                                              const Text(
                                                ', ',
                                                style: TextStyle(
                                                  color: Colors.grey,
                                                ),
                                              ),
                                          ],
                                        );
                                      })
                                    else
                                      Text(
                                        song.artistName,
                                        style: const TextStyle(
                                          color: Colors.grey,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              const Text(
                                ' • ',
                                style: TextStyle(color: Colors.grey),
                              ),
                              Flexible(
                                child: GestureDetector(
                                  onTap: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) => AlbumDetailScreen(
                                          albumId: song.albumId,
                                          audioPlayerService:
                                              widget.audioPlayerService,
                                          parentLabel: 'Most Played',
                                        ),
                                      ),
                                    );
                                  },
                                  child: Text(
                                    song.albumTitle,
                                    style: const TextStyle(color: Colors.grey),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${song.playCount} plays',
                                style: const TextStyle(
                                  color: Color(0xFF00d4ff),
                                  fontSize: 12,
                                ),
                              ),
                              MusicContextMenu(
                                itemType: 'song',
                                itemId: song.id,
                                itemName: song.title,
                                audioPlayerService: widget.audioPlayerService,
                              ),
                            ],
                          ),
                          onTap: () => _playSong(song),
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
