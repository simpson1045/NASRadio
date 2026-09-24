class Playlist {
  final int id;
  final String name;
  final String? description;
  final int songCount;
  final int totalDuration;
  final String createdAt;
  final String updatedAt;
  final String? lastPlayedAt;
  final bool pinned;
  final String? artworkPath;
  final String source;

  Playlist({
    required this.id,
    required this.name,
    this.description,
    required this.songCount,
    required this.totalDuration,
    required this.createdAt,
    required this.updatedAt,
    this.lastPlayedAt,
    this.pinned = false,
    this.artworkPath,
    this.source = 'user',
  });

  factory Playlist.fromJson(Map<String, dynamic> json) {
    return Playlist(
      id: json['id'],
      name: json['name'],
      description: json['description'],
      songCount: json['song_count'],
      totalDuration: json['total_duration'],
      createdAt: json['created_at'],
      updatedAt: json['updated_at'],
      lastPlayedAt: json['last_played_at'],
      pinned: (json['pinned'] ?? 0) == 1,
      artworkPath: json['artwork_path'],
      source: json['source'] ?? 'user',
    );
  }

  String get durationFormatted {
    final hours = totalDuration ~/ 3600;
    final minutes = (totalDuration % 3600) ~/ 60;

    if (hours > 0) {
      return '$hours hr $minutes min';
    }
    return '$minutes min';
  }

  bool get isGenerated => source == 'kylie';
}
