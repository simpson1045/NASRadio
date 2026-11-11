import 'dart:async';

import 'package:flutter/material.dart';

import '../models/album.dart';
import '../models/playlist.dart';
import '../services/api_service.dart';

/// What a wake-up alarm plays. type null = the alarm tone only.
class AlarmSource {
  final String? type; // 'playlist' | 'album' | 'station' | 'shuffle'
  final int? id;
  final String? name;
  const AlarmSource(this.type, this.id, this.name);
}

/// Bottom sheet: pick a playlist, station, album (search) or library shuffle.
Future<AlarmSource?> showAlarmSourcePicker(BuildContext context) {
  return showModalBottomSheet<AlarmSource>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF111824),
    builder: (_) => const _AlarmSourcePicker(),
  );
}

class _AlarmSourcePicker extends StatefulWidget {
  const _AlarmSourcePicker();

  @override
  State<_AlarmSourcePicker> createState() => _AlarmSourcePickerState();
}

class _AlarmSourcePickerState extends State<_AlarmSourcePicker>
    with SingleTickerProviderStateMixin {
  static const _accent = Color(0xFF00d4ff);
  final _api = ApiService();
  late final TabController _tabs = TabController(length: 3, vsync: this);
  late final Future<List<Playlist>> _playlists = _api.getPlaylists();
  late final Future<List<Map<String, dynamic>>> _stations = _api.getStations();
  final _albumQuery = TextEditingController();
  List<Album> _albums = [];
  Timer? _debounce;

  @override
  void dispose() {
    _tabs.dispose();
    _albumQuery.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _searchAlbums(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      if (q.trim().length < 2) {
        setState(() => _albums = []);
        return;
      }
      try {
        final r = await _api.searchAlbums(q.trim());
        if (mounted) setState(() => _albums = r);
      } catch (_) {}
    });
  }

  void _pick(String? type, int? id, String? name) =>
      Navigator.of(context).pop(AlarmSource(type, id, name));

  Widget _error(Object e) => Padding(
        padding: const EdgeInsets.all(24),
        child: Text("Couldn't load: $e",
            style: const TextStyle(color: Colors.grey)),
      );

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.8,
      child: Column(
        children: [
          const SizedBox(height: 12),
          const Text('Wake to',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          ListTile(
            leading: const Icon(Icons.shuffle, color: _accent),
            title: const Text('Shuffle my library'),
            onTap: () => _pick('shuffle', null, 'Shuffle my library'),
          ),
          ListTile(
            leading: const Icon(Icons.notifications_active, color: Colors.grey),
            title: const Text('Alarm tone only'),
            subtitle: const Text("Your phone's alarm sound, no music"),
            onTap: () => _pick(null, null, null),
          ),
          TabBar(
            controller: _tabs,
            labelColor: _accent,
            indicatorColor: _accent,
            tabs: const [
              Tab(text: 'Playlists'),
              Tab(text: 'Stations'),
              Tab(text: 'Album'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                FutureBuilder<List<Playlist>>(
                  future: _playlists,
                  builder: (context, snap) {
                    if (snap.hasError) return _error(snap.error!);
                    if (!snap.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    return ListView(
                      children: [
                        for (final p in snap.data!)
                          ListTile(
                            leading: const Icon(Icons.queue_music),
                            title: Text(p.name,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text('${p.songCount} songs'),
                            onTap: () => _pick('playlist', p.id, p.name),
                          ),
                      ],
                    );
                  },
                ),
                FutureBuilder<List<Map<String, dynamic>>>(
                  future: _stations,
                  builder: (context, snap) {
                    if (snap.hasError) return _error(snap.error!);
                    if (!snap.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    return ListView(
                      children: [
                        for (final s in snap.data!)
                          if (s['id'] != null)
                            ListTile(
                              leading: const Icon(Icons.radio),
                              title: Text('${s['name'] ?? 'Station'}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              subtitle: Text('${s['genre'] ?? ''}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              onTap: () => _pick('station', s['id'] as int,
                                  '${s['name'] ?? 'Station'}'),
                            ),
                      ],
                    );
                  },
                ),
                Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: TextField(
                        controller: _albumQuery,
                        onChanged: _searchAlbums,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Search your albums',
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        children: [
                          for (final a in _albums)
                            ListTile(
                              leading: const Icon(Icons.album),
                              title: Text(a.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              subtitle: Text(a.artistName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              onTap: () => _pick('album', a.id,
                                  '${a.title} · ${a.artistName}'),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
