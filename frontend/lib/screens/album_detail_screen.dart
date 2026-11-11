import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';
import '../models/album.dart';
import '../models/song.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import 'now_playing_screen.dart';
import 'album_images_screen.dart';
import 'artist_detail_screen.dart';
import '../widgets/music_context_menu.dart';
import '../widgets/favorite_button.dart';
import '../widgets/mouse_back_button_wrapper.dart';
import '../widgets/breadcrumb_bar.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../widgets/explicit_badge.dart';
import '../widgets/hdcd_badge.dart';
import '../widgets/surround_badge.dart';
import '../widgets/design_system.dart';
import '../widgets/image_zoom.dart';
import '../layout_context.dart';
import '../widgets/download_button.dart';
import '../widgets/editions_row.dart';

class AlbumDetailScreen extends StatefulWidget {
  final int albumId;
  final AudioPlayerService audioPlayerService;
  final String? artistName; // For breadcrumb display
  final int? artistId; // For breadcrumb navigation
  final String? parentLabel; // e.g., "Library" or "Search"

  const AlbumDetailScreen({
    super.key,
    required this.albumId,
    required this.audioPlayerService,
    this.artistName,
    this.artistId,
    this.parentLabel,
  });

  @override
  State<AlbumDetailScreen> createState() => _AlbumDetailScreenState();
}

class _AlbumDetailScreenState extends State<AlbumDetailScreen> {
  final ApiService _apiService = ApiService();
  final ScrollController _scrollController = ScrollController();
  Album? _album;
  List<Song> _songs = [];
  // Sibling editions of this album's group (empty = ungrouped).
  List<Map<String, dynamic>> _editions = [];
  // The edition on screen. Starts as widget.albumId; edition chips swap it
  // IN PLACE (no new route), so every per-album call reads this instead.
  late int _albumId;
  // Edition group (null = ungrouped): its title and original year head the
  // page whichever edition is showing.
  int? _groupId;
  String? _groupTitle;
  int? _groupYear;
  // True while a chip-picked edition loads; dims the tracklist.
  bool _swappingEdition = false;
  // Images/booklets in the album folder (scans, back cover, photos).
  List<Map<String, dynamic>> _albumImages = [];
  Map<int, String> _discNames = {};
  bool _isLoading = true;
  String? _error;
  int _artworkCacheKey = 0;
  bool _isSelectMode = false;
  final Set<int> _selectedSongIds = {};
  // Dominant color sampled from the album artwork. Drives the
  // GradientBackdrop behind the hero so the page color echoes the
  // cover instead of being a flat dark slab. Null until extraction
  // completes; the backdrop falls back to a neutral gray in that
  // window so the UI doesn't flash.
  Color? _dominantColor;

  // Listen to current song changes
  VoidCallback? _playerListener;

  @override
  void initState() {
    super.initState();
    _albumId = widget.albumId;
    _loadAlbum();

    // Listen for player state changes to update highlighting: only when the
    // song or play state changes. This page stays mounted under other pages
    // and below Now Playing, and used to rebuild whole on every 250 ms tick.
    Object? shownState;
    _playerListener = () {
      final s = widget.audioPlayerService;
      final shown = (s.currentSong?.id, s.isPlaying, s.isLoading);
      if (shown == shownState) return;
      shownState = shown;
      if (mounted) setState(() {});
    };
    widget.audioPlayerService.addListener(_playerListener!);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    if (_playerListener != null) {
      widget.audioPlayerService.removeListener(_playerListener!);
    }
    super.dispose();
  }

  /// Artist breadcrumb: pop back to the artist page when it is on this
  /// section's stack (Library → Artist → Album), otherwise open it on top
  /// (Search → Album → tap the artist). Never a blind single pop.
  void _goToArtistCrumb() {
    final artistId = widget.artistId ?? _album?.artistId;
    if (artistId == null) {
      Navigator.pop(context);
      return;
    }
    if (ArtistDetailScreen.isOnStack(context, artistId)) {
      Navigator.popUntil(
        context,
        (r) => r.isFirst || ArtistDetailScreen.liveRoutes[r] == artistId,
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ArtistDetailScreen(
          artistId: artistId,
          audioPlayerService: widget.audioPlayerService,
          parentLabel: widget.parentLabel,
        ),
      ),
    );
  }

  Future<void> _extractAlbumDominantColor() async {
    if (_album == null) return;
    if (_album!.artworkPath == null || _album!.artworkPath!.isEmpty) return;
    final url = _apiService.getArtworkUrl(
      _album!.id,
      cacheBuster: _artworkCacheKey,
    );
    final color = await extractDominantColor(CachedNetworkImageProvider(url));
    if (!mounted || color == null) return;
    setState(() => _dominantColor = color);
  }

  // Sum of all track durations in seconds. Used for the metadata
  // strip ("12 songs · 47 min"). Returns 0 if the album hasn't
  // finished loading or has no tracks yet.
  int get _totalDurationSeconds {
    int total = 0;
    for (final s in _songs) {
      total += s.duration;
    }
    return total;
  }

  String _formatTotalDuration(int seconds) {
    if (seconds <= 0) return '';
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    if (hours > 0) {
      return '$hours hr ${minutes} min';
    }
    return '$minutes min';
  }

