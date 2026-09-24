import 'package:audio_service/audio_service.dart';
import 'api_service.dart';
import '../models/song.dart';
import 'audio_player_service.dart' show AudioPlayerService, RepeatMode;
import 'app_logger.dart';

class NASRadioAudioHandler extends BaseAudioHandler with SeekHandler {
  final AudioPlayerService _playerService;
  static final String _baseUrl = ApiService.baseHost;

  // Throttle updates to avoid spam
  DateTime _lastUpdate = DateTime.now();
  static const _updateThreshold = Duration(milliseconds: 500);

  // Tracks the most recently published AndroidPlaybackInfo so we only
  // re-emit when the cast connection state, remote volume, or volume
  // control type actually changes. Without this, every position tick
  // (1Hz) would republish.
  static const int _kRemoteMaxVolume = 100;
  bool? _lastWasCasting;
  int? _lastRemoteVolumeIndex;
  AndroidVolumeControlType? _lastRemoteVolumeControlType;

  NASRadioAudioHandler(this._playerService) {
    print('🎧 NASRadioAudioHandler created, attaching listener...');
    // Listen to player changes and update media session
    _playerService.addListener(_onPlayerChanged);
    _onPlayerChanged();
    print('🎧 Listener attached successfully');
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
    return '$_baseUrl/api/artwork/$albumId';
  }

  void updateMediaSessionPublic() {
    // Bypass throttle for external calls (playing state changes)
    _lastUpdate = DateTime.now().subtract(const Duration(seconds: 1));
    _updateMediaSession();
  }

