import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/album.dart';
import '../../models/artist.dart';
import '../../models/playlist.dart';
import '../../models/rss_feed.dart';
import '../../services/api_service.dart';
import '../../services/audio_player_service.dart';
import '../../widgets/tv_focus.dart';
import '../album_detail_screen.dart';
import '../artist_detail_screen.dart';
import 'tv_playlist_detail_screen.dart';
import 'tv_rss_feed_detail_screen.dart';

/// TV-variant Library. Four sub-tabs along the top — Albums, Playlists,
/// Artists, Podcasts — each rendered as a grid of cards underneath.
/// Tap a card to push the existing phone detail screen for that item;
/// the detail screens haven't been TV-ified yet (slice 3) but they're
/// functional via d-pad through Material's default focus on `ListTile`.
class TvLibraryScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;

  const TvLibraryScreen({super.key, required this.audioPlayerService});

  @override
  State<TvLibraryScreen> createState() => _TvLibraryScreenState();
}

class _TvLibraryScreenState extends State<TvLibraryScreen> {
  final ApiService _apiService = ApiService();

  int _selectedTab = 0;

  // Per-tab content. Lazy-loaded the first time each tab is shown so we
  // don't slam four list endpoints on rail entry — `getAlbums()` and
  // `getArtists()` can be heavy on a large library.
  List<Album>? _albums;
  List<Playlist>? _playlists;
  List<Artist>? _artists;
  List<RssFeed>? _feeds;

  bool _loadingAlbums = false;
  bool _loadingPlaylists = false;
  bool _loadingArtists = false;
  bool _loadingFeeds = false;

  // Cache of first-4 unique album IDs per playlist, used to render the
  // 2×2 collage in playlist cards. Same pattern as the phone playlists
  // screen — fetching `getPlaylist(id)` per playlist is N+1 against
  // the API, so we cache the result the first time a card asks for
  // it. Caches survive tab switches because TvMainNavigationScreen
  // keeps TvLibraryScreen mounted in an IndexedStack.
  final Map<int, List<int>> _playlistAlbumIdsCache = {};

  Future<List<int>> _getPlaylistAlbumIds(int playlistId) async {
    if (_playlistAlbumIdsCache.containsKey(playlistId)) {
      return _playlistAlbumIdsCache[playlistId]!;
    }
    try {
      final data = await _apiService.getPlaylist(playlistId);
      final songs = (data['songs'] as List?) ?? const [];
      final ids = <int>[];
      final seen = <int>{};
      for (final s in songs) {
        final albumId = s['album_id'];
        if (albumId is int && !seen.contains(albumId)) {
          seen.add(albumId);
          ids.add(albumId);
          if (ids.length >= 4) break;
        }
      }
      _playlistAlbumIdsCache[playlistId] = ids;
      return ids;
    } catch (_) {
      _playlistAlbumIdsCache[playlistId] = const [];
      return const [];
    }
  }

  @override
  void initState() {
    super.initState();
    // Albums is the default tab — load eagerly so the first focusable
    // card is ready when the user d-pads in from the rail.
    _loadAlbums();
  }

  Future<void> _loadAlbums() async {
    if (_albums != null || _loadingAlbums) return;
    setState(() => _loadingAlbums = true);
    try {
      final albums = await _apiService.getAlbums();
      if (!mounted) return;
      setState(() {
        _albums = albums;
        _loadingAlbums = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _albums = const <Album>[];
        _loadingAlbums = false;
      });
    }
  }

  Future<void> _loadPlaylists() async {
    if (_playlists != null || _loadingPlaylists) return;
    setState(() => _loadingPlaylists = true);
    try {
      final playlists = await _apiService.getPlaylists();
      if (!mounted) return;
      setState(() {
        _playlists = playlists;
        _loadingPlaylists = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _playlists = const <Playlist>[];
        _loadingPlaylists = false;
      });
    }
  }

  Future<void> _loadArtists() async {
    if (_artists != null || _loadingArtists) return;
    setState(() => _loadingArtists = true);
    try {
      final artists = await _apiService.getArtists();
      if (!mounted) return;
      setState(() {
        _artists = artists;
        _loadingArtists = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _artists = const <Artist>[];
        _loadingArtists = false;
      });
    }
  }

  Future<void> _loadFeeds() async {
    if (_feeds != null || _loadingFeeds) return;
    setState(() => _loadingFeeds = true);
    try {
      final raw = await _apiService.getRssFeeds();
      final feeds = raw
          .map((e) => RssFeed.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() {
        _feeds = feeds;
        _loadingFeeds = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _feeds = const <RssFeed>[];
        _loadingFeeds = false;
      });
    }
  }

  void _selectTab(int idx) {
    if (idx == _selectedTab) return;
    setState(() => _selectedTab = idx);
    switch (idx) {
      case 0:
        _loadAlbums();
      case 1:
        _loadPlaylists();
      case 2:
        _loadArtists();
      case 3:
        _loadFeeds();
    }
  }

