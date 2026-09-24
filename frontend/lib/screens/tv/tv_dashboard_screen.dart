import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/song.dart';
import '../../services/api_service.dart';
import '../../services/audio_player_service.dart';
import '../../widgets/tv_focus.dart';
import '../now_playing_screen.dart';

/// TV-variant dashboard. Vertical scroll of horizontally-scrolling rows
/// — the standard 10-foot UX pattern. Two rows in this slice (Recently
/// Played + Most Played); Recently Added albums lands in the Library
/// slice that's coming next.
class TvDashboardScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;

  const TvDashboardScreen({super.key, required this.audioPlayerService});

  @override
  State<TvDashboardScreen> createState() => _TvDashboardScreenState();
}

class _TvDashboardScreenState extends State<TvDashboardScreen> {
  final ApiService _apiService = ApiService();

  List<Song> _recentlyPlayed = [];
  List<Song> _mostPlayed = [];
  bool _loading = true;
  int? _lastSongId;

  @override
  void initState() {
    super.initState();
    _lastSongId = widget.audioPlayerService.currentSong?.id;
    widget.audioPlayerService.addListener(_onAudioChange);
    _loadAll();
  }

  @override
  void dispose() {
    widget.audioPlayerService.removeListener(_onAudioChange);
    super.dispose();
  }

  // Refresh "Recently Played" whenever a new song starts. The dashboard
  // is wrapped in an IndexedStack inside the TV main nav so initState
  // only fires once per app session — without this, the row never
  // updates after the first load.
  void _onAudioChange() {
    final cur = widget.audioPlayerService.currentSong;
    if (cur != null && cur.id != _lastSongId) {
      _lastSongId = cur.id;
      _refreshRecentlyPlayed();
    }
  }

  Future<void> _loadAll() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        _apiService.getRecentlyPlayed(limit: 30),
        _apiService.getMostPlayed(limit: 30),
      ]);
      if (!mounted) return;
      setState(() {
        _recentlyPlayed = results[0];
        _mostPlayed = results[1];
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _refreshRecentlyPlayed() async {
    try {
      final list = await _apiService.getRecentlyPlayed(limit: 30);
      if (!mounted) return;
      setState(() => _recentlyPlayed = list);
    } catch (_) {
      // Silent — recently-played freshness is nice-to-have, not critical.
    }
  }

  // Mirrors the phone dashboard's `_playSong`: fetch the full album so
  // prev/next work, queue from there with the tapped song as the start
  // index, fall back to single-song play if the album fetch fails.
  Future<void> _playSong(Song song) async {
    try {
      final albumData = await _apiService.getAlbum(song.albumId);
      final albumSongs = (albumData['songs'] as List).map((json) {
        json['artist_name'] = albumData['artist_name'];
        json['album_title'] = albumData['title'];
        return Song.fromJson(json);
      }).toList();

      final songIndex = albumSongs.indexWhere((s) => s.id == song.id);
      widget.audioPlayerService.setQueue(
        albumSongs,
        songIndex >= 0 ? songIndex : 0,
        sourceType: 'album',
        sourceId: song.albumId,
        sourceName: albumData['title'],
      );

      if (!mounted) return;
      NowPlayingScreen.open(
        context,
        audioPlayerService: widget.audioPlayerService,
      );
    } catch (_) {
      widget.audioPlayerService.setQueue([song], 0, sourceType: 'single');
      if (!mounted) return;
      NowPlayingScreen.open(
        context,
        audioPlayerService: widget.audioPlayerService,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF00d4ff)),
      );
    }

    final hasRecent = _recentlyPlayed.isNotEmpty;
    final hasMost = _mostPlayed.isNotEmpty;

    // Removed the giant "Home" header — redundant with the rail's
    // already-highlighted "Home" item, and at 38pt × 1.25 TV font
    // scaling it pushed "Recently Played" past the viewport on first
    // build, leaving the user unable to tell which row their cyan
    // focus ring was on. Section headers now sit at the top.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(40, 16, 40, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasRecent) ...[
            const _TvSectionHeader(title: 'Recently Played'),
            const SizedBox(height: 14),
            _TvSongRow(
              songs: _recentlyPlayed,
              onPlay: _playSong,
              autofocusFirst: true,
            ),
            const SizedBox(height: 24),
          ],
          if (hasMost) ...[
            const _TvSectionHeader(title: 'Most Played'),
            const SizedBox(height: 14),
            _TvSongRow(
              songs: _mostPlayed,
              onPlay: _playSong,
              autofocusFirst: !hasRecent,
            ),
            const SizedBox(height: 24),
          ],
          if (!hasRecent && !hasMost)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 96),
              child: Center(
                child: Text(
                  'Nothing here yet — play something on your phone first.',
                  style: TextStyle(color: Colors.white38, fontSize: 18),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TvSectionHeader extends StatelessWidget {
  final String title;

  const _TvSectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 22,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _TvSongRow extends StatelessWidget {
  final List<Song> songs;
  final void Function(Song) onPlay;
  final bool autofocusFirst;

  const _TvSongRow({
    required this.songs,
    required this.onPlay,
    this.autofocusFirst = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 270,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: songs.length,
        separatorBuilder: (_, __) => const SizedBox(width: 18),
        itemBuilder: (context, i) => _TvSongCard(
          song: songs[i],
          onTap: () => onPlay(songs[i]),
          autofocus: i == 0 && autofocusFirst,
        ),
      ),
    );
  }
}

class _TvSongCard extends StatelessWidget {
  final Song song;
  final VoidCallback onTap;
  final bool autofocus;

  const _TvSongCard({
    required this.song,
    required this.onTap,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final apiService = ApiService();
    return TvFocusable(
      onTap: onTap,
      autofocus: autofocus,
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 200,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CachedNetworkImage(
                imageUrl: apiService.getArtworkUrl(song.albumId),
                width: 200,
                height: 200,
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(
                  width: 200,
                  height: 200,
                  color: const Color(0xFF1a2332),
                ),
                errorWidget: (_, __, ___) => Container(
                  width: 200,
                  height: 200,
                  color: const Color(0xFF0d1b2a),
                  child: const Icon(
                    Icons.album,
                    color: Color(0xFF00d4ff),
                    size: 64,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                song.title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                song.artistsFormatted,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 13,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
