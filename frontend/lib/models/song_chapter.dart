class SongChapter {
  final int orderIndex;
  final int startTimeSeconds;
  final int? endTimeSeconds;
  final String? title;
  final String? imageUrl;
  final String? linkUrl;
  final bool isSkippable;
  final String? source;

  const SongChapter({
    required this.orderIndex,
    required this.startTimeSeconds,
    this.endTimeSeconds,
    this.title,
    this.imageUrl,
    this.linkUrl,
    required this.isSkippable,
    this.source,
  });

  factory SongChapter.fromJson(Map<String, dynamic> json) {
    int parseInt(dynamic v, [int fallback = 0]) {
      if (v is int) return v;
      if (v is double) return v.toInt();
      if (v is String) return int.tryParse(v) ?? fallback;
      return fallback;
    }

    return SongChapter(
      orderIndex: parseInt(json['order_index']),
      startTimeSeconds: parseInt(json['start_time_seconds']),
      endTimeSeconds: json['end_time_seconds'] == null
          ? null
          : parseInt(json['end_time_seconds']),
      title: json['title'] as String?,
      imageUrl: json['image_url'] as String?,
      linkUrl: json['link_url'] as String?,
      isSkippable: json['is_skippable'] == true || json['is_skippable'] == 1,
      source: json['source'] as String?,
    );
  }

  /// Human-readable start time, e.g. "1:23:45" or "5:07".
  String get startTimeFormatted {
    final h = startTimeSeconds ~/ 3600;
    final m = (startTimeSeconds % 3600) ~/ 60;
    final s = startTimeSeconds % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// Returns true if the given position (seconds) falls within this chapter.
  /// End time is open-ended if not set (runs until the next chapter or EOF).
  bool containsSeconds(int positionSeconds, {int? nextChapterStart}) {
    if (positionSeconds < startTimeSeconds) return false;
    final end = endTimeSeconds ?? nextChapterStart;
    if (end == null) return true;
    return positionSeconds < end;
  }
}
