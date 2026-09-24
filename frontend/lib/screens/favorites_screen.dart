import 'package:flutter/material.dart';
import 'dart:io' show Platform;
import '../models/artist.dart';
import '../models/album.dart';
import '../models/song.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import '../widgets/music_context_menu.dart';
import 'artist_detail_screen.dart';
import 'album_detail_screen.dart';
import 'now_playing_screen.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../widgets/explicit_badge.dart';
import '../widgets/hdcd_badge.dart';
import '../widgets/surround_badge.dart';
import '../widgets/favorite_button.dart';

enum SongSortOption { dateAdded, title, artist, playCount }
enum AlbumSortOption { dateAdded, title, artist, year }
enum ArtistSortOption { dateAdded, name }

class FavoritesScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;
  final bool showMiniPlayer;

  const FavoritesScreen({
    super.key,
    required this.audioPlayerService,
    this.showMiniPlayer = true,
  });

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen>
    with SingleTickerProviderStateMixin {
  final ApiService _apiService = ApiService();
  late TabController _tabController;

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  List<Song> _favoriteSongs = [];
  List<Album> _favoriteAlbums = [];
  List<Artist> _favoriteArtists = [];
  List<Map<String, dynamic>> _favoriteStations = [];
  bool _isLoading = true;
  String? _error;

  // Original API order (date added DESC) preserved for sorting back
  List<Song> _originalSongs = [];
  List<Album> _originalAlbums = [];
  List<Artist> _originalArtists = [];

  // Sort state per tab
  SongSortOption _songSort = SongSortOption.dateAdded;
  AlbumSortOption _albumSort = AlbumSortOption.dateAdded;
  ArtistSortOption _artistSort = ArtistSortOption.dateAdded;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    // Rebuild AppBar sort button when tab changes
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) setState(() {});
    });
    _loadFavorites();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadFavorites() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final songs = await _apiService.getFavoriteSongs();
      final albums = await _apiService.getFavoriteAlbums();
      final artists = await _apiService.getFavoriteArtists();
      final stations = await _apiService.getFavoriteStations();

      setState(() {
        _favoriteStations = stations;
        _originalSongs = List.from(songs);
        _originalAlbums = List.from(albums);
        _originalArtists = List.from(artists);
        _favoriteSongs = _sortSongs(songs);
        _favoriteAlbums = _sortAlbums(albums);
        _favoriteArtists = _sortArtists(artists);
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  // --- Sorting logic ---

  List<Song> _sortSongs(List<Song> songs) {
    switch (_songSort) {
      case SongSortOption.dateAdded:
        return List.from(_originalSongs.isNotEmpty ? _originalSongs : songs);
      case SongSortOption.title:
        final sorted = List<Song>.from(songs);
        sorted.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
        return sorted;
      case SongSortOption.artist:
        final sorted = List<Song>.from(songs);
        sorted.sort((a, b) => a.artistName.toLowerCase().compareTo(b.artistName.toLowerCase()));
        return sorted;
      case SongSortOption.playCount:
        final sorted = List<Song>.from(songs);
        sorted.sort((a, b) => b.playCount.compareTo(a.playCount));
        return sorted;
    }
  }

  List<Album> _sortAlbums(List<Album> albums) {
    switch (_albumSort) {
      case AlbumSortOption.dateAdded:
        return List.from(_originalAlbums.isNotEmpty ? _originalAlbums : albums);
      case AlbumSortOption.title:
        final sorted = List<Album>.from(albums);
        sorted.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
        return sorted;
      case AlbumSortOption.artist:
        final sorted = List<Album>.from(albums);
        sorted.sort((a, b) => a.artistName.toLowerCase().compareTo(b.artistName.toLowerCase()));
        return sorted;
      case AlbumSortOption.year:
        final sorted = List<Album>.from(albums);
        sorted.sort((a, b) => (b.year ?? 0).compareTo(a.year ?? 0));
        return sorted;
    }
  }

  List<Artist> _sortArtists(List<Artist> artists) {
    switch (_artistSort) {
      case ArtistSortOption.dateAdded:
        return List.from(_originalArtists.isNotEmpty ? _originalArtists : artists);
      case ArtistSortOption.name:
        final sorted = List<Artist>.from(artists);
        sorted.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        return sorted;
    }
  }

  // --- Sort UI ---

  String _sortLabel(dynamic option) {
    switch (option) {
      case SongSortOption.dateAdded:
      case AlbumSortOption.dateAdded:
      case ArtistSortOption.dateAdded:
        return 'Date Added';
      case SongSortOption.title:
      case AlbumSortOption.title:
        return 'Title';
      case SongSortOption.artist:
      case AlbumSortOption.artist:
        return 'Artist';
      case SongSortOption.playCount:
        return 'Play Count';
      case AlbumSortOption.year:
        return 'Year';
      case ArtistSortOption.name:
        return 'Name';
      default:
        return '';
    }
  }

  Widget _buildSortButton() {
    final tabIndex = _tabController.index;

    // Stations keep favorited order — no sort menu (and the else-branches
    // below would misread index 3 as the artists tab).
    if (tabIndex == 3) return const SizedBox.shrink();

    return PopupMenuButton<String>(
      icon: const Icon(Icons.sort, color: Color(0xFF00d4ff)),
      tooltip: 'Sort',
      color: const Color(0xFF1e2836),
      onSelected: (value) {
        setState(() {
          if (tabIndex == 0) {
            _songSort = SongSortOption.values.firstWhere((e) => e.name == value);
            _favoriteSongs = _sortSongs(_originalSongs);
          } else if (tabIndex == 1) {
            _albumSort = AlbumSortOption.values.firstWhere((e) => e.name == value);
            _favoriteAlbums = _sortAlbums(_originalAlbums);
          } else {
            _artistSort = ArtistSortOption.values.firstWhere((e) => e.name == value);
            _favoriteArtists = _sortArtists(_originalArtists);
          }
        });
      },
      itemBuilder: (context) {
        if (tabIndex == 0) {
          return SongSortOption.values.map((option) => PopupMenuItem<String>(
            value: option.name,
            child: Row(
              children: [
                if (_songSort == option)
                  const Icon(Icons.check, size: 18, color: Color(0xFF00d4ff))
                else
                  const SizedBox(width: 18),
                const SizedBox(width: 8),
                Text(_sortLabel(option), style: const TextStyle(color: Colors.white)),
              ],
            ),
          )).toList();
        } else if (tabIndex == 1) {
          return AlbumSortOption.values.map((option) => PopupMenuItem<String>(
            value: option.name,
            child: Row(
              children: [
                if (_albumSort == option)
                  const Icon(Icons.check, size: 18, color: Color(0xFF00d4ff))
                else
                  const SizedBox(width: 18),
                const SizedBox(width: 8),
                Text(_sortLabel(option), style: const TextStyle(color: Colors.white)),
              ],
            ),
          )).toList();
        } else {
          return ArtistSortOption.values.map((option) => PopupMenuItem<String>(
            value: option.name,
            child: Row(
              children: [
                if (_artistSort == option)
                  const Icon(Icons.check, size: 18, color: Color(0xFF00d4ff))
                else
                  const SizedBox(width: 18),
                const SizedBox(width: 8),
                Text(_sortLabel(option), style: const TextStyle(color: Colors.white)),
              ],
            ),
          )).toList();
        }
      },
    );
  }

  // Station row → playable Song. Mirrors stations_screen._toSong: station
  // Songs carry NEGATIVE ids (-dbId) by design so they can't collide with
  // real song ids in favorites/now-playing.
  Song _stationToSong(Map<String, dynamic> s) {
    return Song(
      id: -((s['id'] as num?)?.toInt() ?? 0),
      title: (s['name'] ?? 'Station').toString(),
      artistId: 0,
      artistName: (s['genre'] ?? 'Live Radio').toString(),
      albumId: 0,
      albumTitle: 'Stations',
      trackNumber: 0,
      duration: 0,
      filePath: (s['url'] ?? '').toString(),
      fileSize: 0,
      bitrate: 0,
      sourceType: 'station',
      stationArtworkUrl: (s['favicon'] ?? '').toString(),
    );
  }

  Widget _buildStationsList() {
    if (_favoriteStations.isEmpty) {
      return const Center(
        child: Text(
          'No favorite stations yet.\nTap ♥ while listening to a station.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white54),
        ),
      );
    }
    return ListView.builder(
      itemCount: _favoriteStations.length,
      itemBuilder: (context, index) {
        final s = _favoriteStations[index];
        final favicon = (s['favicon'] ?? '').toString();
        final genre = (s['genre'] ?? '').toString();
        return ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 48,
              height: 48,
              child: favicon.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: favicon,
                      fit: BoxFit.cover,
                      errorWidget: (c, u, e) => Container(
                        color: const Color(0xFF16273a),
                        child: const Icon(Icons.radio,
                            color: Color(0xFF00d4ff)),
                      ),
                    )
                  : Container(
                      color: const Color(0xFF16273a),
                      child:
                          const Icon(Icons.radio, color: Color(0xFF00d4ff)),
                    ),
            ),
          ),
          title: Text((s['name'] ?? 'Station').toString()),
          subtitle: Row(
            children: [
              const Icon(Icons.circle, color: Colors.red, size: 8),
              const SizedBox(width: 4),
              const Text('LIVE',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Colors.red,
                    letterSpacing: 1.2,
                  )),
              if (genre.isNotEmpty) ...[
                const Text(' • ', style: TextStyle(color: Colors.grey)),
                Expanded(
                  child: Text(
                    genre,
                    style: const TextStyle(color: Colors.grey),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
          trailing: FavoriteButton(
            itemType: 'station',
            itemId: ((s['id'] as num?)?.toInt() ?? 0),
            stationUrl: (s['url'] ?? '').toString(),
            size: 22,
          ),
          onTap: () {
            widget.audioPlayerService.playSong(_stationToSong(s));
            NowPlayingScreen.open(
              context,
              audioPlayerService: widget.audioPlayerService,
            );
          },
        );
      },
    );
  }

  void _playSong(Song song, int index) {
    widget.audioPlayerService.setQueue(
      _favoriteSongs,
      index,
      sourceType: 'favorites',
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
        title: const Text('Your Favorites'),
        backgroundColor: const Color(0xFF0d1b2a),
        actions: [
          _buildSortButton(),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF00d4ff),
          labelColor: const Color(0xFF00d4ff),
          unselectedLabelColor: Colors.white70,
          tabs: const [
            Tab(text: 'Songs'),
            Tab(text: 'Albums'),
            Tab(text: 'Artists'),
            Tab(text: 'Stations'),
          ],
        ),
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
                          onPressed: _loadFavorites,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  )
                : TabBarView(
                    controller: _tabController,
                    children: [
                      _buildSongsList(),
                      _buildAlbumsList(),
                      _buildArtistsList(),
                      _buildStationsList(),
                    ],
                  ),
          ),
        ],
      ),
      // Show nav bar when this is a pushed route (showMiniPlayer = true)
    );
  }

  Widget _buildSongsList() {
    if (_favoriteSongs.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.favorite_border, size: 80, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              'No favorite songs yet',
              style: TextStyle(fontSize: 18, color: Colors.grey),
            ),
            SizedBox(height: 8),
            Text(
              'Tap the heart icon to save your favorites',
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadFavorites,
      child: ListView.builder(
        itemCount: _favoriteSongs.length,
        itemBuilder: (context, index) {
          final song = _favoriteSongs[index];
          return ListTile(
            contentPadding: EdgeInsets.symmetric(
              horizontal: _isMobile ? 12 : 16,
              vertical: _isMobile ? 4 : 0,
            ),
            leading: const Icon(
              Icons.music_note,
              size: 40,
              color: Color(0xFF00d4ff),
            ),
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: _isMobile ? 14 : 16),
                  ),
                ),
                if (song.isExplicit) ...[                  const SizedBox(width: 6),
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
              style: TextStyle(
                color: Colors.grey,
                fontSize: _isMobile ? 12 : 14,
              ),
            ),
            trailing: _isMobile
                ? MusicContextMenu(
                    itemType: 'song',
                    itemId: song.id,
                    itemName: song.title,
                    onFavoriteChanged: _loadFavorites,
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
                        onFavoriteChanged: _loadFavorites,
                        audioPlayerService: widget.audioPlayerService,
                      ),
                    ],
                  ),
            onTap: () => _playSong(song, index),
          );
        },
      ),
    );
  }

  Widget _buildAlbumsList() {
    if (_favoriteAlbums.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.favorite_border, size: 80, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              'No favorite albums yet',
              style: TextStyle(fontSize: 18, color: Colors.grey),
            ),
            SizedBox(height: 8),
            Text(
              'Tap the heart icon to save your favorites',
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadFavorites,
      child: ListView.builder(
        itemCount: _favoriteAlbums.length,
        itemBuilder: (context, index) {
          final album = _favoriteAlbums[index];
          return ListTile(
            leading: album.artworkPath != null && album.artworkPath!.isNotEmpty
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
              onFavoriteChanged: _loadFavorites,
              audioPlayerService: widget.audioPlayerService,
            ),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => AlbumDetailScreen(
                    albumId: album.id,
                    audioPlayerService: widget.audioPlayerService,
                    parentLabel: 'Favorites',
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildArtistsList() {
    if (_favoriteArtists.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.favorite_border, size: 80, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              'No favorite artists yet',
              style: TextStyle(fontSize: 18, color: Colors.grey),
            ),
            SizedBox(height: 8),
            Text(
              'Tap the heart icon to save your favorites',
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadFavorites,
      child: ListView.builder(
        itemCount: _favoriteArtists.length,
        itemBuilder: (context, index) {
          final artist = _favoriteArtists[index];
          return ListTile(
            leading: artist.imagePath != null && artist.imagePath!.isNotEmpty
                ? ClipOval(
                    child: CachedNetworkImage(
                      imageUrl: _apiService.getArtistImageUrl(artist.id),
                      width: 50,
                      height: 50,
                      fit: BoxFit.cover,
                      placeholder: (context, url) => Container(
                        width: 50,
                        height: 50,
                        color: const Color(0xFF1a2332),
                      ),
                      errorWidget: (context, url, error) => const Icon(
                        Icons.person,
                        size: 40,
                        color: Color(0xFF00d4ff),
                      ),
                    ),
                  )
                : const Icon(Icons.person, size: 40, color: Color(0xFF00d4ff)),
            title: Text(artist.name),
            subtitle: Text(
              '${artist.albumCount} albums • ${artist.songCount} songs',
            ),
            trailing: MusicContextMenu(
              itemType: 'artist',
              itemId: artist.id,
              itemName: artist.name,
              onFavoriteChanged: _loadFavorites,
              audioPlayerService: widget.audioPlayerService,
            ),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => ArtistDetailScreen(
                    artistId: artist.id,
                    audioPlayerService: widget.audioPlayerService,
                    parentLabel: 'Favorites',
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
