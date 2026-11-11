import 'package:flutter/foundation.dart';

/// Fires only when [select] returns something different (compared with ==,
/// so a record of the shown fields works).
///
/// AudioPlayerService notifies 4 times a second while playing, for position
/// alone. A screen that only shows which song is playing (a highlight, a
/// play/pause icon) listens to this instead, so it rebuilds when that changes
/// rather than 4 times a second, even while hidden (Nov 9 audit).
class PlayerWatch extends ValueNotifier<Object?> {
  PlayerWatch(this.source, this.select) : super(select()) {
    source.addListener(_check);
  }

  final Listenable source;
  final Object? Function() select;

  void _check() => value = select();

  @override
  void dispose() {
    source.removeListener(_check);
    super.dispose();
  }
}
