import 'dart:async';
import 'package:flutter/material.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:url_launcher/url_launcher.dart';
import '../models/album.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import 'album_detail_screen.dart';
import '../widgets/artwork_picker_dialog.dart';

class YouTubeDownloadScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;
  final String? initialUrl;
  /// Album search to run on open (the Prowlarr screen hands its query over).
  final String? initialSearch;

  const YouTubeDownloadScreen({
    super.key,
    required this.audioPlayerService,
    this.initialUrl,
    this.initialSearch,
  });

  @override
  State<YouTubeDownloadScreen> createState() => _YouTubeDownloadScreenState();
}

class _YouTubeDownloadScreenState extends State<YouTubeDownloadScreen> {
  final ApiService _apiService = ApiService();
  final TextEditingController _urlController = TextEditingController();
  // Scroll controller so we can auto-scroll the body to the live
  // download/import progress widget when a job starts (the progress
  // section is rendered below the URL input + the video/playlist card,
  // which is often off-screen on a phone — without this the user has
  // to scroll manually to see the websocket updates).
  final ScrollController _scrollController = ScrollController();
  // Global key on the _buildDownloadProgress widget so we can scroll it
  // into view via Scrollable.ensureVisible — survives layout changes
  // better than computing an offset by hand.
  final GlobalKey _progressKey = GlobalKey();

  // WebSocket
  io.Socket? _socket;
  String? _currentOperationId;

  // URL validation state
  Map<String, dynamic>? _urlInfo;
  bool _isValidating = false;

  // Video info state
  Map<String, dynamic>? _videoInfo;
  bool _isLoadingInfo = false;

  // Chapter-split mode (single-video → album with chapter tracks). Lit up
  // when the backend's preview-chapters endpoint finds either native YouTube
  // chapters or a parseable description-timestamp tracklist.
  Map<String, dynamic>? _chapterPreview;   // {header, chapters, chapter_source}
  bool _isLoadingChapters = false;
  bool _useChapterSplit = true;            // toggle, default on when chapters detected
  Set<int> _skippedChapterIndices = {};
  final List<TextEditingController> _chapterTitleControllers = [];
  final TextEditingController _chapAlbumTitleController = TextEditingController();
  final TextEditingController _chapAlbumArtistController = TextEditingController();
  final TextEditingController _chapAlbumYearController = TextEditingController();

  // Playlist state
  List<Map<String, dynamic>>? _playlistTracks;
  bool _isLoadingPlaylist = false;

  // --- Album search + curation (backend: youtube_curate.py) ---
  final TextEditingController _albumSearchController = TextEditingController();
  bool _isSearchingAlbums = false;
  List<Map<String, dynamic>>? _albumResults;
  String? _albumSearchError;
  // Whole-playlist curation result: artist/album/year, MusicBrainz match,
  // and the ok/suspect/replaced summary shown above the track list.
  Map<String, dynamic>? _curation;
  // Original video for every index that got auto-swapped, so it can be
  // reverted from the alternatives sheet.
  final Map<int, Map<String, dynamic>> _originalTracks = {};
  final Set<int> _swappedIndices = {};

  // Download state
  bool _isDownloading = false;
  String _downloadStatus = '';
  int _downloadProgress = 0;
  Set<int> _excludedTrackIndices = {};
  bool _isImporting = false;
  List<Map<String, dynamic>> _downloadedTracks = [];

  // Tagging state - individual mode
  int _currentTaggingIndex = 0;
  final _tagFormKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _artistController = TextEditingController();
  final _albumController = TextEditingController();
  final _trackNumberController = TextEditingController();
  final _yearController = TextEditingController();

  // Bulk tagging mode
  bool _bulkTagMode = false;
  final _bulkArtistController = TextEditingController();
  final _bulkAlbumController = TextEditingController();
  final _bulkYearController = TextEditingController();
  List<TextEditingController> _bulkTitleControllers = [];
  List<TextEditingController> _bulkTrackNumControllers = [];
  // Per-track artist credit captured from MusicBrainz (e.g. "Drake feat.
  // Rihanna"). Null = fall back to the album-level artist field. There's no
  // per-track artist text box in bulk mode, so this is how featured/guest
  // artists survive; the backend splits the string into song_artists.
  List<String?> _bulkTrackArtists = [];

  // Import to existing album
  int? _selectedAlbumId;
  String? _selectedAlbumName;

  // yt-dlp version state
  String? _ytdlpVersion;
  String? _ytdlpLatest;
  bool _ytdlpUpdateAvailable = false;
  bool _isUpdatingYtdlp = false;

  @override
  void initState() {
    super.initState();
    _connectSocket();
    _checkYtDlpVersion();
    // Rejoin any in-flight download/import the user navigated away
    // from. Backend keeps the subprocess running and tracks last
    // progress in _job_state, so a screen-revisit can pick up the
    // job by its operation_id without breaking the running download.
    _rejoinActiveJob();
    if (widget.initialUrl != null) {
      _urlController.text = widget.initialUrl!;
      _validateUrl();
    } else if (widget.initialSearch != null &&
        widget.initialSearch!.trim().isNotEmpty) {
      _albumSearchController.text = widget.initialSearch!.trim();
      _searchAlbums();
    }
  }

  // ---------------------------------------------------------------------
  // Album search: find the playlist without leaving the app
  // ---------------------------------------------------------------------

