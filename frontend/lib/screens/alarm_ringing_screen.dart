import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/alarm_service.dart';
import '../services/api_service.dart';

/// Full-screen "alarm is ringing" page, shown over the lock screen: the
/// time, what's playing (art, title, artist, album), and Snooze / Stop /
/// "I'm up, keep playing". Back can't dismiss it: it's a deliberate choice.
/// It closes itself when the alarm ends any other way (notification button,
/// auto-silence).
class AlarmRingingScreen extends StatefulWidget {
  const AlarmRingingScreen({super.key});

  @override
  State<AlarmRingingScreen> createState() => _AlarmRingingScreenState();
}

class _AlarmRingingScreenState extends State<AlarmRingingScreen> {
  static const _accent = Color(0xFF00d4ff);
  late final Timer _clock;
  DateTime _now = DateTime.now();
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    AlarmService.instance.ringing.addListener(_onRingingChanged);
  }

  @override
  void dispose() {
    _clock.cancel();
    AlarmService.instance.ringing.removeListener(_onRingingChanged);
    super.dispose();
  }

  void _onRingingChanged() {
    if (AlarmService.instance.ringing.value == null) {
      _close();
    } else if (mounted) {
      setState(() {}); // new track / tone state
    }
  }

  void _close() {
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.of(context).pop();
  }

  Future<void> _stop() async {
    await AlarmService.instance.stop();
    _close();
  }

  Future<void> _snooze() async {
    await AlarmService.instance.snooze();
    _close();
  }

  Future<void> _keepPlaying() async {
    _close();
    await AlarmService.instance.keepPlaying();
  }

  String get _time {
    final h = _now.hour % 12 == 0 ? 12 : _now.hour % 12;
    return '$h:${_now.minute.toString().padLeft(2, '0')}';
  }

  Widget _art(Map<String, dynamic> track) {
    final albumId = track['albumId'] as int? ?? 0;
    final stationArt = track['art'] as String? ?? '';
    final url = albumId > 0
        ? ApiService().getArtworkUrl(albumId)
        : (stationArt.isNotEmpty ? stationArt : null);
    const placeholder = SizedBox(
      width: 88,
      height: 88,
      child: ColoredBox(
        color: Color(0xFF1a2332),
        child: Icon(Icons.music_note, color: _accent, size: 40),
      ),
    );
    if (url == null) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: CachedNetworkImage(
        imageUrl: url,
        width: 88,
        height: 88,
        fit: BoxFit.cover,
        placeholder: (_, __) => placeholder,
        errorWidget: (_, __, ___) => placeholder,
      ),
    );
  }

  /// What's playing, why the tone is playing, or that music is starting.
  Widget _nowPlaying(Map<String, dynamic>? info) {
    final track = info?['track'] as Map<String, dynamic>?;
    final tone = info?['tone'] as String?;
    Widget body;
    if (track != null) {
      final album = (track['album'] as String? ?? '');
      body = Row(
        children: [
          _art(track),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('NOW PLAYING',
                    style: TextStyle(
                        fontSize: 11, letterSpacing: 1.2, color: _accent)),
                const SizedBox(height: 4),
                Text(track['title'] as String? ?? '',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: Colors.white)),
                const SizedBox(height: 2),
                Text(track['artist'] as String? ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70)),
                if (album.isNotEmpty)
                  Text(album,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.grey)),
              ],
            ),
          ),
        ],
      );
    } else if (tone != null) {
      body = Row(
        children: [
          const Icon(Icons.notifications_active, color: Colors.orangeAccent),
          const SizedBox(width: 12),
          Expanded(
            child: Text('Alarm tone: $tone',
                style: const TextStyle(color: Colors.orangeAccent)),
          ),
        ],
      );
    } else {
      body = const Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 12),
          Text('Starting your music…', style: TextStyle(color: Colors.grey)),
        ],
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF111824),
        borderRadius: BorderRadius.circular(16),
      ),
      child: body,
    );
  }

  @override
  Widget build(BuildContext context) {
    final info = AlarmService.instance.ringing.value;
    final label = (info?['label'] as String?) ?? 'Alarm';
    final musicOn = info?['track'] != null;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF0a0e14),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Column(
              children: [
                const Spacer(),
                const Icon(Icons.alarm, size: 44, color: _accent),
                const SizedBox(height: 12),
                Text(
                  _time,
                  style: const TextStyle(
                    fontSize: 84,
                    fontWeight: FontWeight.w300,
                    color: Colors.white,
                  ),
                ),
                Text(
                  _now.hour < 12 ? 'AM' : 'PM',
                  style: const TextStyle(fontSize: 18, color: Colors.grey),
                ),
                const SizedBox(height: 12),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 20, color: Colors.white),
                ),
                const Spacer(),
                _nowPlaying(info),
                const Spacer(),
                if (musicOn) ...[
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: TextButton.icon(
                      onPressed: _keepPlaying,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text("I'm up, keep playing",
                          style: TextStyle(fontSize: 16)),
                      style: TextButton.styleFrom(foregroundColor: _accent),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                SizedBox(
                  width: double.infinity,
                  height: 60,
                  child: OutlinedButton.icon(
                    onPressed: _snooze,
                    icon: const Icon(Icons.snooze),
                    label: const Text('Snooze 9 min',
                        style: TextStyle(fontSize: 18)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _accent,
                      side: const BorderSide(color: _accent),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30)),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  height: 60,
                  child: FilledButton.icon(
                    onPressed: _stop,
                    icon: const Icon(Icons.alarm_off),
                    label: const Text('Stop', style: TextStyle(fontSize: 18)),
                    style: FilledButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30)),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