  /// Edition picker chip (ALBUM_EDITIONS_SPEC.md §4) — one chip per
  /// sibling edition in this album's group. The label is the edition
  /// ("2025 Remaster"), the icon its format (stereo vs surround/Atmos).
  /// Tapping swaps the edition in place.
  Widget _editionChip(Map<String, dynamic> e) {
    final isCurrent = e['id'] == _albumId;
    final label =
        (e['edition_label'] as String?) ??
        ((e['has_atmos'] == 1)
            ? 'Dolby Atmos'
            : ((e['max_channels'] ?? 2) > 2 ? 'Surround' : 'Stereo'));
    final spatial = e['has_atmos'] == 1 || (e['max_channels'] ?? 2) > 2;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: isCurrent ? null : () => _switchEdition(e['id'] as int),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        decoration: BoxDecoration(
          color: isCurrent
              ? const Color(0xFF00d4ff).withOpacity(0.18)
              : Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isCurrent
                ? const Color(0xFF00d4ff)
                : Colors.white.withOpacity(0.15),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              spatial ? Icons.surround_sound : Icons.graphic_eq,
              size: 13,
              color: isCurrent ? const Color(0xFF00d4ff) : Colors.white54,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
                color: isCurrent ? const Color(0xFF00d4ff) : Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Chip tap: swap this page to another edition IN PLACE (no new route,
  /// so Back still returns to wherever the user came from) and remember the
  /// pick so the group's card opens to it next time.
  void _switchEdition(int albumId) {
    if (albumId == _albumId) return;
    setState(() {
      _albumId = albumId;
      _swappingEdition = true;
      _isSelectMode = false;
      _selectedSongIds.clear();
    });
    _loadAlbum(editionSwap: true);
    final groupId = _groupId;
    if (groupId != null) {
      _apiService.setPreferredEdition(groupId, albumId).catchError((_) {});
    }
  }

  // The album's name: the group title for an edition group (the edition
  // itself is named by the selected chip), else the album's own title.
  String get _displayTitle => (_groupTitle ?? _album?.title ?? '').trim();

  // "1985", or "1985 · 2025 edition" when the edition on screen came out
  // later than the album itself.
  String get _yearLabel {
    final editionYear = (_album?.year ?? 0) > 0 ? _album!.year : null;
    final albumYear = _groupYear ?? editionYear;
    if (albumYear == null) return 'Unknown year';
    if (editionYear != null && editionYear != albumYear) {
      return '$albumYear · $editionYear edition';
    }
    return '$albumYear';
  }

  // Long titles step down a size and wrap (up to 3 lines) instead of
  // being cut off after 2.
  TextStyle get _titleStyle {
    final n = _displayTitle.length;
    return TextStyle(
      fontSize: n <= 22 ? 34 : (n <= 40 ? 28 : 24),
      fontWeight: FontWeight.w800,
      color: Colors.white,
      letterSpacing: -0.5,
      height: 1.05,
    );
  }

  // Height of the hero's bottom info band (category label, title row,
  // artist, meta strip, edition chips), measured rather than guessed so the
  // hero always has room for it below the cover. A fixed allowance let a
  // two-line title + chips ride up over the bottom of the cover.
  double _heroInfoHeight(double bandWidth) {
    final scaler = MediaQuery.textScalerOf(context);
    final title = TextPainter(
      text: TextSpan(text: _displayTitle, style: _titleStyle),
      maxLines: 3,
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout(maxWidth: (bandWidth - 96).clamp(120.0, double.infinity));
    // The title row is at least as tall as the favorite / menu buttons.
    final titleRow = title.height < 48 ? 48.0 : title.height;
    var h = scaler.scale(16) + 6 + titleRow + 10 + scaler.scale(24) + 8 +
        scaler.scale(24) + 16;
    if (_editions.length > 1) h += 10 + 30;
    return h + 8;
  }

  Future<void> _loadAlbum({bool editionSwap = false}) async {
    // A full (re)load clears the image cache to force fresh artwork. An
    // edition swap keeps it and precaches the new cover below instead, so
    // the hero never flashes blank mid-swap.
    if (!editionSwap) {
      imageCache.clear();
      imageCache.clearLiveImages();
      _artworkCacheKey = DateTime.now().millisecondsSinceEpoch;
    }
    final requestedId = _albumId;

    try {
      final data = await _apiService.getAlbum(requestedId);
      final art = data['artwork_path'] as String?;
      if (editionSwap && mounted && art != null && art.isNotEmpty) {
        try {
          await precacheImage(
            CachedNetworkImageProvider(
              _apiService.getArtworkUrl(
                requestedId,
                cacheBuster: _artworkCacheKey,
              ),
            ),
            context,
          );
        } catch (_) {}
      }

      // setState-after-dispose guard: see favorite_button.dart for the
      // pattern. Caught a 2026-05-23 crash. The await above can outlive
      // the widget if the user navigates away mid-fetch. A newer chip tap
      // also supersedes this load.
      if (!mounted || requestedId != _albumId) return;
      setState(() {
        _album = Album.fromJson(data);
        _editions = List<Map<String, dynamic>>.from(
          data['editions'] ?? const [],
        );
        _groupId = data['group_id'] as int?;
        _groupTitle = data['group_title'] as String?;
        _groupYear = data['group_year'] as int?;
        _swappingEdition = false;

        // Manually add artist_name and album_title to each song
        final songsData = data['songs'] as List;
        _songs = songsData.map((json) {
          if (json['linked'] == true) {
            // Album reference: the song lives on another album. Keep its
            // home album + real artist (that's the file that plays).
            final artists = json['artists'] as List?;
            json['artist_name'] = (artists != null && artists.isNotEmpty)
                ? artists.first['name']
                : data['artist_name'];
            json['album_title'] = json['home_album_title'] ?? data['title'];
          } else {
            json['artist_name'] = data['artist_name'];
            json['album_title'] = data['title'];
          }
          return Song.fromJson(json);
        }).toList();

        // Load disc names if available
        if (data['disc_names'] != null) {
          final discNamesData = data['disc_names'] as Map<String, dynamic>;
          _discNames = discNamesData.map(
            (k, v) => MapEntry(int.parse(k), v as String),
          );
        } else {
          _discNames = {};
        }

        _isLoading = false;
      });
      _apiService.getAlbumImages(_albumId).then((imgs) {
        if (mounted) setState(() => _albumImages = imgs);
      }).catchError((_) {});
      // Kick off dominant color extraction in the background — drives
      // the GradientBackdrop on the hero. Not awaited; the UI renders
      // immediately with a neutral fallback and re-paints when the
      // color arrives. Best-effort; failure is invisible.
      _extractAlbumDominantColor();
    } catch (e) {
      if (!mounted) return;
      if (editionSwap && _album != null) {
        // Keep showing the edition we had; just say the swap failed.
        setState(() {
          _albumId = _album!.id;
          _swappingEdition = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't load that edition")),
        );
        return;
      }
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _shufflePlayAlbum() {
    if (_songs.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No songs to play')));
      return;
    }

    // Pick a random starting song
    final randomIndex = (List.generate(
      _songs.length,
      (i) => i,
    )..shuffle()).first;

    // Set queue with ORIGINAL order, starting at random song
    widget.audioPlayerService.setQueue(
      _songs,
      randomIndex,
      sourceType: 'album',
      sourceId: _albumId,
      sourceName: _album?.title,
    );
    if (!widget.audioPlayerService.isShuffled) {
      widget.audioPlayerService.toggleShuffle();
    }

    NowPlayingScreen.open(
      context,
      audioPlayerService: widget.audioPlayerService,
    );
  }

  void _playAlbum() {
    if (_songs.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No songs to play')));
      return;
    }

    widget.audioPlayerService.setQueue(
      _songs,
      0,
      sourceType: 'album',
      sourceId: _albumId,
      sourceName: _album?.title,
    );

    NowPlayingScreen.open(
      context,
      audioPlayerService: widget.audioPlayerService,
    );
  }

  Future<void> _splitBoxSet() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1b2838),
        title: const Text('Split Box Set?'),
        content: Text(
          'This will split "${_album!.title}" back into ${_discNames.length} separate albums:\n\n'
          '${_discNames.entries.map((e) => '• ${e.value}').join('\n')}\n\n'
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
            ),
            child: const Text('Split'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _apiService.splitBoxSet(_albumId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Split into ${_discNames.length} albums'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context); // Go back since this album is now different
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error splitting box set: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _playSong(Song song, int index) {
    widget.audioPlayerService.setQueue(
      _songs,
      index,
      sourceType: 'album',
      sourceId: _albumId,
      sourceName: _album?.title,
    );
    NowPlayingScreen.open(
      context,
      audioPlayerService: widget.audioPlayerService,
    );
  }

  List<Map<String, dynamic>> _buildDiscList() {
    final List<Map<String, dynamic>> items = [];

    // Group songs by disc number
    final discGroups = <int, List<Song>>{};
    for (var song in _songs) {
      discGroups.putIfAbsent(song.discNumber, () => []).add(song);
    }

    // Sort disc numbers
    final sortedDiscs = discGroups.keys.toList()..sort();

    // Build list with headers
    for (var discNumber in sortedDiscs) {
      // Only show disc header if there are multiple discs
      if (sortedDiscs.length > 1) {
        final discName = _discNames[discNumber];
        final title = discName != null
            ? 'Disc $discNumber - $discName'
            : 'Disc $discNumber';
        items.add({'type': 'header', 'title': title, 'discNumber': discNumber});
      }

      // Add songs for this disc
      final discSongs = discGroups[discNumber]!;
      for (var song in discSongs) {
        items.add({
          'type': 'song',
          'song': song,
          'songIndex': _songs.indexOf(song),
        });
      }
    }

    return items;
  }

  Future<void> _stripAlbumVersion() async {
    // Count how many songs will be affected
    final affectedSongs = _songs
        .where((s) => s.title.contains('Album Version'))
        .length;

    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Strip Album Version Tags'),
        content: Text(
          'This will remove "(Album Version)" and "(Original Album Version)" '
          'from $affectedSongs song titles.\n\nThis cannot be undone.\n\nContinue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
            ),
            child: const Text('Strip Tags'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final result = await _apiService.stripAlbumVersion(_album!.id);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result['message']),
            backgroundColor: Colors.green,
          ),
        );

        // Reload album to show updated titles
        _loadAlbum();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _deleteSelectedSongs() async {
    if (_selectedSongIds.isEmpty) return;

    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Selected Songs'),
        content: Text(
          'Are you sure you want to delete ${_selectedSongIds.length} songs from the database?\n\nThe files will remain on disk.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      // Delete each selected song
      for (final songId in _selectedSongIds) {
        await _apiService.deleteSong(songId);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Deleted ${_selectedSongIds.length} songs from database',
            ),
            backgroundColor: Colors.green,
          ),
        );

        // Exit selection mode and reload
        setState(() {
          _isSelectMode = false;
          _selectedSongIds.clear();
        });
        _loadAlbum();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _changeSelectedArtist() async {
    if (_selectedSongIds.isEmpty) return;

    dynamic selectedArtistId;
    String selectedArtistName = _album!.artistName;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1a2332),
          title: Text('Change Artist for ${_selectedSongIds.length} Tracks'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Current album artist: ${_album!.artistName}',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
                const SizedBox(height: 16),
                _AlbumArtistSearchField(
                  apiService: _apiService,
                  currentArtistId: _album!.artistId,
                  currentArtistName: _album!.artistName,
                  onArtistSelected: (id, name) {
                    setDialogState(() {
                      selectedArtistId = id;
                      selectedArtistName = name ?? _album!.artistName;
                    });
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: selectedArtistId == null
                  ? null
                  : () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00d4ff),
                foregroundColor: Colors.black,
              ),
              child: const Text('Change'),
            ),
          ],
        ),
      ),
    );

    if (result != true || selectedArtistId == null) return;

    try {
      await _apiService.editSongsArtist(
        _selectedSongIds.toList(),
        selectedArtistId,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Changed artist to $selectedArtistName for ${_selectedSongIds.length} tracks',
            ),
            backgroundColor: Colors.green,
          ),
        );
        setState(() {
          _isSelectMode = false;
          _selectedSongIds.clear();
        });
        _loadAlbum();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _showRenumberDialog(int discNumber) async {
    final TextEditingController startController = TextEditingController(
      text: '1',
    );

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Renumber Disc $discNumber Tracks'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'All tracks in this disc will be renumbered sequentially starting from:',
              style: TextStyle(fontSize: 14, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: startController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Start track number',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00d4ff),
              foregroundColor: Colors.black,
            ),
            child: const Text('Renumber'),
          ),
        ],
      ),
    );

    if (result != true) return;

    final startNumber = int.tryParse(startController.text);
    if (startNumber == null || startNumber < 1) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please enter a valid starting number'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    try {
      await _apiService.renumberDiscTracks(
        _albumId,
        discNumber,
        startNumber,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Renumbered Disc $discNumber tracks starting from $startNumber',
            ),
            backgroundColor: Colors.green,
          ),
        );
        _loadAlbum();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ── Album references ────────────────────────────────────────────────
  void _openHomeAlbum(Song song) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => AlbumDetailScreen(
          albumId: song.albumId,
          audioPlayerService: widget.audioPlayerService,
          parentLabel: _album?.title,
        ),
      ),
    );
  }

  Future<void> _showLinkedSongMenu(Song song) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1b2838),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.album, color: Color(0xFF00d4ff)),
              title: const Text('Go to home album',
                  style: TextStyle(color: Colors.white)),
              subtitle: Text(song.homeAlbumTitle ?? '',
                  style: const TextStyle(color: Colors.grey)),
              onTap: () => Navigator.pop(context, 'home'),
            ),
            ListTile(
              leading: const Icon(Icons.link_off, color: Colors.redAccent),
              title: const Text('Unlink from this album',
                  style: TextStyle(color: Colors.white)),
              subtitle: const Text(
                  'The song stays on its home album',
                  style: TextStyle(color: Colors.grey)),
              onTap: () => Navigator.pop(context, 'unlink'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'home') {
      _openHomeAlbum(song);
      return;
    }
    try {
      await _apiService.unlinkAlbumTrack(_albumId, song.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unlinked "${song.title}"')),
      );
      _loadAlbum();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unlink failed: $e')),
      );
    }
  }

  /// First empty track slot on a disc (1, 2, … or one past the end).
  int _firstFreeTrack(int discNumber) {
    final used = _songs
        .where((s) => s.discNumber == discNumber)
        .map((s) => s.trackNumber)
        .toSet();
    var n = 1;
    while (used.contains(n)) {
      n++;
    }
    return n;
  }

  Future<void> _showLinkTrackDialog(int discNumber) async {
    final searchCtrl = TextEditingController();
    final trackCtrl =
        TextEditingController(text: '${_firstFreeTrack(discNumber)}');
    List<Map<String, dynamic>> results = [];
    Map<String, dynamic>? picked;
    bool searching = false;
    Timer? debounce;

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) {
          Future<void> runSearch(String q) async {
            if (q.trim().length < 2) {
              setDialog(() => results = []);
              return;
            }
            setDialog(() => searching = true);
            try {
              final data = await _apiService.search(q.trim());
              final songs = (data['songs'] as List? ?? const [])
                  .cast<Map<String, dynamic>>()
                  .where((m) => m['album_id'] != _albumId)
                  .take(25)
                  .toList();
              setDialog(() => results = songs);
            } catch (_) {
              setDialog(() => results = []);
            } finally {
              setDialog(() => searching = false);
            }
          }

          return AlertDialog(
            backgroundColor: const Color(0xFF1b2838),
            title: Text('Link a track to Disc $discNumber',
                style: const TextStyle(color: Colors.white)),
            content: SizedBox(
              width: 420,
              height: 380,
              child: Column(
                children: [
                  TextField(
                    controller: searchCtrl,
                    autofocus: true,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: 'Search your library…',
                      hintStyle: TextStyle(color: Colors.grey),
                      prefixIcon: Icon(Icons.search, color: Colors.grey),
                    ),
                    onChanged: (q) {
                      debounce?.cancel();
                      debounce = Timer(const Duration(milliseconds: 350),
                          () => runSearch(q));
                    },
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: searching
                        ? const Center(child: CircularProgressIndicator())
                        : ListView.builder(
                            itemCount: results.length,
                            itemBuilder: (context, i) {
                              final m = results[i];
                              final sel = picked?['id'] == m['id'];
                              return ListTile(
                                dense: true,
                                selected: sel,
                                selectedTileColor: const Color(0xFF00d4ff)
                                    .withOpacity(0.15),
                                title: Text(m['title']?.toString() ?? '',
                                    style: const TextStyle(color: Colors.white),
                                    overflow: TextOverflow.ellipsis),
                                subtitle: Text(
                                  '${m['artist_name'] ?? ''} · ${m['album_title'] ?? m['album'] ?? ''}',
                                  style: const TextStyle(color: Colors.grey),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () => setDialog(() => picked = m),
                              );
                            },
                          ),
                  ),
                  Row(
                    children: [
                      const Text('Track #',
                          style: TextStyle(color: Colors.grey)),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 64,
                        child: TextField(
                          controller: trackCtrl,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: picked == null
                    ? null
                    : () => Navigator.pop(context, true),
                child: const Text('Link'),
              ),
            ],
          );
        },
      ),
    );
    debounce?.cancel();
    final track = int.tryParse(trackCtrl.text.trim());
    if (ok != true || picked == null || !mounted) return;
    if (track == null || track < 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Track number must be 1 or more')),
      );
      return;
    }
    try {
      await _apiService.linkAlbumTrack(
        _albumId,
        picked!['id'] as int,
        trackNumber: track,
        discNumber: discNumber,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Linked "${picked!['title']}" as track $track')),
      );
      _loadAlbum();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Link failed: $e')),
      );
    }
  }

  Future<void> _showMoveToPositionDialog(Song song) async {
    final discController = TextEditingController(text: '${song.discNumber}');
    final trackController = TextEditingController();

    final result = await showDialog<Map<String, int>>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: const Text('Move to Position'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: discController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Disc Number',
                border: OutlineInputBorder(),
                hintText: 'e.g. 1 for Side A, 2 for Side B',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: trackController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Track Number',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final discNum = int.tryParse(discController.text);
              final trackNum = int.tryParse(trackController.text);
              if (discNum != null &&
                  discNum > 0 &&
                  trackNum != null &&
                  trackNum > 0) {
                Navigator.pop(context, {'disc': discNum, 'track': trackNum});
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00d4ff),
              foregroundColor: Colors.black,
            ),
            child: const Text('Move'),
          ),
        ],
      ),
    );

    if (result == null) return;

    try {
      if (song.linked) {
        // Linked song: move its slot on THIS album. editSong would rewrite
        // its real track number on its home album.
        await _apiService.linkAlbumTrack(
          _albumId,
          song.id,
          trackNumber: result['track']!,
          discNumber: result['disc'] ?? 1,
        );
      } else {
        await _apiService.editSong(
          song.id,
          trackNumber: result['track'],
          discNumber: result['disc'],
        );
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Moved "${song.title}" to Disc ${result['disc']}, Track ${result['track']}',
            ),
            backgroundColor: Colors.green,
          ),
        );
        _loadAlbum();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _moveSelectedToPosition() async {
    if (_selectedSongIds.isEmpty) return;

    final selectedSongs = _songs
        .where((s) => _selectedSongIds.contains(s.id))
        .toList();

    final discController = TextEditingController(
      text: '${selectedSongs.first.discNumber}',
    );
    final trackController = TextEditingController(text: '1');

    final result = await showDialog<Map<String, int>>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: Text('Move ${selectedSongs.length} Tracks'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Tracks will be numbered sequentially starting from the position you specify.',
              style: TextStyle(color: Colors.grey[400], fontSize: 12),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: discController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Disc Number',
                border: OutlineInputBorder(),
                hintText: 'e.g. 1 for Side A, 2 for Side B',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: trackController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Starting Track Number',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final discNum = int.tryParse(discController.text);
              final trackNum = int.tryParse(trackController.text);
              if (discNum != null &&
                  discNum > 0 &&
                  trackNum != null &&
                  trackNum > 0) {
                Navigator.pop(context, {'disc': discNum, 'track': trackNum});
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00d4ff),
              foregroundColor: Colors.black,
            ),
            child: const Text('Move'),
          ),
        ],
      ),
    );

    if (result == null) return;

    try {
      int trackNum = result['track']!;
      for (final song in selectedSongs) {
        await _apiService.editSong(
          song.id,
          trackNumber: trackNum,
          discNumber: result['disc'],
        );
        trackNum++;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Moved ${selectedSongs.length} tracks to Disc ${result['disc']}',
            ),
            backgroundColor: Colors.green,
          ),
        );
        setState(() {
          _isSelectMode = false;
          _selectedSongIds.clear();
        });
        _loadAlbum();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _showChangeArtistDialog() async {
    dynamic selectedArtistId;
    String selectedArtistName = _album!.artistName;
    bool updateSongArtists = false;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1a2332),
          title: const Text('Change Album Artist'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Current: ${_album!.artistName}',
                  style: const TextStyle(color: Colors.grey, fontSize: 14),
                ),
                const SizedBox(height: 16),
                _AlbumArtistSearchField(
                  apiService: _apiService,
                  currentArtistId: _album!.artistId,
                  currentArtistName: _album!.artistName,
                  onArtistSelected: (id, name) {
                    setDialogState(() {
                      selectedArtistId = id;
                      selectedArtistName = name ?? _album!.artistName;
                    });
                  },
                ),
                const SizedBox(height: 16),
                CheckboxListTile(
                  value: updateSongArtists,
                  onChanged: (v) =>
                      setDialogState(() => updateSongArtists = v ?? false),
                  title: const Text('Also update track artists'),
                  subtitle: const Text(
                    'Change artist for all songs in this album',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  activeColor: const Color(0xFF00d4ff),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: selectedArtistId == null
                  ? null
                  : () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00d4ff),
                foregroundColor: Colors.black,
              ),
              child: const Text('Change'),
            ),
          ],
        ),
      ),
    );

    if (result != true || selectedArtistId == null) return;

    print('=== _showChangeArtistDialog DEBUG ===');
    print('  albumId: ${_album!.id} (${_album!.id.runtimeType})');
    print(
      '  selectedArtistId: $selectedArtistId (${selectedArtistId.runtimeType})',
    );
    print('  updateSongArtists: $updateSongArtists');

    try {
      await _apiService.editAlbumArtist(
        _album!.id,
        selectedArtistId,
        updateSongArtists: updateSongArtists,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Album artist changed to $selectedArtistName'),
            backgroundColor: Colors.green,
          ),
        );
        _loadAlbum();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseBackButtonWrapper(
      child: Scaffold(
        backgroundColor: const Color(0xFF0d1b2a),
        body: Column(
          children: [
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(child: Text('Error: $_error'))
                  : _buildContent(),
            ),
          ],
        ),
        floatingActionButton: _buildJumpToCurrentFAB(),
      ),
    );
  }

  Widget? _buildJumpToCurrentFAB() {
    final currentSong = widget.audioPlayerService.currentSong;
    if (currentSong == null) return null;

    // Check if current song is from this album
    final currentSongIndex = _songs.indexWhere((s) => s.id == currentSong.id);
    if (currentSongIndex == -1) return null;

    return FloatingActionButton.small(
      onPressed: () {
        // Calculate approximate scroll position
        // Header is ~350px, action buttons ~150px, each song row ~56px.
        // Desktop's tracklist scrolls on its own, with nothing above it.
        final headerHeight = _desktopLayout ? 0.0 : 350.0 + 150.0;
        final songHeight = 56.0;
        final targetOffset =
            headerHeight + (currentSongIndex * songHeight) - 100;

        _scrollController.animateTo(
          targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      },
      backgroundColor: const Color(0xFF00d4ff),
      child: const Icon(Icons.my_location, color: Colors.black, size: 20),
    );
  }

  // Album cover with its glow: the cover casts its own dominant color,
  // plus a plain drop shadow so it lifts off the gradient.
  Widget _buildCover(double coverSize) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: (_dominantColor ?? const Color(0xFF00d4ff))
                .withOpacity(0.55),
            blurRadius: 48,
            spreadRadius: 2,
            offset: const Offset(0, 18),
          ),
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: coverSize,
          height: coverSize,
          child:
              _album!.artworkPath != null &&
                  _album!.artworkPath!.isNotEmpty
              ? GestureDetector(
                  onTap: () => showImageZoom(
                    context,
                    imageUrl: _apiService.getArtworkUrl(
                      _album!.id,
                      cacheBuster: _artworkCacheKey,
                    ),
                  ),
                  child: CachedNetworkImage(
                    imageUrl: _apiService.getArtworkUrl(
                      _album!.id,
                      cacheBuster: _artworkCacheKey,
                    ),
                    fit: BoxFit.cover,
                    placeholder: (context, url) =>
                        Container(color: const Color(0xFF1a2332)),
                    errorWidget: (context, url, error) =>
                        Container(
                          color: const Color(0xFF1a2332),
                          child: const Icon(
                            Icons.album,
                            size: 80,
                            color: Color(0xFF00d4ff),
                          ),
                        ),
                  ),
                )
              : Container(
                  color: const Color(0xFF1a2332),
                  child: const Icon(
                    Icons.album,
                    size: 80,
                    color: Color(0xFF00d4ff),
                  ),
                ),
        ),
      ),
    );
  }

  // Category label, title row (favorite + menu), artist, meta strip and
  // edition chips. Bottom band of the phone hero; left column on desktop.
  Widget _buildInfoColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Small "ALBUM" label up top for Spotify-style hierarchy
        Text(
          _album!.category.toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: Colors.white70,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 6),
        // Album title with favorite + menu inline at the right
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                _displayTitle,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: _titleStyle,
              ),
            ),
            FavoriteButton(
              itemType: 'album',
              itemId: _album!.id,
              size: 28,
            ),
            MusicContextMenu(
              itemType: 'album',
              itemId: _album!.id,
              itemName: _album!.title,
              onFavoriteChanged: _loadAlbum,
              onArtworkChanged: _loadAlbum,
              audioPlayerService: widget.audioPlayerService,
            ),
          ],
        ),
        const SizedBox(height: 10),
        // Artist name (tappable, cyan accent)
        GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ArtistDetailScreen(
                  artistId: _album!.artistId,
                  audioPlayerService: widget.audioPlayerService,
                  parentLabel: widget.parentLabel,
                ),
              ),
            );
          },
          child: Text(
            _album!.artistName,
            style: const TextStyle(
              fontSize: 17,
              color: Color(0xFF00d4ff),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 8),
        // Metadata strip: year · song count · total duration
        Wrap(
          spacing: 12,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _MetaChip(
              icon: Icons.calendar_today,
              label: _yearLabel,
            ),
            _MetaChip(
              icon: Icons.queue_music,
              label: '${_songs.length} songs',
            ),
            if (_totalDurationSeconds > 0)
              _MetaChip(
                icon: Icons.schedule,
                label: _formatTotalDuration(
                  _totalDurationSeconds,
                ),
              ),
          ],
        ),
        // Album editions (ALBUM_EDITIONS_SPEC.md §4):
        // this album belongs to a group — offer its
        // sibling editions as a picker. One row that
        // scrolls sideways, so 5+ editions never push the
        // hero taller.
        if (_editions.length > 1) ...[
          const SizedBox(height: 10),
          SizedBox(
            height: 30,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _editions.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(width: 6),
              itemBuilder: (_, i) =>
                  Center(child: _editionChip(_editions[i])),
            ),
          ),
        ],
        // Every edition on MusicBrainz (Atmos, 5.1, SACD...), yours marked.
        const SizedBox(height: 8),
        EditionsRow(
          key: ValueKey('editions_${_album!.id}'),
          albumId: _album!.id,
          artist: _album!.artistName,
          album: _album!.title,
          audioPlayerService: widget.audioPlayerService,
        ),
      ],
    );
  }

  // Play / Shuffle, Images, Select-mode and the album tools.
  Widget _buildActions({
    EdgeInsetsGeometry padding = const EdgeInsets.all(16),
  }) {
    return Padding(
      padding: padding,
      child: Column(
        children: [
          // Play and Shuffle buttons
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _playAlbum,
                  icon: const Icon(Icons.play_arrow, size: 20),
                  label: const Text('Play'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00d4ff),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _shufflePlayAlbum,
                  icon: const Icon(Icons.shuffle, size: 20),
                  label: const Text('Shuffle'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1a2332),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ),
          DownloadButton(kind: 'album', id: _albumId),
          if (_albumImages.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => AlbumImagesScreen(
                      albumId: _albumId,
                      albumTitle: _album?.title ?? 'Album',
                      images: _albumImages,
                    ),
                  ),
                ),
                icon: const Icon(Icons.photo_library_outlined, size: 18),
                label: Text('Images (${_albumImages.length})'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Color(0xFF2a3a4d)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          // Select mode buttons
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  icon: Icon(
                    _isSelectMode ? Icons.close : Icons.checklist,
                    size: 18,
                  ),
                  label: Text(_isSelectMode ? 'Cancel' : 'Select'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isSelectMode
                        ? Colors.grey
                        : const Color(0xFF1a2332),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () {
                    setState(() {
                      _isSelectMode = !_isSelectMode;
                      _selectedSongIds.clear();
                    });
                  },
                ),
              ),
              if (_isSelectMode) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    icon: Icon(
                      _selectedSongIds.length == _songs.length
                          ? Icons.deselect
                          : Icons.select_all,
                      size: 18,
                    ),
                    label: Text(
                      _selectedSongIds.length == _songs.length
                          ? 'Deselect'
                          : 'Select All',
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1a2332),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () {
                      setState(() {
                        if (_selectedSongIds.length == _songs.length) {
                          _selectedSongIds.clear();
                        } else {
                          _selectedSongIds.clear();
                          _selectedSongIds.addAll(
                            _songs.map((s) => s.id),
                          );
                        }
                      });
                    },
                  ),
                ),
              ],
            ],
          ),
          // Action buttons row (separate row to prevent overflow on mobile)
          if (_isSelectMode && _selectedSongIds.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.person_outline, size: 18),
                      label: Text('Artist (${_selectedSongIds.length})'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00d4ff),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                      onPressed: _changeSelectedArtist,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.open_with, size: 18),
                      label: Text('Move (${_selectedSongIds.length})'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00d4ff),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                      onPressed: _moveSelectedToPosition,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: Text('Delete (${_selectedSongIds.length})'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                      onPressed: _deleteSelectedSongs,
                    ),
                  ),
                ],
              ),
            ),
          // Strip Album Version button (only show if any songs have it)
          if (_songs.any((song) => song.title.contains('Album Version')))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.auto_fix_high, size: 18),
                  label: Text(
                    'Strip (Album Version) from ${_songs.where((s) => s.title.contains('Album Version')).length} songs',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: _stripAlbumVersion,
                ),
              ),
            ),
          // Split Box Set button (only for box sets)
          if (_discNames.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.call_split, size: 18),
                  label: Text(
                    'Split Box Set (${_discNames.length} discs)',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepPurple,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: _splitBoxSet,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // The tracklist (disc headers + rows); dims while a chip-picked edition
  // loads.
  Widget _buildTrackListSliver(List<Map<String, dynamic>> discList) {
    return SliverAnimatedOpacity(
      opacity: _swappingEdition ? 0.35 : 1.0,
      duration: const Duration(milliseconds: 180),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate((context, index) {
          final item = discList[index];

          // Disc header
          if (item['type'] == 'header') {
            final discNumber = item['discNumber'] as int;
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Text(
                    item['title'],
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF00d4ff),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(
                      Icons.format_list_numbered,
                      size: 18,
                      color: Colors.grey,
                    ),
                    onPressed: () => _showRenumberDialog(discNumber),
                    tooltip: 'Renumber tracks',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  const SizedBox(width: 12),
                  IconButton(
                    icon: const Icon(
                      Icons.add_link,
                      size: 18,
                      color: Colors.grey,
                    ),
                    onPressed: () => _showLinkTrackDialog(discNumber),
                    tooltip: 'Link a track from another album',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            );
          }

          // Song item
          final song = item['song'] as Song;
          final songIndex = item['songIndex'] as int;
          final isSelected = _selectedSongIds.contains(song.id);

          // Check if this song is currently playing
          final currentSong = widget.audioPlayerService.currentSong;
          final isCurrentlyPlaying = currentSong?.id == song.id;
          final isPlaying =
              isCurrentlyPlaying && widget.audioPlayerService.isPlaying;

          return Container(
            margin: const EdgeInsets.only(
              left: 4,
              right: 0,
              top: 2,
              bottom: 2,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: isCurrentlyPlaying
                  ? const Color(0xFF00d4ff).withOpacity(0.15)
                  : Colors.transparent,
              border: isCurrentlyPlaying
                  ? Border.all(
                      color: const Color(0xFF00d4ff).withOpacity(0.3),
                      width: 1,
                    )
                  : null,
            ),
            child: InkWell(
              onTap: () {
                if (_isSelectMode) {
                  setState(() {
                    if (_selectedSongIds.contains(song.id)) {
                      _selectedSongIds.remove(song.id);
                    } else {
                      _selectedSongIds.add(song.id);
                    }
                  });
                } else {
                  _playSong(song, songIndex);
                }
              },
              onLongPress: song.linked && !_isSelectMode
                  ? () => _showLinkedSongMenu(song)
                  : null,
              child: Padding(
                padding: const EdgeInsets.only(
                  left: 0,
                  right: 0,
                  top: 12,
                  bottom: 12,
                ),
                child: Row(
                  children: [
                    // Leading: checkbox or track number
                    _isSelectMode
                        ? SizedBox(
                            width: 32,
                            child: Checkbox(
                              value: isSelected,
                              onChanged: (bool? value) {
                                setState(() {
                                  if (value == true) {
                                    _selectedSongIds.add(song.id);
                                  } else {
                                    _selectedSongIds.remove(song.id);
                                  }
                                });
                              },
                              activeColor: const Color(0xFF00d4ff),
                            ),
                          )
                        : SizedBox(
                            width: 32,
                            child: isCurrentlyPlaying
                                ? Icon(
                                    isPlaying ? Icons.volume_up : Icons.pause,
                                    color: const Color(0xFF00d4ff),
                                    size: 20,
                                  )
                                : Text(
                                    '${song.trackNumber}',
                                    style: const TextStyle(
                                      fontSize: 16,
                                      color: Colors.grey,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                          ),
                    const SizedBox(width: 8),
                    // Title and subtitle
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            song.title,
                            style: TextStyle(
                              color: isCurrentlyPlaying
                                  ? const Color(0xFF00d4ff)
                                  : Colors.white,
                              fontWeight: isCurrentlyPlaying
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                              fontSize: 16,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (song.linked)
                            GestureDetector(
                              onTap: () => _openHomeAlbum(song),
                              child: Row(
                                children: [
                                  const Icon(Icons.link,
                                      size: 13, color: Color(0xFF00d4ff)),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      _album!.artistName == 'Various Artists'
                                          ? '${song.artistsFormatted} · from ${song.homeAlbumTitle ?? 'another album'}'
                                          : 'from ${song.homeAlbumTitle ?? 'another album'}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: const Color(0xFF00d4ff)
                                            .withOpacity(0.75),
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else if (_album!.artistName == 'Various Artists')
                            Text(
                              song.artistsFormatted,
                              style: TextStyle(
                                fontSize: 12,
                                color: isCurrentlyPlaying
                                    ? const Color(0xFF00d4ff).withOpacity(0.7)
                                    : Colors.grey,
                              ),
                              overflow: TextOverflow.ellipsis,
                            )
                          else if (song.artists.length > 1)
                            Text(
                              'feat. ${song.artists.skip(1).map((a) => a.name).join(', ')}',
                              style: TextStyle(
                                fontSize: 12,
                                color: isCurrentlyPlaying
                                    ? const Color(0xFF00d4ff).withOpacity(0.7)
                                    : Colors.grey,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    // Trailing: format badge, explicit badge, duration, menu
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: song.formatColor.withOpacity(0.2),
                        border: Border.all(color: song.formatColor, width: 1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        song.fileFormat,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: song.formatColor,
                        ),
                      ),
                    ),
                    if (song.isExplicit) ...[
                      const SizedBox(width: 4),
                      const ExplicitBadge(fontSize: 10),
                    ],
                    if (song.isAtmos || song.isSurround) ...[
                      const SizedBox(width: 4),
                      SpatialBadge(song: song, fontSize: 10),
                    ],
                    if (song.isHdcd) ...[
                      const SizedBox(width: 4),
                      const HdcdBadge(fontSize: 10),
                    ],
                    Padding(
                      padding: const EdgeInsets.only(left: 8, right: 4),
                      child: Text(
                        song.durationFormatted,
                        style: TextStyle(
                          color: isCurrentlyPlaying
                              ? const Color(0xFF00d4ff).withOpacity(0.8)
                              : Colors.grey,
                        ),
                      ),
                    ),
                    MusicContextMenu(
                      itemType: 'song',
                      itemId: song.id,
                      itemName: song.title,
                      audioPlayerService: widget.audioPlayerService,
                      onFavoriteChanged: _loadAlbum,
                      onMoveToPosition: () => _showMoveToPositionDialog(song),
                    ),
                    // Extra padding on desktop to avoid scrollbar overlap
                    if (Platform.isWindows ||
                        Platform.isLinux ||
                        Platform.isMacOS)
                      const SizedBox(width: 12),
                  ],
                ),
              ),
            ),
          );
        }, childCount: discList.length),
      ),
    );
  }

  bool get _desktopLayout => LayoutScope.maybeOf(context)?.isDesktop ?? false;

  Widget _buildBreadcrumb() {
    return BreadcrumbBar(
      items: [
        BreadcrumbItem(
          label: widget.parentLabel ?? 'Library',
          // Root of the current section, however deep we are.
          onTap: () => Navigator.popUntil(context, (route) => route.isFirst),
        ),
        if (widget.artistName != null)
          BreadcrumbItem(label: widget.artistName!, onTap: _goToArtistCrumb),
        BreadcrumbItem(label: _displayTitle),
      ],
    );
  }

  /// Desktop album page (DESKTOP_UX_SPEC.md §5 #6): two columns. Cover,
  /// info, edition chips and actions on the left; the tracklist scrolls on
  /// its own on the right, so picking an edition swaps just that column.
  Widget _buildDesktopContent() {
    final discList = _buildDiscList();
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          stops: const [0.0, 0.6],
          colors: [
            Color.lerp(
                  _dominantColor ?? const Color(0xFF1a2332),
                  const Color(0xFF0d1b2a),
                  0.35,
                ) ??
                const Color(0xFF1a2332),
            const Color(0xFF0d1b2a),
          ],
        ),
      ),
      child: Column(
        children: [
          AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            title: _buildBreadcrumb(),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 420,
                  child: SingleChildScrollView(
                    // Let the cover's glow spill past the column edge.
                    clipBehavior: Clip.none,
                    padding: const EdgeInsets.fromLTRB(32, 8, 24, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(child: _buildCover(340)),
                        const SizedBox(height: 32),
                        _buildInfoColumn(),
                        _buildActions(padding: const EdgeInsets.only(top: 20)),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: CustomScrollView(
                    controller: _scrollController,
                    slivers: [
                      const SliverToBoxAdapter(child: SizedBox(height: 8)),
                      _buildTrackListSliver(discList),
                      const SliverToBoxAdapter(child: SizedBox(height: 20)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_desktopLayout) return _buildDesktopContent();
    final discList = _buildDiscList();

    // Cover is much larger on desktop (the 200px version looked tiny
    // dwarfed by a wide banner). Mobile keeps a smaller cover so the
    // hero doesn't eat the whole screen on a phone.
    final bool isMobile = Platform.isAndroid || Platform.isIOS;
    // Cover sits below the status bar + breadcrumb (see the cover's `top`
    // below); the title band is pinned to the hero's bottom. The hero must be
    // tall enough to hold both without them overlapping, so it's deliberately
    // generous here (a shorter hero scrunches the cover onto the title).
    // Mobile: the cover is the hero. Size it off the screen width (~72%)
    // and derive the hero height from it plus the title band, instead of
    // a fixed 175px cover floating in a fixed 500px hero (the "tiny cover
    // in a sea of gradient" look).
    final double screenWidth = MediaQuery.of(context).size.width;
    final double topInset =
        MediaQuery.of(context).padding.top + kToolbarHeight + 8;
    final double coverSize = isMobile
        ? (screenWidth * 0.72).clamp(200.0, 340.0)
        : 260;
    final double bandWidth =
        screenWidth -
        24 -
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS ? 32 : 16);
    final double heroBody =
        topInset + coverSize + 30 + _heroInfoHeight(bandWidth);
    final double heroHeight = isMobile
        ? heroBody
        : (heroBody > 580 ? heroBody : 580);

    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        // App bar with album artwork
        SliverAppBar(
          expandedHeight: heroHeight,
          pinned: true,
          backgroundColor: const Color(0xFF0d1b2a),
          title: _album != null ? _buildBreadcrumb() : null,
          flexibleSpace: FlexibleSpaceBar(
            background: Stack(
              fit: StackFit.expand,
              children: [
                // Dominant-color gradient backdrop (Spotify-pattern hero).
                // Replaces the previous full-bleed BoxFit.cover artwork
                // that center-cropped the cover to a sliver on ultrawide
                // displays. Now the cover sits at native 1:1 on the left
                // (see below) and this gradient fills the rest of the
                // banner with atmosphere echoing the cover.
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color.lerp(
                              _dominantColor ?? const Color(0xFF1a2332),
                              const Color(0xFF0d1b2a),
                              0.35,
                            ) ??
                            const Color(0xFF1a2332),
                        const Color(0xFF0d1b2a),
                      ],
                    ),
                  ),
                ),
                // Soft radial glow from the cover area outward so the
                // dominant color reads more strongly behind the artwork.
                Container(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(0, -0.45),
                      radius: 1.0,
                      colors: [
                        (_dominantColor ?? Colors.transparent).withOpacity(0.5),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
                // Subtle dark gradient at the bottom so the existing
                // title/favorite/menu row (positioned below) remains
                // readable on light dominant colors.
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        const Color(0xFF0d1b2a).withOpacity(0.4),
                        const Color(0xFF0d1b2a),
                      ],
                      stops: const [0.5, 0.85, 1.0],
                    ),
                  ),
                ),
                // Native-aspect album cover, CENTERED horizontally near
                // the top. Full image visible (no crop). Text sits in a
                // band below — mirrors the artist-detail layout that simpson1045
                // liked, instead of the lopsided cover-left/info-right
                // that left a dead zone on the right of ultrawide banners.
                Positioned(
                  // Clear the status-bar inset + the pinned breadcrumb toolbar
                  // so the cover isn't scrunched up underneath them on tall
                  // phones (was a flat top: 24, which sat behind both).
                  top: MediaQuery.of(context).padding.top + kToolbarHeight + 8,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: _buildCover(coverSize),
                  ),
                ),
                // Album info positioned to the right of the cover
                // Album info in a band at the bottom-left, full width,
                // below the centered cover. Left-aligned text like the
                // original layout.
                Positioned(
                  left: 24,
                  right:
                      Platform.isWindows || Platform.isLinux || Platform.isMacOS
                      ? 32
                      : 16,
                  bottom: 16,
                  child: _buildInfoColumn(),
                ),
              ],
            ),
          ),
        ),

        // Action buttons
        SliverToBoxAdapter(
          child: _buildActions(),
        ),

        _buildTrackListSliver(discList),

        // Bottom padding
        const SliverToBoxAdapter(child: SizedBox(height: 20)),
      ],
    );
  }
}