  void _openAlbum(Album album) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AlbumDetailScreen(
          albumId: album.id,
          audioPlayerService: widget.audioPlayerService,
          artistName: album.artistName,
          artistId: album.artistId,
          parentLabel: 'Library',
        ),
      ),
    );
  }

  void _openPlaylist(Playlist playlist) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TvPlaylistDetailScreen(
          playlistId: playlist.id,
          audioPlayerService: widget.audioPlayerService,
        ),
      ),
    );
  }

  void _openArtist(Artist artist) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ArtistDetailScreen(
          artistId: artist.id,
          audioPlayerService: widget.audioPlayerService,
          parentLabel: 'Library',
        ),
      ),
    );
  }

  void _openFeed(RssFeed feed) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TvRssFeedDetailScreen(
          feed: feed,
          audioPlayerService: widget.audioPlayerService,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildTabStrip(),
        Expanded(
          child: IndexedStack(
            index: _selectedTab,
            children: [
              _buildAlbumsGrid(),
              _buildPlaylistsGrid(),
              _buildArtistsGrid(),
              _buildPodcastsGrid(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTabStrip() {
    const tabs = <(IconData, String)>[
      (Icons.album, 'Albums'),
      (Icons.playlist_play, 'Playlists'),
      (Icons.person, 'Artists'),
      (Icons.podcasts, 'Podcasts'),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 16, 40, 12),
      child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++) ...[
            _TvLibraryTab(
              icon: tabs[i].$1,
              label: tabs[i].$2,
              selected: _selectedTab == i,
              onTap: () => _selectTab(i),
            ),
            if (i < tabs.length - 1) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _buildAlbumsGrid() {
    if (_albums == null) {
      return const _LoadingCenter();
    }
    if (_albums!.isEmpty) {
      return const _EmptyMessage(text: 'No albums in your library yet.');
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(40, 8, 40, 24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 260,
        crossAxisSpacing: 18,
        mainAxisSpacing: 24,
        childAspectRatio: 0.78,
      ),
      itemCount: _albums!.length,
      itemBuilder: (context, i) {
        final a = _albums![i];
        return _LibraryCard(
          imageUrl: _apiService.getArtworkUrl(a.id),
          title: a.title,
          subtitle: a.artistName,
          fallbackIcon: Icons.album,
          autofocus: i == 0,
          onTap: () => _openAlbum(a),
        );
      },
    );
  }

  Widget _buildPlaylistsGrid() {
    if (_playlists == null) {
      return const _LoadingCenter();
    }
    if (_playlists!.isEmpty) {
      return const _EmptyMessage(text: 'No playlists yet.');
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(40, 8, 40, 24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 260,
        crossAxisSpacing: 18,
        mainAxisSpacing: 24,
        childAspectRatio: 0.78,
      ),
      itemCount: _playlists!.length,
      itemBuilder: (context, i) {
        final p = _playlists![i];
        // Build the 2×2 collage of first-4-unique-album covers
        // client-side, like the phone playlists screen does. The
        // backend's /api/playlist-artwork/<id> endpoint only returns
        // the FIRST song's album art (single image) — a 2×2 collage
        // requires fetching the playlist's songs and pulling the
        // first 4 distinct album_ids, which is what _getPlaylistAlbumIds
        // does. _TvPlaylistCard handles the FutureBuilder so each
        // playlist tile loads its collage independently as the user
        // scrolls.
        return _TvPlaylistCard(
          playlist: p,
          albumIdsFuture: _getPlaylistAlbumIds(p.id),
          subtitle: '${p.songCount} songs · ${p.durationFormatted}',
          onTap: () => _openPlaylist(p),
        );
      },
    );
  }

  Widget _buildArtistsGrid() {
    if (_artists == null) {
      return const _LoadingCenter();
    }
    if (_artists!.isEmpty) {
      return const _EmptyMessage(text: 'No artists yet.');
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(40, 8, 40, 24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 260,
        crossAxisSpacing: 18,
        mainAxisSpacing: 24,
        childAspectRatio: 0.78,
      ),
      itemCount: _artists!.length,
      itemBuilder: (context, i) {
        final a = _artists![i];
        final albumWord = a.albumCount == 1 ? 'album' : 'albums';
        return _LibraryCard(
          imageUrl: _apiService.getArtistImageUrl(a.id),
          title: a.name,
          subtitle: '${a.albumCount} $albumWord',
          fallbackIcon: Icons.person,
          isCircular: true,
          onTap: () => _openArtist(a),
        );
      },
    );
  }

  Widget _buildPodcastsGrid() {
    if (_feeds == null) {
      return const _LoadingCenter();
    }
    if (_feeds!.isEmpty) {
      return const _EmptyMessage(text: 'No podcast feeds yet.');
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(40, 8, 40, 24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 260,
        crossAxisSpacing: 18,
        mainAxisSpacing: 24,
        childAspectRatio: 0.78,
      ),
      itemCount: _feeds!.length,
      itemBuilder: (context, i) {
        final f = _feeds![i];
        return _LibraryCard(
          imageUrl: f.artworkCached ?? f.artworkUrl,
          title: f.title,
          subtitle: f.author.isNotEmpty ? f.author : '${f.episodeCount} episodes',
          fallbackIcon: Icons.podcasts,
          onTap: () => _openFeed(f),
        );
      },
    );
  }
}

class _TvLibraryTab extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _TvLibraryTab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? const Color(0xFF00d4ff) : Colors.white70;
    return TvFocusable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF00d4ff).withOpacity(0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? const Color(0xFF00d4ff).withOpacity(0.6)
                : Colors.white.withOpacity(0.12),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 16,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LibraryCard extends StatelessWidget {
  final String? imageUrl;
  final String title;
  final String subtitle;
  final IconData fallbackIcon;
  final bool isCircular;
  final bool autofocus;
  final VoidCallback onTap;

  const _LibraryCard({
    required this.imageUrl,
    required this.title,
    required this.subtitle,
    required this.fallbackIcon,
    required this.onTap,
    this.isCircular = false,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final radius = isCircular
        ? BorderRadius.circular(999)
        : BorderRadius.circular(8);
    return TvFocusable(
      onTap: onTap,
      autofocus: autofocus,
      borderRadius: radius,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: radius,
              child: (imageUrl != null && imageUrl!.isNotEmpty)
                  ? CachedNetworkImage(
                      imageUrl: imageUrl!,
                      fit: BoxFit.cover,
                      placeholder: (_, __) =>
                          Container(color: const Color(0xFF1a2332)),
                      errorWidget: (_, __, ___) => _FallbackTile(
                        icon: fallbackIcon,
                      ),
                    )
                  : _FallbackTile(icon: fallbackIcon),
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              subtitle,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 12,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Playlist card with a 2×2 collage of first-4-album covers built
/// client-side from the playlist's songs. Mirrors the phone playlists
/// screen's pattern (`playlists_screen.dart` line ~474). Single image
/// when the playlist has 1-3 unique albums; falls back to the
/// `playlist_play` icon when empty or on fetch error.
class _TvPlaylistCard extends StatelessWidget {
  final Playlist playlist;
  final Future<List<int>> albumIdsFuture;
  final String subtitle;
  final VoidCallback onTap;

  const _TvPlaylistCard({
    required this.playlist,
    required this.albumIdsFuture,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: FutureBuilder<List<int>>(
                future: albumIdsFuture,
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const _FallbackTile(icon: Icons.playlist_play);
                  }
                  final ids = snapshot.data!;
                  if (ids.isEmpty) {
                    return const _FallbackTile(icon: Icons.playlist_play);
                  }
                  if (ids.length < 4) {
                    return _AlbumArtImage(albumId: ids.first);
                  }
                  // 2×2 collage of the first 4 unique album covers.
                  return GridView.count(
                    crossAxisCount: 2,
                    physics: const NeverScrollableScrollPhysics(),
                    children: ids
                        .take(4)
                        .map((id) => _AlbumArtImage(albumId: id))
                        .toList(),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              playlist.name,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              subtitle,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Single album-cover image, used both as the standalone playlist
/// artwork (1-3 unique albums) and as a tile in the 2×2 collage
/// (4+ unique albums). Falls back to the playlist icon on load error.
class _AlbumArtImage extends StatelessWidget {
  final int albumId;
  const _AlbumArtImage({required this.albumId});

  @override
  Widget build(BuildContext context) {
    final apiService = ApiService();
    return CachedNetworkImage(
      imageUrl: apiService.getArtworkUrl(albumId),
      fit: BoxFit.cover,
      placeholder: (_, __) => Container(color: const Color(0xFF1a2332)),
      errorWidget: (_, __, ___) =>
          const _FallbackTile(icon: Icons.playlist_play),
    );
  }
}

class _FallbackTile extends StatelessWidget {
  final IconData icon;

  const _FallbackTile({required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0d1b2a),
      child: Center(
        child: Icon(
          icon,
          color: const Color(0xFF00d4ff).withOpacity(0.55),
          size: 64,
        ),
      ),
    );
  }
}

class _LoadingCenter extends StatelessWidget {
  const _LoadingCenter();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: CircularProgressIndicator(color: Color(0xFF00d4ff)),
    );
  }
}

class _EmptyMessage extends StatelessWidget {
  final String text;

  const _EmptyMessage({required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 48),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white38, fontSize: 18),
        ),
      ),
    );
  }
}