  void _updateMediaSession() {
    // Throttle updates
    final now = DateTime.now();
    if (now.difference(_lastUpdate) < _updateThreshold) {
      return;
    }
    _lastUpdate = now;

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
        mediaItem.add(
          MediaItem(
            id: song.id.toString(),
            // Station-aware: shows the live track on a station, the song title
            // otherwise — so Android Auto / lock screen track the broadcast.
            title: _playerService.displayTitle,
            artist: _playerService.displayArtist,
            album: song.albumTitle,
            duration: _playerService.duration,
            artUri: artworkUrl != null ? Uri.tryParse(artworkUrl) : null,
          ),
        );
        print('✅ mediaItem updated (artUri: $artworkUrl)');
      }
    } catch (e) {
      print('❌ mediaItem error: $e');
    }

    try {
      playbackState.add(
        PlaybackState(
          controls: [
            MediaControl(
              androidIcon: _playerService.isShuffled
                  ? 'drawable/ic_shuffle_on'
                  : 'drawable/ic_shuffle',
              label: 'Shuffle',
              action: MediaAction.custom,
            ),
            MediaControl.skipToPrevious,
            _playerService.isPlaying ? MediaControl.pause : MediaControl.play,
            MediaControl.skipToNext,
            MediaControl(
              androidIcon: _playerService.repeatMode != RepeatMode.off
                  ? 'drawable/ic_repeat_on'
                  : 'drawable/ic_repeat',
              label: 'Repeat',
              action: MediaAction.custom,
            ),
          ],
          systemActions: const {
            MediaAction.seek,
            MediaAction.seekForward,
            MediaAction.seekBackward,
            MediaAction.setShuffleMode,
            MediaAction.setRepeatMode,
          },
          androidCompactActionIndices: const [1, 2, 3],
          processingState: AudioProcessingState.ready,
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
        if (_playerService.queue.isNotEmpty) {
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
    await _playerService.playExplicit();
    // Force immediate UI update
    _lastUpdate = DateTime.now().subtract(const Duration(seconds: 1));
    _updateMediaSession();
  }

  @override
  Future<void> pause() async {
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

    if (parentMediaId == AudioService.browsableRootId) {
      // Root menu - dashboard style with quick access
      return [
        const MediaItem(
          id: 'recently_played',
          title: 'Recently Played',
          playable: false,
        ),
        const MediaItem(id: 'favorites', title: 'Favorites', playable: false),
        const MediaItem(id: 'playlists', title: 'Playlists', playable: false),
        const MediaItem(id: 'browse', title: 'Browse Library', playable: false),
      ];
    } else if (parentMediaId == 'recently_played') {
      // Recently played - limited to 50
      try {
        final songs = await _apiService.getRecentlyPlayed(limit: 50);
        return songs
            .map(
              (song) => MediaItem(
                id: 'song_${song.id}',
                title: song.title,
                artist: song.artistsFormatted,
                album: song.albumTitle,
                playable: true,
                artUri: Uri.parse('$_baseUrl/api/artwork/${song.albumId}'),
              ),
            )
            .toList();
      } catch (e) {
        print('❌ Failed to load recently played: $e');
        return [];
      }
    } else if (parentMediaId == 'favorites') {
      // Favorite songs - limited to 100
      try {
        final songs = await _apiService.getFavoriteSongs();
        return songs
            .take(100)
            .map(
              (song) => MediaItem(
                id: 'song_${song.id}',
                title: song.title,
                artist: song.artistsFormatted,
                album: song.albumTitle,
                playable: true,
                artUri: Uri.parse('$_baseUrl/api/artwork/${song.albumId}'),
              ),
            )
            .toList();
      } catch (e) {
        print('❌ Failed to load favorites: $e');
        return [];
      }
    } else if (parentMediaId == 'playlists') {
      // User playlists
      try {
        final playlists = await _apiService.getPlaylists();
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
        print('❌ Failed to load playlists: $e');
        return [];
      }
    } else if (parentMediaId.startsWith('playlist_') &&
        !parentMediaId.startsWith('playlist_shuffle_')) {
      // Songs in a playlist
      try {
        final playlistId = int.parse(
          parentMediaId.replaceFirst('playlist_', ''),
        );
        final playlistData = await _apiService.getPlaylist(playlistId);
        final List<dynamic> songsJson = playlistData['songs'] ?? [];
        final songItems = songsJson
            .map(
              (s) => MediaItem(
                id: 'song_${s['id']}',
                title: s['title'] ?? 'Unknown',
                artist: s['artists_formatted'] ?? s['artist_name'] ?? 'Unknown',
                playable: true,
                artUri: s['album_id'] != null
                    ? Uri.parse('$_baseUrl/api/artwork/${s['album_id']}')
                    : null,
              ),
            )
            .toList();

        // Add shuffle option at the top
        return [
          MediaItem(
            id: 'playlist_shuffle_$playlistId',
            title: '🔀 Shuffle All',
            playable: true,
          ),
          ...songItems,
        ];
      } catch (e) {
        print('❌ Failed to load playlist songs: $e');
        return [];
      }
    } else if (parentMediaId == 'browse') {
      // Browse sub-menu
      return [
        const MediaItem(id: 'albums', title: 'Albums', playable: false),
        const MediaItem(id: 'artists', title: 'Artists', playable: false),
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
                MediaItem(id: 'albums_$letter', title: letter, playable: false),
          )
          .toList();
    } else if (parentMediaId.startsWith('albums_')) {
      // Albums starting with specific letter
      try {
        final letter = parentMediaId.replaceFirst('albums_', '');
        final albums = await _apiService.getAlbums();
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
                artUri: Uri.parse('$_baseUrl/api/artwork/${album.id}'),
              ),
            )
            .toList();
      } catch (e) {
        print('❌ Failed to load albums: $e');
        return [];
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
        final artists = await _apiService.getArtists();
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
        final albumData = await _apiService.getAlbum(albumId);
        final List<dynamic> songsJson = albumData['songs'] ?? [];
        return songsJson
            .map(
              (s) => MediaItem(
                id: 'song_${s['id']}',
                title: s['title'] ?? 'Unknown',
                artist: s['artists_formatted'] ?? s['artist_name'] ?? 'Unknown',
                album: albumData['title'],
                playable: true,
                artUri: Uri.parse('$_baseUrl/api/artwork/$albumId'),
              ),
            )
            .toList();
      } catch (e) {
        print('❌ Failed to load album songs: $e');
        return [];
      }
    } else if (parentMediaId.startsWith('artist_')) {
      // List albums by artist
      try {
        final artistId = int.parse(parentMediaId.replaceFirst('artist_', ''));
        final artistData = await _apiService.getArtist(artistId);
        final List<dynamic> albumsJson = artistData['albums'] ?? [];
        return albumsJson
            .map(
              (a) => MediaItem(
                id: 'album_${a['id']}',
                title: a['title'] ?? 'Unknown',
                artist: artistData['name'],
                playable: false,
                artUri: Uri.parse('$_baseUrl/api/artwork/${a['id']}'),
              ),
            )
            .toList();
      } catch (e) {
        print('❌ Failed to load artist albums: $e');
        return [];
      }
    }

    return [];
  }

  @override
  Future<void> playMediaItem(MediaItem mediaItem) async {
    print('[AudioHandler] playMediaItem: ${mediaItem.id} (${mediaItem.title})');

    if (mediaItem.id.startsWith('playlist_shuffle_')) {
      // Shuffle play entire playlist
      final playlistId = int.parse(
        mediaItem.id.replaceFirst('playlist_shuffle_', ''),
      );
      try {
        final playlistData = await _apiService.getPlaylist(playlistId);
        final List<dynamic> songsJson = playlistData['songs'] ?? [];
        final songs = songsJson.map((s) => Song.fromJson(s)).toList();
        if (songs.isNotEmpty) {
          songs.shuffle();
          _playerService.setQueue(
            songs,
            0,
            sourceType: 'playlist',
            sourceId: playlistId,
            sourceName: playlistData['name'],
          );
        }
      } catch (e) {
        print('❌ Failed to shuffle playlist: $e');
      }
    } else if (mediaItem.id.startsWith('song_')) {
      final songId = int.parse(mediaItem.id.replaceFirst('song_', ''));
      try {
        final songData = await _apiService.getSongDetails(songId);
        final song = Song.fromJson(songData);
        await _playerService.playSong(song);
      } catch (e) {
        print('❌ Failed to play song: $e');
      }
    }
  }

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    print('[AudioHandler] playFromMediaId: $mediaId');

    if (mediaId.startsWith('playlist_shuffle_')) {
      // Shuffle play entire playlist
      final playlistId = int.parse(
        mediaId.replaceFirst('playlist_shuffle_', ''),
      );
      try {
        final playlistData = await _apiService.getPlaylist(playlistId);
        final List<dynamic> songsJson = playlistData['songs'] ?? [];
        // Filter to only available songs (ones actually in the library)
        final availableSongs = songsJson
            .where((s) => s['available'] == 1)
            .toList();
        print(
          '🚗 Playlist: ${availableSongs.length} available of ${songsJson.length} total',
        );
        final songs = availableSongs.map((s) => Song.fromJson(s)).toList();
        if (songs.isNotEmpty) {
          songs.shuffle();
          _playerService.setQueue(
            songs,
            0,
            sourceType: 'playlist',
            sourceId: playlistId,
            sourceName: playlistData['name'],
          );
        }
      } catch (e) {
        print('❌ Failed to shuffle playlist: $e');
      }
    } else if (mediaId.startsWith('song_')) {
      final songId = int.parse(mediaId.replaceFirst('song_', ''));
      try {
        final songData = await _apiService.getSongDetails(songId);
        final song = Song.fromJson(songData);
        await _playerService.playSong(song);
      } catch (e) {
        print('❌ Failed to play song: $e');
      }
    }
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
    } else if (name == 'Repeat') {
      _playerService.toggleRepeat();
      _lastUpdate = DateTime.now().subtract(const Duration(seconds: 1));
      _updateMediaSession();
    }
    return null;
  }

  @override
  Future<List<MediaItem>> getQueue() async {
    return _playerService.queue
        .map(
          (song) => MediaItem(
            id: 'song_${song.id}',
            title: song.title,
            artist: song.artistsFormatted,
            album: song.albumTitle,
            artUri: Uri.parse('$_baseUrl/api/artwork/${song.albumId}'),
          ),
        )
        .toList();
  }
}
