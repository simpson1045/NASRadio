import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../services/app_logger.dart';
import '../services/audio_player_service.dart';
import '../services/song_recognition_service.dart';
import '../widgets/song_recognition_sheet.dart';
import 'album_detail_screen.dart';
import 'youtube_download_screen.dart';

class ProwlarrSearchScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;
  final String? initialQuery;

  const ProwlarrSearchScreen({
    super.key,
    required this.audioPlayerService,
    this.initialQuery,
  });

  @override
  State<ProwlarrSearchScreen> createState() => _ProwlarrSearchScreenState();
}

class _ProwlarrSearchScreenState extends State<ProwlarrSearchScreen> {
  final ApiService _apiService = ApiService();
  final SongRecognitionService _recognitionService = SongRecognitionService();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  List<Map<String, dynamic>> _results = [];
  bool _isLoading = false;
  bool _hasSearched = false;
  String? _error;
  final Set<String> _downloadingGuids = {};
  // Results whose trackers we've scraped directly (see _downloadTorrent).
  // Once a guid is in here its badge shows the real count, not the
  // indexer's stale claim.
  final Set<String> _probingGuids = {};
  final Map<String, Map<String, dynamic>> _verifiedSwarm = {};
  Map<String, Map<String, dynamic>> _libraryMatches = {};
  Set<String> _inTransmission = {};

  // Deep search (RuTracker etc.)
  bool _isDeepSearching = false;
  bool _deepSearchDone = false;
  int _deepResultsAdded = 0;
  // Number of Knaben-via-RuTracker results the backend hid from the
  // default search. Surfaced in the "Also search RuTracker" banner.
  int _rutrackerFilteredCount = 0;

  List<String> _searchHistory = [];
  bool _showHistory = false;
  static const int _maxHistoryItems = 20;

  // Quality filters — applied client-side over the backend's per-result
  // fingerprint (audio_format / is_lossless / bit_depth / audio_layout),
  // so toggling is instant with no re-search. Persisted across sessions.
  bool _fLossless = false; // only titled-lossless (FLAC/DSD/TrueHD/DTS-HD MA...)
  bool _fHiRes = false; // 24-bit+ (DSD's 1-bit counts as hi-res)
  bool _fSurround = false; // multichannel-titled releases only
  bool _fNoLossy = false; // hide MP3/AAC/OGG even when other filters are off

  List<Map<String, dynamic>> get _visibleResults {
    return _results.where((r) {
      final lossless = r['is_lossless'];
      final bits = r['bit_depth'] as int?;
      final layout = r['audio_layout'] as String?;
      final fmt = r['audio_format'] as String?;
      if (_fLossless && lossless != true) return false;
      if (_fHiRes && !(bits != null && (bits >= 24 || bits == 1))) return false;
      if (_fSurround && layout != 'surround') return false;
      if (_fNoLossy && (fmt == 'MP3' || fmt == 'AAC' || fmt == 'OGG')) {
        return false;
      }
      return true;
    }).toList();
  }

  int get _hiddenByFilters => _results.length - _visibleResults.length;

  bool get _anyFilterActive => _fLossless || _fHiRes || _fSurround || _fNoLossy;

