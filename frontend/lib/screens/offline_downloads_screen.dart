import 'package:flutter/material.dart';

import '../main.dart' show globalAudioPlayerService;
import '../models/rss_feed.dart';
import '../services/api_service.dart';
import '../services/offline_service.dart';
import 'now_playing_screen.dart';

/// What's downloaded to this phone (offline_service.dart). Reads only the
/// phone's own index, so it works with no signal: play a download, see how
/// far along it is, or remove it.
class OfflineDownloadsScreen extends StatelessWidget {
  const OfflineDownloadsScreen({super.key});

  static const _accent = Color(0xFF00d4ff);

  @override
  Widget build(BuildContext context) {
    final o = OfflineService.instance;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Downloads'),
        backgroundColor: const Color(0xFF0d1b2a),
      ),
      body: AnimatedBuilder(
        animation: o,
        builder: (context, _) {
          final playlists = o.collectionsOf('playlist');
          final albums = o.collectionsOf('album');
          final episodes = o.collectionsOf('episode');
          final onPhone = o.localSongs();
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  '${o.downloadedSongCount} songs downloaded '
                  '(${OfflineService.formatBytes(o.downloadBytes)} of ${o.capGb} GB) · '
                  'replay cache ${OfflineService.formatBytes(o.cacheBytes)}'
                  '${o.problem != null ? '\n${o.problem}' : ''}',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.phone_android, color: _accent),
                title: const Text('Everything on this phone',
                    style: TextStyle(color: Colors.white)),
                subtitle: Text(
                    '${onPhone.length} songs, most recently played first',
                    style: const TextStyle(color: Colors.grey)),
                onTap: onPhone.isEmpty
                    ? null
                    : () => _play(context, onPhone, 'recently_played', null, null),
              ),
              if (playlists.isEmpty && albums.isEmpty && episodes.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Nothing downloaded yet. Use the Download button on a '
                    'playlist or album, or "Save to phone for offline" on a '
                    'podcast episode.',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              ..._section(context, 'Playlists', Icons.queue_music, playlists),
              ..._section(context, 'Albums', Icons.album, albums),
              ..._section(context, 'Podcasts', Icons.podcasts, episodes),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _section(BuildContext context, String title, IconData icon,
      List<OfflineCollection> items) {
    if (items.isEmpty) return const [];
    final o = OfflineService.instance;
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(title,
            style: const TextStyle(
                color: _accent, fontSize: 16, fontWeight: FontWeight.bold)),
      ),
      for (final c in items)
        Builder(builder: (context) {
          final st = o.statusOf(c.kind, c.id);
          final state = switch (st.state) {
            OfflineState.done => 'Downloaded',
            OfflineState.downloading => 'Downloading',
            OfflineState.waiting => o.problem ?? 'Waiting',
            OfflineState.none => '',
          };
          return ListTile(
            leading: Icon(icon, color: Colors.white70),
            title: Text(c.name.isEmpty ? '(loading…)' : c.name,
                style: const TextStyle(color: Colors.white),
                overflow: TextOverflow.ellipsis),
            subtitle: Text(
                c.kind == 'episode'
                    ? state
                    : '${st.done} of ${st.total} songs · $state',
                style: const TextStyle(color: Colors.grey)),
            onTap: st.done == 0 ? null : () => _open(context, c),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.white54),
              tooltip: 'Remove from phone',
              onPressed: () => _confirmRemove(context, c),
            ),
          );
        }),
    ];
  }

  void _open(BuildContext context, OfflineCollection c) {
    final o = OfflineService.instance;
    if (c.kind == 'episode') {
      final row = c.extra;
      if (row == null) return;
      final ep = RssEpisode.fromJson(row);
      globalAudioPlayerService.playPodcastEpisode(
        ep,
        ApiService().getRssStreamUrl(ep.id),
        artworkUrl: ep.artworkUrl ?? ep.feedArtworkUrl,
        podcastAuthor: ep.feedAuthor,
        podcastTitle: ep.feedTitle,
        feedId: ep.feedId,
        allEpisodes: [ep],
      );
      NowPlayingScreen.open(context, audioPlayerService: globalAudioPlayerService);
      return;
    }
    final songs = o.collectionSongs(c.kind, c.id);
    _play(context, songs, c.kind, c.id, c.name);
  }

  void _play(BuildContext context, List songs, String sourceType, int? id,
      String? name) {
    if (songs.isEmpty) return;
    globalAudioPlayerService.setQueue(
      List.from(songs),
      0,
      sourceType: sourceType,
      sourceId: id,
      sourceName: name,
    );
    NowPlayingScreen.open(context, audioPlayerService: globalAudioPlayerService);
  }

  Future<void> _confirmRemove(BuildContext context, OfflineCollection c) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1b2838),
        title: const Text('Remove from phone?'),
        content: Text('"${c.name}" is deleted from this phone. Songs another '
            'download uses stay. You can download it again any time.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (yes == true) await OfflineService.instance.remove(c.kind, c.id);
  }
}
