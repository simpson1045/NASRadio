import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/playlist.dart';
import '../../models/song.dart';
import '../../services/api_service.dart';
import '../../services/audio_player_service.dart';
import '../../widgets/tv_focus.dart';
import '../now_playing_screen.dart';

/// TV-variant playlist detail. Shows the playlist's tracks as a vertical
/// list of d-pad-focusable rows; tap a row to start playback from that
/// track, queueing the rest of the playlist behind it.
class TvPlaylistDetailScreen extends StatefulWidget {
  final int playlistId;
  final AudioPlayerService audioPlayerService;

  const TvPlaylistDetailScreen({
    super.key,
    required this.playlistId,
    required this.audioPlayerService,
  });

  @override
  State<TvPlaylistDetailScreen> createState() =>
      _TvPlaylistDetailScreenState();
}

class _TvPlaylistDetailScreenState extends State<TvPlaylistDetailScreen> {
  final ApiService _apiService = ApiService();

  Playlist? _playlist;
  List<Song> _songs = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await _apiService.getPlaylist(widget.playlistId);
      final songsData = (data['songs'] as List?) ?? const [];
      // Skip Spotify-import placeholders (unavailable=0) — those have no
      // playable backing track. Phone version shows them greyed out;
      // for the TV layout we just hide them since you can't act on them.
      final songs = <Song>[];
      for (final json in songsData) {
        if ((json['available'] ?? 0) == 1) {
          songs.add(Song.fromJson(json as Map<String, dynamic>));
        }
      }
      if (!mounted) return;
      setState(() {
        _playlist = Playlist.fromJson(data);
        _songs = songs;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _playFrom(int index) {
    final p = _playlist;
    if (p == null) return;
    widget.audioPlayerService.setQueue(
      _songs,
      index,
      sourceType: 'playlist',
      sourceId: p.id,
      sourceName: p.name,
    );
    NowPlayingScreen.open(
      context,
      audioPlayerService: widget.audioPlayerService,
    );
  }

  void _playAll() => _playFrom(0);

  void _shuffleAll() {
    final p = _playlist;
    if (p == null || _songs.isEmpty) return;
    // Mirrors the phone playlist screen's shuffle pattern: pick a
    // random starting index, queue from there, then ensure shuffle
    // mode is on so the rest of the queue is also randomized as it
    // advances.
    final indices = List.generate(_songs.length, (i) => i)..shuffle();
    widget.audioPlayerService.setQueue(
      _songs,
      indices.first,
      sourceType: 'playlist',
      sourceId: p.id,
      sourceName: p.name,
    );
    if (!widget.audioPlayerService.isShuffled) {
      widget.audioPlayerService.toggleShuffle();
    }
    NowPlayingScreen.open(
      context,
      audioPlayerService: widget.audioPlayerService,
    );
  }

  String _fmtDuration(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050a14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0d1b2a),
        title: Text(_playlist?.name ?? 'Playlist'),
        elevation: 0,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF00d4ff)),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Text(
            'Couldn\'t load playlist: $_error',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 16),
          ),
        ),
      );
    }

    final p = _playlist;
    final songs = _songs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header — playlist info + Play/Shuffle action buttons.
        Padding(
          padding: const EdgeInsets.fromLTRB(40, 16, 40, 16),
          child: Row(
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: const Color(0xFF1a2332),
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.playlist_play,
                  color: Color(0xFF00d4ff),
                  size: 44,
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (p != null)
                      Text(
                        p.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    const SizedBox(height: 6),
                    Text(
                      p == null
                          ? '${songs.length} songs'
                          : '${songs.length} songs · ${p.durationFormatted}',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
              if (songs.isNotEmpty) ...[
                const SizedBox(width: 18),
                _TvActionButton(
                  icon: Icons.play_arrow,
                  label: 'Play',
                  primary: true,
                  autofocus: true,
                  onTap: _playAll,
                ),
                const SizedBox(width: 10),
                _TvActionButton(
                  icon: Icons.shuffle,
                  label: 'Shuffle',
                  onTap: _shuffleAll,
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0x1AFFFFFF)),
        if (songs.isEmpty)
          const Expanded(
            child: Center(
              child: Text(
                'No playable tracks in this playlist.',
                style: TextStyle(color: Colors.white38, fontSize: 16),
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
              itemCount: songs.length,
              itemBuilder: (context, i) => _TvTrackRow(
                song: songs[i],
                index: i + 1,
                durationText: _fmtDuration(songs[i].duration),
                // Play button in the header autofocuses on entry — no
                // sense competing with it from the first row.
                autofocus: false,
                onTap: () => _playFrom(i),
              ),
            ),
          ),
      ],
    );
  }
}

/// Compact action button for the playlist header (Play / Shuffle).
/// `primary: true` styles it as the cyan-filled "main action" button,
/// `false` is the dark surface variant. Cyan focus ring via TvFocusable.
class _TvActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;
  final bool autofocus;

  const _TvActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = primary ? Colors.black : Colors.white;
    final bg = primary
        ? const Color(0xFF00d4ff)
        : const Color(0xFF1a2332);
    return TvFocusable(
      onTap: onTap,
      autofocus: autofocus,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: fg, size: 20),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: fg,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TvTrackRow extends StatelessWidget {
  final Song song;
  final int index;
  final String durationText;
  final bool autofocus;
  final VoidCallback onTap;

  const _TvTrackRow({
    required this.song,
    required this.index,
    required this.durationText,
    required this.onTap,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final apiService = ApiService();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TvFocusable(
        onTap: onTap,
        autofocus: autofocus,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF0d1b2a),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 36,
                child: Text(
                  '$index',
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 14,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(width: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: CachedNetworkImage(
                  imageUrl: apiService.getArtworkUrl(song.albumId),
                  width: 48,
                  height: 48,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(
                    width: 48,
                    height: 48,
                    color: const Color(0xFF1a2332),
                  ),
                  errorWidget: (_, __, ___) => Container(
                    width: 48,
                    height: 48,
                    color: const Color(0xFF1a2332),
                    child: const Icon(
                      Icons.music_note,
                      color: Color(0xFF00d4ff),
                      size: 24,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      song.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${song.artistsFormatted} · ${song.albumTitle}',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 13,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Text(
                durationText,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 13,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
