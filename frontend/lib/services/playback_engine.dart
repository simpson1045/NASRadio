import 'dart:async';

/// A "dumb" 2-slot playback engine. The app (AudioPlayerService) is the
/// single source of truth for the queue; this engine only ever holds at
/// most TWO things:
///
///   slot 0 = the currently-playing item
///   slot 1 = the pre-buffered lookahead ("next"), for gapless transition
///
/// The engine NEVER decides what plays next on its own. When slot 0
/// finishes and slot 1 exists, it gaplessly rolls to slot 1 and fires
/// [onAdvanced]; the app then promotes its `_currentIndex` and hands the
/// engine the new lookahead via [setNext]. When slot 0 finishes and there
/// is NO slot 1, it fires [onCompleted] and the app decides what to do
/// (stop, wrap for repeat-all, etc.).
///
/// This collapses the long-standing "two sources of truth" bug class:
/// the old design dumped the entire queue into media_kit's internal
/// playlist and tried to keep it in sync with the app's `_queue` by
/// hand — they drifted constantly ("play next" steamrolled, the player
/// "played what it wanted", crossfade fought the gapless handler). With
/// a 2-slot engine, queue operations only ever touch slots the app
/// explicitly controls, and the player physically cannot advance to
/// anything the app didn't put in slot 1.
///
/// Two concrete implementations:
///   - MediaKitEngine  (desktop: Windows / Linux / macOS)
///   - JustAudioEngine (mobile: Android / iOS)
///
/// Crossfade is built ON TOP of this by AudioPlayerService running two
/// engine instances (an A-deck and a B-deck) and fading volume between
/// them — neither engine needs to know about crossfade.
abstract class PlaybackEngine {
  /// A unique tag for logging ("a" / "b" for the crossfade decks).
  String get tag;

  // ---- Loading the two slots ----------------------------------------

  /// Load [item] into slot 0 as the current track and (optionally) begin
  /// playing. [startPosition] seeks immediately after load (resume).
  /// This replaces whatever was in both slots — it's a hard reset of the
  /// engine to a known single-item state. Used on explicit play, skip,
  /// previous, and queue jumps.
  Future<void> loadCurrent(
    EngineItem item, {
    Duration startPosition = Duration.zero,
    bool autoPlay = true,
  });

  /// Set (or replace) slot 1 — the pre-buffered lookahead. Passing null
  /// clears the lookahead (e.g. end of queue with no repeat). Safe to
  /// call repeatedly; replacing the lookahead does NOT disturb slot 0's
  /// playback. This is the heart of "play next": the app just hands the
  /// engine a different slot-1 item.
  Future<void> setNext(EngineItem? item);

  /// The item currently in slot 1, or null. Lets the app avoid redundant
  /// setNext calls when the desired lookahead is already loaded.
  EngineItem? get nextItem;

  // ---- Transport -----------------------------------------------------

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);

  /// Stop and clear both slots.
  Future<void> stop();

  Future<void> setVolume(double volume); // 0.0 - 1.0
  Future<void> setSpeed(double speed);
  Future<void> setPitchCorrectionEnabled(bool enabled);

  // ---- State streams -------------------------------------------------

  Stream<Duration> get positionStream;
  Stream<Duration?> get durationStream;
  Stream<bool> get playingStream;
  Stream<bool> get bufferingStream;

  /// Fires when slot 0 finished and the engine gaplessly rolled to the
  /// slot-1 lookahead. The app responds by promoting `_currentIndex`
  /// and loading the new next-next via [setNext].
  Stream<void> get onAdvanced;

  /// Fires when slot 0 finished and there was NO slot 1 to roll to.
  /// The app decides: stop, or wrap-to-start for repeat-all.
  Stream<void> get onCompleted;

  /// Fires on a playback error (bad stream, network drop, decode fail)
  /// for the CURRENT item, with a human-readable message.
  Stream<String> get onError;

  // ---- Current snapshot (cheap synchronous reads) --------------------

  Duration get position;
  Duration get duration;
  bool get playing;
  bool get buffering;

  Future<void> dispose();
}

/// What the engine needs to play one item. Decouples the engine from the
/// app's Song model — the app maps Song -> EngineItem when loading slots,
/// so the engine has no dependency on app types and stays trivially
/// testable. `id` is the app's song id (negative for podcast episodes),
/// used only to correlate engine events back to queue entries.
class EngineItem {
  final int id;
  final String url;
  final bool isPodcast;
  // Pre-known duration from metadata (DB), used as a fallback when the
  // decoder is slow to report duration on transcoded/opus streams.
  final Duration? knownDuration;

  // Display metadata for the OS media notification / lock-screen controls.
  // The MediaKitEngine ignores these (desktop drives controls differently);
  // the JustAudioEngine attaches them to the AudioSource `tag` so Android/iOS
  // show title/artist/album/art. All optional — an engine that doesn't need
  // them simply doesn't read them, and they do NOT affect equality/dedup.
  final String? title;
  final String? artist;
  final String? album;
  final String? artUri;

  const EngineItem({
    required this.id,
    required this.url,
    this.isPodcast = false,
    this.knownDuration,
    this.title,
    this.artist,
    this.album,
    this.artUri,
  });

  // Equality/hashCode are intentionally keyed ONLY on (id, url): two items
  // pointing at the same stream are "the same" for lookahead-dedup purposes
  // even if their display metadata differs. Do not fold metadata in here.
  @override
  bool operator ==(Object other) =>
      other is EngineItem && other.id == id && other.url == url;

  @override
  int get hashCode => Object.hash(id, url);

  @override
  String toString() => 'EngineItem(id=$id, podcast=$isPodcast)';
}
