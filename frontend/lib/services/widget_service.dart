import 'dart:io';
import 'package:home_widget/home_widget.dart';
import 'package:path_provider/path_provider.dart';
import 'api_service.dart';
import 'auth_http_client.dart';
import 'app_logger.dart';

class WidgetService {
  static const _androidWidgetName = 'NowPlayingWidgetProvider';

  int? _lastCachedAlbumId;
  String? _lastCachedArtworkUrl;
  bool _isUpdating = false;
  // The widget updates every second while playing; a failed art fetch used
  // to retry on every one of those ticks (Oct 26: 375 401'd art requests in
  // a few minutes after the session expired). Wait a minute before retrying
  // the same art.
  String? _failedArtKey;
  DateTime? _failedArtAt;
  // The song whose waveform the widget has (sent once per song).
  int? _waveSongId;

  bool _artBackoff(String key) =>
      key == _failedArtKey &&
      _failedArtAt != null &&
      DateTime.now().difference(_failedArtAt!) < const Duration(minutes: 1);

  void _artFailed(String key) {
    _failedArtKey = key;
    _failedArtAt = DateTime.now();
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> updateWidget({
    required String? songTitle,
    required String? artistName,
    required String? albumName,
    required String? format,
    required int? albumId,
    required bool isPlaying,
    required Duration position,
    required Duration duration,
    String? artworkUrl,
    int? songId,
    List<double>? waveform,
    bool shuffleOn = false,
    int repeatMode = 0, // 0 off, 1 all, 2 one
  }) async {
    if (!Platform.isAndroid || _isUpdating) return;
    _isUpdating = true;

    try {
      await HomeWidget.saveWidgetData('song_title', songTitle ?? 'Not Playing');
      await HomeWidget.saveWidgetData('artist_name', artistName ?? '');
      await HomeWidget.saveWidgetData('album_name', albumName ?? '');
      await HomeWidget.saveWidgetData('format', format ?? '');
      await HomeWidget.saveWidgetData('is_podcast', artworkUrl != null);
      await HomeWidget.saveWidgetData('is_playing', isPlaying);
      await HomeWidget.saveWidgetData('current_time', _formatDuration(position));
      await HomeWidget.saveWidgetData('total_time', _formatDuration(duration));

      // Progress as 0-1000 int for ProgressBar
      final progress = duration.inMilliseconds > 0
          ? (position.inMilliseconds * 1000 ~/ duration.inMilliseconds)
          : 0;
      await HomeWidget.saveWidgetData('progress', progress);
      await HomeWidget.saveWidgetData('shuffle_on', shuffleOn);
      await HomeWidget.saveWidgetData('repeat_mode', repeatMode);

      // The song's waveform for the widget's progress bar, once per song
      // (the widget draws it, played part in the art's colour).
      if (songId != _waveSongId) {
        _waveSongId = songId;
        await HomeWidget.saveWidgetData('waveform', '');
        if (songId != null && songId > 0) {
          _sendWaveform(songId, waveform);
        }
      }

      // Cache artwork — from URL for podcasts, from API for music. Only mark
      // it cached when the download actually SUCCEEDS, otherwise a single
      // failed fetch would wedge the widget on the placeholder forever (it
      // would never retry that album).
      if (artworkUrl != null && artworkUrl != _lastCachedArtworkUrl) {
        if (!_artBackoff(artworkUrl)) {
          if (await _cacheArtworkFromUrl(artworkUrl)) {
            _lastCachedArtworkUrl = artworkUrl;
            _lastCachedAlbumId = null;
          } else {
            _artFailed(artworkUrl);
          }
        }
      } else if (albumId != null && albumId > 0 && albumId != _lastCachedAlbumId) {
        final key = 'album:$albumId';
        if (!_artBackoff(key)) {
          if (await _cacheArtwork(albumId)) {
            _lastCachedAlbumId = albumId;
            _lastCachedArtworkUrl = null;
          } else {
            _artFailed(key);
          }
        }
      }

      // Trigger native widget update
      await HomeWidget.updateWidget(androidName: _androidWidgetName);
    } catch (e) {
      // Don't crash the player if widget update fails
    } finally {
      _isUpdating = false;
    }
  }

  /// 64 bars, 0-100, comma-separated. Uses the player's copy when it has
  /// one, else fetches it (a slow fetch just leaves the plain bar for now).
  Future<void> _sendWaveform(int songId, List<double>? known) async {
    try {
      final w = known ?? await ApiService().getWaveform(songId);
      if (w.isEmpty || songId != _waveSongId) return;
      const bars = 64;
      final peak = w.reduce((a, b) => a > b ? a : b);
      final out = <int>[];
      for (var i = 0; i < bars; i++) {
        final from = i * w.length ~/ bars;
        final to = ((i + 1) * w.length ~/ bars).clamp(from + 1, w.length);
        var m = 0.0;
        for (var k = from; k < to; k++) {
          if (w[k] > m) m = w[k];
        }
        out.add(peak > 0 ? (m / peak * 100).round() : 0);
      }
      await HomeWidget.saveWidgetData('waveform', out.join(','));
      await HomeWidget.updateWidget(androidName: _androidWidgetName);
    } catch (_) {
      // No waveform: the widget keeps the plain progress bar.
    }
  }

  Future<void> clearWidget() async {
    if (!Platform.isAndroid) return;
    try {
      await HomeWidget.saveWidgetData('song_title', 'Not Playing');
      await HomeWidget.saveWidgetData('artist_name', '');
      await HomeWidget.saveWidgetData('album_name', '');
      await HomeWidget.saveWidgetData('format', '');
      await HomeWidget.saveWidgetData('is_playing', false);
      await HomeWidget.saveWidgetData('progress', 0);
      await HomeWidget.saveWidgetData('current_time', '0:00');
      await HomeWidget.saveWidgetData('total_time', '0:00');
      await HomeWidget.updateWidget(androidName: _androidWidgetName);
    } catch (_) {}
  }

  Future<bool> _cacheArtworkFromUrl(String url) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/widget_artwork.jpg');

      final response = await appHttpClient
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        await file.writeAsBytes(response.bodyBytes);
        await HomeWidget.saveWidgetData('artwork_path', file.path);
        return true;
      }
      AppLogger.instance
          .warning('[widget] artwork(url) failed: HTTP ${response.statusCode}');
      return false;
    } catch (e) {
      AppLogger.instance.warning('[widget] artwork(url) error: $e');
      return false;
    }
  }

  Future<bool> _cacheArtwork(int albumId) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/widget_artwork.jpg');

      final url = '${ApiService.baseHost}/api/artwork/$albumId?size=thumb';
      final response = await appHttpClient
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        await file.writeAsBytes(response.bodyBytes);
        await HomeWidget.saveWidgetData('artwork_path', file.path);
        return true;
      }
      AppLogger.instance
          .warning('[widget] artwork failed: HTTP ${response.statusCode} url=$url');
      return false;
    } catch (e) {
      AppLogger.instance
          .warning('[widget] artwork error: $e (baseHost=${ApiService.baseHost})');
      return false;
    }
  }
}