  Future<void> _loadFilters() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _fLossless = prefs.getBool('search_f_lossless') ?? false;
      _fHiRes = prefs.getBool('search_f_hires') ?? false;
      _fSurround = prefs.getBool('search_f_surround') ?? false;
      _fNoLossy = prefs.getBool('search_f_nolossy') ?? false;
    });
  }

  Future<void> _saveFilters() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('search_f_lossless', _fLossless);
    await prefs.setBool('search_f_hires', _fHiRes);
    await prefs.setBool('search_f_surround', _fSurround);
    await prefs.setBool('search_f_nolossy', _fNoLossy);
  }

  @override
  void initState() {
    super.initState();
    _loadSearchHistory();
    _loadFilters();
    _searchFocusNode.addListener(_onFocusChange);
    if (widget.initialQuery != null) {
      _searchController.text = widget.initialQuery!;
      _performSearch();
    }
  }

  void _onFocusChange() {
    if (_searchFocusNode.hasFocus &&
        _searchController.text.isEmpty &&
        _searchHistory.isNotEmpty) {
      setState(() => _showHistory = true);
    }
    // Don't hide on blur - let TapRegion handle that
  }

  Future<void> _loadSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _searchHistory = prefs.getStringList('prowlarr_search_history') ?? [];
    });
  }

  Future<void> _saveSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('prowlarr_search_history', _searchHistory);
  }

  void _addToHistory(String query) {
    if (query.isEmpty) return;
    setState(() {
      _searchHistory.remove(query); // Remove if exists (to move to top)
      _searchHistory.insert(0, query);
      if (_searchHistory.length > _maxHistoryItems) {
        _searchHistory = _searchHistory.sublist(0, _maxHistoryItems);
      }
    });
    _saveSearchHistory();
  }

  void _clearHistory() async {
    setState(() {
      _searchHistory.clear();
      _showHistory = false;
    });
    _saveSearchHistory();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.removeListener(_onFocusChange);
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _performSearch([String? queryOverride]) async {
    final query = queryOverride ?? _searchController.text.trim();
    if (query.isEmpty) return;

    _addToHistory(query);

    setState(() {
      _isLoading = true;
      _showHistory = false;
      _error = null;
      _hasSearched = true;
      _libraryMatches = {};
      _inTransmission = {};
      _isDeepSearching = false;
      _deepSearchDone = false;
      _deepResultsAdded = 0;
      _rutrackerFilteredCount = 0;
    });

    try {
      final result = await _apiService.searchProwlarr(query);
      final results = List<Map<String, dynamic>>.from(result['results'] ?? []);

      // Widget can be disposed during the await (user navigates away
      // mid-search). setState on a disposed State throws "Null check
      // operator used on a null value" — caught a 2026-05-20 crash.
      if (!mounted) return;
      setState(() {
        _results = results;
        _rutrackerFilteredCount =
            (result['rutracker_filtered_count'] as int?) ?? 0;
      });

      // Check library and Transmission in parallel
      await Future.wait([
        _checkLibraryMatches(results),
        _checkTransmissionMatches(results),
      ]);

      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _performDeepSearch() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;

    setState(() {
      _isDeepSearching = true;
    });

    try {
      final result = await _apiService.searchProwlarr(query, deepOnly: true);
      final deepResults = List<Map<String, dynamic>>.from(result['results'] ?? []);

      // Merge: add only results whose guid isn't already in _results
      final existingGuids = _results.map((r) => r['guid']).toSet();
      final newResults = deepResults.where((r) => !existingGuids.contains(r['guid'])).toList();

      setState(() {
        _results.addAll(newResults);
        // Re-sort by seeders
        _results.sort((a, b) => (b['seeders'] as int? ?? 0).compareTo(a['seeders'] as int? ?? 0));
        _deepResultsAdded = newResults.length;
        _isDeepSearching = false;
        _deepSearchDone = true;
      });

      // Check library/transmission matches for new results
      if (newResults.isNotEmpty) {
        await Future.wait([
          _checkLibraryMatches(newResults),
          _checkTransmissionMatches(newResults),
        ]);
      }
    } catch (e) {
      setState(() {
        _isDeepSearching = false;
        _deepSearchDone = true;
        _deepResultsAdded = 0;
      });
    }
  }

  Future<void> _checkLibraryMatches(List<Map<String, dynamic>> results) async {
    if (results.isEmpty) return;

    try {
      final titles = results.map((r) => r['title'] as String).toList();
      final response = await _apiService.checkLibraryExists(titles);

      if (response['success'] == true) {
        setState(() {
          _libraryMatches = Map<String, Map<String, dynamic>>.from(
            (response['results'] as Map).map(
              (k, v) => MapEntry(k.toString(), Map<String, dynamic>.from(v)),
            ),
          );
        });
      }
    } catch (e, stack) {
      // Non-fatal — the rest of the search still works, we just
      // don't show "in library" chips. Log it so if the backend
      // endpoint breaks again it actually surfaces somewhere
      // (this fell silent for four months before v1.0.14 because
      // the catch was a plain swallow).
      AppLogger.instance.error('Prowlarr library-match check failed: $e');
      AppLogger.instance.error(stack.toString());
    }
  }

  Future<void> _checkTransmissionMatches(
    List<Map<String, dynamic>> results,
  ) async {
    if (results.isEmpty) return;

    try {
      final response = await _apiService.getTransmissionTorrents();

      if (response['success'] == true) {
        final torrents = List<Map<String, dynamic>>.from(
          response['torrents'] ?? [],
        );
        final torrentNames = torrents
            .map((t) => (t['name'] as String).toLowerCase())
            .toSet();

        final matches = <String>{};
        for (final result in results) {
          final title = (result['title'] as String).toLowerCase();
          // Check if any torrent name is similar (contains key parts)
          for (final torrentName in torrentNames) {
            if (_titlesMatch(title, torrentName)) {
              matches.add(result['title'] as String);
              break;
            }
          }
        }

        setState(() {
          _inTransmission = matches;
        });
      }
    } catch (e) {
      // Silently fail - not critical
    }
  }

  bool _titlesMatch(String title1, String title2) {
    // Simple matching - check if they share significant words
    final words1 = title1
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .split(' ')
        .where((w) => w.length > 3)
        .take(5)
        .toSet();
    final words2 = title2
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .split(' ')
        .where((w) => w.length > 3)
        .take(5)
        .toSet();
    final overlap = words1.intersection(words2).length;
    return overlap >= 3; // At least 3 significant words match
  }

  Future<void> _downloadTorrent(Map<String, dynamic> result) async {
    final guid = result['guid'] as String;
    final downloadUrl = result['download_url'] as String?;

    if (downloadUrl == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No download URL available'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Ask the trackers before trusting the indexer. A "5 seed" result can
    // have nobody home (Krokus, 2026-09-11: 1337x said 5, trackers said 1,
    // Transmission connected to 0). If the swarm looks dead, confirm first.
    Map<String, dynamic>? probe;
    setState(() => _probingGuids.add(guid));
    try {
      probe = await _apiService.probeTorrent(downloadUrl);
    } catch (_) {
      probe = null; // a broken probe must never block a download
    } finally {
      if (mounted) setState(() => _probingGuids.remove(guid));
    }
    if (!mounted) return;
    final verified = probe;
    if (verified != null && verified['success'] == true) {
      setState(() => _verifiedSwarm[guid] = verified);
      if (verified['verdict'] != 'alive') {
        final proceed = await _confirmDeadSwarm(verified);
        if (proceed != true || !mounted) return;
      }
    }

    setState(() {
      _downloadingGuids.add(guid);
    });

    try {
      final response = await _apiService.addTorrent(downloadUrl);

      if (response['success'] == true) {
        final torrentName = response['torrent_name'] ?? 'Torrent';
        final isDuplicate = response['duplicate'] == true;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isDuplicate
                  ? '$torrentName already in Transmission'
                  : '$torrentName added to Transmission',
            ),
            backgroundColor: isDuplicate ? Colors.orange : Colors.green,
          ),
        );
      } else {
        throw Exception(response['error'] ?? 'Unknown error');
      }
    } catch (e) {
      // The backend now translates HTTP errors into actionable
      // sentences, so just strip the "Exception: " wrapper and the
      // "Failed to add torrent: " prefix Dart adds for us. The
      // user sees a plain-English description of what went wrong
      // instead of a giant URL and a status code.
      String message = e.toString();
      for (final prefix in const [
        'Exception: ',
        'Failed to add torrent: ',
      ]) {
        while (message.startsWith(prefix)) {
          message = message.substring(prefix.length);
        }
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            message,
            // Error details are often 1–2 sentences; let them wrap
            // instead of clipping.
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
          backgroundColor: Colors.red.shade800,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 8),
          action: SnackBarAction(
            label: 'DISMISS',
            textColor: Colors.white,
            onPressed: () {
              ScaffoldMessenger.of(context).hideCurrentSnackBar();
            },
          ),
        ),
      );
    } finally {
      setState(() {
        _downloadingGuids.remove(guid);
      });
    }
  }

  Future<bool?> _confirmDeadSwarm(Map<String, dynamic> probe) {
    final answered = probe['trackers_answered'] as int? ?? 0;
    final total = probe['trackers_total'] as int? ?? 0;
    final leechers = probe['leechers'] as int? ?? 0;
    final unknown = probe['verdict'] == 'unknown';
    final body = unknown
        ? 'None of $total trackers responded, so there is no way to tell '
            'whether anyone is seeding. It might still find peers over DHT, '
            'or it might sit at 0% forever.'
        : '$answered of $total trackers answered and none of them report a '
            'seeder${leechers > 0 ? ' ($leechers other people are waiting on it too)' : ''}. '
            'This will almost certainly sit at 0% forever.';
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: Text(
          unknown ? 'No trackers answered' : 'No seeders found',
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(body, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Add anyway'),
          ),
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes == 0) return 'Unknown';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    int unitIndex = 0;
    double size = bytes.toDouble();

    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }

    return '${size.toStringAsFixed(1)} ${units[unitIndex]}';
  }

  Widget _fingerprintBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color, width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _filterChip(String label, bool selected, ValueChanged<bool> onChanged) {
    const cyan = Color(0xFF00d4ff);
    return FilterChip(
      label: Text(label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.black : cyan,
          )),
      selected: selected,
      onSelected: (v) {
        onChanged(v);
        _saveFilters();
      },
      selectedColor: cyan,
      checkmarkColor: Colors.black,
      backgroundColor: const Color(0xFF1a2332),
      side: BorderSide(color: cyan.withOpacity(selected ? 1 : 0.35)),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
    );
  }

  Color _getSeedersColor(int seeders) {
    if (seeders >= 20) return Colors.green;
    if (seeders >= 5) return Colors.orange;
    if (seeders > 0) return Colors.red;
    return Colors.grey;
  }

  Map<String, dynamic>? _detectFormat(String title) {
    final titleUpper = title.toUpperCase();

    // Check for lossless formats first (higher priority)
    if (titleUpper.contains('DSD')) {
      // Extract DSD rate if present (DSD64, DSD128, DSD256, etc.)
      final dsdMatch = RegExp(r'DSD\s*(\d+)').firstMatch(titleUpper);
      final rate = dsdMatch?.group(1);
      return {
        'format': rate != null ? 'DSD$rate' : 'DSD',
        'color': const Color(0xFFFFD700), // Gold
        'isLossless': true,
      };
    }

    if (titleUpper.contains('FLAC') || titleUpper.contains('LOSSLESS')) {
      // Check for hi-res indicators
      String format = 'FLAC';
      if (RegExp(r'24[\s/-]?(96|192|88|176|48)').hasMatch(titleUpper) ||
          titleUpper.contains('24BIT') ||
          titleUpper.contains('24-BIT') ||
          titleUpper.contains('HI-RES') ||
          titleUpper.contains('HIRES')) {
        format = 'FLAC HR';
      }
      return {
        'format': format,
        'color': const Color(0xFF00d4ff), // Cyan
        'isLossless': true,
      };
    }

    if (titleUpper.contains('ALAC')) {
      return {
        'format': 'ALAC',
        'color': const Color(0xFF03A9F4), // Light blue
        'isLossless': true,
      };
    }

    if (titleUpper.contains('WAV')) {
      return {'format': 'WAV', 'color': Colors.blue, 'isLossless': true};
    }

    if (titleUpper.contains('WAVPACK') || titleUpper.contains('.WV')) {
      return {
        'format': 'WV',
        'color': const Color(0xFF9C27B0), // Purple
        'isLossless': true,
      };
    }

    if (titleUpper.contains('APE') || titleUpper.contains('MONKEY')) {
      return {
        'format': 'APE',
        'color': const Color(0xFF8BC34A), // Light green
        'isLossless': true,
      };
    }

    if (titleUpper.contains('AIFF')) {
      return {
        'format': 'AIFF',
        'color': const Color(0xFF03A9F4), // Light blue
        'isLossless': true,
      };
    }

    // Lossy formats
    if (titleUpper.contains('MP3')) {
      String format = 'MP3';
      if (titleUpper.contains('320')) {
        format = 'MP3 320';
      } else if (titleUpper.contains('256')) {
        format = 'MP3 256';
      } else if (titleUpper.contains('V0')) {
        format = 'MP3 V0';
      }
      return {'format': format, 'color': Colors.orange, 'isLossless': false};
    }

    if (titleUpper.contains('AAC') || titleUpper.contains('M4A')) {
      return {'format': 'AAC', 'color': Colors.purple, 'isLossless': false};
    }

    if (titleUpper.contains('OGG')) {
      return {'format': 'OGG', 'color': Colors.green, 'isLossless': false};
    }

    return null; // Unknown format
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: const Color(0xFF0a1929),
      appBar: AppBar(
        title: const Text('Search for Music'),
        backgroundColor: const Color(0xFF0d1b2a),
        actions: [
          // Song recognition (Shazam-like)
          IconButton(
            icon: const Icon(Icons.mic, color: Color(0xFF00d4ff)),
            tooltip: 'Identify song',
            onPressed: () async {
              final result = await showSongRecognitionSheet(context, _recognitionService);
              if (result != null && mounted) {
                _searchController.text = result.prowlarrQuery;
                _performSearch();
              }
            },
          ),
          // YouTube download button
          TextButton.icon(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => YouTubeDownloadScreen(
                    audioPlayerService: widget.audioPlayerService,
                  ),
                ),
              );
            },
            icon: const Icon(Icons.play_circle_outline, color: Colors.red),
            label: const Text('YouTube', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Column(
              children: [
                // Search bar
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          decoration: InputDecoration(
                            hintText:
                                'Artist - Album (e.g., Alice Cooper Killer)',
                            hintStyle: TextStyle(color: Colors.grey[600]),
                            prefixIcon: const Icon(
                              Icons.search,
                              color: Color(0xFF00d4ff),
                            ),
                            suffixIcon: _searchController.text.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(
                                      Icons.clear,
                                      color: Colors.grey,
                                    ),
                                    onPressed: () {
                                      _searchController.clear();
                                      setState(() {
                                        _showHistory =
                                            _searchHistory.isNotEmpty;
                                      });
                                    },
                                  )
                                : null,
                            filled: true,
                            fillColor: const Color(0xFF1a2332),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(
                                color: Color(0xFF00d4ff),
                                width: 2,
                              ),
                            ),
                          ),
                          style: const TextStyle(color: Colors.white),
                          onChanged: (value) {
                            setState(() {
                              _showHistory =
                                  value.isEmpty &&
                                  _searchHistory.isNotEmpty &&
                                  _searchFocusNode.hasFocus;
                            });
                          },
                          onSubmitted: (_) => _performSearch(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton(
                        onPressed: _isLoading ? null : _performSearch,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00d4ff),
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 16,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: _isLoading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.black,
                                ),
                              )
                            : const Text(
                                'Search',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                      ),
                    ],
                  ),
                ),

                // Quality filter chips — instant client-side filtering over
                // the backend's title fingerprint. State persists.
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _filterChip('Lossless', _fLossless,
                          (v) => setState(() => _fLossless = v)),
                      _filterChip('24-bit+', _fHiRes,
                          (v) => setState(() => _fHiRes = v)),
                      _filterChip('Surround', _fSurround,
                          (v) => setState(() => _fSurround = v)),
                      _filterChip('No MP3/AAC', _fNoLossy,
                          (v) => setState(() => _fNoLossy = v)),
                      if (_anyFilterActive && _hasSearched && _hiddenByFilters > 0)
                        Text(
                          '$_hiddenByFilters hidden',
                          style: TextStyle(
                              color: Colors.grey[600], fontSize: 11),
                        ),
                    ],
                  ),
                ),

                // Search history dropdown
                if (_showHistory)
                  TapRegion(
                    onTapOutside: (_) {
                      setState(() => _showHistory = false);
                    },
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1a2332),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: const Color(0xFF00d4ff).withOpacity(0.3),
                        ),
                      ),
                      constraints: const BoxConstraints(maxHeight: 250),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.history,
                                  size: 16,
                                  color: Colors.grey,
                                ),
                                const SizedBox(width: 8),
                                const Text(
                                  'Recent Searches',
                                  style: TextStyle(
                                    color: Colors.grey,
                                    fontSize: 12,
                                  ),
                                ),
                                const Spacer(),
                                GestureDetector(
                                  onTap: _clearHistory,
                                  child: const Text(
                                    'Clear',
                                    style: TextStyle(
                                      color: Color(0xFF00d4ff),
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Divider(height: 1, color: Color(0xFF2a3a4a)),
                          Flexible(
                            child: ListView.builder(
                              shrinkWrap: true,
                              itemCount: _searchHistory.length,
                              itemBuilder: (context, index) {
                                final query = _searchHistory[index];
                                return ListTile(
                                  dense: true,
                                  leading: const Icon(
                                    Icons.search,
                                    size: 18,
                                    color: Colors.grey,
                                  ),
                                  title: Text(
                                    query,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                    ),
                                  ),
                                  trailing: IconButton(
                                    icon: const Icon(
                                      Icons.close,
                                      size: 16,
                                      color: Colors.grey,
                                    ),
                                    onPressed: () {
                                      setState(() {
                                        _searchHistory.removeAt(index);
                                        if (_searchHistory.isEmpty) {
                                          _showHistory = false;
                                        }
                                      });
                                      _saveSearchHistory();
                                    },
                                  ),
                                  onTap: () {
                                    print('History item tapped: $query');
                                    _searchController.text = query;
                                    _showHistory = false;
                                    _performSearch(query);
                                  },
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Deep search banner (RuTracker)
                if (_hasSearched && !_isLoading && _results.isNotEmpty && !_deepSearchDone)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: GestureDetector(
                      onTap: _isDeepSearching ? null : _performDeepSearch,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1a2332),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _isDeepSearching
                                ? Colors.orange.withOpacity(0.3)
                                : const Color(0xFF00d4ff).withOpacity(0.3),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (_isDeepSearching) ...[
                              const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.orange,
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Text(
                                'Searching RuTracker...',
                                style: TextStyle(color: Colors.orange, fontSize: 13),
                              ),
                            ] else ...[
                              const Icon(Icons.travel_explore, size: 16, color: Color(0xFF00d4ff)),
                              const SizedBox(width: 8),
                              Text(
                                _rutrackerFilteredCount > 0
                                    ? '$_rutrackerFilteredCount RuTracker result${_rutrackerFilteredCount == 1 ? '' : 's'} hidden — search anyway?'
                                    : 'Also search RuTracker',
                                style: const TextStyle(color: Color(0xFF00d4ff), fontSize: 13, fontWeight: FontWeight.w500),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '(slower)',
                                style: TextStyle(color: Colors.grey[600], fontSize: 11),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),

                // Deep search done banner
                if (_deepSearchDone && _deepResultsAdded > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: Colors.green.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.green.withOpacity(0.3)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.check_circle_outline, size: 14, color: Colors.green),
                          const SizedBox(width: 6),
                          Text(
                            '+$_deepResultsAdded results from RuTracker',
                            style: const TextStyle(color: Colors.green, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),

                // Results
                Expanded(child: _buildResultsContent()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Hand the current query to the YouTube screen and run it there.
  void _openYouTubeSearch() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => YouTubeDownloadScreen(
          audioPlayerService: widget.audioPlayerService,
          initialSearch: _searchController.text.trim(),
        ),
      ),
    );
  }

  /// Slim pickings: fewer than three results, or nothing with a seeder.
  bool get _resultsAreThin =>
      _results.length < 3 ||
      _results.every((r) => ((r['seeders'] as int?) ?? 0) == 0);

  Widget _buildThinResultsBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.amber.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.amber.withOpacity(0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _results.length < 3
                  ? 'Only ${_results.length} result${_results.length == 1 ? '' : 's'} here.'
                  : 'Nothing here shows a seeder.',
              style: TextStyle(color: Colors.amber[100], fontSize: 12),
            ),
          ),
          TextButton.icon(
            onPressed: _openYouTubeSearch,
            icon: const Icon(Icons.play_circle_outline, size: 16, color: Colors.red),
            label: const Text('Try YouTube', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Widget _buildResultsContent() {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Color(0xFF00d4ff)),
            SizedBox(height: 16),
            Text('Searching indexers...', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 48),
            const SizedBox(height: 16),
            Text('Error: $_error', style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _performSearch,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (!_hasSearched) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search, size: 64, color: Colors.grey[700]),
            const SizedBox(height: 16),
            Text(
              'Search for music to download',
              style: TextStyle(color: Colors.grey[600], fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              'Try "Artist Album" or "Artist - Album"',
              style: TextStyle(color: Colors.grey[700], fontSize: 14),
            ),
          ],
        ),
      );
    }

    if (_results.isEmpty) {
      return SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 48),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.music_off, size: 64, color: Colors.grey[700]),
              const SizedBox(height: 16),
              Text(
                'No results found',
                style: TextStyle(color: Colors.grey[600], fontSize: 16),
              ),
              const SizedBox(height: 8),
              Text(
                'Try different search terms',
                style: TextStyle(color: Colors.grey[700], fontSize: 14),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _openYouTubeSearch,
                icon: const Icon(Icons.play_circle_outline),
                label: const Text('Try YouTube Instead'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final visible = _visibleResults;
    if (visible.isEmpty) {
      // Results exist but the quality filters hid them all.
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.filter_alt_off, size: 48, color: Colors.grey[700]),
            const SizedBox(height: 12),
            Text(
              'All ${_results.length} results hidden by filters',
              style: TextStyle(color: Colors.grey[500], fontSize: 14),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => setState(() {
                _fLossless = _fHiRes = _fSurround = _fNoLossy = false;
                _saveFilters();
              }),
              child: const Text('Clear filters',
                  style: TextStyle(color: Color(0xFF00d4ff))),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        if (_resultsAreThin) _buildThinResultsBanner(),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: visible.length,
            itemBuilder: (context, index) {
              final result = visible[index];
              return _buildResultCard(result);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildResultCard(Map<String, dynamic> result) {
    final guid = result['guid'] as String? ?? '';
    final title = result['title'] as String? ?? 'Unknown';
    final indexer = result['indexer'] as String? ?? 'Unknown';
    // Prefer our own tracker scrape over the indexer's number when we have one.
    final verified = _verifiedSwarm[guid];
    final seeders = verified != null
        ? (verified['seeders'] as int? ?? 0)
        : (result['seeders'] as int? ?? 0);
    final leechers = verified != null
        ? (verified['leechers'] as int? ?? 0)
        : (result['leechers'] as int? ?? 0);
    final size = result['size'] as int? ?? 0;
    final isDownloading = _downloadingGuids.contains(guid);
    final isProbing = _probingGuids.contains(guid);
    final formatInfo = _detectFormat(title);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1a2332),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFF00d4ff).withOpacity(0.2),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 10),

            // Badges row - wraps on mobile
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                // Format badge
                if (formatInfo != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: (formatInfo['color'] as Color).withOpacity(0.2),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: formatInfo['color'] as Color,
                        width: 1,
                      ),
                    ),
                    child: Text(
                      formatInfo['format'] as String,
                      style: TextStyle(
                        color: formatInfo['color'] as Color,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                // Fingerprint badges (backend title parse; only shown
                // when the title declared them). Atmos releases wear
                // the actual Dolby wordmark — same mark as the TV.
                if (result['is_atmos'] == true)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E64B4).withOpacity(0.35),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                          color: const Color(0xFF4FC3F7), width: 1),
                    ),
                    child: Image.asset(
                      'assets/images/dolby_atmos_wordmark.png',
                      height: 10,
                      filterQuality: FilterQuality.high,
                    ),
                  ),
                if (result['audio_layout'] == 'surround' &&
                    result['is_atmos'] != true)
                  _fingerprintBadge(
                      (result['audio_layout_label'] as String?) ?? 'SURROUND',
                      const Color(0xFF4FC3F7)),
                if (result['is_atmos'] == true &&
                    (result['channels_label'] as String?) != null)
                  _fingerprintBadge(result['channels_label'] as String,
                      const Color(0xFF4FC3F7)),
                if ((result['bit_depth'] as int?) != null &&
                    ((result['bit_depth'] as int) >= 24 ||
                        (result['bit_depth'] as int) == 1))
                  _fingerprintBadge(
                      (result['bit_depth'] == 1)
                          ? 'DSD'
                          : '${result['bit_depth']}-bit'
                              '${result['sample_rate_khz'] != null ? '/${result['sample_rate_khz']}k' : ''}',
                      const Color(0xFFFFD700)),
                if ((result['bitrate'] as String?) != null)
                  _fingerprintBadge(
                      result['bitrate'] as String, Colors.orange),
                if ((result['source_medium'] as String?) != null)
                  _fingerprintBadge(result['source_medium'] as String,
                      const Color(0xFF9E9E9E)),
                // Indexer badge
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00d4ff).withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    indexer,
                    style: const TextStyle(
                      color: Color(0xFF00d4ff),
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                // Seeders badge
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: _getSeedersColor(seeders).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: _getSeedersColor(seeders).withOpacity(0.5),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.arrow_upward, size: 10, color: _getSeedersColor(seeders)),
                      const SizedBox(width: 2),
                      Text(
                        // "~" = the indexer's claim (a stale scrape);
                        // "✓" = we asked the trackers ourselves.
                        verified != null ? '$seeders seed ✓' : '~$seeders seed',
                        style: TextStyle(
                          color: _getSeedersColor(seeders),
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                // Leechers badge
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.grey.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.arrow_downward, size: 10, color: Colors.grey[500]),
                      const SizedBox(width: 2),
                      Text(
                        '$leechers leech',
                        style: TextStyle(
                          color: Colors.grey[500],
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                // Size badge
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.grey.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _formatSize(size),
                    style: TextStyle(color: Colors.grey[400], fontSize: 10),
                  ),
                ),
                // In Library badge. Green means "you own this mix";
                // amber STEREO IN LIBRARY means the release is a
                // surround/Atmos mix but the library copy is stereo —
                // owning the album isn't the same as owning THIS mix.
                if (_libraryMatches[title]?['in_library'] == true)
                  Builder(builder: (context) {
                    final lm = _libraryMatches[title]!;
                    final releaseSurround =
                        result['audio_layout'] == 'surround';
                    final librarySurround =
                        ((lm['library_max_channels'] ?? 2) as num) > 2 ||
                            lm['library_is_atmos'] == true;
                    final stereoOnly = releaseSurround && !librarySurround;
                    final badgeColor =
                        stereoOnly ? Colors.amber : Colors.green;
                    return GestureDetector(
                      onTap: () {
                        final albumId = lm['album_id'];
                        if (albumId != null) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => AlbumDetailScreen(
                                albumId: albumId,
                                audioPlayerService: widget.audioPlayerService,
                                parentLabel: 'Search',
                              ),
                            ),
                          );
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: badgeColor.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: badgeColor, width: 1),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              stereoOnly ? Icons.volume_down : Icons.check,
                              size: 10,
                              color: badgeColor,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              stereoOnly ? 'STEREO IN LIBRARY' : 'IN LIBRARY',
                              style: TextStyle(
                                color: badgeColor,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  })
                else if (_inTransmission.contains(title))
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.orange.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.orange, width: 1),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.download, size: 10, color: Colors.orange),
                        SizedBox(width: 2),
                        Text(
                          'DOWNLOADING',
                          style: TextStyle(
                            color: Colors.orange,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),

            // Bottom row: link + stats on left, download button on right
            Row(
              children: [
                // Link to torrent page
                if (result['info_url'] != null &&
                    (result['info_url'] as String).isNotEmpty)
                  GestureDetector(
                    onTap: () {
                      launchUrl(
                        Uri.parse(result['info_url'] as String),
                        mode: LaunchMode.externalApplication,
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.grey.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Icon(
                        Icons.open_in_new,
                        size: 14,
                        color: Colors.grey[500],
                      ),
                    ),
                  ),
                if (result['info_url'] != null &&
                    (result['info_url'] as String).isNotEmpty)
                  const SizedBox(width: 8),

                const Spacer(),

                // Download button
                SizedBox(
                  height: 32,
                  child: ElevatedButton.icon(
                    onPressed: (isDownloading || isProbing)
                        ? null
                        : () => _downloadTorrent(result),
                    icon: (isDownloading || isProbing)
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.download, size: 16),
                    label: Text(
                      isProbing
                          ? 'Checking...'
                          : isDownloading
                              ? 'Adding...'
                              : 'Download',
                      style: const TextStyle(fontSize: 12),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: seeders > 0
                          ? const Color(0xFF00d4ff)
                          : Colors.grey[700],
                      foregroundColor: seeders > 0
                          ? Colors.black
                          : Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
