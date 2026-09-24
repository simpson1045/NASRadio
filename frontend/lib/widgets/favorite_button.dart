import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/favorites_batcher.dart';

class FavoriteButton extends StatefulWidget {
  final String itemType; // 'song', 'album', 'artist', or 'station'
  final int itemId;
  final double size;
  final Color? color;

  /// Optional hook run before ADDING a favorite, returning the real item id
  /// to favorite. Used by stations: an unsaved radio-browser result carries a
  /// synthetic negative id, so favoriting it must first save the station
  /// (backend upserts by URL) and favorite the returned DB id.
  final Future<int> Function()? resolveItemId;

  /// For stations only: the stream URL, used to CHECK favorite status
  /// (station Songs carry synthetic negative ids that can never match the
  /// favorites table — the URL is the station's stable identity).
  final String? stationUrl;

  const FavoriteButton({
    super.key,
    required this.itemType,
    required this.itemId,
    this.size = 24,
    this.color,
    this.resolveItemId,
    this.stationUrl,
  });

  @override
  State<FavoriteButton> createState() => _FavoriteButtonState();
}

class _FavoriteButtonState extends State<FavoriteButton> {
  final ApiService _apiService = ApiService();
  bool _isFavorite = false;
  bool _isLoading = true;
  // The id actually favorited — replaced by resolveItemId's result on add
  // (e.g. a station's synthetic negative id → its saved DB id).
  late int _itemId = widget.itemId;

  @override
  void initState() {
    super.initState();
    _checkFavoriteStatus();
  }

  Future<void> _checkFavoriteStatus() async {
    try {
      final bool isFavorite;
      if (widget.stationUrl != null && widget.stationUrl!.isNotEmpty) {
        // Stations: check by stream URL (see stationUrl doc) and adopt the
        // real station id so unfavorite targets the right row.
        final status =
            await _apiService.stationFavoriteStatus(widget.stationUrl!);
        isFavorite = status['is_favorite'] == true;
        final sid = status['station_id'];
        if (sid is num) _itemId = sid.toInt();
      } else {
        // Batched: many buttons mounting at once collapse into one
        // /favorites/check-batch request instead of a per-button storm
        // that exhausts the DB connection pool.
        isFavorite = await FavoritesBatcher.instance.isFavorite(
          widget.itemType,
          _itemId,
        );
      }
      // Widget can be disposed during the await above (user navigates
      // away mid-fetch). setState on a disposed State throws "Null check
      // operator used on a null value" — caught a 2026-05-23 crash.
      if (!mounted) return;
      setState(() {
        _isFavorite = isFavorite;
        _isLoading = false;
      });
    } catch (e) {
      print('❌ Failed to check favorite status: $e');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _toggleFavorite() async {
    // Optimistic update
    setState(() {
      _isFavorite = !_isFavorite;
    });

    try {
      if (_isFavorite) {
        if (widget.resolveItemId != null) {
          _itemId = await widget.resolveItemId!();
        }
        await _apiService.addFavorite(widget.itemType, _itemId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Added to favorites'),
              duration: Duration(seconds: 1),
            ),
          );
        }
      } else {
        await _apiService.removeFavorite(widget.itemType, _itemId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Removed from favorites'),
              duration: Duration(seconds: 1),
            ),
          );
        }
      }
    } catch (e) {
      print('❌ Failed to toggle favorite: $e');
      // Revert on error (only if still mounted — see _checkFavoriteStatus comment)
      if (!mounted) return;
      setState(() {
        _isFavorite = !_isFavorite;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: $e'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: const CircularProgressIndicator(strokeWidth: 2),
      );
    }

    return IconButton(
      icon: Icon(
        _isFavorite ? Icons.favorite : Icons.favorite_border,
        color: _isFavorite ? Colors.red : (widget.color ?? Colors.white54),
        size: widget.size,
      ),
      onPressed: _toggleFavorite,
    );
  }
}
