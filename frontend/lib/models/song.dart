import 'package:flutter/material.dart';

class SongArtist {
  final int id;
  final String name;

  SongArtist({required this.id, required this.name});

  factory SongArtist.fromJson(Map<String, dynamic> json) {
    return SongArtist(
      id: json['id'] is int
          ? json['id']
          : int.tryParse(json['id'].toString()) ?? 0,
      name: json['name'],
    );
  }
}

class Song {
  static int _toInt(dynamic value, [int fallback = 0]) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? fallback;
    if (value is double) return value.toInt();
    return fallback;
  }

  final int id;
  final String title;
  final int artistId;
  final String artistName;
  final int albumId;
  final String albumTitle;
  final int trackNumber;
  final int discNumber;
  final int duration;
  final String filePath;
  final int fileSize;
  final int bitrate;
  final int playCount;
  final List<SongArtist> artists;
  final double? loudness; // Legacy Steven's-power-law loudness (arbitrary
  // positive units). Kept for backward compat with songs analyzed before
  // we upgraded Essentia to return EBU R128 LUFS. New normalization
  // prefers `integratedLoudnessLufs` and falls back to this when null.
  final double? integratedLoudnessLufs; // EBU R128 integrated loudness in
  // LUFS (typically -30 to -5 for music). The standard volume-normalization
  // value used by every streaming service. Null until the song has been
  // analyzed by Essentia + LoudnessEBUR128.
  final double? truePeakDbfs; // Max sample level in dBFS (negative; 0 =
  // digital clipping). Used to determine how much headroom we have when
  // boosting quiet tracks.
  final bool isExplicit;
  final bool isHdcd;
  final bool isAtmos; // E-AC-3 JOC ("Dolby Digital Plus + Dolby Atmos")
  final int audioChannels; // 2 = stereo, 5/6/8 = surround (scan-time probe)

  // Podcast-unification fields (Phase 3 of PODCAST_REFACTOR_PLAN.md).
  // Songs with sourceType='podcast' carry podcast metadata alongside the
  // normal music fields — the player treats them as regular songs and
  // the UI flips to the orange podcast theme based on sourceType.
  final String sourceType; // 'local' | 'podcast' | 'station'
  final int? podcastFeedId;
  final int? podcastEpisodeId;
  final int playedPosition; // seconds, for resume
  final bool isCompleted;

  // Live-radio station artwork (the station's favicon). Set when
  // sourceType=='station'; null otherwise.
  final String? stationArtworkUrl;

  bool get isPodcast => sourceType == 'podcast';
  bool get isStation => sourceType == 'station';

  /// Plain multichannel (no object metadata) — 5.0/5.1/7.1 SACD-style rips.
  bool get isSurround => audioChannels > 2 && !isAtmos;

  /// "5.1" / "5.0" / "7.1" style label for the surround badge.
  String get surroundLabel {
    switch (audioChannels) {
      case 6:
        return '5.1';
      case 8:
        return '7.1';
      case 7:
        return '6.1';
      default:
        return '$audioChannels.0';
    }
  }

  Song({
    required this.id,
    required this.title,
    required this.artistId,
    required this.artistName,
    required this.albumId,
    required this.albumTitle,
    required this.trackNumber,
    this.discNumber = 1,
    required this.duration,
    required this.filePath,
    required this.fileSize,
    required this.bitrate,
    this.playCount = 0,
    this.artists = const [],
    this.loudness,
    this.integratedLoudnessLufs,
    this.truePeakDbfs,
    this.isExplicit = false,
    this.isHdcd = false,
    this.isAtmos = false,
    this.audioChannels = 2,
    this.sourceType = 'local',
    this.podcastFeedId,
    this.podcastEpisodeId,
    this.playedPosition = 0,
    this.isCompleted = false,
    this.stationArtworkUrl,
  });

  factory Song.fromJson(Map<String, dynamic> json) {
    // Parse artists array if present
    List<SongArtist> artistsList = [];
    if (json['artists'] != null) {
      artistsList = (json['artists'] as List)
          .map((a) => SongArtist.fromJson(a))
          .toList();
    }

    return Song(
      id: _toInt(json['id']),
      title: json['title'],
      artistId: _toInt(json['artist_id']),
      artistName: json['artist_name'] ?? 'Unknown Artist',
      albumId: _toInt(json['album_id']),
      albumTitle: json['album_title'] ?? 'Unknown Album',
      trackNumber: _toInt(json['track_number']),
      discNumber: _toInt(json['disc_number'], 1),
      duration: _toInt(json['duration']),
      filePath: json['file_path'] ?? '',
      fileSize: _toInt(json['file_size']),
      bitrate: _toInt(json['bitrate']),
      playCount: _toInt(json['play_count']),
      artists: artistsList,
      loudness: json['loudness']?.toDouble(),
      integratedLoudnessLufs: json['integrated_loudness_lufs']?.toDouble(),
      truePeakDbfs: json['true_peak_dbfs']?.toDouble(),
      isExplicit: json['is_explicit'] == 1,
      isHdcd: json['is_hdcd'] == 1,
      isAtmos: json['is_atmos'] == 1,
      audioChannels: json['audio_channels'] == null
          ? 2
          : _toInt(json['audio_channels'], 2),
      sourceType: json['source_type'] as String? ?? 'local',
      podcastFeedId: json['podcast_feed_id'] == null ? null : _toInt(json['podcast_feed_id']),
      podcastEpisodeId: json['podcast_episode_id'] == null ? null : _toInt(json['podcast_episode_id']),
      playedPosition: _toInt(json['played_position']),
      isCompleted: json['is_completed'] == 1 || json['is_completed'] == true,
      stationArtworkUrl: json['station_artwork_url'] as String?,
    );
  }

  /// Title with a sensible fallback for records that have an empty
  /// `title` field. This used to render as a blank row in the Songs tab
  /// — confusing because you'd see just "Unknown Artist · " with
  /// nothing identifying the track. Now we fall back to the filename
  /// stem (e.g. "Dio - Sacred Heart - 01 - Hide in the Rainbow") so
  /// you can at least see WHICH file is the offender. UI lists should
  /// use this getter instead of accessing `title` directly.
  String get displayTitle {
    if (title.trim().isNotEmpty) return title;
    if (filePath.isEmpty) return '(no title)';
    // Pull the filename, then strip the extension.
    final segments = filePath.split(RegExp(r'[\\/]'));
    final fname = segments.isNotEmpty ? segments.last : filePath;
    final dot = fname.lastIndexOf('.');
    final stem = dot > 0 ? fname.substring(0, dot) : fname;
    return stem.isNotEmpty ? stem : '(no title)';
  }

  /// True when the song has no real title — UI can italicize / dim
  /// the row to flag it as a metadata gap the user might want to fix.
  bool get hasNoTitle => title.trim().isEmpty;

  /// Returns formatted artist names (e.g., "Eminem, Dr. Dre, Sly Pyper")
  String get artistsFormatted {
    if (artists.isNotEmpty) {
      return artists.map((a) => a.name).join(', ');
    }
    return artistName;
  }

  String get durationFormatted {
    final hours = duration ~/ 3600;
    final minutes = (duration % 3600) ~/ 60;
    final seconds = duration % 60;

    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  String get fileFormat {
    if (filePath.isEmpty) return 'UNKNOWN';
    // Stream URLs (stations, podcasts) rarely end in a real audio
    // extension — the naive split('.') below turned a station URL like
    // "http://79.120.39.202:9073/" into a "202:9073/" badge. For http(s)
    // paths, take the extension from the URL *path* (no host/port/query)
    // and only trust known audio types; otherwise show a neutral badge.
    if (filePath.startsWith('http://') || filePath.startsWith('https://')) {
      final path = Uri.tryParse(filePath)?.path ?? '';
      final dot = path.lastIndexOf('.');
      final ext = dot >= 0 ? path.substring(dot + 1).toUpperCase() : '';
      const known = {'MP3', 'AAC', 'AACP', 'M4A', 'OGG', 'OPUS', 'FLAC', 'WAV'};
      if (known.contains(ext)) return ext == 'AACP' ? 'AAC+' : ext;
      return isStation ? 'RADIO' : 'STREAM';
    }
    final extension = filePath.split('.').last.toUpperCase();
    return extension;
  }

  Color get formatColor {
    switch (fileFormat) {
      case 'FLAC':
        return const Color(0xFF00d4ff); // Cyan - the elite choice
      case 'MP3':
        return Colors.orange; // Orange - the peasant format
      case 'WAV':
      case 'WAVE':
        return Colors.blue;
      case 'M4A':
      case 'AAC':
        return Colors.purple;
      case 'OGG':
      case 'OPUS':
        return Colors.green;
      case 'WV':
        return const Color(0xFF9C27B0); // Purple - WavPack lossless
      case 'APE':
        return const Color(0xFF8BC34A); // Light green - Monkey's Audio
      case 'AIFF':
      case 'AIF':
        return const Color(0xFF03A9F4); // Light blue - Apple lossless
      case 'DSF':
      case 'DFF':
        return const Color(0xFFFFD700); // Gold - DSD hi-res
      default:
        return Colors.grey;
    }
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'artist_id': artistId,
      'artist_name': artistName,
      'album_id': albumId,
      'album_title': albumTitle,
      'track_number': trackNumber,
      'disc_number': discNumber,
      'duration': duration,
      'file_path': filePath,
      'file_size': fileSize,
      'bitrate': bitrate,
      'play_count': playCount,
      'loudness': loudness,
      'integrated_loudness_lufs': integratedLoudnessLufs,
      'true_peak_dbfs': truePeakDbfs,
      'artists': artists.map((a) => {'id': a.id, 'name': a.name}).toList(),
      'source_type': sourceType,
      'podcast_feed_id': podcastFeedId,
      'podcast_episode_id': podcastEpisodeId,
      'played_position': playedPosition,
      'is_completed': isCompleted,
      'station_artwork_url': stationArtworkUrl,
    };
  }
}
