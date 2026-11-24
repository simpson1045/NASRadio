import 'dart:math';

/// A shuffle that feels random: each artist's songs are spread evenly through
/// the list (random starting point, a little jitter), then a final pass keeps
/// the same artist from playing twice in a row wherever possible.
///
/// A plain shuffle is truly random, and true randomness clumps: Nov 11, 2026,
/// 80's Pop (144 songs, 11 Phil Collins / Genesis) played four of them in a
/// stretch of seven, Sussudio straight into One More Night. Spotify spreads
/// artists out for the same reason. Songs with no artist count as unique.
List<T> balancedShuffle<T>(List<T> items, String Function(T) artistOf,
    {Random? random}) {
  final rnd = random ?? Random();
  if (items.length < 3) return List<T>.from(items)..shuffle(rnd);

  String keyOf(T item, int index) {
    final a = artistOf(item).trim().toLowerCase();
    return a.isEmpty ? '\u0000$index' : a;
  }

  final groups = <String, List<T>>{};
  for (var i = 0; i < items.length; i++) {
    groups.putIfAbsent(keyOf(items[i], i), () => []).add(items[i]);
  }

  // Each artist's songs at even spacing over [0, 1): random offset inside the
  // first gap, +/-20% jitter on each position so it doesn't feel mechanical.
  final placed = <(double, String, T)>[];
  groups.forEach((key, songs) {
    songs.shuffle(rnd);
    final gap = 1.0 / songs.length;
    final offset = rnd.nextDouble() * gap;
    for (var i = 0; i < songs.length; i++) {
      final jitter = (rnd.nextDouble() - 0.5) * gap * 0.4;
      placed.add((offset + i * gap + jitter, key, songs[i]));
    }
  });
  placed.sort((a, b) => a.$1.compareTo(b.$1));

  final keys = [for (final p in placed) p.$2];
  final out = [for (final p in placed) p.$3];

  // Same artist back to back: swap in the nearest later song whose artist
  // differs from both neighbours, without creating a new clash where it was.
  bool fits(int pos, String key) =>
      (pos == 0 || keys[pos - 1] != key) &&
      (pos == keys.length - 1 || keys[pos + 1] != key);
  for (var i = 1; i < out.length; i++) {
    if (keys[i] != keys[i - 1]) continue;
    for (var j = i + 1; j < out.length; j++) {
      if (keys[j] == keys[i - 1]) continue;
      final ki = keys[i], kj = keys[j];
      keys[i] = kj;
      keys[j] = ki;
      if (fits(i, kj) && fits(j, ki)) {
        final t = out[i];
        out[i] = out[j];
        out[j] = t;
        break;
      }
      keys[i] = ki;
      keys[j] = kj;
    }
  }
  return out;
}

/// [balancedShuffle] in place, for code that shuffles a list it keeps.
void balancedShuffleInPlace<T>(List<T> items, String Function(T) artistOf) {
  final out = balancedShuffle(items, artistOf);
  items
    ..clear()
    ..addAll(out);
}
