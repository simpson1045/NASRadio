/// Strip HTML tags + decode common entities from a description string.
///
/// Most feeds hand us clean text, but plenty of publishers (Megaphone,
/// Libsyn templates, WordPress-based shows) embed `<p>` / `<br>` / `<a>`
/// tags in the description. The backend parser calls _clean_html at RSS
/// parse time, but feeds imported before that fix exists, or metadata
/// reaching us through alternate paths (Podcast Index, cached DB rows),
/// can still carry markup. Strip defensively here so every display site
/// shows clean text without each screen having to remember.
String stripHtml(String input) {
  if (input.isEmpty) return input;
  // Remove HTML tags
  var out = input.replaceAll(RegExp(r'<[^>]+>'), '');
  // Decode the handful of entities that actually show up in podcast feeds.
  // Not a full entity decoder — those extremes are both rare and better
  // served by a dedicated package if we ever need one.
  const entities = {
    '&amp;': '&',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&#39;': "'",
    '&apos;': "'",
    '&nbsp;': ' ',
    '&mdash;': '—',
    '&ndash;': '–',
    '&hellip;': '…',
    '&rsquo;': '\u2019',
    '&lsquo;': '\u2018',
    '&rdquo;': '\u201D',
    '&ldquo;': '\u201C',
  };
  entities.forEach((k, v) => out = out.replaceAll(k, v));
  // Numeric entities (&#8220; etc.) — best-effort
  out = out.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
    final code = int.tryParse(m.group(1)!);
    if (code == null || code < 32 || code > 0x10FFFF) return m.group(0)!;
    return String.fromCharCode(code);
  });
  // Collapse whitespace
  out = out.replaceAll(RegExp(r'\s+'), ' ').trim();
  return out;
}

class RssFeed {
  final int id;
  final String feedUrl;
  final String title;
  final String description;
  final String? artworkUrl;
  final String? artworkCached;
  final String author;
  final String? link;
  final bool autoDownload;
  final String? lastFetchedAt;
  final int episodeCount;
  final int unplayedCount;
  final String playOrder; // 'newest_first' | 'oldest_first' — per-feed sort
  final int introSkipSeconds; // 0 = disabled
  final int outroSkipSeconds; // 0 = disabled
  final int retentionDays; // 0 = keep everything

  RssFeed({
    required this.id,
    required this.feedUrl,
    required this.title,
    required this.description,
    this.artworkUrl,
    this.artworkCached,
    required this.author,
    this.link,
    required this.autoDownload,
    this.lastFetchedAt,
    required this.episodeCount,
    required this.unplayedCount,
    this.playOrder = 'newest_first',
    this.introSkipSeconds = 0,
    this.outroSkipSeconds = 0,
    this.retentionDays = 0,
  });

  bool get isOldestFirst => playOrder == 'oldest_first';

  factory RssFeed.fromJson(Map<String, dynamic> json) {
    int _i(dynamic v) => (v is num) ? v.toInt() : (int.tryParse('$v') ?? 0);
    return RssFeed(
      id: json['id'] ?? 0,
      feedUrl: json['feed_url'] ?? '',
      title: json['title'] ?? 'Unknown Podcast',
      description: stripHtml(json['description'] ?? ''),
      artworkUrl: json['artwork_url'],
      artworkCached: json['artwork_cached'],
      author: json['author'] ?? '',
      link: json['link'],
      autoDownload: (json['auto_download'] ?? 0) == 1,
      lastFetchedAt: json['last_fetched_at'],
      episodeCount: json['episode_count'] ?? 0,
      unplayedCount: json['unplayed_count'] ?? 0,
      playOrder: json['play_order'] as String? ?? 'newest_first',
      introSkipSeconds: _i(json['intro_skip_seconds'] ?? 0),
      outroSkipSeconds: _i(json['outro_skip_seconds'] ?? 0),
      retentionDays: _i(json['retention_days'] ?? 0),
    );
  }
}

class RssEpisode {
  final int id;
  final int feedId;
  final String guid;
  final String title;
  final String description;
  final String? audioUrl;
  final String? audioType;
  final int? audioDuration;
  final int? audioSize;
  final String? link;
  final String? publishedAt;
  final String? artworkUrl;
  final int playedPosition;
  final bool isCompleted;
  // Server timestamp of the most recent progress save for this
  // episode (ISO-8601, UTC). Used by the resume banner to pick the
  // episode the user was actually most recently listening to, not
  // just "first in list order with progress > 0" (which was the
  // previous, broken behavior). Null for episodes that have never
  // been played.
  final String? lastPlayedAt;
  final String? downloadedPath;

  // Feed info (from joined queries)
  final String? feedTitle;
  final String? feedArtworkUrl;
  final String? feedAuthor;

  RssEpisode({
    required this.id,
    required this.feedId,
    required this.guid,
    required this.title,
    required this.description,
    this.audioUrl,
    this.audioType,
    this.audioDuration,
    this.audioSize,
    this.link,
    this.publishedAt,
    this.artworkUrl,
    required this.playedPosition,
    required this.isCompleted,
    this.lastPlayedAt,
    this.downloadedPath,
    this.feedTitle,
    this.feedArtworkUrl,
    this.feedAuthor,
  });

  factory RssEpisode.fromJson(Map<String, dynamic> json) {
    return RssEpisode(
      id: json['id'] ?? 0,
      feedId: json['feed_id'] ?? 0,
      guid: json['guid'] ?? '',
      title: json['title'] ?? 'Untitled Episode',
      description: stripHtml(json['description'] ?? ''),
      audioUrl: json['audio_url'],
      audioType: json['audio_type'],
      audioDuration: json['audio_duration'],
      audioSize: json['audio_size'],
      link: json['link'],
      publishedAt: json['published_at'],
      artworkUrl: json['artwork_url'],
      playedPosition: json['played_position'] ?? 0,
      isCompleted: (json['is_completed'] ?? 0) == 1,
      lastPlayedAt: json['last_played_at'],
      downloadedPath: json['downloaded_path'],
      feedTitle: json['feed_title'],
      feedArtworkUrl: json['feed_artwork_url'],
      feedAuthor: json['feed_author'],
    );
  }

  RssEpisode copyWith({
    int? playedPosition,
    bool? isCompleted,
    String? lastPlayedAt,
  }) {
    return RssEpisode(
      id: id,
      feedId: feedId,
      guid: guid,
      title: title,
      description: description,
      audioUrl: audioUrl,
      audioType: audioType,
      audioDuration: audioDuration,
      audioSize: audioSize,
      link: link,
      publishedAt: publishedAt,
      artworkUrl: artworkUrl,
      playedPosition: playedPosition ?? this.playedPosition,
      isCompleted: isCompleted ?? this.isCompleted,
      lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
      downloadedPath: downloadedPath,
      feedTitle: feedTitle,
      feedArtworkUrl: feedArtworkUrl,
      feedAuthor: feedAuthor,
    );
  }

  bool get isDownloaded => downloadedPath != null && downloadedPath!.isNotEmpty;

  String get durationFormatted {
    if (audioDuration == null) return '--:--';
    final hours = audioDuration! ~/ 3600;
    final mins = (audioDuration! % 3600) ~/ 60;
    final secs = audioDuration! % 60;
    if (hours > 0) {
      return '$hours:${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    }
    return '$mins:${secs.toString().padLeft(2, '0')}';
  }
}
