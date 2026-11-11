import 'package:flutter/material.dart';

import '../main.dart' show globalAudioPlayerService;
import '../services/api_service.dart';

/// Settings > Playback > Not now: the songs you've 👎'd (held 30 days) or
/// told to never play. Queues step over them; "Play again" lifts a hold.
class HeldSongsScreen extends StatefulWidget {
  const HeldSongsScreen({super.key});

  @override
  State<HeldSongsScreen> createState() => _HeldSongsScreenState();
}

class _HeldSongsScreenState extends State<HeldSongsScreen> {
  final ApiService _api = ApiService();
  List<Map<String, dynamic>>? _holds;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final holds = await _api.getHolds();
      if (mounted) setState(() => _holds = holds);
    } catch (e) {
      if (mounted) setState(() => _error = "Couldn't load your held songs");
    }
  }

  String _whenLabel(String? until) {
    if (until == null) return 'Never play';
    final t = DateTime.tryParse(until);
    if (t == null) return 'Held';
    final days = t.difference(DateTime.now()).inDays;
    if (days <= 0) return 'Back today';
    return days == 1 ? 'Back tomorrow' : 'Back in $days days';
  }

  Future<void> _lift(Map<String, dynamic> h) async {
    final id = (h['song_id'] as num).toInt();
    setState(() => _holds!.remove(h));
    try {
      await globalAudioPlayerService.unholdSong(id);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't reach the server; try again")),
        );
        _load();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final holds = _holds;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Held songs'),
        backgroundColor: const Color(0xFF0d1b2a),
      ),
      body: _error != null
          ? Center(child: Text(_error!, style: const TextStyle(color: Colors.grey)))
          : holds == null
              ? const Center(child: CircularProgressIndicator())
              : holds.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Nothing held. Tap 👎 on Now Playing to skip a song '
                          'for 30 days, or hold it for "Never play this".',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: holds.length,
                      itemBuilder: (context, i) {
                        final h = holds[i];
                        final never = h['until'] == null;
                        return ListTile(
                          leading: Icon(
                            never ? Icons.block : Icons.thumb_down_alt_outlined,
                            color: never ? Colors.redAccent : Colors.white54,
                          ),
                          title: Text('${h['title'] ?? 'Unknown'}',
                              style: const TextStyle(color: Colors.white),
                              overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            '${h['artist_name'] ?? ''} · ${_whenLabel(h['until'] as String?)}',
                            style: const TextStyle(color: Colors.grey),
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: TextButton(
                            onPressed: () => _lift(h),
                            child: const Text('Play again'),
                          ),
                        );
                      },
                    ),
    );
  }
}
