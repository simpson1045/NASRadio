import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/rss_feed.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import '../services/device_sync_service.dart';
import '../main.dart' show globalDeviceSyncService;
import 'now_playing_screen.dart';

class RssFeedDetailScreen extends StatefulWidget {
  final RssFeed feed;
  final AudioPlayerService audioPlayerService;

  const RssFeedDetailScreen({
    super.key,
    required this.feed,
    required this.audioPlayerService,
  });

  @override
  State<RssFeedDetailScreen> createState() => _RssFeedDetailScreenState();
}

class _RssFeedDetailScreenState extends State<RssFeedDetailScreen> {
  final ApiService _apiService = ApiService();
  final ScrollController _scrollController = ScrollController();
  List<RssEpisode> _episodes = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _isRefreshing = false;
  String? _error;
  int _page = 1;
  int _total = 0;
  bool _hasMore = true;
  bool _oldestFirst = false;

  // Authoritative resume-episode pulled from
  // /api/rss/feeds/<id>/current-episode. Independent of the paginated
  // _episodes list so the resume banner appears even if the episode
  // the user was last on lives on page 3+ of a long feed.
  RssEpisode? _resumeEpisodeFromApi;

  // Episode IDs with an in-flight download. Populated when the user taps
  // download, cleared when the backend emits podcast_download_complete /
  // podcast_download_failed. Drives the per-button spinner + disabled state
  // so users can actually tell something's happening.
  final Set<int> _downloadingEpisodes = {};

  // Sort-toggle debounce: prevents duplicate PUT + reload round-trips
  // when the user double-taps the sort icon.
  bool _sortToggleInFlight = false;

  // In-feed episode search. When active, the AppBar title flips to a text
  // field; the episode list becomes the server-side-filtered subset.
  // Debounced so each keystroke doesn't hit the backend.
  bool _isSearchActive = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;

  // Local mirror of widget.feed.autoDownload so the checked state in the
  // overflow menu updates immediately on toggle without waiting for a
  // feed refetch.
  late bool _autoDownload;

  // Related shows
  List<dynamic> _relatedShows = [];

  // Spotify rating
  double _averageRating = 0;
  int _totalRatings = 0;

