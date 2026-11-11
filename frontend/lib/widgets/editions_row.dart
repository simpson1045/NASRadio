import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../screens/prowlarr_search_screen.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';

/// "Editions Available": every release of this album on MusicBrainz, sorted
/// into edition types (Dolby Atmos, 5.1, SACD, DVD-Audio, Blu-ray, hi-res,
/// Japan / SHM-CD, vinyl, remaster / deluxe). On an album you own
/// ([albumId] set) the editions you have get a check, and an Atmos / 5.1 copy
/// that MusicBrainz doesn't list is called out so it can be added there.
///
/// Per MusicBrainz only: its Atmos data is spotty, so "not listed" never
/// means "doesn't exist". No spinner while loading (an indeterminate spinner
/// redraws the whole window every frame on desktop).
class EditionsRow extends StatefulWidget {
  final int? albumId;
  final String artist;
  final String album;
  final AudioPlayerService audioPlayerService;

  const EditionsRow({
    super.key,
    this.albumId,
    required this.artist,
    required this.album,
    required this.audioPlayerService,
  });

  @override
  State<EditionsRow> createState() => _EditionsRowState();
}

class _EditionsRowState extends State<EditionsRow> {
  late Future<Map<String, dynamic>> _future;

  static const Map<String, Color> _colors = {
    'atmos': Color(0xFFB388FF),
    'surround': Color(0xFF26C6DA),
    'sacd': Color(0xFFFFD54F),
    'dvd_audio': Color(0xFFFFA726),
    'bluray': Color(0xFF42A5F5),
    'hires': Color(0xFF66BB6A),
    'japan': Color(0xFFEF5350),
    'vinyl': Color(0xFFBDBDBD),
    'remaster': Color(0xFF90A4AE),
  };

  /// What to add to the Prowlarr search for each edition type.
  static const Map<String, String> _searchWord = {
    'atmos': 'Atmos',
    'surround': '5.1',
    'sacd': 'SACD',
    'dvd_audio': 'DVD-Audio',
    'bluray': 'Blu-ray',
    'hires': '24bit',
    'japan': 'Japan',
    'vinyl': 'vinyl',
    'remaster': 'Deluxe',
  };

  static const Map<String, String> _labels = {
    'atmos': 'Dolby Atmos',
    'surround': '5.1 / Surround',
    'sacd': 'SACD',
    'dvd_audio': 'DVD-Audio / DualDisc',
    'bluray': 'Blu-ray',
    'hires': 'Hi-Res',
    'japan': 'Japan / SHM-CD',
    'vinyl': 'Vinyl',
    'remaster': 'Remaster / Deluxe',
  };

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<Map<String, dynamic>> _load({bool refresh = false}) {
    final api = ApiService();
    return widget.albumId != null
        ? api.getAlbumEditions(widget.albumId!, refresh: refresh)
        : api.getEditionsByName(widget.artist, widget.album);
  }

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Couldn't open $url")));
      }
    }
  }

  void _searchProwlarr(String typeKey) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ProwlarrSearchScreen(
          audioPlayerService: widget.audioPlayerService,
          initialQuery:
              '${widget.artist} ${widget.album} ${_searchWord[typeKey] ?? ''}'
                  .trim(),
        ),
      ),
    );
  }

  void _showType(Map<String, dynamic> type, String? releaseGroup) {
    final key = type['key'] as String;
    final releases = (type['releases'] as List? ?? []).cast<Map>();
    final count = type['count'] as int? ?? releases.length;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1a2332),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.75),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(
                  '${type['label']} · $count on MusicBrainz'
                  '${type['owned'] == true ? ' · you have one' : ''}',
                  style: TextStyle(
                    color: _colors[key] ?? Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final r in releases)
                      ListTile(
                        dense: true,
                        title: Text(
                          [
                            r['title'] ?? '',
                            if ((r['disambiguation'] ?? '').toString().isNotEmpty)
                              '(${r['disambiguation']})',
                          ].join(' '),
                          style: const TextStyle(color: Colors.white),
                        ),
                        subtitle: Text(
                          [
                            if ((r['date'] ?? '').toString().isNotEmpty) r['date'],
                            if ((r['country'] ?? '').toString().isNotEmpty) r['country'],
                            (r['formats'] as List? ?? []).join(' + '),
                            if ((r['label'] ?? '').toString().isNotEmpty) r['label'],
                            if ((r['track_count'] ?? 0) > 0) '${r['track_count']} tracks',
                          ].where((s) => s.toString().isNotEmpty).join(' · '),
                          style: const TextStyle(color: Colors.white54),
                        ),
                        trailing: const Icon(Icons.open_in_new,
                            size: 16, color: Colors.white38),
                        onTap: () =>
                            _open('https://musicbrainz.org/release/${r['id']}'),
                      ),
                    if (count > releases.length && releaseGroup != null)
                      ListTile(
                        dense: true,
                        title: Text(
                          '…and ${count - releases.length} more on MusicBrainz',
                          style: const TextStyle(color: Colors.white54),
                        ),
                        onTap: () => _open(
                            'https://musicbrainz.org/release-group/$releaseGroup'),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: TextButton.icon(
                  icon: const Icon(Icons.search),
                  label: Text('Search Prowlarr for the ${type['label']} edition'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _searchProwlarr(key);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(Map<String, dynamic> type, String? releaseGroup) {
    final key = type['key'] as String;
    final color = _colors[key] ?? Colors.white70;
    final owned = type['owned'] == true;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => _showType(type, releaseGroup),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: owned ? 0.28 : 0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: owned ? 0.9 : 0.45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (owned) ...[
              Icon(Icons.check, size: 13, color: color),
              const SizedBox(width: 3),
            ],
            Text(
              '${type['label']}  ${type['count']}',
              style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text('Looking up editions on MusicBrainz…',
                style: TextStyle(color: Colors.white38, fontSize: 12)),
          );
        }
        if (snap.hasError || snap.data == null) {
          return const SizedBox.shrink();
        }
        final data = snap.data!;
        final types = (data['types'] as List? ?? [])
            .cast<Map>()
            .map((t) => Map<String, dynamic>.from(t))
            .toList();
        final rg = data['release_group_mbid'] as String?;
        final missing =
            (data['missing_on_musicbrainz'] as List? ?? []).cast<String>();

        if (types.isEmpty && missing.isEmpty) {
          final note = data['note'] as String?;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              note ?? 'Only standard editions listed on MusicBrainz',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Text(
                    'EDITIONS AVAILABLE',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Colors.white70,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: rg == null
                        ? null
                        : () => _open('https://musicbrainz.org/release-group/$rg'),
                    child: const Text(
                      'per MusicBrainz',
                      style: TextStyle(fontSize: 11, color: Colors.white38),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [for (final t in types) _chip(t, rg)],
              ),
              if (missing.isNotEmpty && rg != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.info_outline, size: 14, color: Colors.amber.shade300),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'You have the ${missing.map((k) => _labels[k] ?? k).join(' and ')} '
                        "edition, but MusicBrainz doesn't list it yet",
                        style: TextStyle(color: Colors.amber.shade200, fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: () =>
                          _open('https://musicbrainz.org/release-group/$rg'),
                      child: const Text('Add it'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
