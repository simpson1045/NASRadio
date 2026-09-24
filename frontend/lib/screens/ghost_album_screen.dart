import 'dart:io' show Platform, Directory, FileSystemEntity;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import '../widgets/mouse_back_button_wrapper.dart';
import 'import_queue_screen.dart' show openImportDetail;
import 'prowlarr_search_screen.dart';
import 'youtube_download_screen.dart';

const _kAudioExtensions = [
  'flac', 'mp3', 'm4a', 'wav', 'ogg', 'opus', 'aac', 'wma', 'ape', 'wv',
  'aiff', 'aif', 'dsf', 'dff', 'mpc', 'cue', 'log',
];

/// A release MusicBrainz knows about that isn't in the library yet.
/// Shows the cover, the tracklist, and the three ways to get it:
/// search Prowlarr, search YouTube, or import files already on hand.
class GhostAlbumScreen extends StatefulWidget {
  final Map<String, dynamic> release; // one discography entry
  final String artistName;
  final int artistId;
  final String? artistMbid;
  final AudioPlayerService audioPlayerService;
  /// Called after an import finishes so the artist page can relight the tile.
  final VoidCallback? onImported;

  const GhostAlbumScreen({
    super.key,
    required this.release,
    required this.artistName,
    required this.artistId,
    this.artistMbid,
    required this.audioPlayerService,
    this.onImported,
  });

  @override
  State<GhostAlbumScreen> createState() => _GhostAlbumScreenState();
}

class _GhostAlbumScreenState extends State<GhostAlbumScreen> {
  final ApiService _api = ApiService();
  List<Map<String, dynamic>>? _tracks;
  bool _tracksLoading = true;
  String? _tracksError;

  bool _uploading = false;
  int _sent = 0;
  int _total = 0;

