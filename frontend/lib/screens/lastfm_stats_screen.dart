import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/api_service.dart';

/// In-app Last.fm dashboard: profile totals, top artists + top tracks for a
/// selectable period, and a recent-scrobbles feed. Goal: never open Last.fm.
class LastfmStatsScreen extends StatefulWidget {
  final ApiService apiService;
  const LastfmStatsScreen({super.key, required this.apiService});

  @override
  State<LastfmStatsScreen> createState() => _LastfmStatsScreenState();
}

class _LastfmStatsScreenState extends State<LastfmStatsScreen> {
  static const _accent = Color(0xFF00d4ff);
  static const _card = Color(0xFF1a2332);
  static const _bg = Color(0xFF0d1b2a);

  // Last.fm period keys -> display labels.
  static const Map<String, String> _periods = {
    '7day': '7 Days',
    '1month': '1 Month',
    '3month': '3 Months',
    '12month': '1 Year',
    'overall': 'All Time',
  };

  String _period = 'overall';
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _stats;

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
      final s = await widget.apiService.getLastfmStats(period: _period);
      if (!mounted) return;
      setState(() {
        _stats = s;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        title: const Text('Last.fm'),
      ),
      body: RefreshIndicator(
        color: _accent,
        onRefresh: _load,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _stats == null) {
      return const Center(child: CircularProgressIndicator(color: _accent));
    }
    if (_error != null && _stats == null) {
      return ListView(
        children: [
          const SizedBox(height: 100),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Icon(Icons.cloud_off, color: Colors.white24, size: 48),
                  const SizedBox(height: 12),
                  Text(
                    "Couldn't load Last.fm stats.\n$_error",
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white54),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    final s = _stats!;
    final user = (s['user'] ?? {}) as Map<String, dynamic>;
    final topArtists = (s['top_artists'] ?? []) as List;
    final topTracks = (s['top_tracks'] ?? []) as List;
    final recent = (s['recent'] ?? []) as List;

    return ListView(
      padding: const EdgeInsets.only(bottom: 40),
      children: [
        _profileHeader(user),
        _periodSelector(),
        if (_loading)
          const LinearProgressIndicator(
            color: _accent,
            backgroundColor: Colors.transparent,
            minHeight: 2,
          ),
        _sectionTitle('Top Artists'),
        if (topArtists.isEmpty)
          _emptyNote('No artists for this period')
        else
          ...topArtists.asMap().entries.map(
                (e) => _rankRow(
                  e.key + 1,
                  e.value['image'] as String?,
                  (e.value['name'] ?? '') as String,
                  '${e.value['playcount']} plays',
                  circular: true,
                ),
              ),
        _sectionTitle('Top Tracks'),
        if (topTracks.isEmpty)
          _emptyNote('No tracks for this period')
        else
          ...topTracks.asMap().entries.map(
                (e) => _rankRow(
                  e.key + 1,
                  e.value['image'] as String?,
                  (e.value['name'] ?? '') as String,
                  '${e.value['artist'] ?? ''}  •  ${e.value['playcount']} plays',
                ),
              ),
        _sectionTitle('Recent Scrobbles'),
        if (recent.isEmpty)
          _emptyNote('No recent scrobbles')
        else
          ...recent.map((t) => _recentRow(t as Map<String, dynamic>)),
      ],
    );
  }

  Widget _profileHeader(Map<String, dynamic> user) {
    final name = (user['name'] ?? 'Last.fm') as String;
    final image = user['image'] as String?;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          ClipOval(
            child: _image(image, 64, circular: true),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _statChip('${user['playcount'] ?? 0}', 'scrobbles'),
                    _statChip('${user['artist_count'] ?? 0}', 'artists'),
                    _statChip('${user['track_count'] ?? 0}', 'tracks'),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statChip(String value, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: value,
              style: const TextStyle(
                color: _accent,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
            TextSpan(
              text: '  $label',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _periodSelector() {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        children: _periods.entries.map((e) {
          final selected = _period == e.key;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(e.value),
              selected: selected,
              onSelected: (_) {
                if (_period == e.key) return;
                setState(() => _period = e.key);
                _load();
              },
              selectedColor: _accent,
              backgroundColor: _card,
              labelStyle: TextStyle(
                color: selected ? Colors.black : Colors.white70,
                fontWeight: FontWeight.w600,
              ),
              side: BorderSide.none,
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w800,
          color: Colors.white,
          letterSpacing: -0.2,
        ),
      ),
    );
  }

  Widget _rankRow(
    int rank,
    String? image,
    String title,
    String subtitle, {
    bool circular = false,
  }) {
    return ListTile(
      dense: true,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 24,
            child: Text(
              '$rank',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white38,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 6),
          ClipRRect(
            borderRadius:
                BorderRadius.circular(circular ? 22 : 6),
            child: _image(image, 44, circular: circular),
          ),
        ],
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white54, fontSize: 12),
      ),
    );
  }

  Widget _recentRow(Map<String, dynamic> t) {
    final nowPlaying = t['nowplaying'] == true;
    return ListTile(
      dense: true,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: _image(t['image'] as String?, 44),
      ),
      title: Text(
        (t['name'] ?? '') as String,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        (t['artist'] ?? '') as String,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white54, fontSize: 12),
      ),
      trailing: nowPlaying
          ? const Icon(Icons.graphic_eq, color: _accent, size: 20)
          : Text(
              (t['date'] ?? '') as String,
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
    );
  }

  Widget _emptyNote(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Text(text, style: const TextStyle(color: Colors.white38)),
    );
  }

  Widget _image(String? url, double size, {bool circular = false}) {
    final fallback = Container(
      width: size,
      height: size,
      color: _card,
      child: Icon(
        circular ? Icons.person : Icons.music_note,
        color: _accent,
        size: size * 0.5,
      ),
    );
    if (url == null || url.isEmpty) return fallback;
    return CachedNetworkImage(
      imageUrl: url,
      width: size,
      height: size,
      fit: BoxFit.cover,
      placeholder: (_, __) => Container(width: size, height: size, color: _card),
      errorWidget: (_, __, ___) => fallback,
    );
  }
}
