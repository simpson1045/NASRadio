class Artist {
  final int id;
  final String name;
  final int albumCount;
  final int songCount;
  final String? imagePath;

  Artist({
    required this.id,
    required this.name,
    required this.albumCount,
    required this.songCount,
    this.imagePath,
  });

  factory Artist.fromJson(Map<String, dynamic> json) {
    return Artist(
      id: json['id'],
      name: json['name'],
      albumCount: json['album_count'],
      songCount: json['song_count'],
      imagePath: json['image_path'],
    );
  }
}