  Future<void> _searchAlbums() async {
    final q = _albumSearchController.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _isSearchingAlbums = true;
      _albumResults = null;
      _albumSearchError = null;
    });
    try {
      final r = await _apiService.searchYouTubeAlbums(q);
      if (!mounted) return;
      setState(() {
        _albumResults = List<Map<String, dynamic>>.from(r['results'] ?? []);
        _isSearchingAlbums = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSearchingAlbums = false;
        _albumSearchError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _pickAlbumResult(Map<String, dynamic> r) {
    _urlController.text = (r['url'] as String?) ??
        'https://www.youtube.com/playlist?list=${r['id']}';
    setState(() => _albumResults = null);
    _validateUrl();
  }

  // ---------------------------------------------------------------------
  // Curation helpers
  // ---------------------------------------------------------------------

  /// Build the track that replaces [track] at its playlist position: the
  /// replacement's video identity, the original's curation context.
  Map<String, dynamic> _applyReplacement(
      Map<String, dynamic> track, Map<String, dynamic> rep) {
    final out = Map<String, dynamic>.from(track);
    out['id'] = rep['id'];
    out['title'] = rep['title'];
    out['channel'] = rep['channel'];
    out['uploader'] = rep['channel'];
    out['duration'] = rep['duration'];
    out['url'] = rep['url'] ??
        'https://www.youtube.com/watch?v=${rep['id']}';
    out['is_topic'] = rep['is_topic'] == true;
    out['delta'] = rep['delta'];
    out['verdict'] = 'ok';
    out['reason'] = rep['is_topic'] == true
        ? 'replaced with label audio'
        : 'replaced with a length-matched upload';
    out['replacement'] = null;
    return out;
  }

  void _useReplacement(int index, Map<String, dynamic> rep) {
    if (_playlistTracks == null || index >= _playlistTracks!.length) return;
    setState(() {
      _originalTracks.putIfAbsent(
          index, () => Map<String, dynamic>.from(_playlistTracks![index]));
      _playlistTracks![index] =
          _applyReplacement(_playlistTracks![index], rep);
      _swappedIndices.add(index);
      _excludedTrackIndices.remove(index);
    });
  }

  void _revertReplacement(int index) {
    final original = _originalTracks.remove(index);
    if (original == null || _playlistTracks == null) return;
    setState(() {
      _playlistTracks![index] = original;
      _swappedIndices.remove(index);
    });
  }

  String _curationArtist() =>
      (_curation?['artist'] as String?)?.trim().isNotEmpty == true
          ? _curation!['artist'] as String
          : '';

  /// Alternatives sheet: current pick, revert, candidates, re-search, and
  /// a paste-a-URL field for when none of them is right.
  Future<void> _showAlternativesSheet(int index) async {
    if (_playlistTracks == null) return;
    final urlCtl = TextEditingController();
    var alternatives = List<Map<String, dynamic>>.from(
        _playlistTracks![index]['alternatives'] ?? const []);
    var busy = false;
    String? error;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1a2332),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final track = _playlistTracks![index];
          final original = _originalTracks[index];
          final target = (track['mb_length'] as num?)?.toInt();
          final albumTitle = (track['mb_title'] as String?) ?? '';

          Future<void> research() async {
            setSheet(() {
              busy = true;
              error = null;
            });
            try {
              final r = await _apiService.findCleanYouTubeUpload(
                artist: _curationArtist(),
                title: albumTitle.isNotEmpty
                    ? albumTitle
                    : (track['title'] as String? ?? ''),
                targetDuration: target,
                excludeId: track['id'] as String?,
              );
              alternatives = List<Map<String, dynamic>>.from(
                  r['candidates'] ?? const []);
              track['alternatives'] = alternatives;
            } catch (e) {
              error = e.toString().replaceFirst('Exception: ', '');
            }
            setSheet(() => busy = false);
          }

          Future<void> useUrl() async {
            final url = urlCtl.text.trim();
            if (url.isEmpty) return;
            setSheet(() {
              busy = true;
              error = null;
            });
            try {
              final info = await _apiService.getYouTubeInfo(url);
              final idMatch = RegExp(r'(?:v=|youtu\.be/|shorts/)([A-Za-z0-9_-]{11})')
                  .firstMatch(url);
              final id = (info['id'] as String?) ?? idMatch?.group(1);
              if (id == null) throw Exception('Could not read a video id from that URL');
              final dur = (info['duration'] as num?)?.toInt();
              _useReplacement(index, {
                'id': id,
                'title': info['title'] ?? url,
                'channel': info['channel'] ?? info['uploader'] ?? '',
                'duration': dur,
                'url': 'https://www.youtube.com/watch?v=$id',
                'is_topic': false,
                'delta': (dur != null && target != null) ? dur - target : null,
              });
              if (ctx.mounted) Navigator.pop(ctx);
              return;
            } catch (e) {
              error = e.toString().replaceFirst('Exception: ', '');
            }
            setSheet(() => busy = false);
          }

          Widget candidateTile(Map<String, dynamic> c) {
            final delta = (c['delta'] as num?)?.toInt();
            final isTopic = c['is_topic'] == true;
            return ListTile(
              dense: true,
              leading: Icon(
                isTopic ? Icons.verified : Icons.play_circle_outline,
                color: isTopic ? Colors.green : Colors.grey[500],
                size: 20,
              ),
              title: Text(
                c['title'] as String? ?? '',
                style: const TextStyle(color: Colors.white, fontSize: 13),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${c['channel'] ?? ''} · '
                '${_formatDuration((c['duration'] as num?)?.toInt())}'
                '${delta != null ? ' (${delta >= 0 ? '+' : ''}${delta}s vs album)' : ''}'
                '${isTopic ? ' · label audio' : ''}',
                style: TextStyle(color: Colors.grey[500], fontSize: 11),
              ),
              onTap: busy
                  ? null
                  : () {
                      _useReplacement(index, c);
                      Navigator.pop(ctx);
                    },
            );
          }

          return Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    albumTitle.isNotEmpty
                        ? 'Track ${index + 1}: $albumTitle'
                        : 'Track ${index + 1}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Using: ${track['title']} · ${track['channel'] ?? ''} · '
                    '${_formatDuration((track['duration'] as num?)?.toInt())}'
                    '${target != null ? '  (album cut ${_formatDuration(target)})' : ''}',
                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                  ),
                  Text(
                    track['reason'] as String? ?? '',
                    style: TextStyle(color: Colors.grey[600], fontSize: 11),
                  ),
                  if (original != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Replaced: ${original['title']} · '
                            '${_formatDuration((original['duration'] as num?)?.toInt())}',
                            style: TextStyle(color: Colors.grey[500], fontSize: 11),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton(
                          onPressed: busy
                              ? null
                              : () {
                                  _revertReplacement(index);
                                  Navigator.pop(ctx);
                                },
                          child: const Text('Revert'),
                        ),
                      ],
                    ),
                  ],
                  const Divider(color: Colors.white12, height: 20),
                  Row(
                    children: [
                      Text('Alternatives',
                          style: TextStyle(
                              color: Colors.grey[300],
                              fontSize: 13,
                              fontWeight: FontWeight.w600)),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: busy ? null : research,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('Search again'),
                      ),
                    ],
                  ),
                  if (busy) const LinearProgressIndicator(minHeight: 2),
                  if (alternatives.isEmpty && !busy)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text('No candidates yet. Search again or paste a URL.',
                          style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                    ),
                  ...alternatives.take(8).map(candidateTile),
                  const Divider(color: Colors.white12, height: 20),
                  TextField(
                    controller: urlCtl,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Or paste a YouTube URL for this track',
                      hintStyle: TextStyle(color: Colors.grey[600], fontSize: 13),
                      prefixIcon: const Icon(Icons.link, size: 18),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.check),
                        onPressed: busy ? null : useUrl,
                      ),
                      filled: true,
                      fillColor: const Color(0xFF0f1722),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: (_) => useUrl(),
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(error!,
                          style: const TextStyle(color: Colors.red, fontSize: 12)),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
    urlCtl.dispose();
    if (mounted) setState(() {});
  }

  /// Ask the backend whether any download/import is currently active.
  /// If so, restore the visible progress UI to that job so the user
  /// can see what's still running. The websocket subscription is
  /// already wired up — once _currentOperationId matches, fresh
  /// progress events will flow into setState as if the user never
  /// left.
  Future<void> _rejoinActiveJob() async {
    try {
      final jobs = await _apiService.getActiveYouTubeJobs();
      if (!mounted || jobs.isEmpty) return;
      // If multiple jobs are tracked (rare — the screen only starts
      // one at a time), prefer the freshest by updated_at. Fall back
      // to the first entry if updated_at isn't available.
      jobs.sort((a, b) {
        final at = a['updated_at'] as String?;
        final bt = b['updated_at'] as String?;
        if (at == null && bt == null) return 0;
        if (at == null) return 1;
        if (bt == null) return -1;
        return bt.compareTo(at);
      });
      final job = jobs.first;
      final opId = job['operation_id'] as String?;
      final status = job['status'] as String?;
      final message = (job['message'] as String?) ?? '';
      final progress = (job['progress'] is int)
          ? job['progress'] as int
          : (job['progress'] is double ? (job['progress'] as double).toInt() : 0);
      if (opId == null) return;
      // Skip terminal-state jobs that are just lingering in the
      // grace window — nothing useful for the user to "rejoin".
      if (status == 'complete' || status == 'cancelled' || status == 'error') {
        return;
      }
      setState(() {
        _currentOperationId = opId;
        _isDownloading = true;
        _downloadStatus = message.isEmpty ? 'Rejoining download…' : message;
        _downloadProgress = progress;
      });
      _scrollToProgress();
    } catch (_) {
      // Non-fatal — fall through to normal idle state.
    }
  }

  Future<void> _checkYtDlpVersion() async {
    try {
      final result = await _apiService.getYtDlpVersion();
      if (mounted) {
        setState(() {
          _ytdlpVersion = result['installed'];
          _ytdlpLatest = result['latest'];
          _ytdlpUpdateAvailable = result['update_available'] == true;
        });
      }
    } catch (_) {}
  }

  Future<void> _updateYtDlp() async {
    setState(() => _isUpdatingYtdlp = true);
    try {
      final result = await _apiService.updateYtDlp();
      if (mounted) {
        if (result['success'] == true) {
          _showSuccess('yt-dlp updated to ${result['new_version'] ?? 'latest'}');
          _checkYtDlpVersion();
        } else {
          _showError('Update failed: ${result['error'] ?? 'Unknown error'}');
        }
      }
    } catch (e) {
      if (mounted) _showError('Update failed: $e');
    } finally {
      if (mounted) setState(() => _isUpdatingYtdlp = false);
    }
  }

  void _connectSocket() {
    _socket = io.io(
      ApiService.baseHost,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .build(),
    );

    _socket!.on('youtube_progress', (data) {
      if (!mounted) return;

      final operationId = data['operation_id'];
      if (operationId != _currentOperationId) return;

      final status = data['status'] ?? '';
      final message = data['message'] ?? '';
      final progress = data['progress'] ?? 0;

      setState(() {
        // Don't overwrite status during playlist loop - it manages its own messages
        if (_playlistTracks == null || _playlistTracks!.isEmpty) {
          _downloadStatus = message;
        }
        _downloadProgress = progress is int
            ? progress
            : (progress as double).toInt();

        if (status == 'complete' || status == 'error') {
          // Download phase complete, but we may still be waiting for API response
        }
      });
    });

    _socket!.connect();
  }

  @override
  void dispose() {
    _socket?.disconnect();
    _socket?.dispose();
    _urlController.dispose();
    _albumSearchController.dispose();
    _scrollController.dispose();
    _titleController.dispose();
    _artistController.dispose();
    _albumController.dispose();
    _trackNumberController.dispose();
    _yearController.dispose();
    _bulkArtistController.dispose();
    _bulkAlbumController.dispose();
    _bulkYearController.dispose();
    for (var c in _bulkTitleControllers) {
      c.dispose();
    }
    for (var c in _bulkTrackNumControllers) {
      c.dispose();
    }
    for (var c in _chapterTitleControllers) {
      c.dispose();
    }
    _chapAlbumTitleController.dispose();
    _chapAlbumArtistController.dispose();
    _chapAlbumYearController.dispose();
    super.dispose();
  }

  // Scroll the body so the live progress widget is on screen. Called
  // right after _isDownloading flips to true. Posted to the next frame
  // because the progress widget doesn't exist in the tree until after
  // the setState that toggled _isDownloading rebuilds.
  void _scrollToProgress() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _progressKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
          alignment: 0.1, // ~10% from top — leaves room above for context
        );
      }
    });
  }

  Future<void> _validateUrl() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;

    setState(() {
      _isValidating = true;
      _urlInfo = null;
      _videoInfo = null;
      _playlistTracks = null;
      _resetChapterState();
    });

    try {
      final result = await _apiService.validateYouTubeUrl(url);
      setState(() {
        _urlInfo = result;
        _isValidating = false;
      });

      if (result['valid'] == true) {
        if (result['type'] == 'playlist') {
          _loadPlaylistInfo();
        } else {
          _loadVideoInfo();
        }
      }
    } catch (e) {
      setState(() {
        _urlInfo = {'valid': false, 'error': e.toString()};
        _isValidating = false;
      });
    }
  }

  Future<void> _loadVideoInfo() async {
    setState(() => _isLoadingInfo = true);

    try {
      final result = await _apiService.getYouTubeInfo(
        _urlController.text.trim(),
      );
      if (result['success'] == true) {
        setState(() {
          _videoInfo = result['info'];
          _isLoadingInfo = false;
        });
        // Kick off the chapter preview in the background — the UI extends
        // the video card with a chapter-split panel iff this finds chapters.
        _loadChapterPreview();
      } else {
        setState(() => _isLoadingInfo = false);
        final errorType = result['error_type'] ?? 'unknown';
        final error = result['error'] ?? 'Unknown error';
        final warnings = List<String>.from(result['warnings'] ?? []);
        final details = List<String>.from(result['details'] ?? []);

        String message;
        switch (errorType) {
          case 'needs_update':
            message = 'yt-dlp may be outdated. Try updating using the button above.';
            _checkYtDlpVersion(); // Refresh version info
            break;
          case 'unavailable':
            message = 'This video is not available (may be region-restricted or removed).';
            break;
          case 'private':
            message = 'This video is private.';
            break;
          case 'age_restricted':
            message = 'This video is age-restricted and cannot be downloaded.';
            break;
          case 'copyright':
            message = 'This video is blocked due to copyright.';
            break;
          case 'timeout':
            message = 'Request timed out. Try again.';
            break;
          default:
            // Clean up the raw error for display
            message = error
                .replaceAll(RegExp(r'^Exception: '), '')
                .replaceAll(RegExp(r'^ERROR: \[youtube\] [a-zA-Z0-9_-]+: '), '');
        }

        // Append first warning if relevant
        if (warnings.isNotEmpty && errorType != 'needs_update') {
          final relevantWarning = warnings.where(
            (w) => w.contains('challenge solver') || w.contains('not supported'),
          ).firstOrNull;
          if (relevantWarning != null) {
            message += '\n\nHint: yt-dlp may need updating.';
          }
        }

        _showError(message);
      }
    } catch (e) {
      setState(() => _isLoadingInfo = false);
      _showError('Failed to load video info: $e');
    }
  }

  /// Reset chapter-split state — called from _validateUrl when a new URL
  /// is entered, and during dispose-equivalent cleanup. Safe to call when
  /// nothing was loaded yet.
  void _resetChapterState() {
    for (var c in _chapterTitleControllers) {
      c.dispose();
    }
    _chapterTitleControllers.clear();
    _chapterPreview = null;
    _isLoadingChapters = false;
    _useChapterSplit = true;
    _skippedChapterIndices = {};
    _chapAlbumTitleController.clear();
    _chapAlbumArtistController.clear();
    _chapAlbumYearController.clear();
    // Also clear "import to existing album" target — _selectedAlbumId is
    // shared with the legacy tagging flow but a new URL means a new
    // decision. Without this, switching from one URL to another would
    // silently inherit the previous target.
    _selectedAlbumId = null;
    _selectedAlbumName = null;
  }

  /// Open MusicBrainz search for the chapter-split album. On a full-tracklist
  /// result, populate album metadata + (if track count matches) overwrite
  /// each chapter title with the MB-canonical name.
  Future<void> _pickMusicBrainzForChapters() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _MusicBrainzSearchDialog(
        apiService: _apiService,
        initialArtist: _chapAlbumArtistController.text,
        initialAlbum: _chapAlbumTitleController.text,
        initialTitle: '',
        returnFullTrackList: true,
      ),
    );
    if (result == null || !mounted) return;

    final tracks = result['tracks'];
    final chapters = _chapterPreview != null
        ? (_chapterPreview!['chapters'] as List)
        : const [];

    setState(() {
      if (result['album'] != null) {
        _chapAlbumTitleController.text = result['album'].toString();
      }
      if (result['artist'] != null) {
        _chapAlbumArtistController.text = result['artist'].toString();
      }
      if (result['year'] != null) {
        _chapAlbumYearController.text = result['year'].toString();
      }

      if (tracks is List && tracks.isNotEmpty) {
        if (tracks.length == chapters.length) {
          // 1:1 track-count match — overwrite each chapter title with the
          // MusicBrainz canonical name.
          for (int i = 0; i < tracks.length; i++) {
            final t = tracks[i];
            final title = (t is Map ? t['title'] : null)?.toString();
            if (title != null && title.isNotEmpty) {
              _chapterTitleControllers[i].text = title;
            }
          }
        } else {
          // Track-count mismatch — applying 1:1 would misname tracks. Keep
          // the parser's titles, just take the album-level metadata.
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'MusicBrainz returned ${tracks.length} tracks, but the video '
                'has ${chapters.length} chapters. Album info applied; track '
                'names kept as-is. Edit them inline if you want.',
              ),
              duration: const Duration(seconds: 5),
            ),
          );
        }
      }
    });
  }

  /// Open the existing-album picker. On a result, pin _selectedAlbumId so
  /// the import routes the songs into that album (no new artist/album rows,
  /// files moved into the existing folder, existing cover preserved).
  /// Also overwrites the album title/artist/year fields so the per-track
  /// file tags match the target.
  Future<void> _pickExistingAlbumForChapters() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _AlbumPickerDialog(apiService: _apiService),
    );
    if (result == null || !mounted) return;

    final id = result['id'];
    if (id is! int) return;
    setState(() {
      _selectedAlbumId = id;
      _selectedAlbumName = (result['title'] ?? '').toString();
      final albumTitle = (result['title'] ?? '').toString();
      final artistName = (result['artist_name'] ?? '').toString();
      if (albumTitle.isNotEmpty) _chapAlbumTitleController.text = albumTitle;
      if (artistName.isNotEmpty) _chapAlbumArtistController.text = artistName;
      final y = result['year'];
      if (y != null) _chapAlbumYearController.text = y.toString();
    });
  }

  /// Ask the backend whether this video has chapters (native markers or a
  /// description-timestamp tracklist). When it does, populate the chapter
  /// list + album-form defaults; the video card then extends with the
  /// chapter-split panel. Failure is non-fatal — the single-video download
  /// path still works.
  Future<void> _loadChapterPreview() async {
    setState(() => _isLoadingChapters = true);
    try {
      final result = await _apiService.getYouTubeChapters(_urlController.text.trim());
      if (!mounted) return;
      if (result['success'] != true) {
        setState(() => _isLoadingChapters = false);
        return;
      }
      final chapters = List<Map<String, dynamic>>.from(result['chapters'] ?? []);
      final source = (result['chapter_source'] ?? 'none').toString();
      final header = Map<String, dynamic>.from(result['header'] ?? {});

      // One TextEditingController per chapter for inline title editing.
      // Replace any leftover from a prior URL.
      for (var c in _chapterTitleControllers) {
        c.dispose();
      }
      _chapterTitleControllers.clear();
      for (final ch in chapters) {
        _chapterTitleControllers.add(
          TextEditingController(text: (ch['title'] ?? '').toString()),
        );
      }

      // Auto-skip likely-non-music chapters (intro/outro/subscribe/credits).
      final skipPat = RegExp(
        r'\b(intro|outro|subscribe|like\s*&?\s*subscribe|sponsor|credits|thanks for watching)\b',
        caseSensitive: false,
      );
      final autoSkip = <int>{};
      for (int i = 0; i < chapters.length; i++) {
        if (skipPat.hasMatch((chapters[i]['title'] ?? '').toString())) {
          autoSkip.add(i);
        }
      }

      // Default album fields from the video metadata. Year derives from
      // YYYYMMDD `upload_date`. Don't clobber what the user already typed.
      final videoTitle = (header['title'] ?? '').toString();
      final channel = (header['channel'] ?? header['uploader'] ?? '').toString();
      final uploadDate = (header['upload_date'] ?? '').toString();
      final defaultYear = uploadDate.length >= 4 ? uploadDate.substring(0, 4) : '';

      setState(() {
        _chapterPreview = {
          'header': header,
          'chapters': chapters,
          'chapter_source': source,
        };
        _skippedChapterIndices = autoSkip;
        _isLoadingChapters = false;
        _useChapterSplit = source != 'none' && chapters.length >= 2;
        if (_chapAlbumTitleController.text.isEmpty) {
          _chapAlbumTitleController.text = videoTitle;
        }
        if (_chapAlbumArtistController.text.isEmpty) {
          _chapAlbumArtistController.text = channel;
        }
        if (_chapAlbumYearController.text.isEmpty && defaultYear.isNotEmpty) {
          _chapAlbumYearController.text = defaultYear;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _isLoadingChapters = false);
      // Non-fatal: the regular single-video Download button still works.
      print('Chapter preview failed: $e');
    }
  }

  /// Submit the chapter-split album import. Builds the payload from the
  /// editable controllers + skip set, fires the backend endpoint, and
  /// tracks progress through the existing _downloadStatus/_downloadProgress
  /// + youtube_progress websocket pipeline.
  Future<void> _importAsAlbum() async {
    if (_chapterPreview == null) return;
    final albumTitle = _chapAlbumTitleController.text.trim();
    final albumArtist = _chapAlbumArtistController.text.trim();
    if (albumTitle.isEmpty || albumArtist.isEmpty) {
      _showError('Album title and artist required');
      return;
    }

    final origChapters =
        List<Map<String, dynamic>>.from(_chapterPreview!['chapters']);
    final payload = <Map<String, dynamic>>[];
    for (int i = 0; i < origChapters.length; i++) {
      final c = Map<String, dynamic>.from(origChapters[i]);
      final edited = _chapterTitleControllers[i].text.trim();
      c['title'] = edited.isEmpty
          ? (c['title'] ?? 'Track ${i + 1}').toString()
          : edited;
      c['skip'] = _skippedChapterIndices.contains(i);
      payload.add(c);
    }
    final selectedCount = payload.where((c) => c['skip'] != true).length;
    if (selectedCount == 0) {
      _showError('Select at least one track to import');
      return;
    }

    final opId = DateTime.now().millisecondsSinceEpoch.toString();
    setState(() {
      _isImporting = true;
      _currentOperationId = opId;
      _downloadStatus = 'Starting import...';
      _downloadProgress = 0;
    });
    _scrollToProgress();

    final yearStr = _chapAlbumYearController.text.trim();
    final albumMeta = <String, dynamic>{
      'title': albumTitle,
      'artist': albumArtist,
      if (yearStr.isNotEmpty) 'year': int.tryParse(yearStr),
    };

    try {
      final result = await _apiService.importYouTubeAsAlbum(
        url: _urlController.text.trim(),
        chapters: payload,
        album: albumMeta,
        operationId: opId,
        albumId: _selectedAlbumId,
      );
      if (!mounted) return;
      final ok = result['success'] == true;
      setState(() {
        _isImporting = false;
        _downloadStatus = ok
            ? 'Imported ${result['songs_added']} tracks into "$albumTitle"'
            : 'Import failed: ${result['error']}';
        _downloadProgress = ok ? 100 : 0;
      });
      if (ok) {
        final newAlbumId = result['album_id'];

        // Open the artwork picker for newly-created albums so the user can
        // override the YouTube thumbnail with a proper album cover from
        // MusicBrainz/Cover Art Archive/file upload. Matches the legacy
        // single-track flow's post-import behavior. Skipped when importing
        // INTO an existing album (target already has whatever cover the
        // user wants — we shouldn't pop a picker for it).
        if (_selectedAlbumId == null && newAlbumId is int && mounted) {
          await showDialog(
            context: context,
            builder: (ctx) => ArtworkPickerDialog(
              albumId: newAlbumId,
              albumTitle: albumTitle,
              artistName: albumArtist,
            ),
          );
          if (!mounted) return;
        }

        // Snackbar with a "View Album" action so the user can jump to the
        // freshly-imported album and verify it landed correctly.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Album "$albumTitle" imported '
              '(${result['songs_added']} tracks)',
            ),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 8),
            action: (newAlbumId is int)
                ? SnackBarAction(
                    label: 'View Album',
                    textColor: Colors.white,
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => AlbumDetailScreen(
                            albumId: newAlbumId,
                            audioPlayerService: widget.audioPlayerService,
                            parentLabel: 'YouTube',
                          ),
                        ),
                      );
                    },
                  )
                : null,
          ),
        );
        // Reset the form so the user can immediately paste another URL.
        // The video card + chapter card both render off these values, so
        // wiping them returns the screen to its initial "paste a URL" state.
        setState(() {
          _urlController.clear();
          _urlInfo = null;
          _videoInfo = null;
          _resetChapterState();
          _downloadStatus = '';
          _downloadProgress = 0;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isImporting = false;
        _downloadStatus = 'Failed: $e';
      });
      _showError('Import failed: $e');
    }
  }

  /// Chapter-split panel — extends the single-video card with album-import
  /// UI when chapters were detected. Toggle off to fall back to the
  /// existing "Download Audio" single-track flow on the parent video card.
  Widget _buildChapterSplitCard() {
    if (_chapterPreview == null) {
      if (_isLoadingChapters) {
        return const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00d4ff)),
                  ),
                  SizedBox(width: 12),
                  Text('Checking for chapters…', style: TextStyle(color: Colors.white70)),
                ],
              ),
            ),
          ),
        );
      }
      return const SizedBox.shrink();
    }

    final preview = _chapterPreview!;
    final source = preview['chapter_source'] as String;
    if (source == 'none') return const SizedBox.shrink();
    final chapters = List<Map<String, dynamic>>.from(preview['chapters']);
    final selectedCount = chapters.length - _skippedChapterIndices.length;

    return Card(
      margin: const EdgeInsets.only(top: 12),
      color: const Color(0xFF0d1b2a),
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: Color(0xFF00d4ff), width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.queue_music, color: Color(0xFF00d4ff)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${chapters.length} tracks detected',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                Chip(
                  label: Text(
                    source == 'native' ? 'YouTube chapters' : 'Parsed from description',
                    style: const TextStyle(fontSize: 11),
                  ),
                  backgroundColor: source == 'native'
                      ? Colors.green.withOpacity(0.18)
                      : Colors.orange.withOpacity(0.18),
                  side: BorderSide(
                    color: source == 'native' ? Colors.green : Colors.orange,
                    width: 0.5,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Switch(
                  value: _useChapterSplit,
                  activeColor: const Color(0xFF00d4ff),
                  onChanged: (v) => setState(() => _useChapterSplit = v),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _useChapterSplit
                        ? 'Import as album with chapter tracks'
                        : 'Toggle on to import as album',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
            if (_useChapterSplit) ...[
              const Divider(color: Colors.white12, height: 24),
              // Metadata-source buttons — mirror the legacy tagging form so
              // the chapter-split flow has the same options for filling in
              // album/track titles and for routing into an existing album.
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: (_isImporting || _isDownloading)
                          ? null
                          : _pickMusicBrainzForChapters,
                      icon: const Icon(Icons.search, size: 18),
                      label: const Text('MusicBrainz',
                          style: TextStyle(fontSize: 13)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF00d4ff),
                        side: const BorderSide(color: Color(0xFF00d4ff)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: (_isImporting || _isDownloading)
                          ? null
                          : _pickExistingAlbumForChapters,
                      icon: const Icon(Icons.library_music, size: 18),
                      label: const Text('Existing Album',
                          style: TextStyle(fontSize: 13)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.orange,
                        side: const BorderSide(color: Colors.orange),
                      ),
                    ),
                  ),
                ],
              ),
              // "Importing to an existing album" badge with dismiss X.
              if (_selectedAlbumId != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: Colors.orange.withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.library_music,
                            color: Colors.orange, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Importing tracks into: '
                            '${_selectedAlbumName ?? "existing album"}',
                            style: const TextStyle(
                                color: Colors.orange, fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        InkWell(
                          onTap: () => setState(() {
                            _selectedAlbumId = null;
                            _selectedAlbumName = null;
                          }),
                          child: const Icon(Icons.close,
                              color: Colors.orange, size: 16),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              const Text(
                'ALBUM',
                style: TextStyle(
                  color: Color(0xFF00d4ff),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _chapAlbumTitleController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Album title',
                  labelStyle: TextStyle(color: Colors.white70),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _chapAlbumArtistController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Album artist',
                  labelStyle: TextStyle(color: Colors.white70),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: 140,
                child: TextField(
                  controller: _chapAlbumYearController,
                  style: const TextStyle(color: Colors.white),
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Year (optional)',
                    labelStyle: TextStyle(color: Colors.white70),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Divider(color: Colors.white12, height: 0),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.list, color: Color(0xFF00d4ff), size: 18),
                  const SizedBox(width: 6),
                  Text(
                    'TRACKS — $selectedCount of ${chapters.length} selected',
                    style: const TextStyle(
                      color: Color(0xFF00d4ff),
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => setState(() => _skippedChapterIndices = {}),
                    child: const Text('Select all'),
                  ),
                  TextButton(
                    onPressed: () => setState(
                      () => _skippedChapterIndices = Set<int>.from(
                          List.generate(chapters.length, (i) => i)),
                    ),
                    child: const Text('Deselect all'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Container(
                constraints: const BoxConstraints(maxHeight: 320),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: chapters.length,
                  itemBuilder: (ctx, i) {
                    final c = chapters[i];
                    final skipped = _skippedChapterIndices.contains(i);
                    final start = (c['start_seconds'] as num?)?.toInt() ?? 0;
                    final end = (c['end_seconds'] as num?)?.toInt();
                    final range = end != null
                        ? '${_formatDuration(start)}–${_formatDuration(end)}'
                        : '${_formatDuration(start)}+';
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(color: Colors.white.withOpacity(0.04)),
                        ),
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            icon: Icon(
                              skipped
                                  ? Icons.check_box_outline_blank
                                  : Icons.check_box,
                              color: skipped
                                  ? Colors.white38
                                  : const Color(0xFF00d4ff),
                              size: 22,
                            ),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 32, minHeight: 32),
                            onPressed: () => setState(() {
                              if (skipped) {
                                _skippedChapterIndices.remove(i);
                              } else {
                                _skippedChapterIndices.add(i);
                              }
                            }),
                          ),
                          SizedBox(
                            width: 28,
                            child: Text(
                              '${i + 1}.',
                              style: TextStyle(
                                color:
                                    skipped ? Colors.white38 : Colors.white70,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                          Expanded(
                            child: TextField(
                              controller: _chapterTitleControllers[i],
                              enabled: !skipped,
                              style: TextStyle(
                                color: skipped ? Colors.white38 : Colors.white,
                                decoration: skipped
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                              decoration: const InputDecoration(
                                isDense: true,
                                border: InputBorder.none,
                                contentPadding:
                                    EdgeInsets.symmetric(vertical: 8),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            range,
                            style: TextStyle(
                              color: skipped ? Colors.white38 : Colors.white54,
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.album),
                  label: Text(
                    _selectedAlbumId != null
                        ? 'Import into "$_selectedAlbumName" '
                          '($selectedCount track${selectedCount == 1 ? "" : "s"})'
                        : 'Import as Album '
                          '($selectedCount track${selectedCount == 1 ? "" : "s"})',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00d4ff),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    textStyle: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                  onPressed: (_isImporting ||
                          _isDownloading ||
                          selectedCount == 0)
                      ? null
                      : _importAsAlbum,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _loadPlaylistInfo() async {
    setState(() {
      _isLoadingPlaylist = true;
      _curation = null;
      _originalTracks.clear();
      _swappedIndices.clear();
      _excludedTrackIndices.clear();
    });

    final url = _urlController.text.trim();
    try {
      // Curated load: every video graded against the album's MusicBrainz
      // track lengths, suspects auto-swapped for a clean upload.
      final result = await _apiService.curateYouTubePlaylist(url);
      if (!mounted) return;
      if (result['success'] != true) throw Exception(result['error']);

      final tracks = List<Map<String, dynamic>>.from(result['tracks'] ?? []);
      final swapped = <int>{};
      final excluded = <int>{};
      for (int i = 0; i < tracks.length; i++) {
        final rep = tracks[i]['replacement'];
        if (rep is Map) {
          _originalTracks[i] = Map<String, dynamic>.from(tracks[i]);
          tracks[i] = _applyReplacement(
              tracks[i], Map<String, dynamic>.from(rep));
          swapped.add(i);
        } else if (tracks[i]['verdict'] == 'suspect') {
          // Nothing clean found: leave it unticked, same as the old
          // manual flow, with the badge to go pick one.
          excluded.add(i);
        }
      }
      if (result['url_was_rewritten'] == true && result['url'] is String) {
        _urlController.text = result['url'] as String;
      }
      setState(() {
        _playlistTracks = tracks;
        _curation = result;
        _swappedIndices.addAll(swapped);
        _excludedTrackIndices.addAll(excluded);
        _isLoadingPlaylist = false;
      });
      return;
    } catch (e) {
      // Curation is a bonus. If it falls over, load the plain list so the
      // old manual flow still works, and say why.
      if (!mounted) return;
      _showError('Curation unavailable: ${e.toString().replaceFirst('Exception: ', '')}');
    }

    try {
      final result = await _apiService.getYouTubePlaylistInfo(url);
      if (!mounted) return;
      if (result['success'] == true) {
        setState(() {
          _playlistTracks = List<Map<String, dynamic>>.from(
            result['tracks'] ?? [],
          );
          _isLoadingPlaylist = false;
        });
      } else {
        throw Exception(result['error']);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingPlaylist = false);
      _showError('Failed to load playlist: $e');
    }
  }

  Future<void> _downloadSingleVideo() async {
    // Generate operation ID for WebSocket progress tracking
    _currentOperationId = DateTime.now().millisecondsSinceEpoch.toString();

    setState(() {
      _isDownloading = true;
      _downloadStatus = 'Starting download...';
      _downloadProgress = 0;
    });
    _scrollToProgress();

    try {
      final result = await _apiService.downloadYouTubePlaylist(
        _urlController.text.trim(),
        operationId: _currentOperationId,
      );
      if (result['success'] == true) {
        final tracks = List<Map<String, dynamic>>.from(result['tracks'] ?? []);
        setState(() {
          _downloadedTracks = tracks;
          _isDownloading = false;
          _downloadStatus = 'Download complete!';
          _downloadProgress = 100;
        });
        if (tracks.isNotEmpty) {
          _prepareTagging(0);
        }
      } else {
        throw Exception(result['error']);
      }
    } catch (e) {
      setState(() {
        _isDownloading = false;
        _downloadStatus = 'Download failed';
      });
      _showError('Download failed: $e');
    }
  }

  Future<void> _cancelDownload() async {
    if (_currentOperationId == null) return;

    setState(() {
      _isDownloading = false;
      _downloadStatus = 'Download cancelled';
      _downloadProgress = 0;
    });

    try {
      await _apiService.cancelYouTubeDownload(_currentOperationId!);
    } catch (e) {
      // Backend cancel failed, but we've already stopped the loop
    }
  }

  Future<void> _downloadPlaylist() async {
    _currentOperationId = DateTime.now().millisecondsSinceEpoch.toString();

    // Filter to only included tracks, preserving original playlist index
    final includedTracks = <Map<String, dynamic>>[];
    for (int i = 0; i < _playlistTracks!.length; i++) {
      if (!_excludedTrackIndices.contains(i)) {
        final track = Map<String, dynamic>.from(_playlistTracks![i]);
        track['_originalIndex'] = i; // preserve 0-based playlist position
        includedTracks.add(track);
      }
    }

    if (includedTracks.isEmpty) {
      _showError('No tracks selected');
      return;
    }

    setState(() {
      _isDownloading = true;
      _downloadStatus = 'Downloading ${includedTracks.length} tracks...';
      _downloadProgress = 0;
    });
    _scrollToProgress();

    final downloaded = <Map<String, dynamic>>[];

    try {
      for (int i = 0; i < includedTracks.length; i++) {
        final track = includedTracks[i];
        final trackUrl =
            track['url'] ?? 'https://www.youtube.com/watch?v=${track['id']}';
        final trackTitle = track['title'] ?? 'Track ${i + 1}';

        setState(() {
          _downloadProgress = ((i / includedTracks.length) * 100).toInt();
          _downloadStatus =
              'Downloading ${i + 1}/${includedTracks.length}: $trackTitle';
        });

        if (!_isDownloading) {
          downloaded.clear();
          break;
        }

        try {
          final result = await _apiService.downloadYouTube(
            trackUrl,
            operationId: _currentOperationId,
          );
          if (result['success'] == true) {
            // Preserve original playlist position for correct track numbering
            result['_originalIndex'] = track['_originalIndex'] ?? i;
            downloaded.add(result);
          }
        } catch (e) {
          if (!_isDownloading) {
            downloaded.clear();
            break;
          }
          print('Failed to download $trackTitle: $e');
        }
      }

      if (_downloadStatus == 'Download cancelled') return;

      // Widget can be disposed during the await above (user navigates
      // away mid-download). setState on a disposed State throws "Null
      // check operator used on a null value" — caught a 2026-05-20
      // crash from this callsite.
      if (!mounted) return;
      setState(() {
        _downloadedTracks = downloaded;
        _isDownloading = false;
        _downloadStatus =
            'Downloaded ${downloaded.length}/${includedTracks.length} tracks';
        _downloadProgress = 100;
      });

      if (downloaded.isNotEmpty) {
        if (downloaded.length > 1) {
          _showTaggingModeDialog();
        } else {
          _prepareTagging(0);
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isDownloading = false;
        _downloadStatus = 'Download failed';
      });
      _showError('Download failed: $e');
    }
  }

  void _showTaggingModeDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: const Text('How would you like to tag?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_downloadedTracks.length} tracks downloaded',
              style: TextStyle(color: Colors.grey[400]),
            ),
            const SizedBox(height: 16),
            const Text('Choose tagging mode:', style: TextStyle(fontSize: 14)),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.pop(context);
              _prepareTagging(0);
            },
            icon: const Icon(Icons.looks_one),
            label: const Text('One at a time'),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pop(context);
              _prepareBulkTagging();
            },
            icon: const Icon(Icons.list),
            label: const Text('Bulk Tag All'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00d4ff),
              foregroundColor: Colors.black,
            ),
          ),
        ],
      ),
    );
  }

  void _prepareBulkTagging() {
    // Clean up old controllers
    for (var c in _bulkTitleControllers) {
      c.dispose();
    }
    for (var c in _bulkTrackNumControllers) {
      c.dispose();
    }

    // Create new controllers for each track
    _bulkTitleControllers = [];
    _bulkTrackNumControllers = [];
    _bulkTrackArtists = List<String?>.filled(_downloadedTracks.length, null);

    // Try to extract common artist/album from first track
    final firstMetadata =
        _downloadedTracks.first['metadata'] as Map<String, dynamic>? ?? {};
    // Curation knows better than the uploader field: artist/album/year
    // from MusicBrainz, and the proper track title per playlist slot.
    final mb = (_curation?['musicbrainz'] as Map?) ?? const {};
    final curatedArtist = (_curation?['artist'] as String?)?.trim() ?? '';
    final curatedAlbum =
        ((mb['album'] as String?) ?? (_curation?['album'] as String?) ?? '').trim();
    _bulkArtistController.text = curatedArtist.isNotEmpty
        ? curatedArtist
        : (firstMetadata['channel'] ?? firstMetadata['uploader'] ?? '');
    _bulkAlbumController.text =
        curatedAlbum.isNotEmpty ? curatedAlbum : 'YouTube Downloads';
    _bulkYearController.text = (mb['year'] as String?)?.isNotEmpty == true
        ? mb['year'] as String
        : _extractYear(firstMetadata['upload_date']);

    for (int i = 0; i < _downloadedTracks.length; i++) {
      final track = _downloadedTracks[i];
      final metadata = track['metadata'] as Map<String, dynamic>? ?? {};

      // Use original playlist position for track number (1-based)
      final originalIndex = track['_originalIndex'] as int? ?? i;
      final slot = (_playlistTracks != null &&
              originalIndex < _playlistTracks!.length)
          ? _playlistTracks![originalIndex]
          : null;
      final mbTitle = (slot?['mb_title'] as String?)?.trim();
      final mbPos = (slot?['mb_position'] as num?)?.toInt();
      final trackNum = mbPos ?? (originalIndex + 1);

      _bulkTitleControllers.add(
        TextEditingController(
          text: (mbTitle != null && mbTitle.isNotEmpty)
              ? mbTitle
              : _cleanTitle(metadata['title'] ?? 'Track $trackNum'),
        ),
      );
      _bulkTrackNumControllers.add(TextEditingController(text: '$trackNum'));
    }

    setState(() => _bulkTagMode = true);
  }

  Future<void> _applyBulkTagsAndImport() async {
    final artist = _bulkArtistController.text.trim();
    final album = _bulkAlbumController.text.trim();
    final year = int.tryParse(_bulkYearController.text.trim());
    int? lastAlbumId;

    if (artist.isEmpty || album.isEmpty) {
      _showError('Artist and Album are required');
      return;
    }

    setState(() {
      _isImporting = true;
      _downloadStatus = 'Importing tracks...';
    });
    _scrollToProgress();

    int successCount = 0;

    for (int i = 0; i < _downloadedTracks.length; i++) {
      final track = _downloadedTracks[i];
      final filename = track['filename'] as String;
      final title = _bulkTitleControllers[i].text.trim();
      final trackNum =
          int.tryParse(_bulkTrackNumControllers[i].text.trim()) ?? (i + 1);
      // Track artist (TPE1) = the per-track MusicBrainz credit when present,
      // else the album artist. The album artist (TPE2/albumartist) below is
      // what the album files under — so a compilation can group under
      // "Various Artists" while each song keeps its real artist. The backend
      // splits the track credit into the song_artists junction.
      final mbArtist = (i < _bulkTrackArtists.length)
          ? _bulkTrackArtists[i]
          : null;
      final trackArtist = (mbArtist != null && mbArtist.isNotEmpty)
          ? mbArtist
          : artist;

      try {
        setState(
          () => _downloadStatus =
              'Tagging ${i + 1}/${_downloadedTracks.length}: $title',
        );

        // Apply tags: per-track artist + album-level album_artist.
        await _apiService.tagYouTubeDownload(filename, {
          'title': title,
          'artist': trackArtist,
          'album_artist': artist,
          'album': album,
          'track_number': trackNum,
          'year': year,
        });

        // Import to library — folder stays album-level so the album's files
        // sit together; the scanner groups the DB album by album_artist.
        final importResult = await _apiService.importYouTubeDownload(
          filename,
          artist,
          album,
        );
        successCount++;
        lastAlbumId = importResult['album_id'];
      } catch (e) {
        print('Failed to import track $i: $e');
      }
    }

    _showSuccess(
      'Imported $successCount/${_downloadedTracks.length} tracks to "$album"',
    );

    // Show artwork picker once for the album
    if (lastAlbumId != null && mounted) {
      await showDialog(
        context: context,
        builder: (context) => ArtworkPickerDialog(
          albumId: lastAlbumId!,
          albumTitle: album,
          artistName: artist,
        ),
      );
    }

    setState(() {
      _downloadedTracks = [];
      _bulkTagMode = false;
      _isImporting = false;
      _downloadStatus = 'All tracks imported!';
    });
    _resetForm();
  }

  Future<void> _bulkMusicBrainzLookup() async {
    // Open MusicBrainz dialog using the bulk artist/album fields
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _MusicBrainzSearchDialog(
        apiService: _apiService,
        initialArtist: _bulkArtistController.text,
        initialAlbum: _bulkAlbumController.text,
        initialTitle: '', // No single track title in bulk mode
        returnFullTrackList: true, // Request the full track list back
      ),
    );

    if (result != null && mounted) {
      setState(() {
        // Update album-level info
        if (result['artist'] != null) {
          _bulkArtistController.text = result['artist'];
        }
        if (result['album'] != null) {
          _bulkAlbumController.text = result['album'];
        }
        if (result['year'] != null) {
          _bulkYearController.text = result['year'].toString();
        }

        // If we got a full track list back, match tracks by position
        final tracks = result['tracks'] as List<Map<String, dynamic>>?;
        if (tracks != null && tracks.isNotEmpty) {
          for (int i = 0; i < _downloadedTracks.length; i++) {
            final trackNum =
                int.tryParse(_bulkTrackNumControllers[i].text) ?? (i + 1);
            // Find the MusicBrainz track that matches this track number
            final mbTrack = tracks.firstWhere(
              (t) => (t['position'] ?? t['number']) == trackNum,
              orElse: () => <String, dynamic>{},
            );
            if (mbTrack.isNotEmpty && mbTrack['title'] != null) {
              _bulkTitleControllers[i].text = mbTrack['title'];
              // Per-track credit (incl. featured artists). Falls back to the
              // album artist at import time when MB didn't supply one.
              final tArtist = mbTrack['artist'] as String?;
              if (i < _bulkTrackArtists.length) {
                _bulkTrackArtists[i] =
                    (tArtist != null && tArtist.isNotEmpty) ? tArtist : null;
              }
            }
          }
          _showSuccess(
            'Applied MusicBrainz data: ${tracks.length} tracks found',
          );
        }
      });
    }
  }

  void _prepareTagging(int index) {
    if (index >= _downloadedTracks.length) return;

    final track = _downloadedTracks[index];
    final metadata = track['metadata'] as Map<String, dynamic>? ?? {};

    // Pre-fill form with YouTube metadata
    _titleController.text = _cleanTitle(metadata['title'] ?? '');
    _artistController.text = metadata['channel'] ?? metadata['uploader'] ?? '';
    _albumController.text = 'YouTube Downloads'; // Default album
    _trackNumberController.text = '${index + 1}';
    _yearController.text = _extractYear(metadata['upload_date']);

    // Clear any existing album selection when moving to next track
    _selectedAlbumId = null;
    _selectedAlbumName = null;

    setState(() => _currentTaggingIndex = index);
  }

  String _cleanTitle(String title) {
    // Remove common YouTube title patterns
    String cleaned = title;
    // Remove "Official Video", "Official Audio", "Lyric Video", etc.
    cleaned = cleaned.replaceAll(
      RegExp(
        r'\s*[\(\[]?\s*official\s*(video|audio|music video|lyric video|lyrics|hd|hq)?\s*[\)\]]?\s*',
        caseSensitive: false,
      ),
      ' ',
    );
    // Remove "ft.", "feat." patterns at the end (we want these in artist field)
    cleaned = cleaned.replaceAll(
      RegExp(r'\s*[\(\[]\s*ft\.?\s+[^\)\]]+[\)\]]', caseSensitive: false),
      '',
    );
    cleaned = cleaned.trim();
    return cleaned;
  }

  String _extractYear(String? uploadDate) {
    if (uploadDate == null || uploadDate.length < 4) return '';
    return uploadDate.substring(0, 4);
  }

  Future<void> _applyTagsAndImport() async {
    if (!_tagFormKey.currentState!.validate()) return;

    final track = _downloadedTracks[_currentTaggingIndex];
    final filename = track['filename'] as String;

    setState(() {
      _isImporting = true;
      _downloadStatus = 'Applying tags...';
    });
    _scrollToProgress();

    try {
      // Apply tags
      await _apiService.tagYouTubeDownload(filename, {
        'title': _titleController.text.trim(),
        'artist': _artistController.text.trim(),
        'album': _albumController.text.trim(),
        'track_number': int.tryParse(_trackNumberController.text) ?? 1,
        'year': int.tryParse(_yearController.text),
      });

      setState(() => _downloadStatus = 'Importing to library...');

      // Import to library (pass album_id if importing to existing album)
      final importResult = await _apiService.importYouTubeDownload(
        filename,
        _artistController.text.trim(),
        _albumController.text.trim(),
        albumId: _selectedAlbumId,
      );

      if (importResult['success'] == true) {
        _showSuccess('Imported: ${_titleController.text}');

        // Show artwork picker only for NEW albums (not when importing to existing)
        if (_selectedAlbumId == null) {
          final albumId = importResult['album_id'];
          if (albumId != null && mounted) {
            await showDialog(
              context: context,
              builder: (context) => ArtworkPickerDialog(
                albumId: albumId,
                albumTitle: _albumController.text.trim(),
                artistName: _artistController.text.trim(),
              ),
            );
          }
        }

        // Move to next track or finish
        if (_currentTaggingIndex < _downloadedTracks.length - 1) {
          setState(() => _isImporting = false);
          _prepareTagging(_currentTaggingIndex + 1);
        } else {
          setState(() {
            _downloadedTracks = [];
            _downloadStatus = 'All tracks imported!';
            _isImporting = false;
          });
          _resetForm();
        }
      } else {
        throw Exception(importResult['error']);
      }
    } catch (e) {
      setState(() => _isImporting = false);
      _showError('Import failed: $e');
    }
  }

  void _skipTrack() {
    if (_currentTaggingIndex < _downloadedTracks.length - 1) {
      _prepareTagging(_currentTaggingIndex + 1);
    } else {
      setState(() {
        _downloadedTracks = [];
        _downloadStatus = 'Finished';
      });
      _resetForm();
    }
  }

  void _resetForm() {
    _urlController.clear();
    _titleController.clear();
    _artistController.clear();
    _albumController.clear();
    _trackNumberController.clear();
    _yearController.clear();
    _bulkArtistController.clear();
    _bulkAlbumController.clear();
    _bulkYearController.clear();
    for (var c in _bulkTitleControllers) {
      c.dispose();
    }
    for (var c in _bulkTrackNumControllers) {
      c.dispose();
    }
    _bulkTitleControllers = [];
    _bulkTrackNumControllers = [];
    setState(() {
      _urlInfo = null;
      _videoInfo = null;
      _playlistTracks = null;
      _excludedTrackIndices = {};
      _bulkTagMode = false;
      _selectedAlbumId = null;
      _selectedAlbumName = null;
    });
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  Widget _buildUpdateBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orange.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.system_update, color: Colors.orange, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'yt-dlp update available',
                  style: TextStyle(
                    color: Colors.orange,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                Text(
                  '$_ytdlpVersion \u2192 $_ytdlpLatest',
                  style: TextStyle(
                    color: Colors.orange.withOpacity(0.7),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 32,
            child: ElevatedButton(
              onPressed: _isUpdatingYtdlp ? null : _updateYtDlp,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: _isUpdatingYtdlp
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.black,
                      ),
                    )
                  : const Text('Update', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.green),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Width-aware AppBar layout. The version chip + the 'Torrents' label
    // both crowd the bar on narrow phones (Pixel-class ~360-411dp wide)
    // and visually overlap the title; on tablets/desktop they fit fine.
    // Threshold of 480dp picks "phone in portrait" reliably without
    // false-positives on tablets in portrait.
    final isNarrow = MediaQuery.of(context).size.width < 480;
    return Scaffold(
      backgroundColor: const Color(0xFF0a1929),
      appBar: AppBar(
        title: const Text(
          'YouTube Download',
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: const Color(0xFF0d1b2a),
        actions: [
          // Version chip — only shown on wider screens (still visible
          // in the update-banner when an update is available, so we
          // aren't hiding important info on mobile).
          if (_ytdlpVersion != null && !isNarrow)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: _ytdlpUpdateAvailable
                        ? Colors.orange.withOpacity(0.2)
                        : Colors.grey.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: _ytdlpUpdateAvailable
                          ? Colors.orange.withOpacity(0.5)
                          : Colors.grey.withOpacity(0.3),
                    ),
                  ),
                  child: Text(
                    'yt-dlp $_ytdlpVersion',
                    style: TextStyle(
                      fontSize: 10,
                      color:
                          _ytdlpUpdateAvailable ? Colors.orange : Colors.grey,
                    ),
                  ),
                ),
              ),
            ),
          IconButton(
            onPressed: () => launchUrl(
              Uri.parse('https://www.youtube.com'),
              mode: LaunchMode.externalApplication,
            ),
            icon: const Icon(Icons.open_in_new, color: Colors.red),
            tooltip: 'Open YouTube',
          ),
          // Switch to Prowlarr. Icon-only on narrow screens to leave
          // room for the title; labelled on wider screens for clarity.
          if (isNarrow)
            IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.swap_horiz, color: Color(0xFF00d4ff)),
              tooltip: 'Switch to Torrents',
            )
          else
            TextButton.icon(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.swap_horiz, color: Color(0xFF00d4ff)),
              label: const Text(
                'Torrents',
                style: TextStyle(color: Color(0xFF00d4ff)),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_ytdlpUpdateAvailable) _buildUpdateBanner(),
                  _buildAlbumSearch(),
                  const SizedBox(height: 12),
                  _buildUrlInput(),
                  const SizedBox(height: 16),
                  if (_downloadedTracks.isNotEmpty) ...[
                    _bulkTagMode ? _buildBulkTaggingForm() : _buildTaggingForm(),
                    // Show live download/import progress under the
                    // tagging form too — websocket updates fire during
                    // import (cover fetch, tag write, library scan) and
                    // the user wants to see them without scrolling
                    // somewhere else.
                    if (_isDownloading || _isImporting) _buildDownloadProgress(),
                  ] else ...[
                    if (_isLoadingInfo || _isLoadingPlaylist)
                      _buildLoadingCard()
                    else if (_videoInfo != null) ...[
                      _buildVideoCard(),
                      // Chapter-split panel extends the video card when the
                      // backend finds native chapters or a parseable
                      // description-timestamp tracklist. Renders nothing
                      // when chapter_source is 'none'.
                      _buildChapterSplitCard(),
                    ] else if (_playlistTracks != null)
                      _buildPlaylistCard(),
                    if (_isDownloading || _isImporting) _buildDownloadProgress(),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAlbumSearch() {
    final cyan = const Color(0xFF00d4ff);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _albumSearchController,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Find an album on YouTube (Artist Album)...',
            hintStyle: TextStyle(color: Colors.grey[600]),
            prefixIcon: const Icon(Icons.album, color: Colors.red),
            suffixIcon: _isSearchingAlbums
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    icon: const Icon(Icons.search, color: Colors.red),
                    onPressed: _searchAlbums,
                  ),
            filled: true,
            fillColor: const Color(0xFF1a2332),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Colors.red, width: 2),
            ),
          ),
          style: const TextStyle(color: Colors.white),
          onSubmitted: (_) => _searchAlbums(),
        ),
        if (_albumSearchError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_albumSearchError!,
                style: const TextStyle(color: Colors.red, fontSize: 12)),
          ),
        if (_albumResults != null) ...[
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1a2332),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                  child: Row(
                    children: [
                      Text(
                        _albumResults!.isEmpty
                            ? 'No playlists found'
                            : '${_albumResults!.length} playlists',
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => setState(() => _albumResults = null),
                        child: const Text('Hide'),
                      ),
                    ],
                  ),
                ),
                ..._albumResults!.take(8).map((r) {
                  final isTopic =
                      r['is_topic'] == true || r['is_topic_album'] == true;
                  final count = r['video_count'];
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      isTopic ? Icons.verified : Icons.playlist_play,
                      color: isTopic ? Colors.green : cyan,
                    ),
                    title: Text(
                      r['title'] as String? ?? '',
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${r['channel'] ?? ''}'
                      '${count != null ? ' · $count videos' : ''}'
                      '${isTopic ? ' · label playlist, no curation needed' : ''}',
                      style: TextStyle(color: Colors.grey[500], fontSize: 11),
                    ),
                    onTap: () => _pickAlbumResult(r),
                  );
                }),
                const SizedBox(height: 4),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// One line under the playlist header: who/what this is and how the
  /// curation went.
  Widget _buildCurationSummary() {
    final c = _curation;
    if (c == null) return const SizedBox.shrink();
    final mb = (c['musicbrainz'] as Map?) ?? const {};
    final sum = (c['summary'] as Map?) ?? const {};
    final artist = (c['artist'] as String?) ?? '';
    final album = (mb['album'] as String?) ?? (c['album'] as String?) ?? '';
    final year = mb['year'];
    final matched = mb['matched'] == true;
    final parts = <String>[];
    if ((sum['ok'] ?? 0) > 0) parts.add('${sum['ok']} ok');
    if ((sum['replaced'] ?? 0) > 0) parts.add('${sum['replaced']} replaced');
    final needPick = (sum['suspect'] ?? 0) - (sum['replaced'] ?? 0);
    if (needPick > 0) parts.add('$needPick need a pick');
    if ((sum['unverified'] ?? 0) > 0) parts.add('${sum['unverified']} unverified');
    final head = [
      if (artist.isNotEmpty) artist,
      if (album.isNotEmpty) album,
    ].join(' – ');
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (head.isNotEmpty)
            Text(
              '$head${year != null ? ' ($year)' : ''}',
              style: TextStyle(color: Colors.grey[300], fontSize: 12),
            ),
          Text(
            matched
                ? 'Checked against MusicBrainz (${mb['track_count']} tracks): ${parts.join(' · ')}'
                : 'No MusicBrainz match, titles only: ${parts.join(' · ')}',
            style: TextStyle(
                color: matched ? Colors.grey[500] : Colors.amber[200],
                fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _curationBadge(int index, Map<String, dynamic> track, bool isExcluded) {
    final verdict = track['verdict'] as String?;
    final swapped = _swappedIndices.contains(index);
    if (verdict == null) return const SizedBox.shrink();
    Color color;
    String label;
    if (swapped) {
      color = Colors.green;
      label = 'replaced';
    } else if (verdict == 'suspect') {
      color = Colors.amber;
      label = 'suspect';
    } else if (verdict == 'unverified') {
      color = Colors.grey;
      label = '?';
    } else {
      return const SizedBox.shrink();
    }
    return GestureDetector(
      onTap: () => _showAlternativesSheet(index),
      child: Tooltip(
        message: '${track['reason'] ?? ''}\nTap for alternatives',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: color.withOpacity(isExcluded ? 0.08 : 0.15),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: color.withOpacity(0.5)),
          ),
          child: Text(
            label,
            style: TextStyle(
                color: isExcluded ? color.withOpacity(0.5) : color,
                fontSize: 10,
                fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }

  Widget _buildUrlInput() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _urlController,
          decoration: InputDecoration(
            hintText: 'Paste YouTube URL...',
            hintStyle: TextStyle(color: Colors.grey[600]),
            prefixIcon: const Icon(Icons.link, color: Color(0xFF00d4ff)),
            suffixIcon: _isValidating
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    icon: const Icon(
                      Icons.check_circle,
                      color: Color(0xFF00d4ff),
                    ),
                    onPressed: _validateUrl,
                  ),
            filled: true,
            fillColor: const Color(0xFF1a2332),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFF00d4ff), width: 2),
            ),
          ),
          style: const TextStyle(color: Colors.white),
          onSubmitted: (_) => _validateUrl(),
        ),
        if (_urlInfo != null && _urlInfo!['valid'] != true)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _urlInfo!['error'] ?? 'Invalid URL',
              style: const TextStyle(color: Colors.red, fontSize: 12),
            ),
          ),
        if (_urlInfo != null && _urlInfo!['valid'] == true)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Icon(
                  _urlInfo!['type'] == 'playlist'
                      ? Icons.playlist_play
                      : Icons.play_circle,
                  color: Colors.green,
                  size: 16,
                ),
                const SizedBox(width: 4),
                // Flexible+ellipsis so the status text never bumps into
                // the right edge or the trailing IconButton on the
                // TextField when phones are narrow.
                Flexible(
                  child: Text(
                    _urlInfo!['type'] == 'playlist'
                        ? 'Playlist detected'
                        : 'Video detected',
                    style: const TextStyle(color: Colors.green, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildLoadingCard() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF1a2332),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Center(
        child: Column(
          children: [
            CircularProgressIndicator(color: Color(0xFF00d4ff)),
            SizedBox(height: 16),
            Text(
              _isLoadingPlaylist
                  ? 'Reading playlist, checking track lengths against '
                      'MusicBrainz, finding clean uploads for anything off. '
                      'Give it 20-40 seconds.'
                  : 'Loading info...',
              style: const TextStyle(color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1a2332),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Thumbnail
          if (_videoInfo!['thumbnail'] != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: Image.network(
                _videoInfo!['thumbnail'],
                width: double.infinity,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => Container(
                  height: 180,
                  color: Colors.grey[800],
                  child: const Icon(
                    Icons.music_note,
                    size: 64,
                    color: Colors.grey,
                  ),
                ),
              ),
              ),
            ),
          const SizedBox(height: 12),
          Text(
            _videoInfo!['title'] ?? 'Unknown',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _videoInfo!['channel'] ?? _videoInfo!['uploader'] ?? 'Unknown',
            style: const TextStyle(color: Color(0xFF00d4ff), fontSize: 14),
          ),
          const SizedBox(height: 4),
          Text(
            _formatDuration(_videoInfo!['duration']),
            style: TextStyle(color: Colors.grey[400], fontSize: 12),
          ),
          const SizedBox(height: 16),
          // Hide the single-track "Download Audio" button when chapter-split
          // mode is active — the chapter card below has its own "Import as
          // Album" button and showing both makes the two modes look like
          // complementary steps instead of mutually-exclusive choices.
          if (!_isInChapterSplitMode())
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isDownloading ? null : _downloadSingleVideo,
                icon: const Icon(Icons.download),
                label: const Text('Download Audio'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00d4ff),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// True when the chapter-split panel is going to render its own action
  /// button — the single-track "Download Audio" button is then redundant
  /// and hidden so the two modes can't be mistaken for sequential steps.
  bool _isInChapterSplitMode() {
    if (!_useChapterSplit) return false;
    if (_chapterPreview == null) return false;
    final source = (_chapterPreview!['chapter_source'] ?? 'none').toString();
    final chapters = _chapterPreview!['chapters'] as List?;
    return source != 'none' && chapters != null && chapters.length >= 2;
  }

  Widget _buildPlaylistCard() {
    final includedCount =
        _playlistTracks!.length - _excludedTrackIndices.length;
    final allExcluded = _excludedTrackIndices.length == _playlistTracks!.length;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1a2332),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.playlist_play,
                color: Color(0xFF00d4ff),
                size: 24,
              ),
              const SizedBox(width: 8),
              Text(
                '${_playlistTracks!.length} tracks',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              if (_excludedTrackIndices.isNotEmpty)
                Text(
                  '${_excludedTrackIndices.length} excluded',
                  style: const TextStyle(color: Colors.orange, fontSize: 12),
                ),
            ],
          ),
          const SizedBox(height: 4),
          // Select/deselect all
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Tap tracks to exclude them from download',
                style: TextStyle(color: Colors.grey[500], fontSize: 12),
              ),
              TextButton(
                onPressed: () {
                  setState(() {
                    if (_excludedTrackIndices.isEmpty) {
                      // Exclude all
                      _excludedTrackIndices = Set.from(
                        List.generate(_playlistTracks!.length, (i) => i),
                      );
                    } else {
                      // Include all
                      _excludedTrackIndices = {};
                    }
                  });
                },
                child: Text(
                  _excludedTrackIndices.isEmpty ? 'Deselect All' : 'Select All',
                  style: const TextStyle(
                    color: Color(0xFF00d4ff),
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Track list with checkboxes
          _buildCurationSummary(),
          Container(
            constraints: const BoxConstraints(maxHeight: 300),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _playlistTracks!.length,
              itemBuilder: (context, index) {
                final track = _playlistTracks![index];
                final isExcluded = _excludedTrackIndices.contains(index);
                return InkWell(
                  onTap: () {
                    setState(() {
                      if (isExcluded) {
                        _excludedTrackIndices.remove(index);
                      } else {
                        _excludedTrackIndices.add(index);
                      }
                    });
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Icon(
                          isExcluded
                              ? Icons.check_box_outline_blank
                              : Icons.check_box,
                          color: isExcluded
                              ? Colors.grey[600]
                              : const Color(0xFF00d4ff),
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${index + 1}.',
                          style: TextStyle(
                            color: isExcluded
                                ? Colors.grey[700]
                                : Colors.grey[500],
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            track['title'] ?? 'Unknown',
                            style: TextStyle(
                              color: isExcluded
                                  ? Colors.grey[700]
                                  : Colors.white,
                              fontSize: 13,
                              decoration: isExcluded
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        _curationBadge(index, track, isExcluded),
                        // Title heuristic only when the backend gave no
                        // verdict (curation unavailable).
                        if (track['verdict'] == null &&
                            _isSuspiciousTrack(track['title'] ?? ''))
                          Tooltip(
                            message: 'May be a music video or non-album content',
                            child: Icon(
                              Icons.warning_amber_rounded,
                              color: isExcluded ? Colors.grey[700] : Colors.amber,
                              size: 16,
                            ),
                          ),
                        const SizedBox(width: 6),
                        Text(
                          // Cast through num — yt-dlp returns float
                          // durations on authenticated calls and int
                          // on anonymous ones. A direct `as int?` cast
                          // throws on a double and silently kills this
                          // entire itemBuilder, leaving a sized-but-
                          // empty grey rectangle where the list should
                          // render. Backend coerces too; this is the
                          // belt to its suspenders.
                          _formatDuration((track['duration'] as num?)?.toInt()),
                          style: TextStyle(
                            color: isExcluded
                                ? Colors.grey[800]
                                : Colors.grey[500],
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isDownloading || allExcluded
                  ? null
                  : _downloadPlaylist,
              icon: const Icon(Icons.download),
              label: Text('Download $includedCount tracks'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00d4ff),
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadProgress() {
    return Container(
      key: _progressKey,
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1a2332),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: _downloadProgress / 100,
              backgroundColor: const Color(0xFF0d1b2a),
              valueColor: const AlwaysStoppedAnimation<Color>(
                Color(0xFF00d4ff),
              ),
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_downloadProgress < 100)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFF00d4ff),
                  ),
                ),
              if (_downloadProgress < 100) const SizedBox(width: 8),
              Flexible(
                child: Text(
                  _downloadStatus,
                  style: const TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
          if (_downloadProgress > 0 && _downloadProgress < 100)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '$_downloadProgress%',
                style: TextStyle(
                  color: Colors.grey[400],
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          if (_isDownloading)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: TextButton.icon(
                onPressed: _cancelDownload,
                icon: const Icon(Icons.cancel, color: Colors.red),
                label: const Text(
                  'Cancel Download',
                  style: TextStyle(color: Colors.red),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTaggingForm() {
    final track = _downloadedTracks[_currentTaggingIndex];
    final metadata = track['metadata'] as Map<String, dynamic>? ?? {};

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1a2332),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Form(
        key: _tagFormKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Progress indicator for multiple tracks
            if (_downloadedTracks.length > 1)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  children: [
                    Text(
                      'Tagging track ${_currentTaggingIndex + 1} of ${_downloadedTracks.length}',
                      style: const TextStyle(
                        color: Color(0xFF00d4ff),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: _prepareBulkTagging,
                      child: const Text('Bulk Mode'),
                    ),
                    TextButton(
                      onPressed: _skipTrack,
                      child: const Text('Skip'),
                    ),
                  ],
                ),
              ),

            // Original title for reference
            if (metadata['title'] != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'Original: ${metadata['title']}',
                  style: TextStyle(color: Colors.grey[500], fontSize: 12),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),

            // Title
            TextFormField(
              controller: _titleController,
              decoration: _inputDecoration('Title'),
              style: const TextStyle(color: Colors.white),
              validator: (v) => v?.isEmpty == true ? 'Required' : null,
            ),
            const SizedBox(height: 12),

            // Artist
            TextFormField(
              controller: _artistController,
              decoration: _inputDecoration('Artist'),
              style: const TextStyle(color: Colors.white),
              validator: (v) => v?.isEmpty == true ? 'Required' : null,
            ),
            const SizedBox(height: 12),

            // Album
            TextFormField(
              controller: _albumController,
              decoration: _inputDecoration('Album'),
              style: const TextStyle(color: Colors.white),
              validator: (v) => v?.isEmpty == true ? 'Required' : null,
            ),
            const SizedBox(height: 12),

            // Track Number and Year row
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _trackNumberController,
                    decoration: _inputDecoration('Track #'),
                    style: const TextStyle(color: Colors.white),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _yearController,
                    decoration: _inputDecoration('Year'),
                    style: const TextStyle(color: Colors.white),
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Action buttons row
            Row(
              children: [
                // MusicBrainz search button
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _showMusicBrainzSearch(),
                    icon: const Icon(Icons.search, size: 18),
                    label: const Text('MusicBrainz', style: TextStyle(fontSize: 13)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF00d4ff),
                      side: const BorderSide(color: Color(0xFF00d4ff)),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Import to existing album button
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      // Step 1: Pick an album from the library
                      final albumResult = await showDialog<Map<String, dynamic>>(
                        context: context,
                        builder: (context) => _AlbumPickerDialog(
                          apiService: _apiService,
                        ),
                      );
                      if (albumResult == null || !mounted) return;

                      final albumId = albumResult['id'] as int;
                      final artistName = albumResult['artist_name'] as String;
                      final albumTitle = albumResult['title'] as String;

                      // Step 2: Open MusicBrainz search pre-filled with album info
                      final trackResult = await showDialog<Map<String, dynamic>>(
                        context: context,
                        builder: (context) => _MusicBrainzSearchDialog(
                          apiService: _apiService,
                          initialArtist: artistName,
                          initialAlbum: albumTitle,
                          initialTitle: '',
                        ),
                      );

                      if (trackResult != null) {
                        setState(() {
                          _selectedAlbumId = albumId;
                          _selectedAlbumName = albumTitle;
                          _artistController.text = trackResult['artist'] ?? artistName;
                          _albumController.text = trackResult['album'] ?? albumTitle;
                          if (trackResult['year'] != null) {
                            _yearController.text = trackResult['year'].toString();
                          }
                          if (trackResult['title'] != null) {
                            _titleController.text = trackResult['title'] as String;
                          }
                          if (trackResult['track_number'] != null) {
                            _trackNumberController.text = trackResult['track_number'].toString();
                          }
                        });
                      } else {
                        // User cancelled MusicBrainz — still set album info
                        setState(() {
                          _selectedAlbumId = albumId;
                          _selectedAlbumName = albumTitle;
                          _artistController.text = artistName;
                          _albumController.text = albumTitle;
                          if (albumResult['year'] != null) {
                            _yearController.text = albumResult['year'].toString();
                          }
                        });
                      }
                    },
                    icon: const Icon(Icons.library_music, size: 18),
                    label: const Text('Existing Album', style: TextStyle(fontSize: 13)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.orange,
                      side: const BorderSide(color: Colors.orange),
                    ),
                  ),
                ),
              ],
            ),

            // Show selected album badge
            if (_selectedAlbumId != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.library_music, color: Colors.orange, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Importing to: $_selectedAlbumName',
                          style: const TextStyle(color: Colors.orange, fontSize: 12),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      InkWell(
                        onTap: () => setState(() {
                          _selectedAlbumId = null;
                          _selectedAlbumName = null;
                        }),
                        child: const Icon(Icons.close, color: Colors.orange, size: 16),
                      ),
                    ],
                  ),
                ),
              ),

            const SizedBox(height: 16),

            // Import button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isImporting ? null : _applyTagsAndImport,
                icon: _isImporting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check),
                label: Text(_isImporting
                    ? _downloadStatus
                    : _selectedAlbumId != null
                        ? 'Apply Tags & Import to Album'
                        : 'Apply Tags & Import'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBulkTaggingForm() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1a2332),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              const Icon(Icons.list, color: Color(0xFF00d4ff)),
              const SizedBox(width: 8),
              Text(
                'Bulk Tag ${_downloadedTracks.length} Tracks',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF00d4ff),
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () {
                  setState(() => _bulkTagMode = false);
                  _prepareTagging(0);
                },
                child: const Text('Switch to Individual'),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Common fields: Artist, Album, Year
          const Text(
            'Common Info (applies to all tracks)',
            style: TextStyle(fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _bulkArtistController,
            decoration: _inputDecoration('Artist'),
            style: const TextStyle(color: Colors.white),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _bulkAlbumController,
            decoration: _inputDecoration('Album'),
            style: const TextStyle(color: Colors.white),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: 120,
            child: TextFormField(
              controller: _bulkYearController,
              decoration: _inputDecoration('Year'),
              style: const TextStyle(color: Colors.white),
              keyboardType: TextInputType.number,
            ),
          ),
          const SizedBox(height: 16),

          // MusicBrainz lookup button for bulk mode
          OutlinedButton.icon(
            onPressed: _bulkMusicBrainzLookup,
            icon: const Icon(Icons.search, size: 18),
            label: const Text('Lookup on MusicBrainz'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF00d4ff),
              side: const BorderSide(color: Color(0xFF00d4ff)),
            ),
          ),
          const SizedBox(height: 16),

          // Track list
          const Text(
            'Track Titles & Numbers',
            style: TextStyle(fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 8),
          Container(
            constraints: const BoxConstraints(maxHeight: 300),
            decoration: BoxDecoration(
              color: const Color(0xFF0d1b2a),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _downloadedTracks.length,
              itemBuilder: (context, index) {
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      // Track number
                      SizedBox(
                        width: 50,
                        child: TextField(
                          controller: _bulkTrackNumControllers[index],
                          decoration: InputDecoration(
                            hintText: '#',
                            hintStyle: TextStyle(color: Colors.grey[600]),
                            filled: true,
                            fillColor: const Color(0xFF1a2332),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(4),
                              borderSide: BorderSide.none,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                          ),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
                          textAlign: TextAlign.center,
                          keyboardType: TextInputType.number,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Title
                      Expanded(
                        child: TextField(
                          controller: _bulkTitleControllers[index],
                          decoration: InputDecoration(
                            hintText: 'Track title',
                            hintStyle: TextStyle(color: Colors.grey[600]),
                            filled: true,
                            fillColor: const Color(0xFF1a2332),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(4),
                              borderSide: BorderSide.none,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                          ),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),

          // Import all button / progress
          if (_isImporting)
            Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: const LinearProgressIndicator(
                    backgroundColor: Color(0xFF0d1b2a),
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Color(0xFF00d4ff),
                    ),
                    minHeight: 8,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Color(0xFF00d4ff),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _downloadStatus,
                        style: const TextStyle(color: Colors.white),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ],
            )
          else
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isImporting ? null : _applyBulkTagsAndImport,
                icon: _isImporting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check_circle),
                label: Text(_isImporting
                    ? _downloadStatus
                    : 'Import All ${_downloadedTracks.length} Tracks'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(color: Colors.grey[400]),
      filled: true,
      fillColor: const Color(0xFF0d1b2a),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFF00d4ff)),
      ),
    );
  }

  Future<void> _showMusicBrainzSearch() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _MusicBrainzSearchDialog(
        apiService: _apiService,
        initialArtist: _artistController.text,
        initialAlbum: _albumController.text,
        initialTitle: _titleController.text,
      ),
    );

    if (result != null) {
      setState(() {
        if (result['title'] != null) _titleController.text = result['title'];
        if (result['artist'] != null) _artistController.text = result['artist'];
        if (result['album'] != null) _albumController.text = result['album'];
        if (result['year'] != null) {
          _yearController.text = result['year'].toString();
        }
        if (result['track_number'] != null) {
          _trackNumberController.text = result['track_number'].toString();
        }
      });
    }
  }

  String _formatDuration(int? seconds) {
    if (seconds == null) return '?:??';
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    if (minutes >= 60) {
      final hours = minutes ~/ 60;
      final mins = minutes % 60;
      return '$hours:${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    }
    return '$minutes:${secs.toString().padLeft(2, '0')}';
  }

  bool _isSuspiciousTrack(String title) {
    final lower = title.toLowerCase();
    final patterns = [
      'official video',
      'music video',
      'official music',
      'lyric video',
      'lyrics video',
      'live at',
      'live from',
      'live in',
      'concert',
      'performance',
      'behind the scenes',
      'making of',
      'interview',
      'reaction',
      'review',
      'karaoke',
      'instrumental',
      'visualizer',
      'video clip',
    ];
    return patterns.any((p) => lower.contains(p));
  }

}

// MusicBrainz Search Dialog
class _MusicBrainzSearchDialog extends StatefulWidget {
  final ApiService apiService;
  final String initialArtist;
  final String initialAlbum;
  final String initialTitle;
  final bool returnFullTrackList;

  const _MusicBrainzSearchDialog({
    required this.apiService,
    required this.initialArtist,
    required this.initialAlbum,
    required this.initialTitle,
    this.returnFullTrackList = false,
  });

  @override
  State<_MusicBrainzSearchDialog> createState() =>
      _MusicBrainzSearchDialogState();
}

class _MusicBrainzSearchDialogState extends State<_MusicBrainzSearchDialog> {
  final _artistController = TextEditingController();
  final _albumController = TextEditingController();

  List<Map<String, dynamic>> _results = [];
  bool _isSearching = false;
  String? _error;

  // For track selection after album selection
  Map<String, dynamic>? _selectedAlbum;
  List<Map<String, dynamic>>? _albumTracks;
  bool _isLoadingTracks = false;
  Set<int> _selectedTrackIndices = {};

  @override
  void initState() {
    super.initState();
    _artistController.text = widget.initialArtist;
    // Try to guess album from title if no album provided
    _albumController.text = widget.initialAlbum.isNotEmpty
        ? widget.initialAlbum
        : _guessAlbumFromTitle(widget.initialTitle);

    // Auto-search if we have data
    if (_artistController.text.isNotEmpty || _albumController.text.isNotEmpty) {
      _search();
    }
  }

  String _guessAlbumFromTitle(String title) {
    // Often YouTube titles are "Artist - Song" or "Song - Artist"
    // This is a simple heuristic - user can edit
    return '';
  }

  @override
  void dispose() {
    _artistController.dispose();
    _albumController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (_artistController.text.isEmpty && _albumController.text.isEmpty) return;

    setState(() {
      _isSearching = true;
      _error = null;
      _results = [];
      _selectedAlbum = null;
      _albumTracks = null;
    });

    try {
      final result = await widget.apiService.searchMusicBrainz(
        _artistController.text,
        _albumController.text,
      );

      setState(() {
        _results = List<Map<String, dynamic>>.from(result['results'] ?? []);
        _isSearching = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isSearching = false;
      });
    }
  }

  Future<void> _selectAlbum(Map<String, dynamic> album) async {
    setState(() {
      _selectedAlbum = album;
      _isLoadingTracks = true;
      _albumTracks = null;
    });

    try {
      // Get tracks from MusicBrainz
      final result = await widget.apiService.getMusicBrainzTracks(
        album['mbid'],
      );

      setState(() {
        _albumTracks = List<Map<String, dynamic>>.from(result['tracks'] ?? []);
        _isLoadingTracks = false;
      });
    } catch (e) {
      setState(() {
        _isLoadingTracks = false;
        // If no tracks found, allow using just album info
        _albumTracks = [];
      });
    }
  }

  void _selectTrack(Map<String, dynamic> track) {
    // Use the track's own MusicBrainz credit (e.g. "Drake feat. Rihanna")
    // when present so featured artists carry into the artist field; the
    // import pipeline splits it into the song_artists junction. Fall back to
    // the album artist for tracks MB didn't credit individually.
    final trackArtist = track['artist'] as String?;
    final result = <String, dynamic>{
      'title': track['title'],
      'artist': (trackArtist != null && trackArtist.isNotEmpty)
          ? trackArtist
          : _selectedAlbum!['artist'],
      'album': _selectedAlbum!['title'],
      'year': _selectedAlbum!['year'],
      'track_number': track['position'] ?? track['number'],
    };
    Navigator.pop(context, result);
  }

  /// Apply selected tracks only (multi-select mode)
  void _applySelectedTracks() {
    if (_albumTracks == null || _selectedTrackIndices.isEmpty) return;
    final result = <String, dynamic>{
      'artist': _selectedAlbum!['artist'],
      'album': _selectedAlbum!['title'],
      'year': _selectedAlbum!['year'],
      'tracks': [for (final i in _selectedTrackIndices.toList()..sort()) _albumTracks![i]],
    };
    Navigator.pop(context, result);
  }

  /// Apply all tracks
  void _applyAllTracks() {
    final result = <String, dynamic>{
      'artist': _selectedAlbum!['artist'],
      'album': _selectedAlbum!['title'],
      'year': _selectedAlbum!['year'],
      'tracks': _albumTracks,
    };
    Navigator.pop(context, result);
  }

  void _useAlbumOnly() {
    final result = <String, dynamic>{
      'artist': _selectedAlbum!['artist'],
      'album': _selectedAlbum!['title'],
      'year': _selectedAlbum!['year'],
    };
    // Explicitly NO tracks — album metadata only
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1a2332),
      child: Container(
        width: 500,
        constraints: const BoxConstraints(maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                color: Color(0xFF0d1b2a),
                borderRadius: BorderRadius.vertical(top: Radius.circular(4)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.album, color: Color(0xFF00d4ff)),
                  const SizedBox(width: 8),
                  Text(
                    _selectedAlbum != null
                        ? 'Select Track'
                        : 'Search MusicBrainz',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  if (_selectedAlbum != null)
                    IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => setState(() {
                        _selectedAlbum = null;
                        _albumTracks = null;
                        _selectedTrackIndices = {};
                      }),
                      tooltip: 'Back to results',
                    ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),

            // Content
            Flexible(
              child: _selectedAlbum != null
                  ? _buildTrackSelection()
                  : _buildAlbumSearch(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlbumSearch() {
    return Column(
      children: [
        // Search fields
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _artistController,
                  decoration: InputDecoration(
                    labelText: 'Artist',
                    labelStyle: TextStyle(color: Colors.grey[400]),
                    filled: true,
                    fillColor: const Color(0xFF0d1b2a),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _albumController,
                  decoration: InputDecoration(
                    labelText: 'Album',
                    labelStyle: TextStyle(color: Colors.grey[400]),
                    filled: true,
                    fillColor: const Color(0xFF0d1b2a),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  onSubmitted: (_) => _search(),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _isSearching ? null : _search,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00d4ff),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
                child: _isSearching
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black,
                        ),
                      )
                    : const Text('Search'),
              ),
            ],
          ),
        ),

        // Results
        Expanded(child: _buildResultsList()),
      ],
    );
  }

  Widget _buildResultsList() {
    if (_isSearching) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Text(
          'Error: $_error',
          style: const TextStyle(color: Colors.red),
        ),
      );
    }

    if (_results.isEmpty) {
      return Center(
        child: Text(
          'No results found',
          style: TextStyle(color: Colors.grey[500]),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final album = _results[index];
        return _buildAlbumCard(album);
      },
    );
  }

  Widget _buildAlbumCard(Map<String, dynamic> album) {
    return Card(
      color: const Color(0xFF0d1b2a),
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => _selectAlbum(album),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // Cover art
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.network(
                  album['cover_url'] ?? '',
                  width: 50,
                  height: 50,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    width: 50,
                    height: 50,
                    color: Colors.grey[800],
                    child: const Icon(Icons.album, color: Colors.grey),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      album['title'] ?? 'Unknown',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      album['artist'] ?? 'Unknown',
                      style: TextStyle(color: Colors.grey[400], fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              // Type badge and year
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (album['type'] != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: _getTypeBadgeColor(
                          album['type'],
                        ).withOpacity(0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        album['type'],
                        style: TextStyle(
                          color: _getTypeBadgeColor(album['type']),
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  if (album['year'] != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        album['year'],
                        style: TextStyle(color: Colors.grey[500], fontSize: 12),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }

  Color _getTypeBadgeColor(String type) {
    switch (type) {
      case 'Album':
        return const Color(0xFF00d4ff);
      case 'EP':
        return Colors.purple;
      case 'Single':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  Widget _buildTrackSelection() {
    final isBulkMode = widget.returnFullTrackList;
    final hasSelectedTracks = _selectedTrackIndices.isNotEmpty;

    return Column(
      children: [
        // Selected album header
        Container(
          padding: const EdgeInsets.all(16),
          color: const Color(0xFF0d1b2a).withOpacity(0.5),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.network(
                  _selectedAlbum!['cover_url'] ?? '',
                  width: 60,
                  height: 60,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    width: 60,
                    height: 60,
                    color: Colors.grey[800],
                    child: const Icon(Icons.album, color: Colors.grey),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _selectedAlbum!['title'] ?? 'Unknown',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      _selectedAlbum!['artist'] ?? 'Unknown',
                      style: const TextStyle(
                        color: Color(0xFF00d4ff),
                        fontSize: 14,
                      ),
                    ),
                    if (_selectedAlbum!['year'] != null)
                      Text(
                        _selectedAlbum!['year'],
                        style: TextStyle(color: Colors.grey[500], fontSize: 12),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // Action buttons
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Column(
            children: [
              // "Album info only" — always available, always means just metadata
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _useAlbumOnly,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF00d4ff),
                    side: const BorderSide(color: Color(0xFF00d4ff)),
                  ),
                  child: const Text('Album Info Only (No Track Data)'),
                ),
              ),
              if (isBulkMode && _albumTracks != null && _albumTracks!.isNotEmpty) ...[
                const SizedBox(height: 4),
                // "Apply all tracks"
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _applyAllTracks,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00d4ff),
                      foregroundColor: const Color(0xFF0d1b2a),
                    ),
                    child: Text('Apply All ${_albumTracks!.length} Tracks'),
                  ),
                ),
              ],
            ],
          ),
        ),

        const Divider(height: 1),

        // Bulk mode: select/deselect helpers
        if (isBulkMode && _albumTracks != null && _albumTracks!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Text(
                  hasSelectedTracks
                      ? '${_selectedTrackIndices.length} selected'
                      : 'Tap to select tracks',
                  style: TextStyle(color: Colors.grey[500], fontSize: 12),
                ),
                const Spacer(),
                if (hasSelectedTracks)
                  TextButton(
                    onPressed: () => setState(() => _selectedTrackIndices = {}),
                    child: const Text(
                      'Clear',
                      style: TextStyle(color: Color(0xFF00d4ff), fontSize: 12),
                    ),
                  ),
                TextButton(
                  onPressed: () => setState(() {
                    _selectedTrackIndices = Set.from(
                      List.generate(_albumTracks!.length, (i) => i),
                    );
                  }),
                  child: const Text(
                    'Select All',
                    style: TextStyle(color: Color(0xFF00d4ff), fontSize: 12),
                  ),
                ),
              ],
            ),
          ),

        // Track list
        Expanded(
          child: _isLoadingTracks
              ? const Center(child: CircularProgressIndicator())
              : _albumTracks == null || _albumTracks!.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'No tracks found',
                        style: TextStyle(color: Colors.grey[500]),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Use "Album Info Only" above',
                        style: TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _albumTracks!.length,
                  itemBuilder: (context, index) {
                    final track = _albumTracks![index];
                    final isSelected = _selectedTrackIndices.contains(index);
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: const Color(0xFF0d1b2a),
                        radius: 16,
                        child: Text(
                          '${track['position'] ?? track['number'] ?? index + 1}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      title: Text(
                        track['title'] ?? 'Unknown',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: track['duration'] != null
                          ? Text(
                              _formatDuration(track['duration']),
                              style: TextStyle(
                                color: Colors.grey[500],
                                fontSize: 12,
                              ),
                            )
                          : null,
                      trailing: isBulkMode
                          ? Icon(
                              isSelected
                                  ? Icons.check_circle
                                  : Icons.check_circle_outline,
                              color: isSelected
                                  ? const Color(0xFF00d4ff)
                                  : Colors.grey[600],
                            )
                          : const Icon(
                              Icons.check_circle_outline,
                              color: Color(0xFF00d4ff),
                            ),
                      onTap: isBulkMode
                          ? () {
                              setState(() {
                                if (isSelected) {
                                  _selectedTrackIndices.remove(index);
                                } else {
                                  _selectedTrackIndices.add(index);
                                }
                              });
                            }
                          : () => _selectTrack(track),
                    );
                  },
                ),
        ),

        // "Apply selected" button at the bottom (bulk mode only, when tracks are selected)
        if (isBulkMode && hasSelectedTracks)
          Padding(
            padding: const EdgeInsets.all(8),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _applySelectedTracks,
                icon: const Icon(Icons.check),
                label: Text('Apply ${_selectedTrackIndices.length} Selected Tracks'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00d4ff),
                  foregroundColor: const Color(0xFF0d1b2a),
                ),
              ),
            ),
          ),
      ],
    );
  }

  String _formatDuration(int? milliseconds) {
    if (milliseconds == null) return '';
    final seconds = milliseconds ~/ 1000;
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    return '$minutes:${secs.toString().padLeft(2, '0')}';
  }
}

/// Dialog for picking an existing album from the library
class _AlbumPickerDialog extends StatefulWidget {
  final ApiService apiService;

  const _AlbumPickerDialog({required this.apiService});

  @override
  State<_AlbumPickerDialog> createState() => _AlbumPickerDialogState();
}

class _AlbumPickerDialogState extends State<_AlbumPickerDialog> {
  final _searchController = TextEditingController();
  Timer? _debounce;
  List<Album> _results = [];
  bool _isSearching = false;
  String? _error;

  @override
  void dispose() {
    _searchController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (query.trim().length >= 2) {
        _search(query.trim());
      } else {
        setState(() => _results = []);
      }
    });
  }

  Future<void> _search(String query) async {
    setState(() {
      _isSearching = true;
      _error = null;
    });
    try {
      final results = await widget.apiService.searchAlbums(query);
      if (mounted) {
        setState(() {
          _results = results;
          _isSearching = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Search failed: $e';
          _isSearching = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF0a0e27),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: double.maxFinite,
        constraints: const BoxConstraints(maxHeight: 500, maxWidth: 400),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                const Icon(Icons.library_music, color: Colors.orange),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Import to Existing Album',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.grey),
                  onPressed: () => Navigator.pop(context),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Search field
            TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Search albums...',
                hintStyle: TextStyle(color: Colors.grey[600]),
                prefixIcon: const Icon(Icons.search, color: Colors.grey),
                suffixIcon: _isSearching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFF00d4ff),
                          ),
                        ),
                      )
                    : null,
                filled: true,
                fillColor: const Color(0xFF1a2332),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
            ),
            const SizedBox(height: 12),

            // Error
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
              ),

            // Results
            Flexible(
              child: _results.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _searchController.text.length < 2
                              ? 'Type at least 2 characters to search'
                              : _isSearching
                                  ? 'Searching...'
                                  : 'No albums found',
                          style: TextStyle(color: Colors.grey[600], fontSize: 14),
                        ),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _results.length,
                      itemBuilder: (context, index) {
                        final album = _results[index];
                        return InkWell(
                          onTap: () {
                            Navigator.pop(context, {
                              'id': album.id,
                              'title': album.title,
                              'artist_name': album.artistName,
                              'year': album.year,
                            });
                          },
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                            child: Row(
                              children: [
                                // Album artwork thumbnail
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: Image.network(
                                    '${ApiService.baseUrl}/artwork/${album.id}',
                                    width: 44,
                                    height: 44,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => Container(
                                      width: 44,
                                      height: 44,
                                      color: const Color(0xFF1a2332),
                                      child: const Icon(Icons.album, color: Colors.grey, size: 24),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                // Album info
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        album.title,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 14,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${album.artistName}${album.year != null ? ' • ${album.year}' : ''} • ${album.songCount} tracks',
                                        style: TextStyle(
                                          color: Colors.grey[400],
                                          fontSize: 12,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                const Icon(
                                  Icons.arrow_forward_ios,
                                  color: Colors.grey,
                                  size: 14,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dialog for picking a specific track from an album's tracklist
class _TrackPickerDialog extends StatelessWidget {
  final Map<String, dynamic> albumData;
  final ApiService apiService;

  const _TrackPickerDialog({
    required this.albumData,
    required this.apiService,
  });

  String _formatDuration(dynamic duration) {
    if (duration == null) return '';
    final seconds = (duration is double) ? duration.toInt() : duration as int;
    final minutes = seconds ~/ 60;
    final secs = seconds % 60;
    return '$minutes:${secs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final songs = (albumData['songs'] as List?) ?? [];
    final albumTitle = albumData['title'] ?? 'Unknown Album';
    final artistName = albumData['artist_name'] ?? 'Unknown Artist';
    final year = albumData['year'];
    final albumId = albumData['id'];

    return AlertDialog(
      backgroundColor: const Color(0xFF0d1b2a),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Select Track', style: TextStyle(fontSize: 18)),
          const SizedBox(height: 4),
          Text(
            '$artistName — $albumTitle${year != null ? ' ($year)' : ''}',
            style: const TextStyle(
              fontSize: 13,
              color: Colors.grey,
              fontWeight: FontWeight.normal,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 450,
        height: MediaQuery.of(context).size.height * 0.5,
        child: Column(
          children: [
            // Skip button — just use album info
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pop(<String, dynamic>{
                  'skipped': true,
                  'artist': artistName,
                  'album': albumTitle,
                  'year': year,
                  'album_id': albumId,
                }),
                icon: const Icon(Icons.skip_next, size: 18),
                label: const Text('Skip — Just Use Album Info'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.grey,
                  side: const BorderSide(color: Colors.grey),
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Divider(color: Colors.grey),
            const SizedBox(height: 8),
            // Track list
            Expanded(
              child: songs.isEmpty
                  ? const Center(
                      child: Text(
                        'No tracks found in this album',
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      itemCount: songs.length,
                      itemBuilder: (context, index) {
                        final song = songs[index];
                        final trackNum = song['track_number'] ?? (index + 1);
                        final title = song['title'] ?? 'Unknown';
                        final duration = song['duration'];

                        return ListTile(
                          leading: SizedBox(
                            width: 28,
                            child: Text(
                              '$trackNum',
                              style: const TextStyle(
                                color: Colors.grey,
                                fontSize: 14,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                          title: Text(
                            title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                          ),
                          trailing: duration != null
                              ? Text(
                                  _formatDuration(duration),
                                  style: const TextStyle(
                                    color: Colors.grey,
                                    fontSize: 12,
                                  ),
                                )
                              : null,
                          dense: true,
                          onTap: () => Navigator.of(context).pop(<String, dynamic>{
                            'title': title,
                            'artist': artistName,
                            'album': albumTitle,
                            'year': year,
                            'track_number': trackNum,
                            'album_id': albumId,
                          }),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          hoverColor: const Color(0xFF00d4ff).withOpacity(0.1),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
