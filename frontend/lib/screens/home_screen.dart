import 'package:flutter/material.dart';
import '../models/artist.dart';
import '../models/album.dart';
import '../models/song.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import 'now_playing_screen.dart';
import 'album_detail_screen.dart';
import 'artist_detail_screen.dart';
import 'search_screen.dart';
import 'dashboard_screen.dart';
import 'dart:async';
import '../widgets/alphabet_scroll_bar.dart';
import '../widgets/music_context_menu.dart';
import '../widgets/settings_dialog.dart';
import 'package:cached_network_image/cached_network_image.dart';

class HomeScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;
  final bool showMiniPlayer;

  const HomeScreen({
    super.key,
    required this.audioPlayerService,
    this.showMiniPlayer = true,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final ApiService _apiService = ApiService();
  late TabController _tabController;

  List<Artist> _artists = [];
  List<Album> _albums = [];
  List<Song> _songs = [];
  bool _isLoading = true;
  bool _songsLoading = false;
  bool _songsLoaded = false;
  String? _error;
  List<GlobalKey> _artistKeys = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(_onTabChanged);
    _loadData();
  }

  void _onTabChanged() {
    // Load songs only when user switches to Songs tab (index 3)
    if (_tabController.index == 3 && !_songsLoaded && !_songsLoading) {
      _loadSongs();
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    try {
      final artists = await _apiService.getArtists();
      final albums = await _apiService.getAlbums();

      // setState-after-dispose guard: see favorite_button.dart for the pattern.
      if (!mounted) return;
      setState(() {
        _artists = artists;
        _albums = albums;
        _isLoading = false;
        _artistKeys = List.generate(artists.length, (_) => GlobalKey());
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
    });

    try {
      final songs = await _apiService.getSongs();
      if (mounted) {
        setState(() {
          _songs = songs;
          _songsLoaded = true;
          _songsLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _songsLoading = false;
        });
      }
    }
  }

  void _playSong(Song song, int index) {
    widget.audioPlayerService.setQueue(_songs, index, sourceType: 'all_songs');
    NowPlayingScreen.open(
      context,
      audioPlayerService: widget.audioPlayerService,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('NASRadio'),
        backgroundColor: const Color(0xFF0d1b2a),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => SearchScreen(
                    audioPlayerService: widget.audioPlayerService,
                  ),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              _showSettingsDialog();
            },
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF00d4ff),
          labelColor: const Color(0xFF00d4ff),
          unselectedLabelColor: Colors.white70,
          tabs: const [
            Tab(text: 'Home'),
            Tab(text: 'Artists'),
            Tab(text: 'Albums'),
            Tab(text: 'Songs'),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(child: Text('Error: $_error'))
                : TabBarView(
                    controller: _tabController,
                    children: [
                      _buildDashboard(),
                      _buildArtistsList(),
                      _buildAlbumsList(),
                      _buildSongsList(),
                    ],
                  ),
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
                      parentLabel: 'Home',
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
                      parentLabel: 'Home',
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
    if (_songsLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_songs.isEmpty && !_songsLoaded) {
      return const Center(child: Text('Tap to load songs'));
    }

    return ListView.builder(
      itemCount: _songs.length,
      itemBuilder: (context, index) {
        final song = _songs[index];
        return ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: CachedNetworkImage(
              imageUrl: _apiService.getArtworkUrl(song.albumId),
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
            song.displayTitle,
            style: TextStyle(
              fontStyle: song.hasNoTitle ? FontStyle.italic : FontStyle.normal,
              color: song.hasNoTitle ? Colors.white60 : null,
            ),
          ),
          subtitle: Row(
            children: [
              Flexible(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (song.artists.isNotEmpty)
                      ...song.artists.asMap().entries.map((entry) {
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
                                    builder: (context) => ArtistDetailScreen(
                                      artistId: artist.id,
                                      audioPlayerService:
                                          widget.audioPlayerService,
                                      parentLabel: 'Home',
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
                                style: TextStyle(color: Colors.grey),
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
              const Text(' • ', style: TextStyle(color: Colors.grey)),
              Flexible(
                child: Text(
                  song.albumTitle,
                  style: const TextStyle(color: Colors.grey),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          trailing: Row(
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

  Widget _buildDashboard() {
    // Import at the top of the file
    return DashboardScreen(audioPlayerService: widget.audioPlayerService);
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
