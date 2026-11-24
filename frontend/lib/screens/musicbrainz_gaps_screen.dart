import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api_service.dart';

/// Albums you own in Dolby Atmos or 5.1 that MusicBrainz doesn't list in that
/// format, so they can be added there (/api/editions/gaps). "Check again"
/// starts a background scan on the server; the list fills in as it goes.
class MusicBrainzGapsScreen extends StatefulWidget {
  const MusicBrainzGapsScreen({super.key});

  @override
  State<MusicBrainzGapsScreen> createState() => _MusicBrainzGapsScreenState();
}

class _MusicBrainzGapsScreenState extends State<MusicBrainzGapsScreen> {
  Map<String, dynamic>? _data;
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool scan = false}) async {
    try {
      final data = await ApiService().getEditionsGaps(scan: scan);
      if (!mounted) return;
      setState(() {
        _data = data;
        _error = null;
      });
      // While the server scans, refresh every 5 s until it's done.
      _poll?.cancel();
      if (data['scan_running'] == true) {
        _poll = Timer(const Duration(seconds: 5), () {
          if (mounted) _load();
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _open(String url) async {
    if (!await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication) &&
        mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text("Couldn't open $url")));
    }
  }

  String _label(String key) => switch (key) {
        'atmos' => 'Dolby Atmos',
        'surround' => '5.1 / Surround',
        _ => key,
      };

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final gaps = (d?['gaps'] as List? ?? []).cast<Map>();
    final noLink = (d?['no_musicbrainz_link'] as List? ?? []).cast<Map>();
    final scanning = d?['scan_running'] == true;
    return Scaffold(
      appBar: AppBar(
        title: const Text('MusicBrainz gaps'),
        actions: [
          TextButton.icon(
            onPressed: scanning ? null : () => _load(scan: true),
            icon: const Icon(Icons.refresh),
            label: Text(scanning ? 'Checking…' : 'Check again'),
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Text("Couldn't load the report: $_error",
                  style: const TextStyle(color: Colors.grey)))
          : d == null
              ? const Center(
                  child: Text('Loading…', style: TextStyle(color: Colors.grey)))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                      'Of your ${d['albums_with_spatial']} Dolby Atmos / 5.1 '
                      'albums, ${d['already_listed']} are listed on MusicBrainz '
                      'in that format and ${gaps.length} are not.'
                      '${(d['pending'] ?? 0) > 0 ? ' ${d['pending']} still to check.' : ''}',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Tap one to open it on MusicBrainz and add the missing '
                      'release. NASRadio picks up changes within a week.',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    for (final g in gaps)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.spatial_audio_off,
                            color: Color(0xFFB388FF)),
                        title: Text('${g['artist']} — ${g['album']}',
                            style: const TextStyle(color: Colors.white)),
                        subtitle: Text(
                          'You have: ${(g['owned'] as List).map((k) => _label('$k')).join(', ')}'
                          '  ·  missing on MusicBrainz: '
                          '${(g['missing_on_musicbrainz'] as List).join(', ')}',
                          style: const TextStyle(color: Colors.white54),
                        ),
                        trailing: const Icon(Icons.open_in_new,
                            size: 16, color: Colors.white38),
                        onTap: () => _open('${g['musicbrainz_url']}'),
                      ),
                    if (noLink.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      const Text('No MusicBrainz match found',
                          style: TextStyle(
                              color: Colors.white70,
                              fontWeight: FontWeight.w600)),
                      const Text(
                        'Often classical albums, which MusicBrainz credits to '
                        'the composer. Tap to search for it.',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                      for (final n in noLink)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.search_off,
                              color: Colors.white38),
                          title: Text('${n['artist']} — ${n['album']}',
                              style: const TextStyle(color: Colors.white70)),
                          onTap: () => _open(
                              'https://musicbrainz.org/search?type=release_group&query='
                              '${Uri.encodeQueryComponent('${n['album']} ${n['artist']}')}'),
                        ),
                    ],
                  ],
                ),
    );
  }
}
