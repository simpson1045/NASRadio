import 'dart:async';
import 'api_service.dart';

/// Coalesces the per-button favorite-status checks into batched requests.
///
/// Rendering a list of N songs mounts N [FavoriteButton]s, each of which used
/// to fire its own GET /favorites/check. ~70 landing at once exhausted the DB
/// connection pool (each request grabs a connection, and under eventlet the
/// queries serialize). This batcher collects all the (type, id) checks that
/// happen within a short window and issues ONE POST /favorites/check-batch per
/// item type instead — one connection, one query.
class FavoritesBatcher {
  FavoritesBatcher._();
  static final FavoritesBatcher instance = FavoritesBatcher._();

  final ApiService _api = ApiService();

  // type -> id -> waiters for that id's result.
  final Map<String, Map<int, List<Completer<bool>>>> _pending = {};
  Timer? _timer;

  // Endpoint caps a batch at 500 ids.
  static const int _maxBatch = 500;

  /// Returns this item's favorite status, batched with any other checks that
  /// occur within the coalescing window (~40ms).
  Future<bool> isFavorite(String itemType, int itemId) {
    final completer = Completer<bool>();
    _pending
        .putIfAbsent(itemType, () => {})
        .putIfAbsent(itemId, () => [])
        .add(completer);
    _timer ??= Timer(const Duration(milliseconds: 40), _flush);
    return completer.future;
  }

  void _flush() {
    _timer = null;
    if (_pending.isEmpty) return;

    // Snapshot and clear so checks arriving during the await land in the
    // next batch rather than getting lost.
    final snapshot = _pending.map((k, v) => MapEntry(k, v));
    _pending.clear();

    snapshot.forEach((itemType, byId) {
      final ids = byId.keys.toList();
      for (var i = 0; i < ids.length; i += _maxBatch) {
        final chunk = ids.sublist(
          i,
          i + _maxBatch > ids.length ? ids.length : i + _maxBatch,
        );
        _runChunk(itemType, chunk, byId);
      }
    });
  }

  Future<void> _runChunk(
    String itemType,
    List<int> ids,
    Map<int, List<Completer<bool>>> byId,
  ) async {
    try {
      final result = await _api.checkFavoritesBatch(itemType, ids);
      for (final id in ids) {
        _complete(byId[id], result[id] ?? false);
      }
    } catch (_) {
      // On failure, resolve to "not favorited" rather than leaving the
      // buttons spinning forever (matches the old per-button catch behavior).
      for (final id in ids) {
        _complete(byId[id], false);
      }
    }
  }

  void _complete(List<Completer<bool>>? waiters, bool value) {
    if (waiters == null) return;
    for (final c in waiters) {
      if (!c.isCompleted) c.complete(value);
    }
  }
}
