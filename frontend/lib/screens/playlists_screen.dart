import 'package:flutter/material.dart';
import 'dart:io' show Platform;
import '../models/playlist.dart';
import '../models/song.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import 'playlist_detail_screen.dart';
import '../widgets/spotify_import_dialog.dart';
import '../widgets/m3u8_import_dialog.dart';
import '../widgets/mouse_back_button_wrapper.dart';
import 'missing_albums_screen.dart';
import 'now_playing_screen.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

class PlaylistsScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;
  final bool showMiniPlayer;

  const PlaylistsScreen({
    super.key,
    required this.audioPlayerService,
    this.showMiniPlayer = true,
  });

  @override
  State<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends State<PlaylistsScreen>
    with SingleTickerProviderStateMixin {
  final ApiService _apiService = ApiService();
  List<Playlist> _playlists = [];
  bool _isLoading = true;
  String? _error;
  io.Socket? _socket;
  String _sortBy = 'recent'; // 'recent', 'name', 'played'
  bool _fabExpanded = false;
  late AnimationController _fabAnimationController;
  late Animation<double> _fabAnimation;
  late Animation<Offset> _slideAnimation;

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  List<Playlist> get _kyliePlaylists =>
      _playlists.where((p) => p.isGenerated).toList();

  List<Playlist> get _userPlaylists =>
      _playlists.where((p) => !p.isGenerated).toList();

  List<Playlist> get _pinnedPlaylists {
    final list = _userPlaylists.where((p) => p.pinned).toList();
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  List<Playlist> get _recentlyPlayedPlaylists {
    final list = _userPlaylists
        .where((p) => p.lastPlayedAt != null && !p.pinned)
        .toList();
    list.sort((a, b) => b.lastPlayedAt!.compareTo(a.lastPlayedAt!));
    return list.take(10).toList();
  }

  List<Playlist> get _sortedPlaylists {
    final sorted = List<Playlist>.from(_userPlaylists);
    switch (_sortBy) {
      case 'name':
        sorted.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
        break;
      case 'played':
        sorted.sort((a, b) {
          if (a.lastPlayedAt == null && b.lastPlayedAt == null) return 0;
          if (a.lastPlayedAt == null) return 1;
          if (b.lastPlayedAt == null) return -1;
          return b.lastPlayedAt!.compareTo(a.lastPlayedAt!);
        });
        break;
      case 'recent':
      default:
        sorted.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        break;
    }
    // Always put pinned playlists first
    sorted.sort((a, b) {
      if (a.pinned && !b.pinned) return -1;
      if (!a.pinned && b.pinned) return 1;
      return 0;
    });
    return sorted;
  }

  @override
  void initState() {
    super.initState();
    _loadPlaylists();
    _connectSocket();
    _fabAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _fabAnimation = CurvedAnimation(
      parent: _fabAnimationController,
      curve: Curves.easeOut,
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.5),
      end: Offset.zero,
    ).animate(_fabAnimation);
  }

  void _connectSocket() {
    if (_socket != null) {
      _socket!.dispose();
    }
    _socket = io.io(
      ApiService.baseHost,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .build(),
    );

    _socket!.onConnect((_) {
      print('Playlists socket connected');
    });

    _socket!.on('playlist_updated', (data) {
      if (!mounted) return;
      // Refresh playlists when any playlist changes
      _playlistAlbumCache.clear();
      _loadPlaylists();
    });

    _socket!.connect();
  }

  @override
  void dispose() {
    _socket?.disconnect();
    _socket?.dispose();
    _fabAnimationController.dispose();
    super.dispose();
  }

  Future<void> _loadPlaylists() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final playlists = await _apiService.getPlaylists();
      if (!mounted) return;
      setState(() {
        _playlists = playlists;
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

  final Map<int, List<int>> _playlistAlbumCache = {};

  Future<List<int>> _getPlaylistAlbumIds(int playlistId) async {
    if (_playlistAlbumCache.containsKey(playlistId)) {
      return _playlistAlbumCache[playlistId]!;
    }
    try {
      final data = await _apiService.getPlaylist(playlistId);
      final songs = data['songs'] as List;
      final albumIds = <int>[];
      final seen = <int>{};
      for (final song in songs) {
        // Missing tracks (not yet in the library) have a null album_id —
        // skip them so they don't blow up the cast and blank the thumbnail.
        final albumId = song['album_id'];
        if (albumId is! int) continue;
        if (!seen.contains(albumId)) {
          seen.add(albumId);
          albumIds.add(albumId);
          if (albumIds.length >= 4) break;
        }
      }
      _playlistAlbumCache[playlistId] = albumIds;
      return albumIds;
    } catch (e) {
      return [];
    }
  }

  Future<void> _showCreatePlaylistDialog() async {
    final TextEditingController nameController = TextEditingController();
    final TextEditingController descriptionController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create Playlist'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: 'Playlist Name',
                  border: OutlineInputBorder(),
                ),
                autofocus: true,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                  border: OutlineInputBorder(),
                ),
                maxLines: 3,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00d4ff),
              foregroundColor: Colors.black,
            ),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (result == true && nameController.text.trim().isNotEmpty) {
      try {
        await _apiService.createPlaylist(
          nameController.text.trim(),
          descriptionController.text.trim().isEmpty
              ? null
              : descriptionController.text.trim(),
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Playlist created'),
              backgroundColor: Colors.green,
            ),
          );
          _loadPlaylists();
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

  void _showSpotifyImportDialog() {
    showDialog(
      context: context,
      builder: (context) => SpotifyImportDialog(
        onImportComplete: _loadPlaylists,
        audioService: widget.audioPlayerService,
      ),
    );
  }

  void _showM3u8ImportDialog() {
    showDialog(
      context: context,
      builder: (context) => M3u8ImportDialog(
        onImportComplete: _loadPlaylists,
        audioService: widget.audioPlayerService,
      ),
    );
  }

  Future<void> _showDeleteDialog(Playlist playlist) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Playlist'),
        content: Text(
          'Are you sure you want to delete "${playlist.name}"?\n\nThis cannot be undone.',
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
        await _apiService.deletePlaylist(playlist.id);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Deleted "${playlist.name}"'),
              backgroundColor: Colors.green,
            ),
          );
          _loadPlaylists();
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

  void _openPlaylist(Playlist playlist) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PlaylistDetailScreen(
          playlistId: playlist.id,
          audioPlayerService: widget.audioPlayerService,
        ),
      ),
    ).then((_) => _loadPlaylists());
  }

  Future<void> _playPlaylist(Playlist playlist) async {
    try {
      final data = await _apiService.getPlaylist(playlist.id);
      final songs = (data['songs'] as List)
          .map((s) => Song.fromJson(s))
          .toList();
      if (songs.isEmpty) {
        if (mounted) _openPlaylist(playlist);
        return;
      }
      widget.audioPlayerService.setQueue(
        songs,
        0,
        sourceType: 'playlist',
        sourceId: playlist.id,
        sourceName: playlist.name,
      );
      if (mounted) {
        NowPlayingScreen.open(
          context,
          audioPlayerService: widget.audioPlayerService,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not play playlist: $e')),
        );
      }
    }
  }

  Widget _buildShelfHeader(String title, {IconData? icon, int? count}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: const Color(0xFF00d4ff)),
            const SizedBox(width: 8),
          ],
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          ),
          if (count != null) ...[
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
        ],
      ),
    );
  }

  Widget _buildPlaylistArtworkFill(int playlistId) {
    return FutureBuilder<List<int>>(
      future: _getPlaylistAlbumIds(playlistId),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return Container(
            color: const Color(0xFF16273a),
            child: const Center(
              child: Icon(
                Icons.playlist_play,
                color: Color(0xFF00d4ff),
                size: 40,
              ),
            ),
          );
        }
        final albumIds = snapshot.data!;
        if (albumIds.length < 4) {
          return CachedNetworkImage(
            imageUrl: _apiService.getArtworkUrl(albumIds.first),
            fit: BoxFit.cover,
            placeholder: (context, url) =>
                Container(color: const Color(0xFF16273a)),
            errorWidget: (context, url, error) =>
                Container(color: const Color(0xFF16273a)),
          );
        }
        return GridView.count(
          crossAxisCount: 2,
          physics: const NeverScrollableScrollPhysics(),
          children: albumIds.take(4).map((albumId) {
            return CachedNetworkImage(
              imageUrl: _apiService.getArtworkUrl(albumId),
              fit: BoxFit.cover,
              placeholder: (context, url) =>
                  Container(color: const Color(0xFF16273a)),
              errorWidget: (context, url, error) =>
                  Container(color: const Color(0xFF16273a)),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildCardMenu(Playlist playlist) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, color: Colors.white, size: 20),
      padding: EdgeInsets.zero,
      onSelected: (value) async {
        if (value == 'pin') {
          await _apiService.togglePlaylistPin(playlist.id);
          _loadPlaylists();
        } else if (value == 'delete') {
          _showDeleteDialog(playlist);
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'pin',
          child: Row(
            children: [
              Icon(
                playlist.pinned ? Icons.push_pin_outlined : Icons.push_pin,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(playlist.pinned ? 'Unpin' : 'Pin'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 18, color: Colors.red),
              SizedBox(width: 8),
              Text('Delete'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCoverTile(Playlist playlist) {
    return GestureDetector(
      onTap: () => _openPlaylist(playlist),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AspectRatio(
          aspectRatio: 1,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildPlaylistArtworkFill(playlist.id),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  color: const Color(0xCC040C14),
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 7),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        playlist.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        '${playlist.songCount} songs',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF9fb2c4),
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (playlist.pinned)
                const Positioned(
                  top: 6,
                  left: 6,
                  child: Icon(
                    Icons.push_pin,
                    size: 15,
                    color: Color(0xFF00d4ff),
                  ),
                ),
              Positioned(top: 0, right: 0, child: _buildCardMenu(playlist)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPinnedCard(Playlist playlist, double width) {
    return SizedBox(
      width: width,
      child: GestureDetector(
        onTap: () => _openPlaylist(playlist),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildPlaylistArtworkFill(playlist.id),
                Container(color: const Color(0x57040C14)),
                Positioned(
                  left: 12,
                  right: 56,
                  bottom: 10,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        playlist.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        '${playlist.songCount} songs • ${playlist.durationFormatted}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFcfe0ec),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: GestureDetector(
                    onTap: () => _playPlaylist(playlist),
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: const BoxDecoration(
                        color: Color(0xFF00d4ff),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.play_arrow,
                        color: Color(0xFF06242e),
                        size: 22,
                      ),
                    ),
                  ),
                ),
                Positioned(top: 0, right: 0, child: _buildCardMenu(playlist)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlaylistRail(
    List<Playlist> playlists, {
    double? tileWidth,
    double hPad = 16,
  }) {
    final w = tileWidth ?? (_isMobile ? 108.0 : 120.0);
    return SizedBox(
      height: w,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: hPad),
        itemCount: playlists.length,
        separatorBuilder: (context, index) => const SizedBox(width: 12),
        itemBuilder: (context, index) =>
            SizedBox(width: w, child: _buildCoverTile(playlists[index])),
      ),
    );
  }

  Widget _buildKylieBand() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 14),
      decoration: BoxDecoration(
        color: const Color(0x0A00D4FF),
        border: Border.all(color: const Color(0x4D00D4FF)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [
              Row(
                children: [
                  Icon(Icons.auto_awesome, size: 18, color: Color(0xFF00d4ff)),
                  SizedBox(width: 8),
                  Text(
                    'Made by KYLIE',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
              Text(
                'Updated weekly',
                style: TextStyle(color: Color(0xFF7fd6e8), fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildPlaylistRail(
            _kyliePlaylists,
            tileWidth: _isMobile ? 120 : 130,
            hPad: 0,
          ),
        ],
      ),
    );
  }

  Widget _buildPinnedShowcase() {
    final pinned = _pinnedPlaylists;
    final h = _isMobile ? 120.0 : 150.0;
    return SizedBox(
      height: h,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: pinned.length,
        separatorBuilder: (context, index) => const SizedBox(width: 12),
        itemBuilder: (context, index) =>
            _buildPinnedCard(pinned[index], h * 16 / 9),
      ),
    );
  }

  Widget _buildAllGrid() {
    final all = _sortedPlaylists;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _isMobile ? 2 : 4,
          mainAxisSpacing: 13,
          crossAxisSpacing: 13,
          childAspectRatio: 1,
        ),
        itemCount: all.length,
        itemBuilder: (context, index) => _buildCoverTile(all[index]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MouseBackButtonWrapper(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Playlists'),
          backgroundColor: const Color(0xFF0d1b2a),
          actions: [
            PopupMenuButton<String>(
              icon: const Icon(Icons.sort),
              tooltip: 'Sort by',
              onSelected: (value) {
                setState(() => _sortBy = value);
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'recent',
                  child: Row(
                    children: [
                      Icon(
                        Icons.update,
                        size: 18,
                        color: _sortBy == 'recent'
                            ? const Color(0xFF00d4ff)
                            : null,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Recently Updated',
                        style: TextStyle(
                          color: _sortBy == 'recent'
                              ? const Color(0xFF00d4ff)
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'played',
                  child: Row(
                    children: [
                      Icon(
                        Icons.play_circle,
                        size: 18,
                        color: _sortBy == 'played'
                            ? const Color(0xFF00d4ff)
                            : null,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Recently Played',
                        style: TextStyle(
                          color: _sortBy == 'played'
                              ? const Color(0xFF00d4ff)
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'name',
                  child: Row(
                    children: [
                      Icon(
                        Icons.sort_by_alpha,
                        size: 18,
                        color: _sortBy == 'name'
                            ? const Color(0xFF00d4ff)
                            : null,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Name',
                        style: TextStyle(
                          color: _sortBy == 'name'
                              ? const Color(0xFF00d4ff)
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
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
                            onPressed: _loadPlaylists,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    )
                  : _playlists.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.playlist_play,
                            size: 80,
                            color: Colors.grey,
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'No playlists yet',
                            style: TextStyle(fontSize: 18, color: Colors.grey),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Tap the + button to create your first playlist',
                            style: TextStyle(fontSize: 14, color: Colors.grey),
                          ),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _loadPlaylists,
                      child: ListView(
                        // 160 = FAB (56) + margin (16) + mini player (~70) +
                        // clearance, so the last row clears the bottom stack.
                        padding: const EdgeInsets.only(bottom: 160),
                        children: [
                          if (_kyliePlaylists.isNotEmpty) _buildKylieBand(),
                          if (_pinnedPlaylists.isNotEmpty) ...[
                            _buildShelfHeader('Pinned', icon: Icons.push_pin),
                            _buildPinnedShowcase(),
                            const SizedBox(height: 8),
                          ],
                          if (_recentlyPlayedPlaylists.isNotEmpty) ...[
                            _buildShelfHeader(
                              'Recently played',
                              icon: Icons.history,
                            ),
                            _buildPlaylistRail(_recentlyPlayedPlaylists),
                            const SizedBox(height: 8),
                          ],
                          _buildShelfHeader(
                            'All playlists',
                            count: _sortedPlaylists.length,
                          ),
                          _buildAllGrid(),
                        ],
                      ),
                    ),
            ),
          ],
        ),
        // Show nav bar when this is a pushed route (showMiniPlayer = true)
        floatingActionButton: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Animated expandable options
            SlideTransition(
              position: _slideAnimation,
              child: FadeTransition(
                opacity: _fabAnimation,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // Missing Albums button
                    _buildSpeedDialOption(
                      heroTag: 'missing',
                      icon: Icons.album_outlined,
                      label: 'Missing Albums',
                      color: Colors.orange,
                      onPressed: () {
                        _toggleFab();
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => MissingAlbumsScreen(
                              audioPlayerService: widget.audioPlayerService,
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    // Spotify Import button
                    _buildSpeedDialOption(
                      heroTag: 'import',
                      icon: null,
                      customIcon: Image.asset(
                        'assets/images/spotify_logo.png',
                        width: 20,
                        height: 20,
                      ),
                      label: 'Import from Spotify',
                      color: const Color(0xFF1DB954),
                      onPressed: () {
                        _toggleFab();
                        _showSpotifyImportDialog();
                      },
                    ),
                    const SizedBox(height: 12),
                    // Import from file (.m3u8) button
                    _buildSpeedDialOption(
                      heroTag: 'import_file',
                      icon: Icons.upload_file,
                      label: 'Import from File',
                      color: const Color(0xFF00d4ff),
                      iconColor: Colors.black,
                      onPressed: () {
                        _toggleFab();
                        _showM3u8ImportDialog();
                      },
                    ),
                    const SizedBox(height: 12),
                    // New Playlist button
                    _buildSpeedDialOption(
                      heroTag: 'create',
                      icon: Icons.playlist_add,
                      label: 'New Playlist',
                      color: const Color(0xFF00d4ff),
                      iconColor: Colors.black,
                      onPressed: () {
                        _toggleFab();
                        _showCreatePlaylistDialog();
                      },
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
            // Main FAB
            FloatingActionButton(
              heroTag: 'main',
              onPressed: _toggleFab,
              backgroundColor: _fabExpanded
                  ? Colors.grey[700]
                  : const Color(0xFF00d4ff),
              child: AnimatedRotation(
                turns: _fabExpanded ? 0.125 : 0,
                duration: const Duration(milliseconds: 200),
                child: Icon(
                  Icons.add,
                  color: _fabExpanded ? Colors.white : Colors.black,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _toggleFab() {
    setState(() {
      _fabExpanded = !_fabExpanded;
      if (_fabExpanded) {
        _fabAnimationController.forward();
      } else {
        _fabAnimationController.reverse();
      }
    });
  }

  Widget _buildSpeedDialOption({
    required String heroTag,
    IconData? icon,
    Widget? customIcon,
    required String label,
    required Color color,
    Color iconColor = Colors.white,
    required VoidCallback onPressed,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF1a2332),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
        const SizedBox(width: 12),
        FloatingActionButton.small(
          heroTag: heroTag,
          onPressed: onPressed,
          backgroundColor: color,
          child: customIcon ?? Icon(icon, color: iconColor, size: 20),
        ),
      ],
    );
  }
}
