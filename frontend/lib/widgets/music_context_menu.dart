import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:io';
import '../services/api_service.dart';
import 'artwork_picker_dialog.dart';
import 'artist_image_picker_dialog.dart';
import '../services/audio_player_service.dart';
import '../models/song.dart';
import '../models/playlist.dart';
import '../screens/album_detail_screen.dart';
import '../screens/artist_detail_screen.dart';

class MusicContextMenu extends StatefulWidget {
  final String itemType; // 'song', 'album', or 'artist'
  final int itemId;
  final String itemName; // For display in the menu
  final VoidCallback?
  onFavoriteChanged; // Callback when favorite status changes
  final VoidCallback? onArtworkChanged; // Callback when artwork is changed
  final AudioPlayerService? audioPlayerService; // For adding to queue
  final VoidCallback? onMoveToPosition; // Callback for moving track position
  // Playlist-context callbacks: when these are provided, the menu shows
  // the corresponding playlist-specific items. When null, the items are
  // hidden — so the same widget works as the generic song context menu
  // in non-playlist surfaces (album detail, library, search, etc.).
  final VoidCallback? onReplaceSong;
  final VoidCallback? onRemoveFromPlaylist;
  // When provided, overrides the default "navigate to album page" action.
  // Used in surfaces that need custom navigation (e.g. closing a modal
  // first). Otherwise the menu pushes the album screen directly.
  final VoidCallback? onGoToAlbum;
  final VoidCallback? onGoToArtist;
  final bool hasArtistImage; // Whether artist already has an image

  const MusicContextMenu({
    super.key,
    required this.itemType,
    required this.itemId,
    required this.itemName,
    this.onFavoriteChanged,
    this.onArtworkChanged,
    this.audioPlayerService,
    this.onMoveToPosition,
    this.onReplaceSong,
    this.onRemoveFromPlaylist,
    this.onGoToAlbum,
    this.onGoToArtist,
    this.hasArtistImage = false,
  });

  @override
  State<MusicContextMenu> createState() => _MusicContextMenuState();
}

class _MusicContextMenuState extends State<MusicContextMenu> {
  final ApiService _apiService = ApiService();
  bool _isFavorite = false;
  bool _isCheckingFavorite = true;
  final Map<int, List<int>> _playlistAlbumCache = {};

  Future<List<int>> _getPlaylistAlbumIds(int playlistId) async {
    if (_playlistAlbumCache.containsKey(playlistId)) {
      return _playlistAlbumCache[playlistId]!;
    }
    try {
      final data = await _apiService.getPlaylist(playlistId);
      final songs = data['songs'] as List;
      final albumIds = <int>[];
      final seen = <int>{};
      for (final song in songs) {
        final albumId = song['album_id'] as int;
        if (!seen.contains(albumId)) {
          seen.add(albumId);
          albumIds.add(albumId);
          if (albumIds.length >= 4) break;
        }
      }
      _playlistAlbumCache[playlistId] = albumIds;
      return albumIds;
    } catch (e) {
      return [];
    }
  }

  @override
  void initState() {
    super.initState();
    _checkFavoriteStatus();
  }

  Future<void> _checkFavoriteStatus() async {
    try {
      final isFavorite = await _apiService.checkFavorite(
        widget.itemType,
        widget.itemId,
      );
      if (mounted) {
        setState(() {
          _isFavorite = isFavorite;
          _isCheckingFavorite = false;
        });
      }
    } catch (e) {
      print('❌ Failed to check favorite status: $e');
      if (mounted) {
        setState(() {
          _isCheckingFavorite = false;
        });
      }
    }
  }