class _AlbumArtistSearchField extends StatefulWidget {
  final ApiService apiService;
  final int currentArtistId;
  final String currentArtistName;
  final Function(dynamic artistId, String? artistName) onArtistSelected;

  const _AlbumArtistSearchField({
    required this.apiService,
    required this.currentArtistId,
    required this.currentArtistName,
    required this.onArtistSelected,
  });

  @override
  State<_AlbumArtistSearchField> createState() =>
      _AlbumArtistSearchFieldState();
}

class _AlbumArtistSearchFieldState extends State<_AlbumArtistSearchField> {
  final TextEditingController _controller = TextEditingController();
  List<Map<String, dynamic>> _searchResults = [];
  bool _isSearching = false;
  bool _showResults = false;

  @override
  void initState() {
    super.initState();
    _controller.text = widget.currentArtistName;
  }

  Future<void> _search(String query) async {
    print('SEARCH CALLED: query="$query", length=${query.length}');
    if (query.length < 2) {
      setState(() {
        _searchResults = [];
        _showResults = false;
      });
      return;
    }

    setState(() => _isSearching = true);

    try {
      final results = await widget.apiService.searchArtists(query);
      if (mounted) {
        setState(() {
          _searchResults = results;
          _showResults = true;
          _isSearching = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSearching = false);
      }
    }
  }

  void _selectArtist(dynamic id, String name) {
    setState(() {
      _controller.text = name;
      _showResults = false;
    });
    widget.onArtistSelected(id, name);
  }

  @override
  Widget build(BuildContext context) {
    final trimmedText = _controller.text.trim();
    final showCreateOption =
        trimmedText.length >= 2 &&
        !_searchResults.any(
          (a) =>
              a['name'].toString().toLowerCase() == trimmedText.toLowerCase(),
        );

    print(
      'DEBUG: trimmedText="$trimmedText", showCreateOption=$showCreateOption, _showResults=$_showResults, searchResults=${_searchResults.length}',
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _controller,
          decoration: InputDecoration(
            labelText: 'Search Artist',
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
            suffixIcon: _isSearching
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : null,
          ),
          onTap: () {
            _controller.selection = TextSelection(
              baseOffset: 0,
              extentOffset: _controller.text.length,
            );
          },
          onChanged: _search,
        ),
        if (_showResults || trimmedText.length >= 2)
          Container(
            constraints: const BoxConstraints(maxHeight: 200),
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF0d1b2a),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.grey.shade700),
            ),
            child: ListView(
              shrinkWrap: true,
              children: [
                if (showCreateOption)
                  ListTile(
                    dense: true,
                    leading: const Icon(
                      Icons.add_circle_outline,
                      color: Color(0xFF00d4ff),
                      size: 20,
                    ),
                    title: Text(
                      'Create "$trimmedText"',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF00d4ff),
                      ),
                    ),
                    onTap: () => _selectArtist('new:$trimmedText', trimmedText),
                  ),
                if (_searchResults.isNotEmpty) const Divider(height: 1),
                ..._searchResults.map(
                  (artist) => ListTile(
                    dense: true,
                    title: Text(
                      artist['name'],
                      style: const TextStyle(fontSize: 13),
                    ),
                    onTap: () => _selectArtist(artist['id'], artist['name']),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

/// Small icon + label chip used in the album hero's metadata strip.
/// Year, song count, total duration each render as a chip so they
/// scan as a row of distinct facts rather than a comma-separated blob.
class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MetaChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: Colors.white60),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            color: Colors.white70,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