  // Detach handle for cross-device episode update listener. Using the new
  // multi-listener API instead of the legacy single-assignment setter means
  // this screen + Discovery can both listen without stomping each other.
  VoidCallback? _removeEpisodeListener;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // Per-feed sort order lives in rss_feeds.play_order now (was a global
    // SharedPreferences bool — wrong, because different shows want different
    // orderings: ASOT newest-first, Talk Ville oldest-first, etc.).
    _oldestFirst = widget.feed.isOldestFirst;
    _autoDownload = widget.feed.autoDownload;
    _loadEpisodes();
    _loadResumeEpisode();
    _loadRelatedShows();
    _loadRating();
    // Listen for cross-device podcast episode updates and download events.
    _removeEpisodeListener = globalDeviceSyncService.addPodcastEpisodeListener(
      _handleEpisodeUpdated,
    );
    globalDeviceSyncService.onPodcastDownloadComplete = _handleDownloadComplete;
    globalDeviceSyncService.onPodcastDownloadFailed = _handleDownloadFailed;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    _searchDebounce?.cancel();
    _removeEpisodeListener?.call();
    // Download callbacks are still single-assignment — only unset if we
    // haven't been replaced by a sibling screen in the meantime.
    if (globalDeviceSyncService.onPodcastDownloadComplete == _handleDownloadComplete) {
      globalDeviceSyncService.onPodcastDownloadComplete = null;
    }
    if (globalDeviceSyncService.onPodcastDownloadFailed == _handleDownloadFailed) {
      globalDeviceSyncService.onPodcastDownloadFailed = null;
    }
    super.dispose();
  }

  void _handleEpisodeUpdated(int episodeId, int position, bool? isCompleted) {
    if (!mounted) return;
    // Update the episode in-place if it's in our current list
    final idx = _episodes.indexWhere((e) => e.id == episodeId);
    if (idx >= 0) {
      setState(() {
        _episodes[idx] = _episodes[idx].copyWith(
          playedPosition: position,
          isCompleted: isCompleted ?? _episodes[idx].isCompleted,
          // Stamp now so the resume-banner scan ranks this episode
          // correctly until the next API refresh confirms the
          // server-side timestamp.
          lastPlayedAt: DateTime.now().toUtc().toIso8601String(),
        );
      });
    }
    // Re-fetch the resume episode whenever something changes — the
    // user may have switched to a different episode on another
    // device, or marked the current one complete.
    _loadResumeEpisode();
  }

  void _handleDownloadComplete(int episodeId, String path) {
    if (!mounted) return;
    final idx = _episodes.indexWhere((e) => e.id == episodeId);
    setState(() {
      _downloadingEpisodes.remove(episodeId);
      // Best-effort: mark the cached RssEpisode as downloaded so the button
      // flips from download -> checkmark without a full refetch. We don't
      // have copyWith for downloadedPath so just flag it conceptually — a
      // lazy refetch on the next user action will pull the real path.
      if (idx >= 0) {
        _episodes[idx] = _episodes[idx].copyWith(isCompleted: _episodes[idx].isCompleted);
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Download complete'),
        backgroundColor: Colors.green.shade800,
        duration: const Duration(seconds: 2),
      ),
    );
    // Pull fresh isDownloaded state from the server.
    _loadEpisodes();
  }

  void _handleDownloadFailed(int episodeId, String error) {
    if (!mounted) return;
    setState(() => _downloadingEpisodes.remove(episodeId));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Download failed: $error'),
        backgroundColor: Colors.red.shade800,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  void _handleFeedMenu(String value) {
    switch (value) {
      case 'mark_all_played':
        _confirmMarkAllPlayed();
        break;
      case 'feed_settings':
        _showFeedSettings();
        break;
    }
  }

  // Local state for the Feed Settings sheet — kept in sync with the live
  // RssFeed values on open, persisted to the backend on close.
  int _settingsIntroSkip = 0;
  int _settingsOutroSkip = 0;
  int _settingsRetention = 0;

  Future<void> _showFeedSettings() async {
    _settingsIntroSkip = widget.feed.introSkipSeconds;
    _settingsOutroSkip = widget.feed.outroSkipSeconds;
    _settingsRetention = widget.feed.retentionDays;
    var sheetAutoDownload = _autoDownload;

    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1a2332),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 20, right: 20, top: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Feed settings',
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Auto-download new episodes',
                      style: TextStyle(color: Colors.white)),
                  subtitle: const Text(
                    'Episodes download to the NAS as they publish.',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  value: sheetAutoDownload,
                  activeThumbColor: const Color(0xFF00d4ff),
                  onChanged: (v) => setSheetState(() => sheetAutoDownload = v),
                ),
                const Divider(color: Colors.white12, height: 24),
                _buildSkipSecondsSlider(
                  label: 'Skip intro',
                  subtitle: 'Jump forward this many seconds when an episode starts.',
                  value: _settingsIntroSkip,
                  max: 120,
                  onChanged: (v) => setSheetState(() => _settingsIntroSkip = v),
                ),
                const SizedBox(height: 8),
                _buildSkipSecondsSlider(
                  label: 'Skip outro',
                  subtitle: 'Auto-advance this many seconds before the end.',
                  value: _settingsOutroSkip,
                  max: 120,
                  onChanged: (v) => setSheetState(() => _settingsOutroSkip = v),
                ),
                const Divider(color: Colors.white12, height: 24),
                _buildRetentionSlider(
                  value: _settingsRetention,
                  onChanged: (v) => setSheetState(() => _settingsRetention = v),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00d4ff),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await _saveFeedSettings(
                        autoDownload: sheetAutoDownload,
                      );
                    },
                    child: const Text('Save', style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSkipSecondsSlider({
    required String label,
    required String subtitle,
    required int value,
    required int max,
    required ValueChanged<int> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500)),
            ),
            Text(
              value == 0 ? 'Off' : '${value}s',
              style: const TextStyle(color: Color(0xFF00d4ff), fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        Slider(
          value: value.toDouble().clamp(0, max.toDouble()),
          min: 0,
          max: max.toDouble(),
          divisions: max ~/ 5,
          activeColor: const Color(0xFF00d4ff),
          inactiveColor: Colors.white24,
          onChanged: (v) => onChanged(v.round()),
        ),
      ],
    );
  }

  Widget _buildRetentionSlider({
    required int value,
    required ValueChanged<int> onChanged,
  }) {
    // Non-linear scale: 0, 7, 14, 30, 60, 90, 180, 365.
    const stops = [0, 7, 14, 30, 60, 90, 180, 365];
    final idx = stops.indexOf(value).clamp(0, stops.length - 1);
    final labelText = value == 0 ? 'Keep forever' : '$value days';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('Auto-delete played episodes',
                  style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500)),
            ),
            Text(labelText,
                style: const TextStyle(color: Color(0xFF00d4ff), fontSize: 15, fontWeight: FontWeight.w600)),
          ],
        ),
        const Text(
          "Unplayed episodes are always kept. Shorter windows save disk space.",
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        Slider(
          value: idx.toDouble(),
          min: 0,
          max: (stops.length - 1).toDouble(),
          divisions: stops.length - 1,
          activeColor: const Color(0xFF00d4ff),
          inactiveColor: Colors.white24,
          onChanged: (v) => onChanged(stops[v.round()]),
        ),
      ],
    );
  }

  Future<void> _saveFeedSettings({required bool autoDownload}) async {
    try {
      await _apiService.updateRssFeed(
        widget.feed.id,
        autoDownload: autoDownload,
        introSkipSeconds: _settingsIntroSkip,
        outroSkipSeconds: _settingsOutroSkip,
        retentionDays: _settingsRetention,
      );
      if (!mounted) return;
      setState(() => _autoDownload = autoDownload);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Feed settings saved')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to save: $e'),
          backgroundColor: Colors.red.shade800,
        ),
      );
    }
  }

  Future<void> _confirmMarkAllPlayed() async {
    // The "catch up" shortcut is destructive enough (you can't easily
    // un-do this per-episode) that a quick confirmation is worth it.
    final unplayed = widget.feed.unplayedCount;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: const Text('Mark all as played?', style: TextStyle(color: Colors.white)),
        content: Text(
          unplayed > 0
              ? 'This marks all $unplayed unplayed episode(s) as completed.'
              : 'Every episode in this feed will be marked completed.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Mark all played',
                style: TextStyle(color: Color(0xFF00d4ff))),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final marked = await _apiService.markAllEpisodesPlayed(widget.feed.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(marked == 0
              ? 'Nothing to mark — everything already played.'
              : 'Marked $marked episode(s) as played.'),
          backgroundColor: Colors.green.shade800,
        ),
      );
      _loadEpisodes();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to mark played: $e'), backgroundColor: Colors.red.shade800),
      );
    }
  }

  void _onSearchChanged(String query) {
    _searchDebounce?.cancel();
    // Empty query resolves immediately (user cleared the field). Non-empty
    // query waits 300 ms to coalesce typing into a single backend call.
    if (query.isEmpty && _searchQuery.isEmpty) return;
    if (query.isEmpty) {
      setState(() => _searchQuery = '');
      _loadEpisodes();
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      if (_searchQuery == query) return;
      setState(() => _searchQuery = query);
      _loadEpisodes();
    });
  }

  void _toggleSearchBar() {
    setState(() {
      _isSearchActive = !_isSearchActive;
      if (!_isSearchActive) {
        _searchController.clear();
        if (_searchQuery.isNotEmpty) {
          _searchQuery = '';
          _loadEpisodes();
        }
      }
    });
  }

  Future<void> _toggleSortOrder() async {
    // Debounce: the sort icon has no busy state and it's easy to double-tap.
    // Without this guard, each tap fires a PUT + a full _loadEpisodes()
    // round-trip, doubling work and producing a flicker where the list
    // toggles direction twice in quick succession.
    if (_sortToggleInFlight) return;
    _sortToggleInFlight = true;

    final newOrder = _oldestFirst ? 'newest_first' : 'oldest_first';
    setState(() => _oldestFirst = !_oldestFirst);
    // Persist to backend; ignore failure (local state wins in the UI and
    // next open will re-read widget.feed.playOrder anyway).
    try {
      await _apiService.updateRssFeed(widget.feed.id, playOrder: newOrder);
    } catch (e) {
      // Non-fatal — user still gets the sort change this session.
      debugPrint('Failed to persist play_order for feed ${widget.feed.id}: $e');
    }
    await _loadEpisodes();
    _sortToggleInFlight = false;
  }

  Future<void> _loadRating() async {
    try {
      final data = await _apiService.getPodcastRating(widget.feed.title);
      if (mounted) {
        setState(() {
          _totalRatings = data['totalRatings'] ?? 0;
          _averageRating = (data['averageRating'] ?? 0).toDouble();
        });
      }
    } catch (e) {
      // Silently fail
    }
  }

  Future<void> _loadRelatedShows() async {
    try {
      print('🔍 Loading related shows for: ${widget.feed.title}');
      final results = await _apiService.getSimilarPodcasts(widget.feed.title);
      print('🔍 Got ${results.length} related shows');
      if (mounted) {
        setState(() => _relatedShows = results);
      }
    } catch (e) {
      print('🔍 Related shows error: $e');
    }
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200 &&
        _hasMore &&
        !_isLoadingMore &&
        !_isLoading) {
      _loadMoreEpisodes();
    }
  }

  // Pull the authoritative resume episode from the server. Decoupled
  // from the paginated episode list so we still get the banner when
  // the user's last-listened episode is on a later page.
  Future<void> _loadResumeEpisode() async {
    try {
      final data = await _apiService.getFeedCurrentEpisode(widget.feed.id);
      if (!mounted) return;
      if (data != null) {
        setState(() => _resumeEpisodeFromApi = RssEpisode.fromJson(data));
      } else {
        setState(() => _resumeEpisodeFromApi = null);
      }
    } catch (_) {
      // Non-fatal — fall back to the in-memory scan in _resumeEpisode.
    }
  }

  Future<void> _loadEpisodes() async {
    _page = 1;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final result = await _apiService.getRssEpisodes(
        widget.feed.id,
        page: 1,
        sort: _oldestFirst ? 'asc' : 'desc',
        search: _searchQuery.isEmpty ? null : _searchQuery,
      );
      final episodes = (result['episodes'] as List)
          .map((e) => RssEpisode.fromJson(e))
          .toList();

      setState(() {
        _episodes = episodes;
        _total = result['total'] ?? 0;
        _hasMore = _episodes.length < _total;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _loadMoreEpisodes() async {
    if (_isLoadingMore) return;
    setState(() => _isLoadingMore = true);
    _page++;

    try {
      final result = await _apiService.getRssEpisodes(
        widget.feed.id,
        page: _page,
        sort: _oldestFirst ? 'asc' : 'desc',
        search: _searchQuery.isEmpty ? null : _searchQuery,
      );
      final episodes = (result['episodes'] as List)
          .map((e) => RssEpisode.fromJson(e))
          .toList();

      setState(() {
        _episodes.addAll(episodes);
        _hasMore = _episodes.length < _total;
        _isLoadingMore = false;
      });
    } catch (e) {
      setState(() => _isLoadingMore = false);
      _page--; // Revert so retry works
    }
  }

  Future<void> _refreshFeed() async {
    setState(() => _isRefreshing = true);
    try {
      final result = await _apiService.refreshRssFeed(widget.feed.id);
      final newCount = result['new_episodes'] ?? 0;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(newCount > 0
                ? '$newCount new episodes found'
                : 'Feed is up to date'),
          ),
        );
      }
      await _loadEpisodes();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Refresh failed: $e'), backgroundColor: Colors.red),
        );
      }
    }
    setState(() => _isRefreshing = false);
  }

  Future<void> _playEpisode(RssEpisode episode) async {
    // Build the queue in the SAME order the list is displayed, so "next"
    // walks the episodes exactly the way the user sorted them — ASOT
    // newest-first (don't drag me back to shows from 7 years ago), Talk Ville
    // oldest-first for story order. _episodes is already in display order
    // (loaded with sort = _oldestFirst ? 'asc' : 'desc'). This previously
    // force-sorted to oldest-first regardless, which buried the episode you
    // tapped at the END of a newest-first queue, so it never advanced.
    final queueEpisodes = List<RssEpisode>.from(_episodes);

    // Always stream through the backend proxy. It (a) caches the resolved CDN
    // URL so the tracker chain (Podtrac/Chartable/Megaphone) is walked once
    // instead of on every play — the direct audio_url makes the CLIENT re-chase
    // the whole chain each time (~15-20s) — and (b) synthesizes proper 206 Range
    // responses so seek/rebuffer doesn't restart the episode. The auto-advance
    // path already uses this URL, so this also makes first-play consistent.
    final streamUrl = _apiService.getRssStreamUrl(episode.id);

    // Start playback (don't await — navigate immediately so user sees loading)
    widget.audioPlayerService.playPodcastEpisode(
      episode,
      streamUrl,
      artworkUrl: episode.artworkUrl ?? widget.feed.artworkUrl,
      podcastAuthor: widget.feed.author,
      podcastTitle: widget.feed.title,
      feedId: widget.feed.id,
      allEpisodes: queueEpisodes,
      introSkipSeconds: widget.feed.introSkipSeconds,
      outroSkipSeconds: widget.feed.outroSkipSeconds,
    );
    if (!mounted) return;
    // Navigate to now playing screen right away
    NowPlayingScreen.open(
      context,
      audioPlayerService: widget.audioPlayerService,
    );
  }

  List<RssEpisode> get _sortedEpisodes => _episodes;

  // Pick the resume episode = the most-recently-saved in-progress
  // episode in this feed. Two-tier strategy:
  //
  //   1. Authoritative: _resumeEpisodeFromApi, fetched from
  //      /api/rss/feeds/<id>/current-episode on screen open. This is
  //      independent of the paginated _episodes list so the banner
  //      appears even when the resume episode lives on page 3+.
  //   2. Fallback: scan the loaded _episodes for an in-progress
  //      episode, ranked by lastPlayedAt desc (server timestamp on
  //      every progress save). Used when the API hasn't responded yet
  //      and for podcasts whose backend pre-dates the last_played_at
  //      column. Avoids the previous `firstWhere` bug where the
  //      banner could pick whatever in-progress episode happened to
  //      sort first under the current sort order.
  //
  // If both yield candidates, prefer the live scan only when its top
  // candidate has a strictly newer lastPlayedAt than the API result
  // — handles the cross-device sync case where another device
  // pushed an update after the screen loaded.
  RssEpisode? get _resumeEpisode {
    final apiPick = _resumeEpisodeFromApi;

    final candidates = _episodes
        .where((e) => e.playedPosition > 0 && !e.isCompleted)
        .toList();
    candidates.sort((a, b) {
      final aTs = a.lastPlayedAt;
      final bTs = b.lastPlayedAt;
      if (aTs == null && bTs == null) return 0;
      if (aTs == null) return 1; // nulls last
      if (bTs == null) return -1;
      // ISO-8601 strings compare correctly lexicographically.
      // Descending: most recent first.
      return bTs.compareTo(aTs);
    });
    final scanPick = candidates.isEmpty ? null : candidates.first;

    if (apiPick == null) return scanPick;
    if (scanPick == null) return apiPick;

    // Prefer scan if it has a strictly newer last_played_at (live
    // cross-device update). Otherwise the API result wins.
    final scanTs = scanPick.lastPlayedAt;
    final apiTs = apiPick.lastPlayedAt;
    if (scanTs != null && apiTs != null && scanTs.compareTo(apiTs) > 0) {
      return scanPick;
    }
    return apiPick;
  }

  String _formatDate(String? dateStr) {
    if (dateStr == null) return '';
    try {
      final date = DateTime.parse(dateStr);
      final now = DateTime.now();
      final diff = now.difference(date);

      if (diff.inDays == 0) return 'Today';
      if (diff.inDays == 1) return 'Yesterday';
      if (diff.inDays < 7) return '${diff.inDays}d ago';
      if (diff.inDays < 30) return '${diff.inDays ~/ 7}w ago';
      if (diff.inDays < 365) return '${diff.inDays ~/ 30}mo ago';
      return '${diff.inDays ~/ 365}y ago';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0a1929),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0d1b2a),
        title: _isSearchActive
            ? TextField(
                controller: _searchController,
                autofocus: true,
                onChanged: _onSearchChanged,
                style: const TextStyle(color: Colors.white, fontSize: 18),
                cursorColor: const Color(0xFF00d4ff),
                decoration: const InputDecoration(
                  hintText: 'Search episodes...',
                  hintStyle: TextStyle(color: Colors.white54),
                  border: InputBorder.none,
                ),
              )
            : Text(widget.feed.title),
        actions: [
          IconButton(
            icon: Icon(_isSearchActive ? Icons.close : Icons.search),
            tooltip: _isSearchActive ? 'Close search' : 'Search episodes',
            onPressed: _toggleSearchBar,
          ),
          // Sort toggle — persists per-feed in rss_feeds.play_order
          if (!_isSearchActive)
            IconButton(
              icon: Icon(_oldestFirst ? Icons.arrow_upward : Icons.arrow_downward),
              tooltip: _oldestFirst ? 'Showing oldest first' : 'Showing newest first',
              onPressed: _toggleSortOrder,
            ),
          // Refresh
          if (!_isSearchActive)
            IconButton(
              icon: _isRefreshing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.refresh),
              onPressed: _isRefreshing ? null : _refreshFeed,
            ),
          // Overflow menu — feed-level actions that don't warrant their
          // own visible button.
          if (!_isSearchActive)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              color: const Color(0xFF1a2332),
              onSelected: _handleFeedMenu,
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'mark_all_played',
                  child: ListTile(
                    leading: Icon(Icons.done_all, color: Colors.white),
                    title: Text('Mark all as played', style: TextStyle(color: Colors.white)),
                    contentPadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const PopupMenuItem(
                  value: 'feed_settings',
                  child: ListTile(
                    leading: Icon(Icons.tune, color: Colors.white),
                    title: Text('Feed settings...', style: TextStyle(color: Colors.white)),
                    contentPadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: Colors.orange))
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_error!, style: const TextStyle(color: Colors.white70)),
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: _loadEpisodes,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _refreshFeed,
                        child: _buildEpisodeList(),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildEpisodeList() {
    final sorted = _sortedEpisodes;
    final resume = _resumeEpisode;

    final hasRelated = _relatedShows.isNotEmpty;
    // +1 header, +1 resume (if exists), +1 related (if exists), +1 loading
    final preEpisodeItems = 1 + (resume != null ? 1 : 0) + (hasRelated ? 1 : 0);

    return ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.only(
        bottom: Platform.isAndroid ? 100 : 16,
      ),
      itemCount: sorted.length + preEpisodeItems + (_isLoadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        // Header with artwork and info
        if (index == 0) return _buildHeader();

        // Resume card
        if (resume != null && index == 1) return _buildResumeCard(resume);

        // Related shows (before episodes)
        final relatedIndex = 1 + (resume != null ? 1 : 0);
        if (hasRelated && index == relatedIndex) return _buildRelatedShows();

        // Episodes
        final episodeIndex = index - preEpisodeItems;
        if (episodeIndex >= 0 && episodeIndex < sorted.length) {
          return _buildEpisodeTile(sorted[episodeIndex]);
        }

        // Loading indicator at bottom
        if (_isLoadingMore) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator(color: Colors.orange)),
          );
        }

        return const SizedBox.shrink();
      },
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Artwork
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: widget.feed.artworkUrl != null
                ? Image.network(
                    widget.feed.artworkUrl!,
                    width: 100,
                    height: 100,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _artworkPlaceholder(),
                  )
                : _artworkPlaceholder(),
          ),
          const SizedBox(width: 16),
          // Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.feed.author.isNotEmpty)
                  Text(
                    widget.feed.author,
                    style: const TextStyle(color: Colors.orange, fontSize: 14),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                const SizedBox(height: 4),
                Text(
                  '${widget.feed.episodeCount} episodes',
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
                if (_totalRatings > 0) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.star, color: Colors.amber, size: 14),
                      const SizedBox(width: 4),
                      Text(
                        '${_averageRating > 0 ? _averageRating.toStringAsFixed(1) : "?"} (${_formatCount(_totalRatings)} ratings)',
                        style: const TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                    ],
                  ),
                ],
                if (widget.feed.description.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    widget.feed.description,
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _artworkPlaceholder() {
    return Container(
      width: 100,
      height: 100,
      color: const Color(0xFF1a2332),
      child: const Icon(Icons.podcasts, color: Colors.orange, size: 40),
    );
  }

  Widget _buildResumeCard(RssEpisode episode) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
      ),
      child: ListTile(
        leading: const Icon(Icons.play_circle_filled, color: Colors.orange, size: 36),
        title: Text(
          episode.title,
          style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          'Resume \u2022 ${_formatProgress(episode)}',
          style: const TextStyle(color: Colors.orange, fontSize: 12),
        ),
        onTap: () => _playEpisode(episode),
      ),
    );
  }

  Widget _buildEpisodeTile(RssEpisode episode) {
    final isPlaying = widget.audioPlayerService.isPlayingPodcast &&
        widget.audioPlayerService.currentEpisodeId == episode.id;

    return InkWell(
      onTap: () => _playEpisode(episode),
      onLongPress: () => _showEpisodeMenu(episode),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isPlaying ? Colors.orange.withValues(alpha: 0.1) : null,
          border: Border(
            bottom: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Play/completed indicator
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 12),
              child: Icon(
                isPlaying
                    ? Icons.equalizer
                    : episode.isCompleted
                        ? Icons.check_circle
                        : Icons.play_circle_outline,
                color: isPlaying
                    ? Colors.orange
                    : episode.isCompleted
                        ? Colors.green
                        : Colors.white54,
                size: 28,
              ),
            ),
            // Episode info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    episode.title,
                    style: TextStyle(
                      color: episode.isCompleted ? Colors.white54 : Colors.white,
                      fontWeight: FontWeight.w500,
                      fontSize: 14,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (episode.publishedAt != null) ...[
                        Text(
                          _formatDate(episode.publishedAt),
                          style: const TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        episode.durationFormatted,
                        style: const TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                      if (episode.isDownloaded) ...[
                        const SizedBox(width: 8),
                        const Icon(Icons.download_done, size: 14, color: Colors.green),
                      ],
                      if (episode.playedPosition > 0 && !episode.isCompleted) ...[
                        const SizedBox(width: 8),
                        Text(
                          _formatProgress(episode),
                          style: const TextStyle(color: Colors.orange, fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                  if (episode.description.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      episode.description,
                      style: const TextStyle(color: Colors.white30, fontSize: 12),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            // Download button. Three visible states:
            //   - spinning: download in flight (disabled, shows progress ring)
            //   - green check: already downloaded (disabled)
            //   - grey arrow: available to download (tap to start)
            _buildDownloadButton(episode),
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadButton(RssEpisode episode) {
    final isDownloading = _downloadingEpisodes.contains(episode.id);
    if (isDownloading) {
      return const Padding(
        padding: EdgeInsets.all(10),
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Color(0xFF00d4ff),
          ),
        ),
      );
    }
    return IconButton(
      icon: Icon(
        episode.isDownloaded ? Icons.download_done : Icons.download_outlined,
        color: episode.isDownloaded ? Colors.green : Colors.white38,
        size: 20,
      ),
      tooltip: episode.isDownloaded ? 'Downloaded' : 'Download episode',
      onPressed: episode.isDownloaded ? null : () => _startDownload(episode),
    );
  }

  Future<void> _showPlaylistPicker(RssEpisode episode) async {
    // Fetch the current playlists to pick from. If none exist, nudge the
    // user to create one first instead of silently doing nothing.
    final playlists = await _apiService.getPlaylists().catchError((_) => const []);
    if (!mounted) return;
    if (playlists.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Create a playlist first from the Playlists tab')),
      );
      return;
    }

    final selected = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF1a2332),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Icon(Icons.playlist_add, color: Color(0xFFff8c42)),
                  SizedBox(width: 8),
                  Text(
                    'Add to which playlist?',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: playlists.length,
                itemBuilder: (_, i) {
                  final p = playlists[i];
                  return ListTile(
                    leading: const Icon(Icons.queue_music, color: Colors.white54),
                    title: Text(p.name, style: const TextStyle(color: Colors.white)),
                    subtitle: Text(
                      '${p.songCount} song${p.songCount == 1 ? '' : 's'}',
                      style: const TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                    onTap: () => Navigator.pop(ctx, p.id),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );

    if (selected == null || !mounted) return;

    try {
      await _apiService.addEpisodeToPlaylist(selected, episode.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Added to playlist'),
          backgroundColor: Colors.green.shade800,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Couldn't add to playlist: $e"),
          backgroundColor: Colors.red.shade800,
        ),
      );
    }
  }

  Future<void> _startDownload(RssEpisode episode) async {
    setState(() => _downloadingEpisodes.add(episode.id));
    try {
      await _apiService.downloadEpisode(episode.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Download started'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      // The HTTP kick-off itself failed — we never got to the background
      // worker, so no WebSocket event will come. Clear the spinner.
      if (mounted) {
        setState(() => _downloadingEpisodes.remove(episode.id));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Couldn't start download: $e"),
            backgroundColor: Colors.red.shade800,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  void _showEpisodeMenu(RssEpisode episode) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1a2332),
      builder: (context) => SafeArea(
        child: Padding(
          padding: EdgeInsets.only(bottom: Platform.isAndroid ? 24 : 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  episode.isCompleted ? Icons.radio_button_unchecked : Icons.check_circle,
                  color: episode.isCompleted ? Colors.white54 : Colors.green,
                ),
                title: Text(
                  episode.isCompleted ? 'Mark as unplayed' : 'Mark as complete',
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () async {
                  Navigator.pop(context);
                  await _apiService.updateEpisodeProgress(
                    episode.id,
                    episode.isCompleted ? 0 : (episode.audioDuration ?? 0),
                    isCompleted: !episode.isCompleted,
                  );
                  _loadEpisodes();
                },
              ),
              ListTile(
                leading: const Icon(Icons.queue_music, color: Colors.white54),
                title: const Text('Add to queue', style: TextStyle(color: Colors.white)),
                subtitle: const Text(
                  'Play after current',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
                onTap: () {
                  Navigator.pop(context);
                  widget.audioPlayerService.enqueuePodcastEpisode(
                    episode,
                    feedId: widget.feed.id,
                    author: widget.feed.author.isNotEmpty ? widget.feed.author : widget.feed.title,
                    showName: widget.feed.title,
                    artworkUrl: widget.feed.artworkUrl,
                  );
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Added "${episode.title}" to queue'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.playlist_add, color: Colors.white54),
                title: const Text('Add to playlist...', style: TextStyle(color: Colors.white)),
                subtitle: const Text(
                  'Mix episodes with music in any playlist',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _showPlaylistPicker(episode);
                },
              ),
              if (!episode.isDownloaded && !_downloadingEpisodes.contains(episode.id))
                ListTile(
                  leading: const Icon(Icons.download_outlined, color: Colors.white54),
                  title: const Text('Download episode', style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(context);
                    _startDownload(episode);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRelatedShows() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(color: Colors.white12, height: 32),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            'Related Shows',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Color(0xFF00d4ff),
            ),
          ),
        ),
        SizedBox(
          height: 180,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _relatedShows.length,
            itemBuilder: (context, index) {
              final show = _relatedShows[index];
              final title = show['title'] ?? 'Unknown';
              final author = show['author'] ?? '';
              final artwork = show['artwork'] ?? show['image'] ?? '';
              final feedUrl = show['url'] ?? '';

              return GestureDetector(
                onTap: () => _showPodcastPreview(show),
                child: Container(
                  width: 120,
                  margin: const EdgeInsets.only(right: 12),
                  child: Column(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: artwork.isNotEmpty
                            ? CachedNetworkImage(
                                imageUrl: artwork.toString(),
                                width: 120,
                                height: 120,
                                fit: BoxFit.cover,
                                errorWidget: (_, __, ___) => Container(
                                  width: 120,
                                  height: 120,
                                  color: const Color(0xFF0d1b2a),
                                  child: const Icon(Icons.podcasts, color: Color(0xFF00d4ff), size: 40),
                                ),
                              )
                            : Container(
                                width: 120,
                                height: 120,
                                color: const Color(0xFF0d1b2a),
                                child: const Icon(Icons.podcasts, color: Color(0xFF00d4ff), size: 40),
                              ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        title,
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                      Text(
                        author,
                        style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  String _formatCount(int count) {
    if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}K';
    return count.toString();
  }

  void _showPodcastPreview(dynamic show) {
    final title = show['title'] ?? 'Unknown';
    final author = show['author'] ?? '';
    final artwork = show['artwork'] ?? show['image'] ?? '';
    final description = (show['description'] ?? '').toString().replaceAll(RegExp(r'<[^>]*>'), '');
    final episodeCount = show['episodeCount'] ?? 0;
    final feedUrl = show['url'] ?? '';
    final categories = show['categories'] as Map<String, dynamic>? ?? {};
    final totalRatings = show['totalRatings'] ?? 0;
    final averageRating = (show['averageRating'] ?? 0).toDouble();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0d1b2a),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => SingleChildScrollView(
          controller: scrollController,
          padding: EdgeInsets.only(
            left: 20, right: 20, top: 16,
            bottom: Platform.isAndroid ? 40 : 16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.grey[600],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // Artwork + title row
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: artwork.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: artwork.toString(),
                            width: 120, height: 120, fit: BoxFit.cover,
                            errorWidget: (_, __, ___) => Container(
                              width: 120, height: 120,
                              color: const Color(0xFF1a2332),
                              child: const Icon(Icons.podcasts, color: Color(0xFF00d4ff), size: 40),
                            ),
                          )
                        : Container(
                            width: 120, height: 120,
                            color: const Color(0xFF1a2332),
                            child: const Icon(Icons.podcasts, color: Color(0xFF00d4ff), size: 40),
                          ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        Text(author, style: TextStyle(fontSize: 14, color: Colors.grey[400])),
                        const SizedBox(height: 8),
                        if (episodeCount > 0)
                          Text('$episodeCount episodes', style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                        if (totalRatings > 0) ...[
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              const Icon(Icons.star, color: Colors.amber, size: 14),
                              const SizedBox(width: 4),
                              Text(
                                '${averageRating > 0 ? averageRating.toStringAsFixed(1) : "?"} (${_formatCount(totalRatings)} ratings)',
                                style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                              ),
                            ],
                          ),
                        ],
                        if (categories.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: categories.values.map((cat) => Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFF00d4ff).withOpacity(0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                cat.toString(),
                                style: const TextStyle(fontSize: 10, color: Color(0xFF00d4ff)),
                              ),
                            )).toList(),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              // Subscribe button
              if (feedUrl.isNotEmpty)
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      try {
                        await _apiService.addRssFeed(feedUrl);
                        if (mounted) {
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Subscribed to $title')),
                          );
                        }
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('$e')),
                          );
                        }
                      }
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Subscribe'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00d4ff),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              const SizedBox(height: 20),
              // Description
              if (description.isNotEmpty) ...[
                const Text('About', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF00d4ff))),
                const SizedBox(height: 8),
                Text(
                  description.trim(),
                  style: TextStyle(fontSize: 13, color: Colors.grey[300], height: 1.5),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _formatProgress(RssEpisode episode) {
    if (episode.audioDuration == null || episode.audioDuration == 0) return '';
    final pct = (episode.playedPosition / episode.audioDuration! * 100).round();
    return '$pct% played';
  }
}
