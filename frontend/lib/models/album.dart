class Album {
  final int id;
  final String title;
  final int artistId;
  final String artistName;
  final int? year;
  final int songCount;
  final String? artworkPath;
  final String? createdAt;
  final String? samplePath;
  // Release typing (from albums.album_type / albums.secondary_types).
  // album_type is the primary type (Album/Single/EP); secondaryTypes is a
  // comma-separated list (e.g. "Compilation", "Live", "Soundtrack").
  final String? albumType;
  final String? secondaryTypes;
  // Album editions (ALBUM_EDITIONS_SPEC.md). On a collapsed group card the
  // backend sends the group title/original year as title/year, plus how many
  // editions the group has and its best format (for the card badge).
  final int? groupId;
  final String? editionLabel;
  final int editionCount;
  final bool editionHasAtmos;
  final int editionMaxChannels;

  Album({
    required this.id,
    required this.title,
    required this.artistId,
    required this.artistName,
    this.year,
    required this.songCount,
    this.artworkPath,
    this.createdAt,
    this.samplePath,
    this.albumType,
    this.secondaryTypes,
    this.groupId,
    this.editionLabel,
    this.editionCount = 1,
    this.editionHasAtmos = false,
    this.editionMaxChannels = 2,
  });

  /// Bucket this release into a single display category, mirroring the
  /// backend discography grouping (a Compilation/Live secondary type wins
  /// over the primary type). Untyped/other releases fall under "Album" so
  /// nothing is ever hidden from the artist page.
  String get category {
    final secs = (secondaryTypes ?? '').toLowerCase();
    if (secs.contains('compilation')) return 'Compilation';
    if (secs.contains('live')) return 'Live';
    switch (albumType) {
      case 'Single':
        return 'Single';
      case 'EP':
        return 'EP';
      case 'Album':
        return 'Album';
      default:
        return 'Album';
    }
  }

  factory Album.fromJson(Map<String, dynamic> json) {
    return Album(
      id: json['id'],
      title: json['title'],
      artistId: json['artist_id'],
      artistName: json['artist_name'],
      year: json['year'],
      songCount: json['song_count'] ?? 0,
      artworkPath: json['artwork_path'],
      createdAt: json['created_at'],
      samplePath: json['sample_path'],
      albumType: json['album_type'],
      secondaryTypes: json['secondary_types'],
      groupId: json['group_id'],
      editionLabel: json['edition_label'],
      editionCount: json['edition_count'] ?? 1,
      editionHasAtmos: (json['edition_has_atmos'] ?? 0) == 1,
      editionMaxChannels: json['edition_max_channels'] ?? 2,
    );
  }
}
