import 'dart:async';
import 'dart:io' show SocketException;

import 'package:audio_service/audio_service.dart';
import 'package:http/http.dart' show ClientException;
import '../models/playlist.dart';
import 'offline_service.dart';
import 'api_service.dart';
import '../models/song.dart';
import '../models/rss_feed.dart';
import 'audio_player_service.dart' show AudioPlayerService, RepeatMode;
import 'app_logger.dart';
import 'auth_service.dart';

class NASRadioAudioHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayerService _playerService;

  // Throttle updates to avoid spam
  DateTime _lastUpdate = DateTime.now();
  static const _updateThreshold = Duration(milliseconds: 500);
  // What the car was last told (song / playing / buffering / loading), and a
  // timer that sends the latest update when the throttle held one back.
  Object? _lastPublishedState;
  Timer? _trailingUpdate;

  // Tracks the most recently published AndroidPlaybackInfo so we only
  // re-emit when the cast connection state, remote volume, or volume
  // control type actually changes. Without this, every position tick
  // (1Hz) would republish.
  static const int _kRemoteMaxVolume = 100;
  bool? _lastWasCasting;
  int? _lastRemoteVolumeIndex;
  AndroidVolumeControlType? _lastRemoteVolumeControlType;

  // The last MediaItem we published. Android Auto re-attaches the cover and
  // redraws its full-screen background on EVERY mediaItem update, so
  // republishing an identical item on each player tick (up to 2x a second)
  // made the AA background flash and glitch the whole drive. Publish only
  // when something the screen shows actually changed.
  String? _lastMediaItemKey;

  // ❤️ in the car: whether the current song is in Favorites (checked once
  // per song, flipped right away on a tap).
  int? _favForSongId;
  bool _currentIsFavorite = false;

  // The car's queue header ("Laid Back"), published only when it changes.
  String? _lastQueueTitle;
  // The queue as last sent to the car. Re-sending all of it on every update
  // (about twice a second) made Android Auto redraw the Up Next list and
  // jump back to the top, so you couldn't scroll or tap it (Nov 9 drive).
  String? _lastQueueKey;
  // Podcast rows the car listed, so a tap starts the episode without
  // fetching both episode lists again.
  final Map<int, Map<String, dynamic>> _episodeRows = {};
  static const _speedSteps = [1.0, 1.25, 1.5, 1.75, 2.0];

  // No signal: the car's lists answer from the phone (offline_service.dart).
  // After a network failure the server is skipped for a minute, so a dead
  // zone means instant lists instead of spinners.
  DateTime _offlineUntil = DateTime.fromMillisecondsSinceEpoch(0);

  static const _kGroupHint = 'android.media.browse.CONTENT_STYLE_GROUP_TITLE_HINT';
  // On a folder: show its albums as a cover grid, its playable rows (Play
  // All / Shuffle All) as a list.
  static const Map<String, dynamic> _gridOfAlbums = {
    'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT': 2, // grid
    'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT': 1, // list
  };

  NASRadioAudioHandler(this._playerService) {
    print('🎧 NASRadioAudioHandler created, attaching listener...');
    // Listen to player changes and update media session
    _playerService.addListener(_onPlayerChanged);
    AuthService.instance.addListener(updateMediaSessionPublic);
    _onPlayerChanged();
    print('🎧 Listener attached successfully');
  }

  /// Session expired: tell Android Auto / the lock screen the truth instead
  /// of a frozen "playing" with no audio (Oct 26 drive).
  void _showSignedOut() {
    playbackState.add(PlaybackState(
      controls: const [],
      processingState: AudioProcessingState.error,
      playing: false,
      errorCode: 401,
      errorMessage:
          'Signed out of NASRadio. Open the app on your phone to sign in.',
    ));
  }

  void _onPlayerChanged() {
    _syncAndroidPlaybackInfo();
    _updateMediaSession();
  }

  /// Emit RemoteAndroidPlaybackInfo while casting, LocalAndroidPlaybackInfo
  /// otherwise. Marking the MediaSession as remote tells Android we don't
  /// produce local audio — so other apps grabbing audio focus do NOT pause
  /// us, AND the lock-screen volume slider routes to the cast receiver
  /// (via [androidSetRemoteVolume] / [androidAdjustRemoteVolume]).
  ///
  /// The remote volume control type is derived from what the receiver
  /// reports in `RECEIVER_STATUS.volume.controlType`:
  ///   - 'fixed' (Chromecast → TV → AVR/eARC chain — the AVR is the
  ///     master volume controller and the cast device cannot change it)
  ///     → AndroidVolumeControlType.fixed: lock-screen slider is inert,
  ///       Android won't deliver volume keypresses to us, no
  ///       SET_VOLUME messages get sent. Honest UX — the user sees
  ///       there's no remote volume control instead of a slider that
  ///       moves on screen but does nothing audibly.
  ///   - everything else (or unknown, for setups without an AVR)
  ///     → AndroidVolumeControlType.absolute: the original behavior,
  ///       phone hardware keys + lock-screen slider drive the cast
  ///       receiver volume directly.
  void _syncAndroidPlaybackInfo() {
    final casting = _playerService.isCasting;
    final castControlType = casting
        ? _playerService.castServiceInstance.castVolumeControlType
        : null;
    final volIndex = casting
        ? (_playerService.castServiceInstance.castVolume * _kRemoteMaxVolume)
            .round()
            .clamp(0, _kRemoteMaxVolume)
        : 0;
    final androidControlType = castControlType == 'fixed'
        ? AndroidVolumeControlType.fixed
        : AndroidVolumeControlType.absolute;
    // Short-circuit when nothing actually changed. The volume/control-type
    // only vary while casting; when NOT casting they're reset to null, so
    // comparing them against the always-`absolute` androidControlType used to
    // ALWAYS fail — re-emitting LocalAndroidPlaybackInfo and logging
    // "MediaSession → LOCAL" on every call (~every 0.4s during playback). That
    // flooded the backend with log-ship requests and, on LAN, exhausted its
    // socket table → "too many file descriptors in select()" crash. Now the
    // volume checks only apply while casting.
    if (_lastWasCasting == casting &&
        (!casting ||
            (_lastRemoteVolumeControlType == androidControlType &&
                _lastRemoteVolumeIndex == volIndex))) {
      return;
    }
    _lastWasCasting = casting;
    _lastRemoteVolumeControlType = casting ? androidControlType : null;
    _lastRemoteVolumeIndex = casting ? volIndex : null;
    if (casting) {
      androidPlaybackInfo.add(RemoteAndroidPlaybackInfo(
        volumeControlType: androidControlType,
        maxVolume: _kRemoteMaxVolume,
        volume: volIndex,
      ));
      AppLogger.instance.info(
        '📺 [AudioHandler] MediaSession → REMOTE '
        '(vol=$volIndex/$_kRemoteMaxVolume, '
        'control=${androidControlType == AndroidVolumeControlType.fixed ? "fixed" : "absolute"}, '
        'castControlType=${castControlType ?? "unknown"})',
      );
    } else {
      androidPlaybackInfo.add(LocalAndroidPlaybackInfo());
      AppLogger.instance.info('📱 [AudioHandler] MediaSession → LOCAL');
    }
  }

  String? _getArtworkUrl(int? albumId) {
    // albumId <= 0 means there's no real album (e.g. a live station) — don't
    // build /api/artwork/0, which 401s and spams the media-session updates.
    if (albumId == null || albumId <= 0) return null;
    return _artworkUrl(albumId);
  }

  // Cover URL WITH the media token. Android Auto, the lock screen and the
  // notification fetch artUri themselves (no auth header), so a bare
  // /api/artwork/<id> just 401s and they show no art.
  static String _artworkUrl(dynamic albumId) => ApiService().getArtworkUrl(
      albumId is int ? albumId : int.parse('$albumId'));

  void updateMediaSessionPublic() {
    // Bypass throttle for external calls (playing state changes)
    _lastUpdate = DateTime.now().subtract(const Duration(seconds: 1));
    _updateMediaSession();
  }

  void _updateMediaSession() {
    // Throttle position-only updates, but never lose one: until Nov 10 an
    // update inside the 500 ms window was simply dropped. Leaving home Wi-Fi
    // blipped "buffering" on and off 150 ms apart while paused; the "off"
    // was dropped, nothing else followed (paused = no position updates), and
    // Android Auto showed a spinning, dead play button until pause + play.
    // Real state changes (song, playing, buffering, loading) go out at once.
    final now = DateTime.now();
    final state = (
      _playerService.currentSong?.id,
      _playerService.isPlaying,
      _playerService.isBuffering,
      _playerService.isLoading,
    );
    final stateChanged = state != _lastPublishedState;
    final sinceLast = now.difference(_lastUpdate);
    if (!stateChanged && sinceLast < _updateThreshold) {
      _trailingUpdate ??= Timer(_updateThreshold - sinceLast, () {
        _trailingUpdate = null;
        _updateMediaSession();
      });
      return;
    }
    _trailingUpdate?.cancel();
    _trailingUpdate = null;
    _lastUpdate = now;
    _lastPublishedState = state;

    if (AuthService.instance.sessionExpired) {
      _showSignedOut();
      return;
    }

    final song = _playerService.currentSong;
    final isPlaying = _playerService.isPlaying;
    print('🔔 Audio handler update: song=${song?.title}, playing=$isPlaying');
    try {
      if (song != null) {
        // For podcasts, use the podcast artwork URL directly — the
        // regular artwork endpoint doesn't have music-style album art
        // for virtual podcast album rows.
        String? artworkUrl;
        if (song.isStation &&
            song.stationArtworkUrl != null &&
            song.stationArtworkUrl!.isNotEmpty) {
          artworkUrl = song.stationArtworkUrl;
        } else if (song.isPodcast && _playerService.podcastArtworkUrl != null) {
          artworkUrl = _playerService.podcastArtworkUrl;
        } else {
          artworkUrl = _getArtworkUrl(song.albumId);
        }
        // (Build 167 tried the artist photo in the ART_URI extra for Android
        // Auto's background; a 2026-10-08 drive showed AA still blurs the
        // album cover, so it was reverted.)
        final itemKey = [
          song.id,
          _playerService.displayTitle,
          _playerService.displayArtist,
          _albumLine(song),
          _playerService.duration,
          artworkUrl,
        ].join('|');
        if (itemKey != _lastMediaItemKey) {
          _lastMediaItemKey = itemKey;
          if (_canFavorite(song) && _favForSongId != song.id) {
            _favForSongId = song.id;
            _currentIsFavorite = false;
            _refreshFavorite(song.id);
          }
          mediaItem.add(
            MediaItem(
              id: song.id.toString(),
              // Station-aware: shows the live track on a station, the song
              // title otherwise — so Android Auto / lock screen track the
              // broadcast.
              title: _playerService.displayTitle,
              artist: _playerService.displayArtist,
              album: _albumLine(song),
              duration: _playerService.duration,
              artUri: artworkUrl != null ? Uri.tryParse(artworkUrl) : null,
            ),
          );
          print('✅ mediaItem updated (artUri: $artworkUrl)');
          // Shipped to the server log: what Android Auto / the lock screen
          // were given, so a drive is checkable afterwards (more than ~2 lines
          // per song = the background is flapping again). Tokens stripped.
          String? bare(String? u) => u?.split('?').first;
          AppLogger.instance.info(
              '🚗 [MediaItem] "${_playerService.displayTitle}" '
              'art=${bare(artworkUrl)} '
              'dur=${_playerService.duration?.inSeconds}s');
        }
      }
    } catch (e) {
      print('❌ mediaItem error: $e');
    }

    try {
      playbackState.add(
        PlaybackState(
          controls: [
            if (_playerService.isPlayingPodcast)
              MediaControl(
                androidIcon: 'drawable/ic_speed',
                label: 'Speed ${_speedLabel(_playerService.playbackSpeed)}',
                action: MediaAction.custom,
                customAction: const CustomMediaAction(name: 'Speed'),
              ),
            if (_canFavorite(song))
              MediaControl(
                androidIcon: _currentIsFavorite
                    ? 'drawable/ic_favorite_on'
                    : 'drawable/ic_favorite',
                label: 'Favorite',
                action: MediaAction.custom,
                customAction: const CustomMediaAction(name: 'Favorite'),
              ),
            if (!_playerService.isPlayingPodcast)
            MediaControl(
              androidIcon: _playerService.isShuffled
                  ? 'drawable/ic_shuffle_on'
                  : 'drawable/ic_shuffle',
              label: 'Shuffle',
              action: MediaAction.custom,
              // Named, or audio_service drops it from the car / lock screen
              // (it only builds a real custom action when customAction is set).
              customAction: const CustomMediaAction(name: 'Shuffle'),
            ),
            MediaControl.skipToPrevious,
            _playerService.isPlaying ? MediaControl.pause : MediaControl.play,
            MediaControl.skipToNext,
            if (!_playerService.isPlayingPodcast)
            MediaControl(
              androidIcon: _playerService.repeatMode != RepeatMode.off
                  ? 'drawable/ic_repeat_on'
                  : 'drawable/ic_repeat',
              label: 'Repeat',
              action: MediaAction.custom,
              customAction: const CustomMediaAction(name: 'Repeat'),
            ),
            if (_canFavorite(song))
              MediaControl(
                androidIcon: 'drawable/ic_thumb_down',
                label: 'Not now',
                action: MediaAction.custom,
                customAction: const CustomMediaAction(name: 'NotNow'),
              ),
          ],
          systemActions: const {
            MediaAction.seek,
            MediaAction.seekForward,
            MediaAction.seekBackward,
            MediaAction.setShuffleMode,
            MediaAction.setRepeatMode,
            MediaAction.skipToQueueItem,
            MediaAction.playFromSearch,
          },
          // Indexes into the NOTIFICATION's buttons, which are only the
          // non-custom ones (prev / play / next); used below Android 13.
          androidCompactActionIndices: const [0, 1, 2],
          // Spinner in the car while the NAS is still filling the buffer.
          processingState: _playerService.isBuffering
              ? AudioProcessingState.buffering
              : AudioProcessingState.ready,
          playing: _playerService.isPlaying,
          updatePosition: _playerService.position,
          bufferedPosition: _playerService.duration,
          speed: _playerService.playbackSpeed,
          queueIndex: _playerService.currentIndex,
          shuffleMode: _playerService.isShuffled
              ? AudioServiceShuffleMode.all
              : AudioServiceShuffleMode.none,
          repeatMode: _playerService.repeatMode == RepeatMode.one
              ? AudioServiceRepeatMode.one
              : _playerService.repeatMode == RepeatMode.all
              ? AudioServiceRepeatMode.all
              : AudioServiceRepeatMode.none,
        ),
      );
      // Update queue for Android Auto
      try {
        final queueKey = _playerService.queue.isEmpty
            ? ''
            : '${ApiService.baseHost}|${_playerService.queue.map((s) => s.id).join(',')}';
        if (_playerService.queue.isNotEmpty && queueKey != _lastQueueKey) {
          _lastQueueKey = queueKey;
          queue.add(
            _playerService.queue
                .map(
                  (song) {
                    // Station favicon, else podcast art, else album art.
                    final artworkUrl = (song.isStation &&
                            song.stationArtworkUrl != null &&
                            song.stationArtworkUrl!.isNotEmpty)
                        ? song.stationArtworkUrl
                        : (song.isPodcast &&
                                _playerService.podcastArtworkUrl != null)
                            ? _playerService.podcastArtworkUrl
                            : _getArtworkUrl(song.albumId);
                    final artUri =
                        artworkUrl != null ? Uri.tryParse(artworkUrl) : null;
                    return MediaItem(
                      id: 'song_${song.id}',
                      title: song.title,
                      artist: song.artistsFormatted,
                      album: song.albumTitle,
                      artUri: artUri,
                    );
                  },
                )
                .toList(),
          );
          print('✅ queue updated (${_playerService.queue.length} items)');
        }
      } catch (e) {
        print('❌ queue error: $e');
      }
      final qt = _playerService.playingFromDisplay ?? '';
      if (qt != _lastQueueTitle) {
        _lastQueueTitle = qt;
        queueTitle.add(qt);
      }
      print('✅ playbackState updated');
    } catch (e) {
      print('❌ playbackState error: $e');
    }
  }

  @override
  Future<void> play() async {
    // Explicit, not toggle — the OS told us WHICH way to go. See
    // playExplicit/pauseExplicit for why toggling here inverted
    // commands whenever state was briefly stale (e.g. TV-remote pause).
    AppLogger.instance.info('🚗 [AudioHandler] play (was playing=${_playerService.isPlaying}, '
        'buffering=${_playerService.isBuffering}, song="${_playerService.currentSong?.title}")');
    await _playerService.playExplicit();
    AppLogger.instance.info('🚗 [AudioHandler] play done (playing=${_playerService.isPlaying})');
    // Force immediate UI update
    _lastUpdate = DateTime.now().subtract(const Duration(seconds: 1));
    _updateMediaSession();
  }

  @override
  Future<void> pause() async {
    AppLogger.instance.info('🚗 [AudioHandler] pause (was playing=${_playerService.isPlaying})');
    await _playerService.pauseExplicit();
    // Force immediate UI update
    _lastUpdate = DateTime.now().subtract(const Duration(seconds: 1));
    _updateMediaSession();
  }

  @override
  Future<void> stop() async {
    await _playerService.stop();
  }

  @override
  Future<void> skipToNext() async {
    await _playerService.next();
  }

  @override
  Future<void> skipToPrevious() async {
    await _playerService.previous();
  }

  @override
  Future<void> seek(Duration position) async {
    await _playerService.seek(position);
  }

  // Lock-screen / system volume routing while casting.
  //
  // When MediaSession is in REMOTE mode (see _syncAndroidPlaybackInfo),
  // Android sends volume changes here instead of adjusting the local
  // STREAM_MUSIC level. We forward to the cast receiver so the phone's
  // hardware volume keys and lock-screen slider control the TV.

  @override
  Future<void> androidSetRemoteVolume(int volumeIndex) async {
    if (!_playerService.isCasting) return;
    // When the receiver reports controlType=fixed, the cast service skips
    // the SET_VOLUME send anyway — but Android shouldn't even deliver here
    // since our RemoteAndroidPlaybackInfo.volumeControlType is also fixed.
    // Bailing early avoids the log noise of "told to set volume; will be
    // ignored downstream".
    if (_playerService.castServiceInstance.castVolumeControlType == 'fixed') return;
    final clamped = volumeIndex.clamp(0, _kRemoteMaxVolume);
    final level = clamped / _kRemoteMaxVolume;
    AppLogger.instance.info('🔊 [AudioHandler] androidSetRemoteVolume → $clamped/$_kRemoteMaxVolume (${level.toStringAsFixed(2)})');
    _playerService.castServiceInstance.setCastVolume(level);
  }

  @override
  Future<void> androidAdjustRemoteVolume(AndroidVolumeDirection direction) async {
    if (!_playerService.isCasting) return;
    if (_playerService.castServiceInstance.castVolumeControlType == 'fixed') return;
    // 5% step matches typical Android volume-key feel. Raise/lower only —
    // AndroidVolumeDirection.same is a no-op. AndroidVolumeDirection is
    // not a Dart enum (it's a class with static finals), so .index is the
    // discriminator: -1 lower, 0 same, +1 raise.
    if (direction.index == 0) return;
    final delta = direction.index > 0 ? 0.05 : -0.05;
    AppLogger.instance.info('🔊 [AudioHandler] androidAdjustRemoteVolume → index=${direction.index} ($delta)');
    _playerService.castServiceInstance.adjustCastVolume(delta);
  }

  // Android Auto / Media Browser support
  final ApiService _apiService = ApiService();

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    print('🚗 Android Auto requesting children for: $parentMediaId');

    if (parentMediaId == AudioService.recentRootId) {
      // The "resume" card Android Auto shows when the car connects: what was
      // playing last (after the startup restore has had a moment to run).
      await _playerService.restoredOnce
          .timeout(const Duration(seconds: 5), onTimeout: () {});
      final song = _playerService.currentSong;
      if (song == null) return [];
      final art = song.isStation
          ? song.stationArtworkUrl
          : (song.isPodcast
              ? _playerService.podcastArtworkUrl
              : _getArtworkUrl(song.albumId));
      return [
        MediaItem(
          id: 'resume',
          title: _playerService.displayTitle,
          artist: _playerService.displayArtist,
          album: _playerService.playingFromDisplay,
          playable: true,
          artUri: (art != null && art.isNotEmpty) ? Uri.tryParse(art) : null,
        ),
      ];
    }
    if (parentMediaId == AudioService.browsableRootId) {
      // Root menu - dashboard style with quick access
      // Android Auto shows at most 4 root tabs; the rest live in Library.
      return [
        const MediaItem(id: 'playlists', title: 'Playlists', playable: false),
        const MediaItem(id: 'favorites', title: 'Favorites', playable: false),
        const MediaItem(id: 'stations', title: 'Stations', playable: false),
        const MediaItem(id: 'browse', title: 'Library', playable: false),
      ];
    } else if (parentMediaId == 'recently_played') {
      // Recently played - limited to 50
      try {
        return _carSongRows(await _loadCarList('rec', 0));
      } catch (e) {
        print('❌ Failed to load recently played: $e');
        return [];
      }
    } else if (parentMediaId == 'favorites') {
      // Favorite songs - limited to 100
      try {
        return _carSongRows(await _loadCarList('fav', 0));
      } catch (e) {
        print('❌ Failed to load favorites: $e');
        return [];
      }
    } else if (parentMediaId == 'playlists') {
      // User playlists
      try {
        final playlists = await _net(() => _apiService.getPlaylists());
        return playlists
            .map(
              (playlist) => MediaItem(
                id: 'playlist_${playlist.id}',
                title: playlist.name,
                playable: false,
              ),
            )
            .toList();
      } catch (e) {
        // No signal: the playlists downloaded to the phone.
        print('❌ Failed to load playlists ($e): showing downloads');
        return [
          for (final c in OfflineService.instance.collectionsOf('playlist'))
            MediaItem(id: 'playlist_${c.id}', title: c.name, playable: false),
        ];
      }
    } else if (parentMediaId.startsWith('playlist_') &&
        !parentMediaId.startsWith('playlist_shuffle_') &&
        !parentMediaId.startsWith('playlist_play_')) {
      // Songs in a playlist (only the ones in the library; Spotify-import
      // placeholders can't play and used to show up as "Unknown" rows)
      try {
        final playlistId = int.parse(
          parentMediaId.replaceFirst('playlist_', ''),
        );
        final list = await _loadCarList('pl', playlistId);

        // Play All (in order) + Shuffle All at the top
        return [
          MediaItem(
            id: 'playlist_play_$playlistId',
            title: '▶ Play All',
            playable: true,
          ),
          MediaItem(
            id: 'playlist_shuffle_$playlistId',
            title: '🔀 Shuffle All',
            playable: true,
          ),
          ..._carSongRows(list),
        ];
      } catch (e) {
        print('❌ Failed to load playlist songs: $e');
        return [];
      }
    } else if (parentMediaId == 'stations') {
      try {
        final stations = await _net(() => _apiService.getStations());
        return [
          for (final s in stations)
            if (_intOf(s['id']) > 0)
              MediaItem(
                id: 'st_${_intOf(s['id'])}',
                title: (s['name'] ?? 'Station').toString(),
                artist: (s['genre'] ?? 'Live Radio').toString(),
                playable: true,
                artUri: _httpUri(s['favicon']),
              ),
        ];
      } catch (e) {
        print('❌ Failed to load stations: $e');
        return [];
      }
    } else if (parentMediaId == 'most_played') {
      try {
        return _carSongRows(await _loadCarList('mp', 0));
      } catch (e) {
        print('❌ Failed to load most played: $e');
        return [];
      }
    } else if (parentMediaId == 'recently_added') {
      try {
        final data = await _net(() => _apiService.getRecentlyAdded(days: 90, limit: 60));
        return [
          for (final a in ((data['albums'] as List?) ?? []))
            _albumRow(_intOf(a['id']), '${a['title'] ?? 'Unknown'}',
                a['artist_name']?.toString()),
        ];
      } catch (e) {
        print('❌ Failed to load recently added: $e');
        return [];
      }
    } else if (parentMediaId == 'genres') {
      // Biggest 40 of ~390 ("Rock---Hard Rock" shows as Hard Rock / Rock).
      try {
        final genres = await _net(() => _apiService.getGenres());
        return [
          for (final g in genres.take(40))
            MediaItem(
              id: 'genre|${Uri.encodeComponent('${g['genre']}')}',
              title: _genreName('${g['genre']}'),
              artist: _genreParent('${g['genre']}') ??
                  '${_intOf(g['count'])} songs',
              playable: false,
            ),
        ];
      } catch (e) {
        print('❌ Failed to load genres: $e');
        return [];
      }
    } else if (parentMediaId.startsWith('genre|')) {
      try {
        final enc = parentMediaId.substring(6);
        final list = await _loadGenre(Uri.decodeComponent(enc));
        return [
          MediaItem(id: 'gplay|$enc', title: '▶ Play All', playable: true),
          MediaItem(id: 'gshuf|$enc', title: '🔀 Shuffle All', playable: true),
          for (var i = 0; i < list.songs.length; i++)
            MediaItem(
              id: 'gs|$i|${list.songs[i].id}|$enc',
              title: list.songs[i].title,
              artist: list.songs[i].artistsFormatted,
              album: list.songs[i].albumTitle,
              playable: true,
              artUri: _songArt(list.songs[i]),
            ),
        ];
      } catch (e) {
        print('❌ Failed to load genre songs: $e');
        return [];
      }
    } else if (parentMediaId == 'decades') {
      try {
        final decades = await _net(() => _apiService.getDecades());
        return [
          for (final d in decades)
            if (_intOf(d['decade']) > 0)
              MediaItem(
                id: 'decade_${_intOf(d['decade'])}',
                title: '${_intOf(d['decade'])}s',
                artist: '${_intOf(d['album_count'])} albums',
                playable: false,
                extras: _gridOfAlbums,
              ),
        ];
      } catch (e) {
        print('❌ Failed to load decades: $e');
        return [];
      }
    } else if (parentMediaId.startsWith('decade_')) {
      try {
        final albums = await _apiService
            .getAlbumsByDecade(int.parse(parentMediaId.substring(7)));
        return [for (final a in albums) _albumRow(a.id, a.title, a.artistName)];
      } catch (e) {
        print('❌ Failed to load decade albums: $e');
        return [];
      }
    } else if (parentMediaId == 'podcasts') {
      // Episodes you're partway through, then the newest ones.
      final rows = <MediaItem>[];
      final seen = <int>{};
      try {
        for (final e in await _net(() => _apiService.getRecentlyPlayedEpisodes(limit: 20))) {
          final id = _intOf(e['id']);
          if (_intOf(e['played_position']) <= 0 ||
              _intOf(e['is_completed']) == 1 ||
              !seen.add(id)) {
            continue;
          }
          _episodeRows[id] = e;
          rows.add(_episodeRow(e, 'Continue listening'));
        }
      } catch (e) {
        print('❌ Failed to load in-progress episodes: $e');
      }
      try {
        for (final e in await _net(() => _apiService.getRecentEpisodes(limit: 20))) {
          final id = _intOf(e['id']);
          if (!seen.add(id)) continue;
          _episodeRows[id] = e;
          rows.add(_episodeRow(e, 'New episodes'));
        }
      } catch (e) {
        print('❌ Failed to load new episodes: $e');
      }
      // Downloaded episodes (all there is with no signal).
      final o = OfflineService.instance;
      for (final c in o.collectionsOf('episode')) {
        if (c.extra == null || !o.hasLocal(c.songIds.first) || !seen.add(c.id)) {
          continue;
        }
        _episodeRows[c.id] = c.extra!;
        rows.add(_episodeRow(c.extra!, 'Downloaded'));
      }
      return rows;
    } else if (parentMediaId == 'downloads') {
      // What's downloaded to the phone; works with no signal.
      final o = OfflineService.instance;
      return [
        const MediaItem(
          id: 'on_phone',
          title: 'Everything on this phone',
          playable: false,
        ),
        for (final c in o.collectionsOf('playlist'))
          MediaItem(
            id: 'playlist_${c.id}',
            title: c.name,
            playable: false,
            extras: const {_kGroupHint: 'Playlists'},
          ),
        for (final c in o.collectionsOf('album'))
          MediaItem(
            id: 'album_${c.id}',
            title: c.name,
            playable: false,
            artUri: c.id > 0 ? Uri.parse(_artworkUrl(c.id)) : null,
            extras: const {_kGroupHint: 'Albums'},
          ),
        for (final c in o.collectionsOf('episode'))
          if (c.extra != null && o.hasLocal(c.songIds.first))
            _episodeRow(c.extra!, 'Podcasts'),
      ];
    } else if (parentMediaId == 'on_phone') {
      return _carSongRows(await _loadCarList('loc', 0));
    } else if (parentMediaId == 'browse') {
      // Library menu
      return [
        const MediaItem(id: 'downloads', title: 'Downloads', playable: false),
        const MediaItem(
          id: 'recently_played',
          title: 'Recently Played',
          playable: false,
        ),
        const MediaItem(
          id: 'recently_added',
          title: 'Recently Added',
          playable: false,
          extras: _gridOfAlbums,
        ),
        const MediaItem(id: 'most_played', title: 'Most Played', playable: false),
        const MediaItem(id: 'albums', title: 'Albums', playable: false),
        const MediaItem(id: 'artists', title: 'Artists', playable: false),
        const MediaItem(id: 'genres', title: 'Genres', playable: false),
        const MediaItem(id: 'decades', title: 'Decades', playable: false),
        const MediaItem(id: 'podcasts', title: 'Podcasts', playable: false),
      ];
    } else if (parentMediaId == 'albums') {
      // Show A-Z letter navigation
      const letters = [
        '#',
        'A',
        'B',
        'C',
        'D',
        'E',
        'F',
        'G',
        'H',
        'I',
        'J',
        'K',
        'L',
        'M',
        'N',
        'O',
        'P',
        'Q',
        'R',
        'S',
        'T',
        'U',
        'V',
        'W',
        'X',
        'Y',
        'Z',
      ];
      return letters
          .map(
            (letter) =>
                MediaItem(
                  id: 'albums_$letter',
                  title: letter,
                  playable: false,
                  extras: _gridOfAlbums,
                ),
          )
          .toList();
    } else if (parentMediaId.startsWith('albums_')) {
      // Albums starting with specific letter
      try {
        final letter = parentMediaId.replaceFirst('albums_', '');
        final albums = await _net(() => _apiService.getAlbums());
        final filtered = albums.where((album) {
          if (letter == '#') {
            // Numbers and symbols
            return album.title.isNotEmpty &&
                !RegExp(r'^[A-Za-z]').hasMatch(album.title);
          }
          return album.title.toUpperCase().startsWith(letter);
        }).toList();
        return filtered
            .map(
              (album) => MediaItem(
                id: 'album_${album.id}',
                title: album.title,
                artist: album.artistName,
                playable: false,
                artUri: Uri.parse(_artworkUrl(album.id)),
              ),
            )
            .toList();
      } catch (e) {
        print('❌ Failed to load albums ($e): albums on the phone');
        return _offlineAlbumRows(parentMediaId.replaceFirst('albums_', ''));
      }
    } else if (parentMediaId == 'artists') {
      // Show A-Z letter navigation
      const letters = [
        '#',
        'A',
        'B',
        'C',
        'D',
        'E',
        'F',
        'G',
        'H',
        'I',
        'J',
        'K',
        'L',
        'M',
        'N',
        'O',
        'P',
        'Q',
        'R',
        'S',
        'T',
        'U',
        'V',
        'W',
        'X',
        'Y',
        'Z',
      ];
      return letters
          .map(
            (letter) => MediaItem(
              id: 'artists_$letter',
              title: letter,
              playable: false,
            ),
          )
          .toList();
    } else if (parentMediaId.startsWith('artists_')) {
      // Artists starting with specific letter
      try {
        final letter = parentMediaId.replaceFirst('artists_', '');
        final artists = await _net(() => _apiService.getArtists());
        final filtered = artists.where((artist) {
          if (letter == '#') {
            return artist.name.isNotEmpty &&
                !RegExp(r'^[A-Za-z]').hasMatch(artist.name);
          }
          return artist.name.toUpperCase().startsWith(letter);
        }).toList();
        return filtered
            .map(
              (artist) => MediaItem(
                id: 'artist_${artist.id}',
                title: artist.name,
                playable: false,
                extras: _gridOfAlbums,
              ),
            )
            .toList();
      } catch (e) {
        print('❌ Failed to load artists: $e');
        return [];
      }
    } else if (parentMediaId.startsWith('album_')) {
      // List songs in album
      try {
        final albumId = int.parse(parentMediaId.replaceFirst('album_', ''));
        return _carSongRows(await _loadCarList('al', albumId));
      } catch (e) {
        print('❌ Failed to load album songs: $e');
        return [];
      }
    } else if (parentMediaId.startsWith('artist_')) {
      // List albums by artist
      try {
        final artistId = int.parse(parentMediaId.replaceFirst('artist_', ''));
        final artistData = await _net(() => _apiService.getArtist(artistId));
        final List<dynamic> albumsJson = artistData['albums'] ?? [];
        final albumRows = albumsJson
            .map(
              (a) => MediaItem(
                id: 'album_${a['id']}',
                title: a['title'] ?? 'Unknown',
                artist: artistData['name'],
                playable: false,
                artUri: Uri.parse(_artworkUrl(a['id'])),
              ),
            )
            .toList();
        return [
          MediaItem(id: 'arplay_$artistId', title: '▶ Play All', playable: true),
          MediaItem(
            id: 'arshuf_$artistId',
            title: '🔀 Shuffle All',
            playable: true,
          ),
          ...albumRows,
        ];
      } catch (e) {
        print('❌ Failed to load artist albums: $e');
        final artistId =
            int.tryParse(parentMediaId.replaceFirst('artist_', '')) ?? 0;
        return [
          MediaItem(id: 'arplay_$artistId', title: '▶ Play All', playable: true),
          MediaItem(
            id: 'arshuf_$artistId',
            title: '🔀 Shuffle All',
            playable: true,
          ),
        ];
      }
    }

    return [];
  }

  @override
  Future<void> playMediaItem(MediaItem mediaItem) async {
    print('[AudioHandler] playMediaItem: ${mediaItem.id} (${mediaItem.title})');
    await _playById(mediaItem.id);
  }

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    print('[AudioHandler] playFromMediaId: $mediaId');
    await _playById(mediaId);
  }

  /// Everything the car can play lands here. Song rows carry the list they
  /// were shown in: `q_<kind>_<listId>_<index>_<songId>`, kind = pl (playlist),
  /// al (album), fav (favorites), rec (recently played). Tapping one queues
  /// that WHOLE list in order from that song, like the phone's screens do.
  /// (Until Nov 6 rows were a bare `song_<id>`, so tapping a playlist song
  /// played just that song and then carried on with its album.)
  Future<void> _playById(String id) async {
    try {
      if (id.startsWith('playlist_shuffle_') ||
          id.startsWith('playlist_play_')) {
        final playlistId = int.parse(id.substring(id.lastIndexOf('_') + 1));
        final list = await _loadCarList('pl', playlistId);
        print('🚗 Playlist $playlistId: ${list.songs.length} playable songs');
        if (list.songs.isEmpty) return;
        if (id.startsWith('playlist_shuffle_')) list.songs.shuffle();
        _startCarList(list, 0);
      } else if (id.startsWith('arplay_') || id.startsWith('arshuf_')) {
        final list = await _loadCarList('ar', int.parse(id.substring(7)));
        if (list.songs.isEmpty) return;
        if (id.startsWith('arshuf_')) list.songs.shuffle();
        _startCarList(list, 0);
      } else if (id.startsWith('st_')) {
        await _playStation(int.parse(id.substring(3)));
      } else if (id == 'resume') {
        await play();
      } else if (id.startsWith('gplay|') || id.startsWith('gshuf|')) {
        final list = await _loadGenre(Uri.decodeComponent(id.substring(6)));
        if (list.songs.isEmpty) return;
        if (id.startsWith('gshuf|')) list.songs.shuffle();
        _startCarList(list, 0);
      } else if (id.startsWith('gs|')) {
        final parts = id.split('|'); // gs, index, songId, genre
        if (parts.length != 4) return;
        final list = await _loadGenre(Uri.decodeComponent(parts[3]));
        final index = int.parse(parts[1]);
        final songId = int.parse(parts[2]);
        final start = index < list.songs.length && list.songs[index].id == songId
            ? index
            : list.songs.indexWhere((s) => s.id == songId);
        if (start < 0) return;
        _startCarList(list, start);
      } else if (id.startsWith('ep_')) {
        await _playEpisode(int.parse(id.substring(3)));
      } else if (id.startsWith('q_')) {
        final parts = id.split('_'); // q, kind, listId, index, songId
        if (parts.length != 5) return;
        final list = await _loadCarList(parts[1], int.parse(parts[2]));
        final index = int.parse(parts[3]);
        final songId = int.parse(parts[4]);
        // The index handles a song that's in the list twice; fall back to
        // the song id if the list changed since the car showed it.
        var start = index < list.songs.length && list.songs[index].id == songId
            ? index
            : list.songs.indexWhere((s) => s.id == songId);
        if (start < 0) {
          // Not in that list any more: just play the song.
          final song = Song.fromJson(await _apiService.getSongDetails(songId));
          await _playerService.playSong(song);
          return;
        }
        _startCarList(list, start);
      } else if (id.startsWith('song_')) {
        final songId = int.parse(id.replaceFirst('song_', ''));
        try {
          final song =
              Song.fromJson(await _net(() => _apiService.getSongDetails(songId)));
          await _playerService.playSong(song);
        } catch (e) {
          // No signal: play it from the phone, with the rest of what's there.
          final local = OfflineService.instance.localSongs();
          final i = local.indexWhere((s) => s.id == songId);
          if (i < 0) rethrow;
          _startCarList(_CarList('loc', 0, local, 'recently_played', null), i);
        }
      }
    } catch (e) {
      print('❌ [AudioHandler] could not play $id: $e');
    }
  }

  /// The songs behind one car list. getChildren (what the car shows) and
  /// _playById (what plays) both use this, so the indexes always line up.
  /// No signal: the same list from what's on the phone.
  Future<_CarList> _loadCarList(String kind, int listId) async {
    if (kind == 'loc') return _offlineCarList(kind, listId)!;
    try {
      final list = await _net(() => _loadCarListOnline(kind, listId),
          seconds: kind == 'ar' ? 30 : 10);
      if (kind == 'fav' || kind == 'mp') {
        OfflineService.instance.rememberList(kind, list.songs);
      }
      return list;
    } catch (e) {
      final off = _offlineCarList(kind, listId);
      if (off == null) rethrow;
      print('🚗 offline list $kind $listId: ${off.songs.length} songs on the phone');
      return off;
    }
  }

  /// A car list from what's on the phone (downloads + replay cache).
  _CarList? _offlineCarList(String kind, int listId) {
    final o = OfflineService.instance;
    if (!o.isReady) return null;
    switch (kind) {
      case 'pl':
        return _CarList('pl', listId, o.collectionSongs('playlist', listId),
            'playlist', o.collection(OfflineService.keyFor('playlist', listId))?.name);
      case 'al':
        var songs = o.collectionSongs('album', listId);
        if (songs.isEmpty) {
          songs = o.localSongs().where((s) => s.albumId == listId).toList()
            ..sort((a, b) => a.trackNumber.compareTo(b.trackNumber));
        }
        return _CarList('al', listId, songs, 'album',
            songs.isEmpty ? null : songs.first.albumTitle);
      case 'fav':
        return _CarList('fav', 0, o.rememberedLocal('fav'), 'favorites', null);
      case 'mp':
        return _CarList('mp', 0, o.rememberedLocal('mp'), 'most_played', null);
      case 'rec':
      case 'loc':
        return _CarList(
            kind, 0, o.localSongs().take(100).toList(), 'recently_played', null);
      case 'ar':
        return _CarList('ar', listId,
            o.localSongs().where((s) => s.artistId == listId).toList(), 'artist', null);
    }
    return null;
  }

  List<MediaItem> _offlineAlbumRows(String letter) {
    final seen = <int>{};
    final rows = <MediaItem>[];
    for (final s in OfflineService.instance.localSongs()) {
      if (s.albumId <= 0 || !seen.add(s.albumId)) continue;
      final t = s.albumTitle;
      final ok = letter == '#'
          ? t.isNotEmpty && !RegExp(r'^[A-Za-z]').hasMatch(t)
          : t.toUpperCase().startsWith(letter);
      if (ok) rows.add(_albumRow(s.albumId, t, s.artistName));
    }
    return rows;
  }

  Future<_CarList> _loadCarListOnline(String kind, int listId) async {
    switch (kind) {
      case 'pl':
        final data = await _apiService.getPlaylist(listId);
        final songs = ((data['songs'] as List?) ?? [])
            .where((s) => s['available'] == 1) // in the library
            .map((s) => Song.fromJson(s))
            .toList();
        return _CarList('pl', listId, songs, 'playlist', data['name']);
      case 'al':
        final data = await _apiService.getAlbum(listId);
        final songs = ((data['songs'] as List?) ?? [])
            .map((s) => Song.fromJson(s))
            .toList();
        return _CarList('al', listId, songs, 'album', data['title']);
      case 'fav':
        final songs = (await _apiService.getFavoriteSongs()).take(100).toList();
        return _CarList('fav', 0, songs, 'favorites', null);
      case 'rec':
        final songs = (await _apiService.getRecentlyPlayed(limit: 50)).toList();
        return _CarList('rec', 0, songs, 'recently_played', null);
      case 'mp':
        final songs = (await _apiService.getMostPlayed(limit: 50)).toList();
        return _CarList('mp', 0, songs, 'most_played', null);
      case 'ar':
        // Every album of the artist, in the artist page's order (all albums
        // fetched at once; no single "artist's songs" endpoint).
        final data = await _apiService.getArtist(listId);
        final albums = (data['albums'] as List?) ?? [];
        final perAlbum = await Future.wait(albums.map((a) async {
          try {
            final ad = await _apiService.getAlbum(_intOf(a['id']));
            return ((ad['songs'] as List?) ?? [])
                .map((s) => Song.fromJson(s))
                .toList();
          } catch (_) {
            return <Song>[];
          }
        }));
        return _CarList('ar', listId, [for (final l in perAlbum) ...l],
            'artist', data['name']?.toString());
    }
    return _CarList(kind, listId, [], 'single', null);
  }

  List<MediaItem> _carSongRows(_CarList list) => [
        for (var i = 0; i < list.songs.length; i++)
          MediaItem(
            id: 'q_${list.kind}_${list.listId}_${i}_${list.songs[i].id}',
            title: list.songs[i].title,
            artist: list.songs[i].artistsFormatted,
            album: list.kind == 'al'
                ? (list.sourceName ?? list.songs[i].albumTitle)
                : list.songs[i].albumTitle,
            playable: true,
            artUri: Uri.parse(_artworkUrl(
              list.songs[i].albumId != 0
                  ? list.songs[i].albumId
                  : (list.kind == 'al' ? list.listId : 0),
            )),
          ),
      ];

  void _startCarList(_CarList list, int start) {
    // (setQueue marks a playlist played, for every way of starting one)
    _playerService.setQueue(
      list.songs,
      start,
      sourceType: list.sourceType,
      sourceId: const {'pl', 'al', 'ar'}.contains(list.kind) ? list.listId : null,
      sourceName: list.sourceName,
    );
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    print('🚗 Shuffle mode: $shuffleMode');
    await _playerService.toggleShuffle();
    _lastUpdate = DateTime.now().subtract(const Duration(seconds: 1));
    _updateMediaSession();
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    print('🚗 Repeat mode: $repeatMode');
    _playerService.toggleRepeat();
    _lastUpdate = DateTime.now().subtract(const Duration(seconds: 1));
    _updateMediaSession();
  }

  @override
  Future<dynamic> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async {
    print('🚗 Custom action: $name');
    if (name == 'Shuffle') {
      await _playerService.toggleShuffle();
      _lastUpdate = DateTime.now().subtract(const Duration(seconds: 1));
      _updateMediaSession();
    } else if (name == 'Speed') {
      final cur = _playerService.playbackSpeed;
      final i = _speedSteps.indexWhere((s) => (s - cur).abs() < 0.01);
      final next = _speedSteps[(i + 1) % _speedSteps.length];
      await _playerService.setPlaybackSpeed(next);
      AppLogger.instance.info('🚗 [AudioHandler] podcast speed ${_speedLabel(next)}');
      updateMediaSessionPublic();
    } else if (name == 'NotNow') {
      // 👎 in the car: hold it 30 days and skip it.
      final song = _playerService.currentSong;
      if (song != null) {
        try {
          await _playerService.holdSong(song, days: 30);
        } catch (_) {}
      }
    } else if (name == 'Favorite') {
      await _toggleFavorite();
    } else if (name == 'Repeat') {
      _playerService.toggleRepeat();
      _lastUpdate = DateTime.now().subtract(const Duration(seconds: 1));
      _updateMediaSession();
    }
    return null;
  }

  /// Tapping a song in the car's queue ("Up Next") list.
  @override
  Future<void> skipToQueueItem(int index) async {
    print('🚗 Queue tap: $index');
    await _playerService.playFromQueue(index);
    updateMediaSessionPublic();
  }

  /// The car's 🔍 search: playlists, artists, albums, songs, grouped.
  @override
  Future<List<MediaItem>> search(
    String query, [
    Map<String, dynamic>? extras,
  ]) async {
    final q = query.trim();
    print('🚗 Search: "$q"');
    if (q.isEmpty) return [];
    final out = <MediaItem>[];
    try {
      final nq = _norm(q);
      final playlists = await _net(() => _apiService.getPlaylists());
      for (final p in playlists.where((p) => _norm(p.name).contains(nq)).take(5)) {
        out.add(MediaItem(
          id: 'playlist_${p.id}',
          title: p.name,
          playable: false,
          extras: const {_kGroupHint: 'Playlists'},
        ));
      }
    } catch (e) {
      print('❌ Search playlists failed: $e');
    }
    try {
      final r = await _net(() => _apiService.search(Uri.encodeQueryComponent(q)));
      for (final a in ((r['artists'] as List?) ?? []).take(5)) {
        out.add(MediaItem(
          id: 'artist_${_intOf(a['id'])}',
          title: '${a['name'] ?? 'Unknown'}',
          playable: false,
          extras: const {..._gridOfAlbums, _kGroupHint: 'Artists'},
        ));
      }
      for (final al in ((r['albums'] as List?) ?? []).take(8)) {
        final id = _intOf(al['id']);
        out.add(MediaItem(
          id: 'album_$id',
          title: '${al['title'] ?? 'Unknown'}',
          artist: al['artist_name']?.toString(),
          playable: false,
          artUri: id > 0 ? Uri.parse(_artworkUrl(id)) : null,
          extras: const {_kGroupHint: 'Albums'},
        ));
      }
      for (final s in ((r['songs'] as List?) ?? []).take(20)) {
        final song = Song.fromJson(s);
        out.add(MediaItem(
          id: 'song_${song.id}',
          title: song.title,
          artist: song.artistsFormatted,
          album: song.albumTitle,
          playable: true,
          artUri: song.albumId > 0 ? Uri.parse(_artworkUrl(song.albumId)) : null,
          extras: const {_kGroupHint: 'Songs'},
        ));
      }
    } catch (e) {
      print('❌ Search failed: $e');
    }
    if (out.isEmpty) {
      // No signal (or nothing found): search what's on the phone.
      final o = OfflineService.instance;
      final nq = _norm(q);
      for (final c in o.collectionsOf('playlist')) {
        if (_norm(c.name).contains(nq)) {
          out.add(MediaItem(
            id: 'playlist_${c.id}',
            title: c.name,
            playable: false,
            extras: const {_kGroupHint: 'Playlists'},
          ));
        }
      }
      for (final s in o.localSongs()) {
        if (out.length >= 40) break;
        if (_norm('${s.title} ${s.artistsFormatted} ${s.albumTitle}').contains(nq)) {
          out.add(MediaItem(
            id: 'song_${s.id}',
            title: s.title,
            artist: s.artistsFormatted,
            album: s.albumTitle,
            playable: true,
            artUri: _songArt(s),
            extras: const {_kGroupHint: 'On this phone'},
          ));
        }
      }
    }
    return out;
  }

  /// "Hey Google, play ___ on NASRadio" (Android Auto). Picks, in order: a
  /// playlist by name, an artist (shuffled) or album by exact name, then the
  /// best song ("The Hunter by Dokken" matches the artist too). The words
  /// heard and what was picked go to the server log.
  @override
  Future<void> playFromSearch(
    String query, [
    Map<String, dynamic>? extras,
  ]) async {
    final q = query.trim();
    final focus = (extras?['android.intent.extra.focus'] ?? '').toString();
    final log = AppLogger.instance;
    log.info('🎙️ [AudioHandler] voice "$q" focus=$focus');
    try {
      // A voice request can be what started the app: let the startup
      // restore finish first so it can't replace what was asked for.
      await _playerService.restoredOnce
          .timeout(const Duration(seconds: 8), onTimeout: () {});
      if (q.isEmpty) {
        // "Play music on NASRadio": resume, or shuffle Favorites.
        if (_playerService.currentSong != null) {
          await play();
          return;
        }
        final fav = await _loadCarList('fav', 0);
        if (fav.songs.isEmpty) return;
        fav.songs.shuffle();
        _startCarList(fav, 0);
        log.info('🎙️ [AudioHandler] voice -> shuffle Favorites');
        return;
      }
      final playlistAsked = focus.endsWith('/playlist') ||
          RegExp(r'\bplaylist$', caseSensitive: false).hasMatch(q);
      final text = q
          .replaceAll(RegExp(r'\s*\bplaylist$', caseSensitive: false), '')
          .trim();
      final nText = _norm(text);

      final List<Playlist> playlists;
      try {
        playlists = await _net(() => _apiService.getPlaylists());
      } catch (_) {
        await _offlineVoice(q, text);
        return;
      }
      final pl = playlists.where((p) => _norm(p.name) == nText).firstOrNull ??
          (playlistAsked
              ? playlists.where((p) => _norm(p.name).contains(nText)).firstOrNull
              : null);
      if (pl != null) {
        final list = await _loadCarList('pl', pl.id);
        if (list.songs.isNotEmpty) {
          log.info('🎙️ [AudioHandler] voice -> playlist "${pl.name}"');
          _startCarList(list, 0);
          return;
        }
      }

      var title = text;
      String? byArtist = extras?['android.intent.extra.artist']?.toString();
      final by = RegExp(r'^(.+?)\s+by\s+(.+)$', caseSensitive: false)
          .firstMatch(text);
      if (by != null) {
        title = by.group(1)!.trim();
        byArtist = by.group(2)!.trim();
      }
      final nTitle = _norm(title);
      final r = await _net(() => _apiService.search(Uri.encodeQueryComponent(title)));
      final artists = (r['artists'] as List?) ?? [];
      final albums = (r['albums'] as List?) ?? [];
      final songs = ((r['songs'] as List?) ?? [])
          .map((s) => Song.fromJson(s))
          .toList();

      final artistHit =
          artists.where((a) => _norm('${a['name']}') == nTitle).firstOrNull ??
              (focus.endsWith('/artist') ? artists.firstOrNull : null);
      final albumHit =
          albums.where((a) => _norm('${a['title']}') == nTitle).firstOrNull ??
              (focus.endsWith('/album') ? albums.firstOrNull : null);
      Song? songHit;
      if (byArtist != null && byArtist.isNotEmpty) {
        final nBy = _norm(byArtist);
        songHit = songs
                .where((s) =>
                    _norm(s.title) == nTitle &&
                    _norm(s.artistsFormatted).contains(nBy))
                .firstOrNull ??
            songs
                .where((s) => _norm(s.artistsFormatted).contains(nBy))
                .firstOrNull;
      }
      songHit ??= songs.where((s) => _norm(s.title) == nTitle).firstOrNull;
      final anySong = songHit ?? songs.firstOrNull;

      Future<void> playArtist(dynamic a) async {
        final list = await _loadCarList('ar', _intOf(a['id']));
        if (list.songs.isEmpty) return;
        list.songs.shuffle();
        log.info('🎙️ [AudioHandler] voice -> artist "${a['name']}" (shuffled)');
        _startCarList(list, 0);
      }

      Future<void> playAlbum(dynamic a) async {
        final list = await _loadCarList('al', _intOf(a['id']));
        if (list.songs.isEmpty) return;
        log.info('🎙️ [AudioHandler] voice -> album "${a['title']}"');
        _startCarList(list, 0);
      }

      Future<void> playOne(Song s) async {
        log.info('🎙️ [AudioHandler] voice -> song "${s.title}" (${s.artistsFormatted})');
        await _playerService.playSong(s);
      }

      if (focus.endsWith('/album') && albumHit != null) {
        await playAlbum(albumHit);
      } else if (focus.endsWith('/artist') && artistHit != null) {
        await playArtist(artistHit);
      } else if (focus.endsWith('/audio') && anySong != null) {
        await playOne(anySong);
      } else if (by == null && artistHit != null) {
        await playArtist(artistHit);
      } else if (by == null && albumHit != null) {
        await playAlbum(albumHit);
      } else if (anySong != null) {
        await playOne(anySong);
      } else if (albums.isNotEmpty) {
        await playAlbum(albums.first);
      } else if (artists.isNotEmpty) {
        await playArtist(artists.first);
      } else {
        log.info('🎙️ [AudioHandler] voice: nothing found for "$q"');
      }
    } catch (e) {
      log.info('🎙️ [AudioHandler] voice "$q" failed: $e');
    }
  }

  Future<void> _playStation(int stationId) async {
    final stations = await _net(() => _apiService.getStations());
    final s = stations.where((s) => _intOf(s['id']) == stationId).firstOrNull;
    if (s == null) return;
    await _playerService.playSong(_stationToSong(s));
    _apiService.trackStationPlay(stationId).catchError((_) {});
  }

  /// Same Song the phone's Stations screen builds (stations_screen _toSong).
  Song _stationToSong(Map<String, dynamic> s) => Song(
        id: -_intOf(s['id']),
        title: (s['name'] ?? 'Station').toString(),
        artistId: 0,
        artistName: (s['genre'] ?? 'Live Radio').toString(),
        albumId: 0,
        albumTitle: 'Stations',
        trackNumber: 0,
        duration: 0,
        filePath: (s['url'] ?? '').toString(),
        fileSize: 0,
        bitrate: 0,
        sourceType: 'station',
        stationArtworkUrl: (s['favicon'] ?? '').toString(),
      );

  bool _canFavorite(Song? s) =>
      s != null && s.id > 0 && !s.isStation && !s.isPodcast;

  Future<void> _refreshFavorite(int songId) async {
    try {
      final fav = await _apiService.checkFavorite('song', songId);
      if (_favForSongId == songId && fav != _currentIsFavorite) {
        _currentIsFavorite = fav;
        updateMediaSessionPublic();
      }
    } catch (_) {}
  }

  Future<void> _toggleFavorite() async {
    final song = _playerService.currentSong;
    if (!_canFavorite(song)) return;
    final id = song!.id;
    final was = _favForSongId == id && _currentIsFavorite;
    _favForSongId = id;
    _currentIsFavorite = !was;
    updateMediaSessionPublic();
    try {
      if (was) {
        await _apiService.removeFavorite('song', id);
      } else {
        await _apiService.addFavorite('song', id);
      }
      AppLogger.instance.info(
          '🚗 [AudioHandler] ${was ? "removed" : "added"} favorite "${song.title}"');
    } catch (e) {
      if (_favForSongId == id) {
        _currentIsFavorite = was;
        updateMediaSessionPublic();
      }
    }
  }

  Future<_CarList> _loadGenre(String genre) async {
    final data =
        await _net(() => _apiService.getGenreSongs(genre, limit: 200), seconds: 10);
    final songs = List<Song>.from((data['songs'] as List?) ?? const []);
    return _CarList('gn', 0, songs, 'genre', _genreName(genre));
  }

  static String _genreName(String g) => g.split('---').last.trim();

  static String? _genreParent(String g) {
    final parts = g.split('---');
    return parts.length > 1
        ? parts.sublist(0, parts.length - 1).join(' › ')
        : null;
  }

  MediaItem _albumRow(int id, String title, String? artist) => MediaItem(
        id: 'album_$id',
        title: title,
        artist: artist,
        playable: false,
        artUri: id > 0 ? Uri.parse(_artworkUrl(id)) : null,
      );

  Uri? _songArt(Song s) =>
      s.albumId > 0 ? Uri.parse(_artworkUrl(s.albumId)) : null;

  MediaItem _episodeRow(Map<String, dynamic> e, String group) {
    final dur = _intOf(e['audio_duration']);
    final pos = _intOf(e['played_position']);
    final left = dur > 0 && pos > 0 ? ((dur - pos) / 60).round() : 0;
    final show = '${e['feed_title'] ?? ''}';
    return MediaItem(
      id: 'ep_${_intOf(e['id'])}',
      title: '${e['title'] ?? 'Episode'}',
      artist: left > 0 ? '$show · $left min left' : show,
      playable: true,
      artUri: _httpUri(e['artwork_url']) ?? _httpUri(e['feed_artwork_url']),
      extras: {_kGroupHint: group},
    );
  }

  /// Start a podcast episode the way the phone's show screen does: through
  /// the backend proxy, with the show's art, intro/outro skips, and the
  /// player's own resume position.
  Future<void> _playEpisode(int episodeId) async {
    var row = _episodeRows[episodeId] ??
        OfflineService.instance
            .collection(OfflineService.keyFor('episode', episodeId))
            ?.extra;
    if (row == null) {
      final lists = await Future.wait([
        _apiService.getRecentlyPlayedEpisodes(limit: 20),
        _apiService.getRecentEpisodes(limit: 20),
      ]);
      row = [...lists[0], ...lists[1]]
          .where((e) => _intOf(e['id']) == episodeId)
          .firstOrNull;
    }
    if (row == null) return;
    final ep = RssEpisode.fromJson(row);
    RssFeed? feed;
    try {
      final d = await _net(() => _apiService.getRssFeed(ep.feedId), seconds: 6);
      if (d['feed'] is Map) {
        feed = RssFeed.fromJson(Map<String, dynamic>.from(d['feed'] as Map));
      }
    } catch (_) {}
    AppLogger.instance.info('🚗 [AudioHandler] podcast "${ep.title}"');
    await _playerService.playPodcastEpisode(
      ep,
      _apiService.getRssStreamUrl(ep.id),
      artworkUrl: ep.artworkUrl ?? feed?.artworkUrl ?? ep.feedArtworkUrl,
      podcastAuthor: feed?.author ?? ep.feedAuthor,
      podcastTitle: feed?.title ?? ep.feedTitle,
      feedId: ep.feedId,
      allEpisodes: [ep],
      introSkipSeconds: feed?.introSkipSeconds ?? 0,
      outroSkipSeconds: feed?.outroSkipSeconds ?? 0,
    );
  }

  String _albumLine(Song song) {
    final speed = _playerService.playbackSpeed;
    return song.isPodcast && (speed - 1.0).abs() > 0.01
        ? '${_speedLabel(speed)} · ${song.albumTitle}'
        : song.albumTitle;
  }

  static String _speedLabel(double s) =>
      '${s.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '')}×';

  /// A server call for the car, on a short leash. A network failure marks
  /// the server unreachable for a minute: the lists then come straight from
  /// the phone instead of each waiting out its own timeout.
  Future<T> _net<T>(Future<T> Function() call, {int seconds = 8}) async {
    if (DateTime.now().isBefore(_offlineUntil)) throw const _CarOffline();
    try {
      return await call().timeout(Duration(seconds: seconds));
    } catch (e) {
      if (e is TimeoutException || e is SocketException || e is ClientException) {
        _offlineUntil = DateTime.now().add(const Duration(seconds: 60));
        AppLogger.instance.info(
            '🚗 [AudioHandler] server unreachable ($e): answering from the phone for a minute');
      }
      rethrow;
    }
  }

  /// Voice with no signal: a downloaded playlist by name, else songs on the
  /// phone by artist (shuffled) or title ("X by Y").
  Future<void> _offlineVoice(String q, String text) async {
    final o = OfflineService.instance;
    final log = AppLogger.instance;
    final n = _norm(text);
    final pls = o.collectionsOf('playlist');
    final pl = pls.where((c) => _norm(c.name) == n).firstOrNull ??
        pls.where((c) => _norm(c.name).contains(n)).firstOrNull;
    if (pl != null) {
      final list = _offlineCarList('pl', pl.id)!;
      if (list.songs.isNotEmpty) {
        log.info('🎙️ [AudioHandler] voice offline -> playlist "${pl.name}"');
        _startCarList(list, 0);
        return;
      }
    }
    final local = o.localSongs();
    final byArtist =
        local.where((s) => _norm(s.artistsFormatted) == n).toList();
    if (byArtist.isNotEmpty) {
      byArtist.shuffle();
      log.info('🎙️ [AudioHandler] voice offline -> artist "$text" (${byArtist.length} songs)');
      _startCarList(_CarList('loc', 0, byArtist, 'artist', null), 0);
      return;
    }
    var title = n;
    String? by;
    final m = RegExp(r'^(.+?) by (.+)$').firstMatch(n);
    if (m != null) {
      title = m.group(1)!;
      by = m.group(2)!;
    }
    final i = local.indexWhere((s) =>
        _norm(s.title) == title &&
        (by == null || _norm(s.artistsFormatted).contains(by)));
    if (i >= 0) {
      log.info('🎙️ [AudioHandler] voice offline -> song "${local[i].title}"');
      _startCarList(_CarList('loc', 0, local, 'recently_played', null), i);
      return;
    }
    log.info('🎙️ [AudioHandler] voice offline: nothing on the phone for "$q"');
  }

  static int _intOf(dynamic v) =>
      v is int ? v : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);

  static Uri? _httpUri(dynamic v) {
    final s = (v ?? '').toString();
    return s.startsWith('http') ? Uri.tryParse(s) : null;
  }

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  @override
  Future<List<MediaItem>> getQueue() async {
    return _playerService.queue
        .map(
          (song) => MediaItem(
            id: 'song_${song.id}',
            title: song.title,
            artist: song.artistsFormatted,
            album: song.albumTitle,
            artUri: Uri.parse(_artworkUrl(song.albumId)),
          ),
        )
        .toList();
  }
}

/// One list the car shows (a playlist, album, favorites or recently
/// played) and the songs behind it.
class _CarOffline implements Exception {
  const _CarOffline();
  @override
  String toString() => 'offline (recent network failure)';
}

class _CarList {
  _CarList(this.kind, this.listId, this.songs, this.sourceType, this.sourceName);
  final String kind;
  final int listId;
  final List<Song> songs;
  final String sourceType;
  final String? sourceName;
}
