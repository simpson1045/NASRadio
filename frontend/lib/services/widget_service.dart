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

      // Cache artwork — from URL for podcasts, from API for music. Only mark
      // it cached when the download actually SUCCEEDS, otherwise a single
      // failed fetch would wedge the widget on the placeholder forever (it
      // would never retry that album).
      if (artworkUrl != null && artworkUrl != _lastCachedArtworkUrl) {
        if (await _cacheArtworkFromUrl(artworkUrl)) {
          _lastCachedArtworkUrl = artworkUrl;
          _lastCachedAlbumId = null;
        }
      } else if (albumId != null && albumId > 0 && albumId != _lastCachedAlbumId) {
        if (await _cacheArtwork(albumId)) {
          _lastCachedAlbumId = albumId;
          _lastCachedArtworkUrl = null;
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
