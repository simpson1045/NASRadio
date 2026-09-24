import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io' show Platform;
import '../models/artist.dart';
import '../models/album.dart';
import '../models/song.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import 'artist_detail_screen.dart';
import 'album_detail_screen.dart';
import 'now_playing_screen.dart';
import '../widgets/music_context_menu.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../widgets/explicit_badge.dart';
import '../widgets/hdcd_badge.dart';
import '../widgets/surround_badge.dart';

class SearchScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;
  final bool showMiniPlayer;

  const SearchScreen({
    super.key,
    required this.audioPlayerService,
    this.showMiniPlayer = true,
  });

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final ApiService _apiService = ApiService();
  final TextEditingController _searchController = TextEditingController();
  Timer? _debounceTimer;

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  List<Artist> _artists = [];
  List<Album> _albums = [];
  List<Song> _songs = [];
  bool _isSearching = false;
  bool _hasSearched = false;

  // Discovery content for empty state
  List<String> _searchHistory = [];
  List<Song> _recentlyPlayed = [];
  List<Album> _recentlyAdded = [];
  List<Song> _mostPlayed = [];
  bool _isLoadingDiscovery = true;

  @override
  void initState() {
    super.initState();
    _loadDiscoveryContent();
    _loadSearchHistory();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadDiscoveryContent() async {
    try {
      final results = await Future.wait([
        _apiService.getRecentlyPlayed(limit: 10),
        _apiService.getRecentlyAdded(limit: 10),
        _apiService.getMostPlayed(limit: 10),
      ]);

      if (mounted) {
        setState(() {
          _recentlyPlayed = results[0] as List<Song>;
          final recentlyAddedData = results[1] as Map<String, dynamic>;
          _recentlyAdded = (recentlyAddedData['albums'] as List)
              .map((json) => Album.fromJson(json))
              .toList();
          _mostPlayed = results[2] as List<Song>;
          _isLoadingDiscovery = false;
        });
      }
    } catch (e) {
      print('Failed to load discovery content: $e');
      if (mounted) {
        setState(() {
          _isLoadingDiscovery = false;
        });
      }
    }
  }

  Future<void> _loadSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList('search_history') ?? [];
    if (mounted) {
      setState(() {
        _searchHistory = history;
      });
    }
  }

  Future<void> _addToSearchHistory(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    // Collapse prefixes: typing "whitesnake" with brief pauses used to
    // debounce-save "w", "wh", "whi", ... as separate history entries.
    // Remove any existing entry that is a strict prefix of the new
    // query (case-insensitive). Longer entries that *contain* the new
    // query stay put — searching "whi" again later shouldn't wipe the
    // earlier "whitesnake".
    final lower = trimmed.toLowerCase();
    _searchHistory.removeWhere((existing) {
      final e = existing.toLowerCase();
      return e != lower && lower.startsWith(e);
    });
    _searchHistory.remove(trimmed); // Move-to-top if exact duplicate exists.
    _searchHistory.insert(0, trimmed);
    if (_searchHistory.length > 10) {
      _searchHistory = _searchHistory.sublist(0, 10); // Keep only 10
    }
    await prefs.setStringList('search_history', _searchHistory);
    setState(() {});
  }

  Future<void> _removeFromSearchHistory(String query) async {
    final prefs = await SharedPreferences.getInstance();
    _searchHistory.remove(query);
    await prefs.setStringList('search_history', _searchHistory);
    setState(() {});
  }

  Future<void> _clearSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('search_history', []);
    setState(() {
      _searchHistory = [];
    });
  }

  Future<void> _performSearch(String query) async {
    if (query.isEmpty) {
      setState(() {
        _artists = [];
        _albums = [];
        _songs = [];
        _hasSearched = false;
      });
      return;
    }

    setState(() {
      _isSearching = true;
    });

    try {
      final results = await _apiService.search(query);

      setState(() {
        _artists = (results['artists'] as List)
            .map((json) => Artist.fromJson(json))
            .toList();
        _albums = (results['albums'] as List)
            .map((json) => Album.fromJson(json))
            .toList();
        _songs = (results['songs'] as List)
            .map((json) => Song.fromJson(json))
            .toList();
        _isSearching = false;
        _hasSearched = true;
      });

      // Save to history if we got results
      if (_artists.isNotEmpty || _albums.isNotEmpty || _songs.isNotEmpty) {
        _addToSearchHistory(query);
      }
    } catch (e) {
      setState(() {
        _isSearching = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Search failed: $e')));
      }
    }
  }

  void _playSong(Song song) {
    widget.audioPlayerService.setQueue(
      _songs,
      _songs.indexOf(song),
      sourceType: 'single',
    );
    NowPlayingScreen.open(
      context,
      audioPlayerService: widget.audioPlayerService,
    );
  }

  @override
  Widget build(BuildContext context) {
    final totalResults = _artists.length + _albums.length + _songs.length;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: TextField(
          controller: _searchController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Search artists, albums, songs...',
            hintStyle: const TextStyle(color: Colors.white54),
            border: InputBorder.none,
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, color: Colors.white54),
                    onPressed: () {
                      _searchController.clear();
                      setState(() {
                        _artists = [];
                        _albums = [];
                        _songs = [];
                        _hasSearched = false;
                      });
                    },
                  )
                : null,
          ),
          onChanged: (value) {
            // Cancel previous timer
            _debounceTimer?.cancel();

            // Clear results immediately if empty
            if (value.isEmpty) {
              setState(() {
                _artists = [];
                _albums = [];
                _songs = [];
                _hasSearched = false;
              });
              return;
            }

            // Debounce: wait longer on mobile (slower typing)
            final debounceMs = _isMobile ? 500 : 300;
            _debounceTimer = Timer(Duration(milliseconds: debounceMs), () {
              _performSearch(value);
            });
          },
        ),
        backgroundColor: const Color(0xFF0d1b2a),
      ),
      body: Column(
        children: [
          Expanded(
            child: _isSearching
                ? const Center(child: CircularProgressIndicator())
                : !_hasSearched
                ? _buildDiscoveryContent()
                : totalResults == 0
                ? const Center(
                    child: Text(
                      'No results found',
                      style: TextStyle(color: Colors.grey, fontSize: 18),
                    ),
                  )
                : CustomScrollView(
                    // Slivers so the song list builds lazily — only on-screen
                    // rows fetch album art. Eagerly building every song's
                    // CachedNetworkImage (the old ListView(children:[...]) did)
                    // opened one backend connection per song and could exhaust
                    // its file-descriptor limit (eventlet select() caps at ~512
                    // on Windows), crashing the server on a big search.
                    slivers: [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                          child: Text(
                            _resultSummary(),
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                      // Artists section
                      if (_artists.isNotEmpty) ...[
                        SliverToBoxAdapter(
                          child:
                              _buildSectionHeader('Artists', _artists.length),
                        ),
                        SliverToBoxAdapter(child: _buildArtistResults()),
                        const SliverToBoxAdapter(child: SizedBox(height: 8)),
                      ],

                      // Albums section
                      if (_albums.isNotEmpty) ...[
                        SliverToBoxAdapter(
                          child: _buildSectionHeader('Albums', _albums.length),
                        ),
                        SliverToBoxAdapter(child: _buildAlbumResults()),
                        const SliverToBoxAdapter(child: SizedBox(height: 8)),
                      ],

                      // Songs section — lazy so off-screen art isn't fetched.
                      if (_songs.isNotEmpty) ...[
                        SliverToBoxAdapter(
                          child: _buildSectionHeader('Songs', _songs.length),
                        ),
                        SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, index) =>
                                _buildSongTile(_songs[index], index),
                            childCount: _songs.length,
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildDiscoveryContent() {
    if (_isLoadingDiscovery) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Search History
        if (_searchHistory.isNotEmpty) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Recent Searches',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              TextButton(
                onPressed: _clearSearchHistory,
                child: const Text(
                  'Clear',
                  style: TextStyle(color: Color(0xFF00d4ff)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _searchHistory
                .map(
                  (query) => InputChip(
                    label: Text(query),
                    onPressed: () {
                      _searchController.text = query;
                      _performSearch(query);
                    },
                    onDeleted: () => _removeFromSearchHistory(query),
                    deleteIconColor: Colors.grey,
                    backgroundColor: const Color(0xFF1a2332),
                    labelStyle: const TextStyle(color: Colors.white),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 24),
        ],

        // Recently Played
        if (_recentlyPlayed.isNotEmpty) ...[
          const Text(
            'Recently Played',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: _isMobile ? 175 : 195,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _recentlyPlayed.length,
              itemBuilder: (context, index) {
                final song = _recentlyPlayed[index];
                return _buildSongCard(song);
              },
            ),
          ),
          const SizedBox(height: 24),
        ],

        // Recently Added Albums
        if (_recentlyAdded.isNotEmpty) ...[
          const Text(
            'Recently Added',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: _isMobile ? 180 : 200,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _recentlyAdded.length,
              itemBuilder: (context, index) {
                final album = _recentlyAdded[index];
                return _buildAlbumCard(album);
              },
            ),
          ),
          const SizedBox(height: 24),
        ],

        // Most Played
        if (_mostPlayed.isNotEmpty) ...[
          const Text(
            'Most Played',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: _isMobile ? 175 : 195,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _mostPlayed.length,
              itemBuilder: (context, index) {
                final song = _mostPlayed[index];
                return _buildSongCard(song);
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSongCard(Song song) {
    final size = _isMobile ? 120.0 : 140.0;
    return GestureDetector(
      onTap: () {
        widget.audioPlayerService.playSong(song);
        NowPlayingScreen.open(
          context,
          audioPlayerService: widget.audioPlayerService,
        );
      },
      child: Container(
        width: size,
        margin: const EdgeInsets.only(right: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CachedNetworkImage(
                imageUrl: _apiService.getArtworkUrl(song.albumId),
                width: size,
                height: size,
                fit: BoxFit.cover,
                placeholder: (context, url) => Container(
                  width: size,
                  height: size,
                  color: const Color(0xFF1a2332),
                ),
                errorWidget: (context, url, error) => Container(
                  width: size,
                  height: size,
                  color: const Color(0xFF1a2332),
                  child: const Icon(Icons.music_note, color: Color(0xFF00d4ff)),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Flexible(
                  child: Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: _isMobile ? 12 : 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (song.isExplicit) ...[
                  const SizedBox(width: 4),
                  ExplicitBadge(fontSize: _isMobile ? 8 : 9),
                ],
                if (song.isAtmos || song.isSurround) ...[
                  const SizedBox(width: 4),
                  SpatialBadge(song: song, fontSize: _isMobile ? 8 : 9),
                ],
                if (song.isHdcd) ...[
                  const SizedBox(width: 4),
                  HdcdBadge(fontSize: _isMobile ? 8 : 9),
                ],
              ],
            ),
            Text(
              song.artistName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: _isMobile ? 11 : 12,
                color: Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlbumCard(Album album) {
    final size = _isMobile ? 130.0 : 150.0;
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => AlbumDetailScreen(
              albumId: album.id,
              audioPlayerService: widget.audioPlayerService,
              artistName: album.artistName,
              parentLabel: 'Search',
            ),
          ),
        );
      },
      child: Container(
        width: size,
        margin: const EdgeInsets.only(right: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CachedNetworkImage(
                imageUrl: _apiService.getArtworkUrl(album.id),
                width: size,
                height: size,
                fit: BoxFit.cover,
                placeholder: (context, url) => Container(
                  width: size,
                  height: size,
                  color: const Color(0xFF1a2332),
                ),
                errorWidget: (context, url, error) => Container(
                  width: size,
                  height: size,
                  color: const Color(0xFF1a2332),
                  child: const Icon(Icons.album, color: Color(0xFF00d4ff)),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              album.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: _isMobile ? 12 : 14,
                fontWeight: FontWeight.w500,
              ),
            ),
            Text(
              album.artistName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: _isMobile ? 11 : 12,
                color: Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _resultSummary() {
    final parts = <String>[];
    if (_artists.isNotEmpty) {
      parts.add('${_artists.length} artist${_artists.length == 1 ? '' : 's'}');
    }
    if (_albums.isNotEmpty) {
      parts.add('${_albums.length} album${_albums.length == 1 ? '' : 's'}');
    }
    if (_songs.isNotEmpty) {
      parts.add('${_songs.length} song${_songs.length == 1 ? '' : 's'}');
    }
    return parts.join(' • ');
  }

  Widget _buildSectionHeader(String title, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0x2200d4ff),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '$count',
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF00d4ff),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openArtist(Artist artist) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ArtistDetailScreen(
          artistId: artist.id,
          audioPlayerService: widget.audioPlayerService,
          parentLabel: 'Search',
        ),
      ),
    );
  }

  Widget _buildArtistCard(Artist artist) {
    final size = _isMobile ? 64.0 : 76.0;
    final hasImage = artist.imagePath != null && artist.imagePath!.isNotEmpty;
    return GestureDetector(
      onTap: () => _openArtist(artist),
      child: SizedBox(
        width: size + 18,
        child: Column(
          children: [
            ClipOval(
              child: hasImage
                  ? CachedNetworkImage(
                      imageUrl: _apiService.getArtistImageUrl(artist.id),
                      width: size,
                      height: size,
                      fit: BoxFit.cover,
                      placeholder: (context, url) => Container(
                        width: size,
                        height: size,
                        color: const Color(0xFF16273a),
                      ),
                      errorWidget: (context, url, error) => Container(
                        width: size,
                        height: size,
                        color: const Color(0xFF16273a),
                        child: const Icon(
                          Icons.person,
                          color: Color(0xFF00d4ff),
                        ),
                      ),
                    )
                  : Container(
                      width: size,
                      height: size,
                      color: const Color(0xFF16273a),
                      child: const Icon(
                        Icons.person,
                        size: 30,
                        color: Color(0xFF00d4ff),
                      ),
                    ),
            ),
            const SizedBox(height: 6),
            Text(
              artist.name,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: _isMobile ? 11 : 12, height: 1.2),
            ),
            Text(
              '${artist.songCount} songs',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: _isMobile ? 10 : 11,
                color: Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildArtistResults() {
    if (_isMobile) {
      return SizedBox(
        height: 122,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: _artists.length,
          separatorBuilder: (context, index) => const SizedBox(width: 12),
          itemBuilder: (context, index) => _buildArtistCard(_artists[index]),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 12,
        runSpacing: 16,
        children: _artists.map(_buildArtistCard).toList(),
      ),
    );
  }

  Widget _buildAlbumResults() {
    if (_isMobile) {
      return SizedBox(
        height: 180,
        child: ListView.builder(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: _albums.length,
          itemBuilder: (context, index) => _buildAlbumCard(_albums[index]),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        runSpacing: 12,
        children: _albums.map(_buildAlbumCard).toList(),
      ),
    );
  }

  Widget _buildSongTile(Song song, int index) {
    return ListTile(
            tileColor: index.isOdd
                ? const Color(0x05FFFFFF)
                : null,
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
            title: Row(
              children: [
                Flexible(
                  child: Text(
                    song.title,
                    style: TextStyle(fontSize: _isMobile ? 14 : 16),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (song.isExplicit) ...[
                  const SizedBox(width: 6),
                  ExplicitBadge(fontSize: _isMobile ? 9 : 10),
                ],
                if (song.isAtmos || song.isSurround) ...[
                  const SizedBox(width: 6),
                  SpatialBadge(song: song, fontSize: _isMobile ? 9 : 10),
                ],
                if (song.isHdcd) ...[
                  const SizedBox(width: 6),
                  HdcdBadge(fontSize: _isMobile ? 9 : 10),
                ],
              ],
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
            onTap: () => _playSong(song),
          );
  }
}