  String get _mbid => widget.release['mbid'] as String;
  String get _title => widget.release['title'] as String? ?? 'Unknown';
  int? get _year => widget.release['year'] as int?;
  bool get _desktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    _loadTracks();
  }

  Future<void> _loadTracks() async {
    try {
      final data = await _api.getMusicBrainzTracks(_mbid);
      if (!mounted) return;
      setState(() {
        _tracks = List<Map<String, dynamic>>.from(data['tracks'] ?? []);
        _tracksLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _tracksError = 'Tracklist unavailable';
        _tracksLoading = false;
      });
    }
  }

  String _fmt(int? ms) {
    if (ms == null || ms <= 0) return '';
    final s = ms ~/ 1000;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  void _searchProwlarr() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ProwlarrSearchScreen(
          audioPlayerService: widget.audioPlayerService,
          initialQuery: '${widget.artistName} $_title',
        ),
      ),
    );
  }

  void _searchYouTube() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => YouTubeDownloadScreen(
          audioPlayerService: widget.audioPlayerService,
          initialSearch: '${widget.artistName} $_title',
        ),
      ),
    );
  }

  Future<List<String>> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: _kAudioExtensions,
      dialogTitle: 'Pick the files for $_title',
    );
    if (result == null) return [];
    return result.paths.whereType<String>().toList();
  }

  Future<List<String>> _pickFolder() async {
    final dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Pick the folder for $_title',
    );
    if (dir == null) return [];
    final out = <String>[];
    await for (final FileSystemEntity e in Directory(dir).list(recursive: true)) {
      final ext = e.path.split('.').last.toLowerCase();
      if (_kAudioExtensions.contains(ext)) out.add(e.path);
    }
    out.sort();
    return out;
  }

  Future<void> _importFiles({bool folder = false}) async {
    List<String> paths;
    try {
      paths = folder ? await _pickFolder() : await _pickFiles();
    } catch (e) {
      _snack('Could not open picker: $e', error: true);
      return;
    }
    if (paths.isEmpty) return;

    setState(() {
      _uploading = true;
      _sent = 0;
      _total = 0;
    });
    final yearPart = _year != null ? ' ($_year)' : '';
    Map<String, dynamic> item;
    try {
      item = await _api.uploadImportFiles(
        folder: '${widget.artistName} - $_title$yearPart',
        paths: paths,
        onProgress: (sent, total) {
          if (!mounted) return;
          setState(() {
            _sent = sent;
            _total = total;
          });
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _uploading = false);
      _snack('$e', error: true);
      return;
    }
    if (!mounted) return;
    setState(() => _uploading = false);

    var imported = false;
    await openImportDetail(
      context,
      item: item,
      artist: widget.artistName,
      album: _title,
      year: _year,
      artistMbid: widget.artistMbid,
      albumMbid: _mbid,
      audioPlayerService: widget.audioPlayerService,
      onImportComplete: () {
        imported = true;
        widget.onImported?.call();
      },
    );
    // Back on this page after a successful import: the release is no
    // longer a ghost, so drop back to the artist page, which relights it.
    if (imported && mounted) Navigator.of(context).pop();
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: error ? Colors.red : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final types = <String>[
      if (widget.release['type'] != null) widget.release['type'] as String,
      ...List<String>.from(widget.release['secondary_types'] ?? const []),
      if (widget.release['is_bootleg'] == true) 'Bootleg',
    ];
    final coverUrl =
        'https://coverartarchive.org/release-group/$_mbid/front-500';

    return MouseBackButtonWrapper(
      child: Scaffold(
        backgroundColor: const Color(0xFF0a0e1a),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Text(widget.artistName),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 220,
                  height: 220,
                  child: CachedNetworkImage(
                    imageUrl: coverUrl,
                    fit: BoxFit.cover,
                    placeholder: (_, __) => Container(
                      color: const Color(0xFF1a2332),
                      child: const Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                    errorWidget: (_, __, ___) => Container(
                      color: const Color(0xFF1a2332),
                      child: const Icon(
                        Icons.album,
                        size: 96,
                        color: Colors.white24,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              _title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              [
                if (_year != null) '$_year',
                ...types,
              ].join(' • '),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54),
            ),
            const SizedBox(height: 10),
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.orange.withOpacity(0.5)),
                ),
                child: const Text(
                  'Not in your library',
                  style: TextStyle(
                    color: Colors.orange,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            if (_uploading) ...[
              LinearProgressIndicator(
                value: _total > 0 ? _sent / _total : null,
                color: const Color(0xFF00d4ff),
                backgroundColor: const Color(0xFF1a2332),
              ),
              const SizedBox(height: 6),
              Text(
                _total > 0
                    ? 'Uploading ${(_sent / 1048576).toStringAsFixed(1)} / ${(_total / 1048576).toStringAsFixed(1)} MB'
                    : 'Uploading…',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 16),
            ] else ...[
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 10,
                children: [
                  _ActionButton(
                    icon: Icons.search,
                    label: 'Search Prowlarr',
                    color: Colors.orange,
                    onTap: _searchProwlarr,
                  ),
                  _ActionButton(
                    icon: Icons.play_circle_outline,
                    label: 'Search YouTube',
                    color: const Color(0xFFff4b4b),
                    onTap: _searchYouTube,
                  ),
                  _ActionButton(
                    icon: Icons.upload_file,
                    label: 'Import files',
                    color: const Color(0xFF00d4ff),
                    onTap: () => _importFiles(),
                  ),
                  if (_desktop)
                    _ActionButton(
                      icon: Icons.drive_folder_upload,
                      label: 'Import folder',
                      color: const Color(0xFF00d4ff),
                      onTap: () => _importFiles(folder: true),
                    ),
                ],
              ),
              const SizedBox(height: 24),
            ],
            const Text(
              'Tracklist',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            if (_tracksLoading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_tracksError != null || (_tracks?.isEmpty ?? true))
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _tracksError ?? 'MusicBrainz has no tracklist for this release',
                  style: const TextStyle(color: Colors.white38),
                ),
              )
            else
              ..._tracks!.map(
                (t) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: SizedBox(
                    width: 28,
                    child: Text(
                      '${t['number'] ?? t['position'] ?? ''}',
                      textAlign: TextAlign.right,
                      style: const TextStyle(color: Colors.white38),
                    ),
                  ),
                  title: Text(
                    t['title'] ?? '',
                    style: const TextStyle(color: Colors.white70),
                  ),
                  subtitle: t['artist'] != null &&
                          (t['artist'] as String).toLowerCase() !=
                              widget.artistName.toLowerCase()
                      ? Text(
                          t['artist'],
                          style: const TextStyle(color: Colors.white38, fontSize: 12),
                        )
                      : null,
                  trailing: Text(
                    _fmt(t['duration'] as int?),
                    style: const TextStyle(color: Colors.white38),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18, color: color),
      label: Text(label, style: TextStyle(color: color)),
      style: OutlinedButton.styleFrom(
        side: BorderSide(color: color.withOpacity(0.6)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}
