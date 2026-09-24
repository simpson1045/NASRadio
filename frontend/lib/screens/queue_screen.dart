import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/song.dart';
import '../services/audio_player_service.dart';
import '../services/api_service.dart';
import 'now_playing_screen.dart';
import 'prowlarr_search_screen.dart';
import '../widgets/mouse_back_button_wrapper.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../widgets/explicit_badge.dart';
import '../widgets/hdcd_badge.dart';
import '../widgets/surround_badge.dart';

class QueueScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;

  const QueueScreen({super.key, required this.audioPlayerService});

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  final ApiService _apiService = ApiService();
  // Estimated row height for scroll-to-index math. Real ListTile rows
  // vary slightly with text wrapping, but 76 is the right-of-the-middle
  // ballpark for our content (50dp artwork + padding + 2-line text).
  // Off-by-a-few pixels per row is fine; we use animateTo which feels
  // smooth even with imperfect target positions.
  static const double _kRowHeight = 76.0;
  final ScrollController _scrollController = ScrollController();
  // Tracks whether the currently-playing row is in the visible viewport.
  // Drives the sticky "Jump to current" pill — pill appears only when
  // the user has scrolled away from the playing track.
  bool _isCurrentVisible = true;
  int _lastSeenCurrentIndex = -1;

  // Station mode: when a live station is playing, this screen shows the
  // station's "previously played" history instead of the (meaningless,
  // single-entry) queue. Same entry points, swapped content.
  List<Map<String, dynamic>>? _stationHistory;
  bool _stationHistoryLoading = false;
  Timer? _stationRefreshTimer;

  bool get _isStationMode =>
      widget.audioPlayerService.currentSong?.isStation == true;

  @override
  void initState() {
    super.initState();

    // Listen to player state changes to update UI
    widget.audioPlayerService.addListener(_onPlayerStateChanged);
    _scrollController.addListener(_onScroll);

    if (_isStationMode) {
      _loadStationHistory();
      // The backend caches for 30s, so a 30s tick tracks the station at
      // (roughly) track-change granularity without hammering anything.
      _stationRefreshTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => _loadStationHistory(),
      );
    } else {
      // On open: scroll to put the current track near the top with a
      // bit of leading context (1-2 played tracks visible above).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToCurrent(animate: false);
      });
    }
  }

  // ── Party mode (host controls) ───────────────────────────────────
  Future<void> _onPartyPressed() async {
    final svc = widget.audioPlayerService;
    if (!svc.partyActive) {
      final ok = await svc.startParty();
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not start the party — is the server up?'),
        ));
        return;
      }
    }
    if (mounted) _showPartyDialog();
  }

  void _showPartyDialog() {
    final svc = widget.audioPlayerService;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF0d1b2a),
        title: const Row(
          children: [
            Icon(Icons.celebration, color: Color(0xFF00d4ff)),
            SizedBox(width: 8),
            Text('Party Mode', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (svc.partyQrUrl != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  svc.partyQrUrl!,
                  width: 220,
                  height: 220,
                  errorBuilder: (_, __, ___) => const SizedBox(
                    width: 220,
                    height: 220,
                    child: Center(
                      child: Text('QR unavailable',
                          style: TextStyle(color: Colors.white54)),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            const Text('Guests scan to search your library\nand add songs to the queue.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 8),
            Text(
              svc.partyCode ?? '',
              style: const TextStyle(
                color: Color(0xFF00d4ff),
                fontWeight: FontWeight.bold,
                fontSize: 24,
                letterSpacing: 4,
              ),
            ),
            if (svc.isCasting)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('QR is also showing on the TV',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await svc.endParty();
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('End Party',
                style: TextStyle(color: Colors.redAccent)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00d4ff)),
            child: const Text('Keep Partying',
                style: TextStyle(color: Color(0xFF0d1b2a))),
          ),
        ],
      ),
    );
  }

  Future<void> _loadStationHistory() async {
    final song = widget.audioPlayerService.currentSong;
    if (song == null || !song.isStation) return;
    if (_stationHistory == null) {
      setState(() => _stationHistoryLoading = true);
    }
    // Station Song ids are the negated station DB id.
    final rows = await _apiService.getStationRecentlyPlayed(-song.id);
    if (!mounted) return;
    setState(() {
      _stationHistory = rows;
      _stationHistoryLoading = false;
    });
  }

  void _onPlayerStateChanged() {
    if (!mounted) return;
    final newIndex = widget.audioPlayerService.currentIndex;
    // If the playing track changed AND the user hasn't scrolled away
    // from where it was (i.e. they were following along), auto-scroll
    // to follow the new one. Skip if user has scrolled to inspect
    // history/upcoming — don't fight them.
    if (newIndex != _lastSeenCurrentIndex) {
      _lastSeenCurrentIndex = newIndex;
      if (_isCurrentVisible) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToCurrent(animate: true);
        });
      }
    }
    setState(() {});
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final currentIndex = widget.audioPlayerService.currentIndex;
    if (currentIndex < 0) return;
    final targetOffset = currentIndex * _kRowHeight;
    final visibleStart = _scrollController.offset;
    final visibleEnd = visibleStart + _scrollController.position.viewportDimension;
    // Consider it visible if any part of the row would be on screen.
    final nowVisible = targetOffset + _kRowHeight >= visibleStart &&
        targetOffset <= visibleEnd;
    if (nowVisible != _isCurrentVisible) {
      setState(() => _isCurrentVisible = nowVisible);
    }
  }

  Future<void> _scrollToCurrent({bool animate = true}) async {
    if (!_scrollController.hasClients) return;
    final currentIndex = widget.audioPlayerService.currentIndex;
    if (currentIndex < 0) return;
    // Land the current row roughly 1 row down from the top so the user
    // sees a bit of "what just played" above it for context.
    final target = ((currentIndex - 1).clamp(0, 100000)) * _kRowHeight;
    final clamped = target.clamp(0.0, _scrollController.position.maxScrollExtent);
    if (animate) {
      await _scrollController.animateTo(
        clamped,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scrollController.jumpTo(clamped);
    }
    if (mounted) setState(() => _isCurrentVisible = true);
  }

  @override
  void dispose() {
    _stationRefreshTimer?.cancel();
    widget.audioPlayerService.removeListener(_onPlayerStateChanged);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _playSongAtIndex(int index) {
    widget.audioPlayerService.playFromQueue(index);
    NowPlayingScreen.open(
      context,
      audioPlayerService: widget.audioPlayerService,
    );
  }

  /// "x min ago" for a history row's ISO-8601 played_at (UTC).
  String _relativeTime(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final t = DateTime.tryParse(iso);
    if (t == null) return '';
    final diff = DateTime.now().toUtc().difference(t.toUtc());
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) {
      return '${diff.inHours} hr ${diff.inMinutes % 60} min ago';
    }
    return '${diff.inDays} d ago';
  }

  Future<void> _playLibraryMatch(int songId) async {
    try {
      final data = await _apiService.getSongDetails(songId);
      final song = Song.fromJson(data);
      await widget.audioPlayerService.playSong(song);
      if (!mounted) return;
      NowPlayingScreen.open(
        context,
        audioPlayerService: widget.audioPlayerService,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn\'t play that track')),
      );
    }
  }

  /// Options sheet for a history track that isn't in the library:
  /// hunt it down on Prowlarr (in-app) or YouTube (browser search).
  void _showFindOptions(Map<String, dynamic> row) {
    final title = (row['title'] as String?) ?? '';
    final artist = (row['artist'] as String?) ?? '';
    final query = [artist, title].where((s) => s.isNotEmpty).join(' ');

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1a2332),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          // Keep the actions clear of the Android system navbar.
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetContext).padding.bottom + 8,
            top: 8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  artist.isNotEmpty ? artist : 'Not in your library',
                  style: const TextStyle(color: Colors.grey),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Divider(height: 1, color: Colors.white12),
              ListTile(
                leading:
                    const Icon(Icons.travel_explore, color: Color(0xFF00d4ff)),
                title: const Text('Search on Prowlarr',
                    style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => ProwlarrSearchScreen(
                        audioPlayerService: widget.audioPlayerService,
                        initialQuery: query,
                      ),
                    ),
                  );
                },
              ),
              ListTile(
                leading:
                    const Icon(Icons.play_circle_outline, color: Colors.red),
                title: const Text('Search on YouTube',
                    style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  launchUrl(
                    Uri.parse(
                      'https://www.youtube.com/results?search_query=${Uri.encodeComponent(query)}',
                    ),
                    mode: LaunchMode.externalApplication,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStationHistory() {
    if (_stationHistoryLoading && _stationHistory == null) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF00d4ff)),
      );
    }
    final rows = _stationHistory ?? const [];
    if (rows.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.history, size: 80, color: Colors.grey),
            SizedBox(height: 16),
            Text(
              'No play history',
              style: TextStyle(fontSize: 18, color: Colors.grey),
            ),
            SizedBox(height: 8),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                'This station doesn\'t publish its play history',
                style: TextStyle(fontSize: 14, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      color: const Color(0xFF00d4ff),
      onRefresh: _loadStationHistory,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: rows.length,
        itemBuilder: (context, index) {
          final row = rows[index];
          final songId = row['song_id'] as int?;
          final inLibrary = songId != null;
          final artworkUrl = row['artwork_url'] as String?;
          final artist = (row['artist'] as String?) ?? '';
          final when = _relativeTime(row['played_at'] as String?);

          return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: artworkUrl != null && artworkUrl.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: artworkUrl,
                      width: 50,
                      height: 50,
                      fit: BoxFit.cover,
                      placeholder: (context, url) => Container(
                        width: 50,
                        height: 50,
                        color: const Color(0xFF1a2332),
                      ),
                      errorWidget: (context, url, error) => Container(
                        width: 50,
                        height: 50,
                        color: const Color(0xFF0d1b2a),
                        child: const Icon(Icons.radio,
                            color: Color(0xFF00d4ff), size: 24),
                      ),
                    )
                  : Container(
                      width: 50,
                      height: 50,
                      color: const Color(0xFF0d1b2a),
                      child: const Icon(Icons.radio,
                          color: Color(0xFF00d4ff), size: 24),
                    ),
            ),
            title: Text(
              (row['title'] as String?) ?? '',
              style: const TextStyle(color: Colors.white),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              when.isNotEmpty && artist.isNotEmpty
                  ? '$artist • $when'
                  : (artist.isNotEmpty ? artist : when),
              style: const TextStyle(
                color: Colors.grey,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: inLibrary
                ? const Icon(Icons.library_add_check,
                    color: Color(0xFF00d4ff), size: 22)
                : const Icon(Icons.search, color: Colors.white38, size: 20),
            onTap: () =>
                inLibrary ? _playLibraryMatch(songId) : _showFindOptions(row),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.audioPlayerService,
      builder: (context, child) {
        final queue = widget.audioPlayerService.queue;
        final currentIndex = widget.audioPlayerService.currentIndex;
        final isStationMode = _isStationMode;

        return MouseBackButtonWrapper(
          child: Scaffold(
            appBar: AppBar(
              title: Text(isStationMode ? 'Previously Played' : 'Queue'),
              backgroundColor: const Color(0xFF0d1b2a),
              actions: [
                if (!isStationMode)
                  IconButton(
                    icon: Icon(
                      Icons.celebration,
                      color: widget.audioPlayerService.partyActive
                          ? const Color(0xFF00d4ff)
                          : null,
                    ),
                    tooltip: widget.audioPlayerService.partyActive
                        ? 'Party mode (active)'
                        : 'Start party mode',
                    onPressed: _onPartyPressed,
                  ),
                if (isStationMode)
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Refresh history',
                    onPressed: _loadStationHistory,
                  ),
                if (!isStationMode && queue.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.clear_all),
                    tooltip: 'Clear Queue',
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Clear Queue'),
                          content: const Text(
                            'Are you sure you want to clear the queue and stop playback?',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Cancel'),
                            ),
                            ElevatedButton(
                              onPressed: () {
                                widget.audioPlayerService.clearQueue();
                                Navigator.pop(context); // Close dialog
                                Navigator.pop(context); // Close queue screen
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.red,
                                foregroundColor: Colors.white,
                              ),
                              child: const Text('Clear'),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
              ],
            ),
            body: isStationMode
                ? _buildStationHistory()
                : queue.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.queue_music, size: 80, color: Colors.grey),
                        SizedBox(height: 16),
                        Text(
                          'Queue is empty',
                          style: TextStyle(fontSize: 18, color: Colors.grey),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Play some music to see your queue',
                          style: TextStyle(fontSize: 14, color: Colors.grey),
                        ),
                      ],
                    ),
                  )
                : Stack(
                    children: [
                      ReorderableListView.builder(
                    scrollController: _scrollController,
                    // Disable the auto-appended drag handle. It was being
                    // placed by the framework at the trailing edge, where
                    // it visually collided with our explicit Delete icon
                    // in the ListTile's trailing slot. We now add an
                    // explicit handle ourselves so spacing is under our
                    // control.
                    buildDefaultDragHandles: false,
                    itemCount: queue.length,
                    onReorder: (oldIndex, newIndex) {
                      widget.audioPlayerService.reorderQueue(
                        oldIndex,
                        newIndex,
                      );
                    },
                    itemBuilder: (context, index) {
                      final song = queue[index];
                      final isCurrentSong = index == currentIndex;
                      // Tracks before the playing one are "history".
                      // Dim them so the user can visually scan
                      // played -> current -> upcoming as a gradient
                      // through the list.
                      final isPlayed = index < currentIndex;

                      return Opacity(
                        key: ValueKey(song.id),
                        opacity: isPlayed ? 0.55 : 1.0,
                        child: Container(
                        color: isCurrentSong
                            ? const Color(0xFF00d4ff).withOpacity(0.15)
                            : null,
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 4,
                          ),
                          leading: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Index or playing indicator
                              SizedBox(
                                width: 32,
                                child: isCurrentSong
                                    ? const Icon(
                                        Icons.play_arrow,
                                        color: Color(0xFF00d4ff),
                                        size: 24,
                                      )
                                    : Text(
                                        '${index + 1}',
                                        style: const TextStyle(
                                          fontSize: 14,
                                          color: Colors.grey,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                              ),
                              const SizedBox(width: 8),
                              // Album artwork
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: CachedNetworkImage(
                                  imageUrl: song.albumId < 0 && widget.audioPlayerService.podcastArtworkUrl != null
                                      ? widget.audioPlayerService.podcastArtworkUrl!
                                      : _apiService.getArtworkUrl(song.albumId),
                                  width: 50,
                                  height: 50,
                                  fit: BoxFit.cover,
                                  placeholder: (context, url) => Container(
                                    width: 50,
                                    height: 50,
                                    color: const Color(0xFF1a2332),
                                  ),
                                  errorWidget: (context, url, error) =>
                                      Container(
                                        width: 50,
                                        height: 50,
                                        color: const Color(0xFF0d1b2a),
                                        child: Icon(
                                          song.albumId < 0 ? Icons.podcasts : Icons.music_note,
                                          color: song.albumId < 0 ? Colors.orange : const Color(0xFF00d4ff),
                                          size: 24,
                                        ),
                                      ),
                                ),
                              ),
                            ],
                          ),
                          title: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  song.displayTitle,
                                  style: TextStyle(
                                    color: isCurrentSong
                                        ? const Color(0xFF00d4ff)
                                        : Colors.white,
                                    fontWeight: isCurrentSong
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                  ),
                                ),
                              ),
                              if (song.isExplicit) ...[                                const SizedBox(width: 6),
                                const ExplicitBadge(fontSize: 10),
                              ],
                              if (song.isAtmos || song.isSurround) ...[
                                const SizedBox(width: 6),
                                SpatialBadge(song: song, fontSize: 10),
                              ],
                              if (song.isHdcd) ...[
                                const SizedBox(width: 6),
                                const HdcdBadge(fontSize: 10),
                              ],
                            ],
                          ),
                          subtitle: Builder(builder: (context) {
                            final artistLine = song.artists.isNotEmpty
                                ? song.artists.map((a) => a.name).join(', ')
                                : song.artistName;
                            // Party attribution: "· added by Kayla"
                            final guest = widget.audioPlayerService
                                .partyAttributionFor(song.id);
                            return Text(
                              guest != null
                                  ? '$artistLine · added by $guest'
                                  : artistLine,
                              style: TextStyle(
                                color: guest != null
                                    ? const Color(0xFF00d4ff)
                                    : Colors.grey,
                                fontWeight: FontWeight.w500,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            );
                          }),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                song.durationFormatted,
                                style: const TextStyle(color: Colors.grey),
                              ),
                              // Only show delete button if not currently playing
                              if (!isCurrentSong) ...[
                                const SizedBox(width: 12),
                                SizedBox(
                                  width: 36,
                                  height: 36,
                                  child: IconButton(
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      size: 20,
                                    ),
                                    color: Colors.red.withOpacity(0.7),
                                    onPressed: () {
                                      widget.audioPlayerService
                                          .removeFromQueue(index);
                                    },
                                  ),
                                ),
                              ],
                              const SizedBox(width: 8),
                              // Explicit drag handle so spacing vs. the
                              // delete icon is under our control. Wrapping
                              // in ReorderableDragStartListener makes only
                              // this widget initiate the drag, instead of
                              // the whole tile.
                              ReorderableDragStartListener(
                                index: index,
                                child: const SizedBox(
                                  width: 36,
                                  height: 36,
                                  child: Icon(
                                    Icons.drag_handle,
                                    color: Colors.white38,
                                    size: 22,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          onTap: () => _playSongAtIndex(index),
                        ),
                      ),
                      );
                    },
                  ),
                      // Sticky "Jump to current track" pill — slides in
                      // at the top of the list when the playing row is
                      // off-screen. Tapping smooth-scrolls back to it.
                      if (!_isCurrentVisible && currentIndex >= 0)
                        Positioned(
                          top: 8,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(20),
                                onTap: () => _scrollToCurrent(animate: true),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF00d4ff),
                                    borderRadius: BorderRadius.circular(20),
                                    boxShadow: const [
                                      BoxShadow(
                                        color: Color(0x66000000),
                                        blurRadius: 8,
                                        offset: Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.graphic_eq,
                                        size: 18,
                                        color: Colors.black,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        currentIndex < queue.length
                                            ? 'Jump to: ${queue[currentIndex].displayTitle}'
                                            : 'Jump to current',
                                        style: const TextStyle(
                                          color: Colors.black,
                                          fontWeight: FontWeight.w600,
                                          fontSize: 13,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        );
      },
    );
  }
}