  Future<void> _toggleFavorite(BuildContext context) async {
    try {
      if (_isFavorite) {
        await _apiService.removeFavorite(widget.itemType, widget.itemId);
        if (mounted) {
          setState(() {
            _isFavorite = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Removed from favorites'),
              duration: Duration(seconds: 1),
            ),
          );
        }
      } else {
        await _apiService.addFavorite(widget.itemType, widget.itemId);
        if (mounted) {
          setState(() {
            _isFavorite = true;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Added to favorites'),
              duration: Duration(seconds: 1),
            ),
          );
        }
      }
      widget.onFavoriteChanged?.call();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  // Last.fm scrobble opt-out for an album or artist. Excluding either means
  // that entity's plays won't scrobble or update "now playing" — for personal
  // recordings you don't want showing up on your Last.fm profile.
  Future<void> _showScrobbleDialog(BuildContext context) async {
    final isArtist = widget.itemType == 'artist';
    bool excluded = false;
    try {
      final data = isArtist
          ? await _apiService.getArtist(widget.itemId)
          : await _apiService.getAlbum(widget.itemId);
      excluded = data['exclude_from_scrobble'] == true;
    } catch (_) {}

    if (!context.mounted) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateDialog) => AlertDialog(
          backgroundColor: const Color(0xFF1a2332),
          title: const Text('Last.fm Scrobbling'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                activeColor: const Color(0xFF00d4ff),
                title: const Text('Scrobble plays to Last.fm'),
                subtitle: Text(
                  isArtist
                      ? "Applies to all of this artist's tracks"
                      : "Applies to this album's tracks",
                ),
                value: !excluded,
                onChanged: (v) => setStateDialog(() => excluded = !v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF00d4ff)),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (saved != true) return;
    try {
      if (isArtist) {
        await _apiService.setArtistScrobbleExclude(widget.itemId, excluded);
      } else {
        await _apiService.setAlbumScrobbleExclude(widget.itemId, excluded);
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              excluded ? 'Scrobbling disabled' : 'Scrobbling enabled',
            ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e')),
        );
      }
    }
  }

  // Album release-type editor: primary type (Album/Single/EP) + optional
  // secondary tags (Compilation/Live/Soundtrack). Pre-fills from the album's
  // current type, saves via /api/album/<id>/type, and asks the host screen to
  // refresh so the album re-buckets under the right chip.
  Future<void> _showChangeTypeDialog(BuildContext context) async {
    String primary = 'Album';
    final Set<String> secondary = {};
    try {
      final album = await _apiService.getAlbum(widget.itemId);
      final at = album['album_type'];
      if (at is String && ['Album', 'Single', 'EP'].contains(at)) {
        primary = at;
      }
      final st = album['secondary_types'];
      if (st is String && st.isNotEmpty) {
        for (final s in st.split(',')) {
          final t = s.trim();
          if (t.isNotEmpty) secondary.add(t);
        }
      }
    } catch (_) {}

    if (!context.mounted) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            Widget primaryOption(String value) => RadioListTile<String>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  activeColor: const Color(0xFF00d4ff),
                  title: Text(value),
                  value: value,
                  groupValue: primary,
                  onChanged: (v) => setStateDialog(() => primary = v!),
                );
            Widget secondaryOption(String value) => CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  activeColor: const Color(0xFF00d4ff),
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(value),
                  value: secondary.contains(value),
                  onChanged: (v) => setStateDialog(() {
                    if (v == true) {
                      secondary.add(value);
                    } else {
                      secondary.remove(value);
                    }
                  }),
                );
            return AlertDialog(
              backgroundColor: const Color(0xFF1a2332),
              title: const Text('Change Type'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(bottom: 4),
                      child: Text('Type',
                          style:
                              TextStyle(color: Colors.white54, fontSize: 12)),
                    ),
                    primaryOption('Album'),
                    primaryOption('Single'),
                    primaryOption('EP'),
                    const Padding(
                      padding: EdgeInsets.only(top: 8, bottom: 4),
                      child: Text('Also tag as',
                          style:
                              TextStyle(color: Colors.white54, fontSize: 12)),
                    ),
                    secondaryOption('Compilation'),
                    secondaryOption('Live'),
                    secondaryOption('Soundtrack'),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF00d4ff)),
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    if (saved != true) return;
    try {
      await _apiService.setAlbumType(
        widget.itemId,
        primary,
        secondary.isEmpty ? null : secondary.join(','),
      );
      widget.onArtworkChanged?.call(); // best-effort host refresh
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Type updated')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update type: $e')),
        );
      }
    }
  }

  void _showArtworkPicker(BuildContext context) async {
    // We need to get album info - fetch it from API
    try {
      final albumData = await _apiService.getAlbum(widget.itemId);

      if (!mounted) return;

      final result = await showDialog<bool>(
        context: context,
        builder: (context) => ArtworkPickerDialog(
          albumId: widget.itemId,
          albumTitle: albumData['title'],
          artistName: albumData['artist_name'],
        ),
      );

      // If artwork was saved, trigger callback to refresh
      if (result == true) {
        widget.onArtworkChanged?.call();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _addToQueue(BuildContext context) async {
    if (widget.audioPlayerService == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot add to queue: Audio player not available'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    try {
      if (widget.itemType == 'song') {
        // Fetch single song details (not entire library!)
        final songData = await _apiService.getSongDetails(widget.itemId);
        final song = Song.fromJson(songData);

        widget.audioPlayerService!.addToQueue(song);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Added "${widget.itemName}" to queue'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else if (widget.itemType == 'album') {
        // Fetch the album with all its songs
        final albumData = await _apiService.getAlbum(widget.itemId);
        final songs = (albumData['songs'] as List).map((json) {
          json['artist_name'] = albumData['artist_name'];
          json['album_title'] = albumData['title'];
          return Song.fromJson(json);
        }).toList();

        widget.audioPlayerService!.addMultipleToQueue(songs);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Added ${songs.length} songs from "${widget.itemName}" to queue',
              ),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _playNext(BuildContext context) async {
    if (widget.audioPlayerService == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot play next: Audio player not available'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    try {
      if (widget.itemType == 'song') {
        // Fetch single song details (not entire library!)
        final songData = await _apiService.getSongDetails(widget.itemId);
        final song = Song.fromJson(songData);

        widget.audioPlayerService!.addToQueueNext(song);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('"${widget.itemName}" will play next'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else if (widget.itemType == 'album') {
        // Fetch the album with all its songs
        final albumData = await _apiService.getAlbum(widget.itemId);
        final songs = (albumData['songs'] as List).map((json) {
          json['artist_name'] = albumData['artist_name'];
          json['album_title'] = albumData['title'];
          return Song.fromJson(json);
        }).toList();

        widget.audioPlayerService!.addMultipleToQueueNext(songs);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '${songs.length} songs from "${widget.itemName}" will play next',
              ),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _showAddToPlaylistDialog(BuildContext context) async {
    // Only works for songs and albums
    if (widget.itemType != 'song' && widget.itemType != 'album') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Only songs and albums can be added to playlists'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    try {
      // Load all playlists
      final playlists = await _apiService.getPlaylists();

      if (!mounted) return;

      if (playlists.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No playlists yet. Create one first!'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }

      // Show playlist selection dialog
      final selectedPlaylist = await showDialog<Playlist>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            widget.itemType == 'album'
                ? 'Add Album to Playlist'
                : 'Add to Playlist',
          ),
          content: SizedBox(
            width: 300,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: playlists.length,
              itemBuilder: (context, index) {
                final playlist = playlists[index];
                return ListTile(
                  leading: FutureBuilder<List<int>>(
                    future: _getPlaylistAlbumIds(playlist.id),
                    builder: (context, snapshot) {
                      const size = 45.0;
                      if (!snapshot.hasData || snapshot.data!.isEmpty) {
                        return Container(
                          width: size,
                          height: size,
                          decoration: BoxDecoration(
                            color: const Color(0xFF1a2332),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Icon(Icons.playlist_play, color: Color(0xFF00d4ff), size: 28),
                        );
                      }
                      final albumIds = snapshot.data!;
                      if (albumIds.length < 4) {
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: CachedNetworkImage(
                            imageUrl: _apiService.getArtworkUrl(albumIds.first),
                            width: size,
                            height: size,
                            fit: BoxFit.cover,
                            placeholder: (context, url) => Container(width: size, height: size, color: const Color(0xFF1a2332)),
                            errorWidget: (context, url, error) => Container(
                              width: size, height: size, color: const Color(0xFF1a2332),
                              child: const Icon(Icons.playlist_play, color: Color(0xFF00d4ff), size: 28),
                            ),
                          ),
                        );
                      }
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: SizedBox(
                          width: size,
                          height: size,
                          child: GridView.count(
                            crossAxisCount: 2,
                            physics: const NeverScrollableScrollPhysics(),
                            children: albumIds.take(4).map((albumId) {
                              return CachedNetworkImage(
                                imageUrl: _apiService.getArtworkUrl(albumId),
                                fit: BoxFit.cover,
                                placeholder: (context, url) => Container(color: const Color(0xFF1a2332)),
                                errorWidget: (context, url, error) => Container(color: const Color(0xFF1a2332)),
                              );
                            }).toList(),
                          ),
                        ),
                      );
                    },
                  ),
                  title: Text(playlist.name),
                  subtitle: Text('${playlist.songCount} songs'),
                  onTap: () => Navigator.pop(context, playlist),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );

      if (selectedPlaylist != null && mounted) {
        try {
          if (widget.itemType == 'song') {
            // Add single song to playlist
            await _apiService.addSongToPlaylist(
              selectedPlaylist.id,
              widget.itemId,
            );

            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'Added "${widget.itemName}" to "${selectedPlaylist.name}"',
                  ),
                  backgroundColor: Colors.green,
                ),
              );
            }
          } else if (widget.itemType == 'album') {
            // Fetch album songs and add all to playlist
            final albumData = await _apiService.getAlbum(widget.itemId);
            final songIds = (albumData['songs'] as List)
                .map((s) => s['id'] as int)
                .toList();

            final result = await _apiService.addSongsToPlaylist(
              selectedPlaylist.id,
              songIds,
            );

            if (mounted) {
              final added = result['added'] ?? songIds.length;
              final skipped = result['skipped'] ?? 0;
              String message = 'Added $added songs from "${widget.itemName}"';
              if (skipped > 0) {
                message += ' ($skipped already in playlist)';
              }
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(message), backgroundColor: Colors.green),
              );
            }
          }
        } catch (e) {
          if (mounted) {
            // Check if it's a duplicate error
            final errorMsg = e.toString();
            if (errorMsg.contains('already in playlist')) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Song is already in this playlist'),
                  backgroundColor: Colors.orange,
                ),
              );
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Error: $e'),
                  backgroundColor: Colors.red,
                ),
              );
            }
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _showEditDialog(BuildContext context) async {
    final TextEditingController controller = TextEditingController(
      text: widget.itemName,
    );

    // Only check for Album Version on songs
    final hasAlbumVersion =
        widget.itemType == 'song' &&
        widget.itemName.contains('(Album Version)');
    final strippedTitle = widget.itemName
        .replaceAll(' (Album Version)', '')
        .trim();

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          widget.itemType == 'song' ? 'Edit Song Title' : 'Edit Album Title',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hasAlbumVersion) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning, color: Colors.orange, size: 20),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Detected "(Album Version)" suffix',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.auto_fix_high, size: 16),
                  label: const Text('Strip "(Album Version)"'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00d4ff),
                    foregroundColor: Colors.black,
                  ),
                  onPressed: () {
                    controller.text = strippedTitle;
                  },
                ),
              ),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 16),
            ],
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
              ),
              autofocus: !hasAlbumVersion,
              onSubmitted: (value) => Navigator.pop(context, value.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00d4ff),
              foregroundColor: Colors.black,
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    ).then((newTitle) async {
      if (newTitle == null || newTitle.isEmpty || newTitle == widget.itemName) {
        return;
      }

      try {
        if (widget.itemType == 'song') {
          await _apiService.editSong(widget.itemId, title: newTitle);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Updated to "$newTitle"'),
                backgroundColor: Colors.green,
              ),
            );
            widget.onFavoriteChanged?.call();
          }
        } else if (widget.itemType == 'album') {
          final result = await _apiService.editAlbum(widget.itemId, newTitle);

          if (mounted) {
            // Check if albums were merged
            if (result['merged_into_album_id'] != null) {
              final targetAlbumId = result['merged_into_album_id'] as int;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(result['message'] ?? 'Merged into "$newTitle"'),
                  backgroundColor: Colors.green,
                ),
              );
              // Navigate to the merged album, replacing current screen
              if (widget.audioPlayerService != null) {
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(
                    builder: (context) => AlbumDetailScreen(
                      albumId: targetAlbumId,
                      audioPlayerService: widget.audioPlayerService!,
                    ),
                  ),
                );
              }
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Updated to "$newTitle"'),
                  backgroundColor: Colors.green,
                ),
              );
              widget.onFavoriteChanged?.call();
            }
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
          );
        }
      }
    });
  }

  Future<void> _goToAlbum(BuildContext context) async {
    if (widget.onGoToAlbum != null) {
      widget.onGoToAlbum!();
      return;
    }
    try {
      // For songs, fetch the album ID; for albums the itemId already is one.
      int? albumId;
      if (widget.itemType == 'album') {
        albumId = widget.itemId;
      } else {
        final songData = await _apiService.getSongDetails(widget.itemId);
        albumId = songData['album_id'] as int?;
      }
      if (!mounted || albumId == null) return;
      final svc = widget.audioPlayerService;
      if (svc == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Audio service unavailable'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => AlbumDetailScreen(
            albumId: albumId!,
            audioPlayerService: svc,
            parentLabel: 'Back',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open album: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _goToArtist(BuildContext context) async {
    if (widget.onGoToArtist != null) {
      widget.onGoToArtist!();
      return;
    }
    try {
      int? artistId;
      if (widget.itemType == 'artist') {
        artistId = widget.itemId;
      } else if (widget.itemType == 'song') {
        final songData = await _apiService.getSongDetails(widget.itemId);
        // Prefer the song_artists junction (first artist) over the
        // legacy primary artist_id — handles feat./guest cases where
        // the user expects "Go to Artist" to jump to the headlining
        // act, not the primary album artist.
        final artistsList = songData['artists'] as List?;
        if (artistsList != null && artistsList.isNotEmpty) {
          artistId = artistsList.first['id'] as int?;
        }
        artistId ??= songData['artist_id'] as int?;
      } else if (widget.itemType == 'album') {
        // For albums, fall back to the album's primary artist_id.
        final albumData = await _apiService.getAlbum(widget.itemId);
        artistId = albumData['artist_id'] as int?;
      }
      if (!mounted || artistId == null) return;
      final svc = widget.audioPlayerService;
      if (svc == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Audio service unavailable'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ArtistDetailScreen(
            artistId: artistId!,
            audioPlayerService: svc,
            parentLabel: 'Back',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open artist: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _showAnalysis(BuildContext context) async {
    // Show a loading dialog while the request is in flight — analysis
    // fetch is fast (single SELECT) but the request might hit cold caches
    // on first call, so a spinner is friendlier than a frozen menu.
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF00d4ff)),
        ),
      ),
    );

    Map<String, dynamic>? analysis;
    String? error;
    try {
      analysis = await _apiService.getSongAnalysis(widget.itemId);
    } catch (e) {
      error = e.toString();
    }

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // close loader

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: Row(
          children: [
            const Icon(Icons.insights, color: Color(0xFF00d4ff)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.itemName,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 380,
          child: _buildAnalysisContent(analysis, error),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(
              'Close',
              style: TextStyle(color: Color(0xFF00d4ff)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAnalysisContent(Map<String, dynamic>? analysis, String? error) {
    if (error != null) {
      return Text(
        'Error loading analysis:\n$error',
        style: const TextStyle(color: Colors.red, fontSize: 13),
      );
    }
    if (analysis == null) {
      return const Text(
        'This song has not been analyzed yet.\n\n'
        'Run audio analysis from Settings → Audio Analysis to generate '
        'BPM, key, genre, mood, and loudness data.',
        style: TextStyle(color: Colors.grey, fontSize: 13),
      );
    }

    // Build a clean list of rows. Hide rows where the value is null so
    // partial analyses (Essentia sometimes can't determine genre/mood
    // for very short clips or speech) don't show a wall of dashes.
    final rows = <Widget>[];

    void addRow(String label, String? value) {
      if (value == null || value.isEmpty) return;
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 110,
                child: Text(
                  label,
                  style: const TextStyle(color: Colors.grey, fontSize: 13),
                ),
              ),
              Expanded(
                child: Text(
                  value,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // BPM
    final bpm = analysis['bpm'];
    if (bpm != null) {
      final bpmStr = (bpm is num) ? bpm.toStringAsFixed(1) : bpm.toString();
      addRow('Tempo', '$bpmStr BPM');
    }

    // Key
    final key = analysis['musical_key'];
    final scale = analysis['musical_scale'];
    if (key != null) {
      addRow('Key', scale != null ? '$key $scale' : key.toString());
    }

    // Loudness — prefer EBU R128 LUFS (the streaming-service standard),
    // fall back to legacy Steven's-power-law value for songs analyzed
    // before the 2026-05-25 Essentia upgrade. The legacy value isn't
    // LUFS at all; the original dialog mislabeled it. Now we surface
    // both if both exist, with the right labels.
    final lufs = analysis['integrated_loudness_lufs'];
    if (lufs is num) {
      addRow('Loudness', '${lufs.toStringAsFixed(1)} LUFS');
    } else {
      final legacyLoudness = analysis['loudness'];
      if (legacyLoudness is num) {
        addRow(
          'Loudness (legacy)',
          '${legacyLoudness.toStringAsFixed(1)} (pre-LUFS)',
        );
      }
    }
    final loudnessRange = analysis['loudness_range_lu'];
    if (loudnessRange is num) {
      addRow('Loudness range', '${loudnessRange.toStringAsFixed(1)} LU');
    }
    final truePeak = analysis['true_peak_dbfs'];
    if (truePeak is num) {
      addRow('True peak', '${truePeak.toStringAsFixed(1)} dBFS');
    }
    final dynComplexity = analysis['dynamic_complexity'];
    if (dynComplexity is num) {
      addRow('Dynamic complexity', dynComplexity.toStringAsFixed(2));
    }

    // Top genre
    final genres = analysis['genres'];
    if (genres is List && genres.isNotEmpty) {
      final names = genres
          .whereType<Map>()
          .map((g) => g['name']?.toString())
          .where((n) => n != null && n.isNotEmpty)
          .take(3)
          .join(', ');
      if (names.isNotEmpty) addRow('Genres', names);
    }

    // Moods — show as percentage values for the standout ones
    final moodFields = <String, String>{
      'mood_happy': 'Happy',
      'mood_sad': 'Sad',
      'mood_aggressive': 'Aggressive',
      'mood_relaxed': 'Relaxed',
      'mood_acoustic': 'Acoustic',
      'mood_electronic': 'Electronic',
      'mood_danceability': 'Danceability',
      'mood_party': 'Party',
      'mood_instrumental': 'Instrumental',
      'mood_bright': 'Bright',
    };
    final moodEntries = <MapEntry<String, double>>[];
    moodFields.forEach((key, label) {
      final v = analysis[key];
      if (v is num) moodEntries.add(MapEntry(label, v.toDouble()));
    });
    moodEntries.sort((a, b) => b.value.compareTo(a.value));
    final topMoods = moodEntries
        .take(4)
        .map((e) => '${e.key} ${(e.value * 100).toStringAsFixed(0)}%')
        .join(', ');
    if (topMoods.isNotEmpty) addRow('Moods', topMoods);

    // Voice
    final voiceF = analysis['voice_female'];
    final voiceM = analysis['voice_male'];
    if (voiceF is num && voiceM is num && (voiceF + voiceM) > 0) {
      addRow(
        'Voice',
        'F ${(voiceF * 100).toStringAsFixed(0)}% / M ${(voiceM * 100).toStringAsFixed(0)}%',
      );
    }

    // Instruments
    final instruments = analysis['instruments'];
    if (instruments is List && instruments.isNotEmpty) {
      final names = instruments
          .whereType<Map>()
          .map((g) => g['name']?.toString())
          .where((n) => n != null && n.isNotEmpty)
          .take(4)
          .join(', ');
      if (names.isNotEmpty) addRow('Instruments', names);
    }

    if (rows.isEmpty) {
      return const Text(
        'Analysis exists for this song but no fields were extractable.',
        style: TextStyle(color: Colors.grey, fontSize: 13),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows,
    );
  }

  Future<void> _showFileLocation(BuildContext context) async {
    try {
      // Fetch song details to get file path
      final songData = await _apiService.getSongDetails(widget.itemId);
      final filePath = songData['file_path'] as String?;

      if (filePath == null || filePath.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('File path not found'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      if (!mounted) return;

      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('File Location'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Path:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              SelectableText(
                filePath,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('Open in Explorer'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00d4ff),
                foregroundColor: Colors.black,
              ),
              onPressed: () async {
                try {
                  // Use Windows Explorer to open folder and select file
                  final process = await Process.start('explorer', [
                    '/select,',
                    filePath,
                  ]);
                  await process.exitCode;
                  if (mounted) {
                    Navigator.pop(context);
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Error opening Explorer: $e'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                }
              },
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _deleteTrack(BuildContext context) async {
    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Track'),
        content: Text(
          'Are you sure you want to delete "${widget.itemName}" from the database?\n\nThe file will remain on disk.',
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
      await _apiService.deleteSong(widget.itemId);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Deleted "${widget.itemName}" from database'),
            backgroundColor: Colors.green,
          ),
        );
        widget.onFavoriteChanged?.call();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _deleteAlbum(BuildContext context) async {
    // Show confirmation dialog with delete files option
    bool deleteFiles = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Delete Album'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Are you sure you want to delete the album "${widget.itemName}" and ALL its songs from the database?',
              ),
              const SizedBox(height: 12),
              GestureDetector(
                onTap: () => setState(() => deleteFiles = !deleteFiles),
                child: Row(
                  children: [
                    Checkbox(
                      value: deleteFiles,
                      onChanged: (v) =>
                          setState(() => deleteFiles = v ?? false),
                      activeColor: Colors.red,
                    ),
                    const Expanded(
                      child: Text(
                        'Also delete files from disk',
                        style: TextStyle(fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
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
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: const Text('Delete'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) return;

    try {
      await _apiService.deleteAlbum(widget.itemId, deleteFiles: deleteFiles);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Deleted album "${widget.itemName}" from database'),
            backgroundColor: Colors.green,
          ),
        );
        // Navigate back since the album no longer exists
        Navigator.of(context).pop();
        widget.onFavoriteChanged?.call();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _deleteArtist(BuildContext context) async {
    // Show confirmation dialog with delete files option
    bool deleteFiles = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Delete Artist'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Are you sure you want to delete the artist "${widget.itemName}" and ALL their albums and songs from the database?',
              ),
              const SizedBox(height: 12),
              GestureDetector(
                onTap: () => setState(() => deleteFiles = !deleteFiles),
                child: Row(
                  children: [
                    Checkbox(
                      value: deleteFiles,
                      onChanged: (v) =>
                          setState(() => deleteFiles = v ?? false),
                      activeColor: Colors.red,
                    ),
                    const Expanded(
                      child: Text(
                        'Also delete files from disk',
                        style: TextStyle(fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
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
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: const Text('Delete'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) return;

    try {
      await _apiService.deleteArtist(widget.itemId, deleteFiles: deleteFiles);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Deleted artist "${widget.itemName}" from database'),
            backgroundColor: Colors.green,
          ),
        );
        // Navigate back since the artist no longer exists
        Navigator.of(context).pop();
        widget.onFavoriteChanged?.call();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _downloadArtistImage(BuildContext context) async {
    try {
      final result = await showDialog<bool>(
        context: context,
        builder: (context) => ArtistImagePickerDialog(
          artistId: widget.itemId,
          artistName: widget.itemName,
        ),
      );

      if (result == true) {
        widget.onArtworkChanged?.call();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.orange),
        );
      }
    }
  }

  Future<void> _showChangeArtistDialog(BuildContext context) async {
    // Fetch album info first
    final albumData = await _apiService.getAlbum(widget.itemId);
    final currentArtistId = albumData['artist_id'] as int;
    final currentArtistName = albumData['artist_name'] as String;

    dynamic selectedArtistId;
    String selectedArtistName = currentArtistName;

    if (!mounted) return;

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
                  'Current: $currentArtistName',
                  style: const TextStyle(color: Colors.grey, fontSize: 14),
                ),
                const SizedBox(height: 16),
                _ContextMenuArtistSearchField(
                  apiService: _apiService,
                  currentArtistName: currentArtistName,
                  onArtistSelected: (id, name) {
                    setDialogState(() {
                      selectedArtistId = id;
                      selectedArtistName = name ?? currentArtistName;
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
      await _apiService.editAlbumArtist(widget.itemId, selectedArtistId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Album artist changed to $selectedArtistName'),
            backgroundColor: Colors.green,
          ),
        );
        widget.onFavoriteChanged?.call();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _showEditYearDialog(BuildContext context) async {
    // Fetch album info first
    final albumData = await _apiService.getAlbum(widget.itemId);
    final currentYear = albumData['year'] as int?;

    if (!mounted) return;

    final controller = TextEditingController(
      text: currentYear?.toString() ?? '',
    );

    final result = await showDialog<int?>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a1f3c),
        title: const Text('Edit Album Year'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.itemName,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Year',
                hintText: 'e.g. 1984',
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
          TextButton(
            onPressed: () => Navigator.pop(context, -1), // -1 means clear year
            child: const Text('Clear'),
          ),
          ElevatedButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.isEmpty) {
                Navigator.pop(context);
                return;
              }
              final year = int.tryParse(text);
              if (year != null && year >= 1900 && year <= 2100) {
                Navigator.pop(context, year);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Please enter a valid year (1900-2100)'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00d4ff),
              foregroundColor: Colors.black,
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result == null) return;

    try {
      final yearToSave = result == -1 ? null : result;
      await _apiService.editAlbumYear(widget.itemId, yearToSave);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              yearToSave == null
                  ? 'Year cleared for "${widget.itemName}"'
                  : 'Year updated to $yearToSave for "${widget.itemName}"',
            ),
            backgroundColor: Colors.green,
          ),
        );
        widget.onFavoriteChanged?.call();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update year: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _showChangeSongArtistDialog(BuildContext context) async {
    // Fetch song info first
    final songData = await _apiService.getSongDetails(widget.itemId);
    final currentArtistId = songData['artist_id'] as int;
    final currentArtistName = songData['artist_name'] as String? ?? 'Unknown';

    dynamic selectedArtistId;
    String selectedArtistName = currentArtistName;

    if (!mounted) return;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1a2332),
          title: const Text('Change Track Artist'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.itemName,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Current: $currentArtistName',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
                const SizedBox(height: 16),
                _ContextMenuArtistSearchField(
                  apiService: _apiService,
                  currentArtistName: currentArtistName,
                  onArtistSelected: (id, name) {
                    setDialogState(() {
                      selectedArtistId = id;
                      selectedArtistName = name ?? currentArtistName;
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
      await _apiService.editSongArtist(widget.itemId, selectedArtistId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Track artist changed to $selectedArtistName'),
            backgroundColor: Colors.green,
          ),
        );
        widget.onFavoriteChanged?.call();
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
    return SizedBox(
      width: 24,
      height: 24,
      child: PopupMenuButton<String>(
        padding: EdgeInsets.zero,
        iconSize: 20,
        icon: const Icon(Icons.more_vert, color: Colors.white54, size: 20),
        onSelected: (value) async {
          if (value == 'go_to_album') {
            await _goToAlbum(context);
          } else if (value == 'go_to_artist') {
            await _goToArtist(context);
          } else if (value == 'add_to_queue') {
            await _addToQueue(context);
          } else if (value == 'play_next') {
            await _playNext(context);
          } else if (value == 'add_to_playlist') {
            await _showAddToPlaylistDialog(context);
          } else if (value == 'favorite') {
            await _toggleFavorite(context);
          } else if (value == 'find_artwork') {
            _showArtworkPicker(context);
          } else if (value == 'edit') {
            await _showEditDialog(context);
          } else if (value == 'move_position') {
            widget.onMoveToPosition?.call();
          } else if (value == 'replace_song') {
            widget.onReplaceSong?.call();
          } else if (value == 'remove_from_playlist') {
            widget.onRemoveFromPlaylist?.call();
          } else if (value == 'show_analysis') {
            await _showAnalysis(context);
          } else if (value == 'show_location') {
            await _showFileLocation(context);
          } else if (value == 'delete_track') {
            await _deleteTrack(context);
          } else if (value == 'delete_album') {
            await _deleteAlbum(context);
          } else if (value == 'delete_artist') {
            await _deleteArtist(context);
          } else if (value == 'download_artist_image') {
            await _downloadArtistImage(context);
          } else if (value == 'change_artist') {
            await _showChangeArtistDialog(context);
          } else if (value == 'edit_year') {
            await _showEditYearDialog(context);
          } else if (value == 'change_type') {
            await _showChangeTypeDialog(context);
          } else if (value == 'scrobble_settings') {
            await _showScrobbleDialog(context);
          } else if (value == 'change_song_artist') {
            await _showChangeSongArtistDialog(context);
          }
        },
        itemBuilder: (BuildContext context) {
          return [
            // Navigation actions (top of menu, most common jumps).
            // Songs and albums can both jump to their parent artist.
            // Only songs can jump to their album.
            if (widget.itemType == 'song')
              const PopupMenuItem<String>(
                value: 'go_to_album',
                child: Row(
                  children: [
                    Icon(Icons.album, size: 20, color: Color(0xFF00d4ff)),
                    SizedBox(width: 12),
                    Text('Go to Album'),
                  ],
                ),
              ),
            if (widget.itemType == 'song' || widget.itemType == 'album')
              const PopupMenuItem<String>(
                value: 'go_to_artist',
                child: Row(
                  children: [
                    Icon(Icons.person, size: 20, color: Color(0xFF00d4ff)),
                    SizedBox(width: 12),
                    Text('Go to Artist'),
                  ],
                ),
              ),
            // Add to Queue option (only for songs and albums)
            if (widget.itemType == 'song' || widget.itemType == 'album')
              PopupMenuItem<String>(
                value: 'add_to_queue',
                child: Row(
                  children: [
                    const Icon(Icons.queue_music, size: 20, color: Colors.grey),
                    const SizedBox(width: 12),
                    Text(
                      widget.itemType == 'song'
                          ? 'Add to Queue'
                          : 'Add Album to Queue',
                    ),
                  ],
                ),
              ),
            // Play Next option (only for songs and albums)
            if (widget.itemType == 'song' || widget.itemType == 'album')
              PopupMenuItem<String>(
                value: 'play_next',
                child: Row(
                  children: [
                    const Icon(
                      Icons.playlist_play,
                      size: 20,
                      color: Colors.grey,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      widget.itemType == 'song'
                          ? 'Play Next'
                          : 'Play Album Next',
                    ),
                  ],
                ),
              ),
            // Add to Playlist option (for songs and albums)
            if (widget.itemType == 'song' || widget.itemType == 'album')
              PopupMenuItem<String>(
                value: 'add_to_playlist',
                child: Row(
                  children: [
                    const Icon(
                      Icons.playlist_add,
                      size: 20,
                      color: Colors.grey,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      widget.itemType == 'album'
                          ? 'Add Album to Playlist'
                          : 'Add to Playlist',
                    ),
                  ],
                ),
              ),
            // Edit option (only for songs for now)
            if (widget.itemType == 'song' || widget.itemType == 'album')
              PopupMenuItem<String>(
                value: 'edit',
                child: Row(
                  children: [
                    const Icon(Icons.edit, size: 20, color: Colors.grey),
                    const SizedBox(width: 12),
                    Text(
                      widget.itemType == 'song'
                          ? 'Edit Song Title'
                          : 'Edit Album Title',
                    ),
                  ],
                ),
              ),
            // Edit Year option (only for albums)
            if (widget.itemType == 'album')
              const PopupMenuItem<String>(
                value: 'edit_year',
                child: Row(
                  children: [
                    Icon(Icons.calendar_today, size: 20, color: Colors.grey),
                    SizedBox(width: 12),
                    Text('Edit Year'),
                  ],
                ),
              ),
            // Change Type option (only for albums)
            if (widget.itemType == 'album')
              const PopupMenuItem<String>(
                value: 'change_type',
                child: Row(
                  children: [
                    Icon(Icons.category, size: 20, color: Colors.grey),
                    SizedBox(width: 12),
                    Text('Change Type'),
                  ],
                ),
              ),
            // Last.fm scrobble toggle (albums and artists)
            if (widget.itemType == 'album' || widget.itemType == 'artist')
              const PopupMenuItem<String>(
                value: 'scrobble_settings',
                child: Row(
                  children: [
                    Icon(Icons.graphic_eq, size: 20, color: Colors.grey),
                    SizedBox(width: 12),
                    Text('Last.fm Scrobbling'),
                  ],
                ),
              ),
            // Change Song Artist option (only for songs)
            if (widget.itemType == 'song')
              const PopupMenuItem<String>(
                value: 'change_song_artist',
                child: Row(
                  children: [
                    Icon(Icons.person_outline, size: 20, color: Colors.grey),
                    SizedBox(width: 12),
                    Text('Change Artist'),
                  ],
                ),
              ),
            // Move to Position option (only for songs when callback is provided)
            if (widget.itemType == 'song' && widget.onMoveToPosition != null)
              const PopupMenuItem<String>(
                value: 'move_position',
                child: Row(
                  children: [
                    Icon(Icons.open_with, size: 20, color: Color(0xFF00d4ff)),
                    SizedBox(width: 12),
                    Text('Move to Position'),
                  ],
                ),
              ),
            // Replace Song — only in playlist contexts where the host
            // screen provides the callback. Hidden everywhere else.
            if (widget.itemType == 'song' && widget.onReplaceSong != null)
              const PopupMenuItem<String>(
                value: 'replace_song',
                child: Row(
                  children: [
                    Icon(Icons.find_replace,
                        size: 20, color: Color(0xFF00d4ff)),
                    SizedBox(width: 12),
                    Text('Replace Song'),
                  ],
                ),
              ),
            // Remove from Playlist — same gating as Replace Song.
            if (widget.itemType == 'song' && widget.onRemoveFromPlaylist != null)
              const PopupMenuItem<String>(
                value: 'remove_from_playlist',
                child: Row(
                  children: [
                    Icon(Icons.playlist_remove,
                        size: 20, color: Colors.red),
                    SizedBox(width: 12),
                    Text('Remove from Playlist'),
                  ],
                ),
              ),
            PopupMenuItem<String>(
              value: 'favorite',
              child: _isCheckingFavorite
                  ? const Row(
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 12),
                        Text('Checking...'),
                      ],
                    )
                  : Row(
                      children: [
                        Icon(
                          _isFavorite ? Icons.favorite : Icons.favorite_border,
                          color: _isFavorite ? Colors.red : Colors.grey,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          _isFavorite
                              ? 'Remove from Favorites'
                              : 'Add to Favorites',
                        ),
                      ],
                    ),
            ),
            // Only show "Find Artwork" for albums
            if (widget.itemType == 'album')
              const PopupMenuItem<String>(
                value: 'find_artwork',
                child: Row(
                  children: [
                    Icon(Icons.image_search, size: 20, color: Colors.grey),
                    SizedBox(width: 12),
                    Text('Find Artwork'),
                  ],
                ),
              ),
            // Change Album Artist option
            if (widget.itemType == 'album')
              const PopupMenuItem<String>(
                value: 'change_artist',
                child: Row(
                  children: [
                    Icon(Icons.person_outline, size: 20, color: Colors.grey),
                    SizedBox(width: 12),
                    Text('Change Album Artist'),
                  ],
                ),
              ),
            // Delete Album option
            if (widget.itemType == 'album')
              const PopupMenuItem<String>(
                value: 'delete_album',
                child: Row(
                  children: [
                    Icon(Icons.delete_forever, size: 20, color: Colors.red),
                    SizedBox(width: 12),
                    Text('Delete Album'),
                  ],
                ),
              ),
            // Download/Refresh Artist Image option
            if (widget.itemType == 'artist')
              PopupMenuItem<String>(
                value: 'download_artist_image',
                child: Row(
                  children: [
                    Icon(
                      widget.hasArtistImage
                          ? Icons.image
                          : Icons.image_search,
                      size: 20,
                      color: Colors.grey,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      widget.hasArtistImage
                          ? 'Change Artwork'
                          : 'Choose Artwork',
                    ),
                  ],
                ),
              ),
            // Delete Artist option
            if (widget.itemType == 'artist')
              const PopupMenuItem<String>(
                value: 'delete_artist',
                child: Row(
                  children: [
                    Icon(Icons.delete_forever, size: 20, color: Colors.red),
                    SizedBox(width: 12),
                    Text('Delete Artist'),
                  ],
                ),
              ),
            // Analysis details (only for songs — shows BPM/key/genre/mood
            // from Essentia, or a "not analyzed yet" message)
            if (widget.itemType == 'song')
              const PopupMenuItem<String>(
                value: 'show_analysis',
                child: Row(
                  children: [
                    Icon(Icons.insights, size: 20, color: Color(0xFF00d4ff)),
                    SizedBox(width: 12),
                    Text('Analysis Details'),
                  ],
                ),
              ),
            // Show File Location and Delete Track options (only for songs)
            if (widget.itemType == 'song')
              const PopupMenuItem<String>(
                value: 'show_location',
                child: Row(
                  children: [
                    Icon(Icons.folder_open, size: 20, color: Colors.grey),
                    SizedBox(width: 12),
                    Text('Show File Location'),
                  ],
                ),
              ),
            if (widget.itemType == 'song')
              const PopupMenuItem<String>(
                value: 'delete_track',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline, size: 20, color: Colors.red),
                    SizedBox(width: 12),
                    Text('Delete Track'),
                  ],
                ),
              ),
          ];
        },
      ),
    );
  }
}

class _ContextMenuArtistSearchField extends StatefulWidget {
  final ApiService apiService;
  final String currentArtistName;
  final Function(dynamic artistId, String? artistName) onArtistSelected;

  const _ContextMenuArtistSearchField({
    required this.apiService,
    required this.currentArtistName,
    required this.onArtistSelected,
  });

  @override
  State<_ContextMenuArtistSearchField> createState() =>
      _ContextMenuArtistSearchFieldState();
}

class _ContextMenuArtistSearchFieldState
    extends State<_ContextMenuArtistSearchField> {
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
                ListTile(
                  dense: true,
                  title: const Text(
                    'Various Artists',
                    style: TextStyle(fontSize: 13),
                  ),
                  onTap: () =>
                      _selectArtist('various_artists', 'Various Artists'),
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
