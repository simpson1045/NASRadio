import 'package:flutter/material.dart';
import '../models/album.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import '../widgets/artwork_picker_dialog.dart';

class AlbumMergeScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;

  const AlbumMergeScreen({super.key, required this.audioPlayerService});

  @override
  State<AlbumMergeScreen> createState() => _AlbumMergeScreenState();
}

class _AlbumMergeScreenState extends State<AlbumMergeScreen> {
  final ApiService _apiService = ApiService();
  List<List<Album>> _suggestions = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSuggestions();
  }

  Future<void> _loadSuggestions() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final suggestions = await _apiService.findSimilarAlbums();
      setState(() {
        _suggestions = suggestions;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _showMergeDialog(List<Album> group) async {
    int? selectedTarget;
    Map<int, int> discNumbers = {}; // album_id -> disc_number
    final TextEditingController nameController = TextEditingController();

    // Check if this is a multi-artist group and collect artist options
    final Map<int, String> artistOptions = {};
    for (var album in group) {
      artistOptions[album.artistId] = album.artistName;
    }
    final isMultiArtist = artistOptions.length > 1;
    dynamic
    selectedArtistId; // null = keep target's artist, int = specific artist, "various_artists" = Various Artists

    // Initialize with current disc numbers (default to 1)
    for (var i = 0; i < group.length; i++) {
      discNumbers[group[i].id] = i + 1; // Start with 1, 2, 3, etc.
    }
    bool keepOriginalDiscNumbers = true; // Default to keeping original

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          // Update name field when target changes
          if (selectedTarget != null && nameController.text.isEmpty) {
            final targetAlbum = group.firstWhere((a) => a.id == selectedTarget);
            nameController.text = targetAlbum.title;
          }

          return AlertDialog(
            title: const Text('Merge Albums'),
            content: SizedBox(
              width: 500,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Select the album to keep and set disc numbers:',
                      style: TextStyle(fontSize: 14, color: Colors.grey),
                    ),
                    const SizedBox(height: 16),
                    ...group.map((album) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12.0),
                        child: Column(
                          children: [
                            RadioListTile<int>(
                              title: Text(album.title),
                              subtitle: Text(
                                '${album.artistName} • ${album.year ?? "Unknown"} • ${album.songCount} songs',
                                style: const TextStyle(fontSize: 12),
                              ),
                              value: album.id,
                              groupValue: selectedTarget,
                              onChanged: (value) {
                                setDialogState(() {
                                  selectedTarget = value;
                                  // Auto-fill album name when selected
                                  final selected = group.firstWhere(
                                    (a) => a.id == value,
                                  );
                                  nameController.text = selected.title;
                                });
                              },
                              activeColor: const Color(0xFF00d4ff),
                            ),
                            if (!keepOriginalDiscNumbers)
                              Padding(
                                padding: const EdgeInsets.only(
                                  left: 56,
                                  right: 16,
                                ),
                                child: Row(
                                  children: [
                                    const Text(
                                      'Disc Number:',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    SizedBox(
                                      width: 60,
                                      child: TextField(
                                        decoration: const InputDecoration(
                                          border: OutlineInputBorder(),
                                          contentPadding: EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 8,
                                          ),
                                        ),
                                        keyboardType: TextInputType.number,
                                        controller: TextEditingController(
                                          text: discNumbers[album.id]
                                              .toString(),
                                        ),
                                        onChanged: (value) {
                                          final num = int.tryParse(value);
                                          if (num != null && num > 0) {
                                            discNumbers[album.id] = num;
                                          }
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      );
                    }),
                    const SizedBox(height: 16),
                    CheckboxListTile(
                      title: const Text(
                        'Keep original disc numbers',
                        style: TextStyle(fontSize: 14),
                      ),
                      subtitle: const Text(
                        'Uncheck to reassign disc numbers per album',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                      value: keepOriginalDiscNumbers,
                      onChanged: (value) {
                        setDialogState(() {
                          keepOriginalDiscNumbers = value ?? true;
                        });
                      },
                      activeColor: const Color(0xFF00d4ff),
                      contentPadding: EdgeInsets.zero,
                    ),
                    const SizedBox(height: 16),
                    const Divider(),
                    const SizedBox(height: 16),
                    const Text(
                      'Album Name:',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        hintText: 'Enter album name...',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                      ),
                    ),
                    if (isMultiArtist) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.orange),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(
                                  Icons.people,
                                  color: Colors.orange,
                                  size: 20,
                                ),
                                SizedBox(width: 8),
                                Text(
                                  'Multi-Artist Album Detected',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.orange,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'These albums have different artists. Select which artist should own the merged album:',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
                            const SizedBox(height: 12),
                            _ArtistSearchField(
                              apiService: _apiService,
                              initialOptions: artistOptions,
                              onArtistSelected:
                                  (dynamic artistId, String? artistName) {
                                    setDialogState(() {
                                      selectedArtistId = artistId;
                                    });
                                  },
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Individual songs will keep their original artists',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed:
                    selectedTarget == null || nameController.text.trim().isEmpty
                    ? null
                    : () async {
                        Navigator.pop(context);
                        await _mergeAlbums(
                          group,
                          selectedTarget!,
                          keepOriginalDiscNumbers ? {} : discNumbers,
                          nameController.text.trim(),
                          albumArtistId: selectedArtistId,
                        );
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00d4ff),
                  foregroundColor: Colors.black,
                ),
                child: const Text('Merge'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _mergeAlbums(
    List<Album> group,
    int targetId,
    Map<int, int> discNumbers,
    String newAlbumName, {
    dynamic albumArtistId,
  }) async {
    try {
      final sourceIds = group
          .where((a) => a.id != targetId)
          .map((a) => a.id)
          .toList();

      await _apiService.mergeAlbums(
        targetId,
        sourceIds,
        discNumbers,
        newAlbumName,
        albumArtistId: albumArtistId,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Albums merged successfully'),
            backgroundColor: Colors.green,
          ),
        );
        _loadSuggestions();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error merging albums: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _dismissSuggestion(int index) async {
    final group = _suggestions[index];
    final albumIds = group.map((a) => a.id).toList();

    // Persist to database
    try {
      await _apiService.markNotDuplicates(albumIds);
    } catch (e) {
      // Still dismiss locally even if API fails
      debugPrint('Failed to persist not-duplicates: $e');
    }

    setState(() {
      _suggestions.removeAt(index);
    });
  }

  Future<void> _showManualMergeDialog() async {
    final TextEditingController searchController = TextEditingController();
    final TextEditingController albumNameController = TextEditingController();
    final TextEditingController mbidController = TextEditingController();
    List<Album> searchResults = [];
    List<Album> selectedAlbums = [];
    Map<int, int> discNumbers = {};
    bool isSearching = false;
    int? selectedTargetId;
    String boxSetName = '';

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> searchAlbums(String query) async {
            if (query.length < 2) {
              setDialogState(() {
                searchResults = [];
              });
              return;
            }
            setDialogState(() => isSearching = true);
            try {
              final results = await _apiService.searchAlbums(query);
              setDialogState(() {
                searchResults = results
                    .where((a) => !selectedAlbums.any((s) => s.id == a.id))
                    .toList();
                isSearching = false;
              });
            } catch (e) {
              setDialogState(() => isSearching = false);
            }
          }

          void addToCart(Album album) {
            setDialogState(() {
              selectedAlbums.add(album);
              discNumbers[album.id] = selectedAlbums.length;
              searchResults.removeWhere((a) => a.id == album.id);
              selectedTargetId ??= album.id;
            });
          }

          void removeFromCart(Album album) {
            setDialogState(() {
              selectedAlbums.remove(album);
              discNumbers.remove(album.id);
              if (selectedTargetId == album.id) {
                selectedTargetId = selectedAlbums.isNotEmpty
                    ? selectedAlbums.first.id
                    : null;
              }
              // Renumber remaining discs
              for (var i = 0; i < selectedAlbums.length; i++) {
                discNumbers[selectedAlbums[i].id] = i + 1;
              }
            });
          }

          void reorderDisc(int oldIndex, int newIndex) {
            setDialogState(() {
              if (newIndex > oldIndex) newIndex--;
              final album = selectedAlbums.removeAt(oldIndex);
              selectedAlbums.insert(newIndex, album);
              // Renumber all discs
              for (var i = 0; i < selectedAlbums.length; i++) {
                discNumbers[selectedAlbums[i].id] = i + 1;
              }
            });
          }

          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.library_music, color: Color(0xFF00d4ff)),
                SizedBox(width: 8),
                Text('Build Box Set'),
              ],
            ),
            content: SizedBox(
              width: 700,
              height: 600,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Left side - Search and results
                  Expanded(
                    flex: 1,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Search Albums',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: searchController,
                          decoration: InputDecoration(
                            hintText: 'Search by album name...',
                            prefixIcon: const Icon(Icons.search, size: 20),
                            suffixIcon: isSearching
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: Padding(
                                      padding: EdgeInsets.all(10),
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  )
                                : null,
                            border: const OutlineInputBorder(),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                          ),
                          onChanged: searchAlbums,
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFF0d1b2a),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: const Color(0xFF2a3a4a),
                              ),
                            ),
                            child: searchResults.isEmpty
                                ? Center(
                                    child: Text(
                                      searchController.text.isEmpty
                                          ? 'Search for albums to add'
                                          : 'No results found',
                                      style: const TextStyle(
                                        color: Colors.grey,
                                      ),
                                    ),
                                  )
                                : ListView.builder(
                                    itemCount: searchResults.length,
                                    itemBuilder: (context, index) {
                                      final album = searchResults[index];
                                      return ListTile(
                                        dense: true,
                                        title: Text(
                                          album.title,
                                          style: const TextStyle(fontSize: 13),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        subtitle: Text(
                                          '${album.artistName} • ${album.year ?? "?"} • ${album.songCount} songs',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: Colors.grey,
                                          ),
                                        ),
                                        trailing: IconButton(
                                          icon: const Icon(
                                            Icons.add_circle,
                                            color: Color(0xFF00d4ff),
                                          ),
                                          onPressed: () => addToCart(album),
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Right side - Cart and settings
                  Expanded(
                    flex: 1,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text(
                              'Box Set Discs',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '${selectedAlbums.length} discs',
                              style: const TextStyle(
                                color: Colors.grey,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFF0d1b2a),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: const Color(0xFF2a3a4a),
                              ),
                            ),
                            child: selectedAlbums.isEmpty
                                ? const Center(
                                    child: Text(
                                      'Add albums from the search',
                                      style: TextStyle(color: Colors.grey),
                                    ),
                                  )
                                : ReorderableListView.builder(
                                    itemCount: selectedAlbums.length,
                                    onReorder: reorderDisc,
                                    itemBuilder: (context, index) {
                                      final album = selectedAlbums[index];
                                      final discNum =
                                          discNumbers[album.id] ?? (index + 1);
                                      return ListTile(
                                        key: ValueKey(album.id),
                                        dense: true,
                                        leading: Container(
                                          width: 32,
                                          height: 32,
                                          decoration: BoxDecoration(
                                            color: const Color(
                                              0xFF00d4ff,
                                            ).withOpacity(0.2),
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: Center(
                                            child: Text(
                                              '$discNum',
                                              style: const TextStyle(
                                                color: Color(0xFF00d4ff),
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ),
                                        title: Text(
                                          album.title,
                                          style: const TextStyle(fontSize: 12),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        subtitle: Text(
                                          '${album.songCount} songs',
                                          style: const TextStyle(
                                            fontSize: 10,
                                            color: Colors.grey,
                                          ),
                                        ),
                                        trailing: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Radio<int>(
                                              value: album.id,
                                              groupValue: selectedTargetId,
                                              onChanged: (value) {
                                                setDialogState(() {
                                                  selectedTargetId = value;
                                                });
                                              },
                                              activeColor: const Color(
                                                0xFF00d4ff,
                                              ),
                                            ),
                                            IconButton(
                                              icon: const Icon(
                                                Icons.remove_circle,
                                                color: Colors.red,
                                                size: 20,
                                              ),
                                              onPressed: () =>
                                                  removeFromCart(album),
                                            ),
                                            const Icon(
                                              Icons.drag_handle,
                                              color: Colors.grey,
                                              size: 20,
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Box Set Name',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: albumNameController,
                          decoration: const InputDecoration(
                            hintText:
                                'e.g., Slip of the Tongue (30th Anniversary)',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                          ),
                          onChanged: (value) => setDialogState(() {
                            boxSetName = value;
                          }),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'MusicBrainz Release ID (optional)',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: mbidController,
                          decoration: const InputDecoration(
                            hintText:
                                'e.g., 12345678-1234-1234-1234-123456789012',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              // Debug text - remove later
              Text(
                'Albums: ${selectedAlbums.length}, Name: ${boxSetName.isNotEmpty}, Target: $selectedTargetId',
                style: const TextStyle(fontSize: 10, color: Colors.grey),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              ElevatedButton.icon(
                icon: const Icon(Icons.merge, size: 18),
                label: const Text('Build Box Set'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00d4ff),
                  foregroundColor: Colors.black,
                ),
                onPressed:
                    selectedAlbums.length < 2 ||
                        boxSetName.trim().isEmpty ||
                        selectedTargetId == null
                    ? null
                    : () async {
                        Navigator.pop(context);
                        // Build disc names map from disc numbers and album titles
                        final discNamesMap = <int, String>{};
                        for (final album in selectedAlbums) {
                          final discNum = discNumbers[album.id]!;
                          discNamesMap[discNum] = album.title;
                        }

                        await _buildBoxSet(
                          selectedAlbums,
                          selectedTargetId!,
                          discNumbers,
                          discNamesMap,
                          boxSetName.trim(),
                          mbidController.text.trim().isNotEmpty
                              ? mbidController.text.trim()
                              : null,
                        );
                      },
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _buildBoxSet(
    List<Album> albums,
    int targetId,
    Map<int, int> discNumbers,
    Map<int, String> discNames,
    String boxSetName,
    String? mbid,
  ) async {
    try {
      final sourceIds = albums
          .where((a) => a.id != targetId)
          .map((a) => a.id)
          .toList();

      // Get artist name from target album for artwork picker
      final targetAlbum = albums.firstWhere((a) => a.id == targetId);
      final artistName = targetAlbum.artistName;

      await _apiService.mergeAlbums(
        targetId,
        sourceIds,
        discNumbers,
        boxSetName,
        mbid: mbid,
        discNames: discNames,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Box set "$boxSetName" created with ${albums.length} discs',
            ),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );

        // Open artwork picker for the new box set
        await showDialog(
          context: context,
          builder: (context) => ArtworkPickerDialog(
            albumId: targetId,
            albumTitle: boxSetName,
            artistName: artistName,
          ),
        );

        _loadSuggestions();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error building box set: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Merge Duplicate Albums'),
        backgroundColor: const Color(0xFF0d1b2a),
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 80),
        child: FloatingActionButton.extended(
          onPressed: _showManualMergeDialog,
          backgroundColor: const Color(0xFF00d4ff),
          icon: const Icon(Icons.add, color: Colors.black),
          label: const Text(
            'Build Box Set',
            style: TextStyle(color: Colors.black),
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Container(
              color: const Color(0xFF0d1b2a),
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.error, color: Colors.red, size: 48),
                          const SizedBox(height: 16),
                          Text(
                            'Error: $_error',
                            style: const TextStyle(color: Colors.red),
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton(
                            onPressed: _loadSuggestions,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    )
                  : _suggestions.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.check_circle,
                            color: Colors.green,
                            size: 48,
                          ),
                          SizedBox(height: 16),
                          Text(
                            'No duplicate albums found!',
                            style: TextStyle(fontSize: 18, color: Colors.grey),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(
                        left: 16,
                        right: 16,
                        top: 16,
                        bottom: 100, // Extra space for FAB
                      ),
                      itemCount: _suggestions.length,
                      itemBuilder: (context, index) {
                        final group = _suggestions[index];
                        return Card(
                          color: const Color(0xFF1a2332),
                          margin: const EdgeInsets.only(bottom: 16),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.album,
                                      color: Colors.orange,
                                      size: 24,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'Possible duplicates (${group.length} albums)',
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(
                                        Icons.close,
                                        color: Colors.grey,
                                      ),
                                      onPressed: () =>
                                          _dismissSuggestion(index),
                                      tooltip: 'Dismiss',
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                ...group.asMap().entries.map((entry) {
                                  final index = entry.key;
                                  final album = entry.value;
                                  return _AlbumSongList(
                                    key: ValueKey(
                                      album.id,
                                    ), // Forces rebuild when album changes
                                    album: album,
                                    apiService: _apiService,
                                    isLast: index == group.length - 1,
                                  );
                                }),
                                const SizedBox(height: 12),
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    TextButton(
                                      onPressed: () =>
                                          _dismissSuggestion(index),
                                      child: const Text('Not Duplicates'),
                                    ),
                                    const SizedBox(width: 8),
                                    ElevatedButton.icon(
                                      icon: const Icon(Icons.merge, size: 18),
                                      label: const Text('Merge'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(
                                          0xFF00d4ff,
                                        ),
                                        foregroundColor: Colors.black,
                                      ),
                                      onPressed: () => _showMergeDialog(group),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AlbumSongList extends StatefulWidget {
  final Album album;
  final ApiService apiService;
  final bool isLast;

  const _AlbumSongList({
    super.key,
    required this.album,
    required this.apiService,
    required this.isLast,
  });

  @override
  State<_AlbumSongList> createState() => _AlbumSongListState();
}

class _AlbumSongListState extends State<_AlbumSongList> {
  List<dynamic>? _songs;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSongs();
  }

  Future<void> _loadSongs() async {
    try {
      final data = await widget.apiService.getAlbum(widget.album.id);
      if (mounted) {
        setState(() {
          _songs = data['songs'] as List;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Album header
        Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF1a2332),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFF00d4ff),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.album.title,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      '${widget.album.artistName} • ${widget.album.year ?? "Unknown"} • ${widget.album.songCount} songs',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    if (widget.album.samplePath != null)
                      Text(
                        widget.album.samplePath!.replaceAll('/music/', ''),
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.grey,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // Songs list
        Container(
          margin: const EdgeInsets.only(left: 16, top: 8, bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF0d1b2a),
            borderRadius: BorderRadius.circular(8),
          ),
          child: _isLoading
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(8.0),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : _songs == null || _songs!.isEmpty
              ? const Text(
                  'No songs found',
                  style: TextStyle(color: Colors.grey),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _songs!.map((song) {
                    final discNum = song['disc_number'] ?? 1;
                    final trackNum = song['track_number'] ?? 0;
                    final title = song['title'] ?? 'Unknown';
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        '$discNum-$trackNum. $title',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                    );
                  }).toList(),
                ),
        ),
        if (!widget.isLast) const SizedBox(height: 8),
      ],
    );
  }
}

class _ArtistSearchField extends StatefulWidget {
  final ApiService apiService;
  final Map<int, String> initialOptions;
  final Function(dynamic artistId, String? artistName) onArtistSelected;

  const _ArtistSearchField({
    required this.apiService,
    required this.initialOptions,
    required this.onArtistSelected,
  });

  @override
  State<_ArtistSearchField> createState() => _ArtistSearchFieldState();
}

class _ArtistSearchFieldState extends State<_ArtistSearchField> {
  final TextEditingController _controller = TextEditingController();
  List<Map<String, dynamic>> _searchResults = [];
  bool _isSearching = false;
  bool _showResults = false;
  dynamic _selectedId;
  String? _selectedName;

  @override
  void initState() {
    super.initState();
    _controller.text = 'Keep original (from selected album)';
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
        setState(() {
          _isSearching = false;
        });
      }
    }
  }

  void _selectArtist(dynamic id, String name) {
    setState(() {
      _selectedId = id;
      _selectedName = name;
      _controller.text = name;
      _showResults = false;
    });
    widget.onArtistSelected(id, name);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _controller,
          decoration: InputDecoration(
            labelText: 'Album Artist',
            border: const OutlineInputBorder(),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
            suffixIcon: _isSearching
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {
                      _controller.clear();
                      _selectArtist(
                        null,
                        'Keep original (from selected album)',
                      );
                    },
                  ),
          ),
          onTap: () {
            _controller.selection = TextSelection(
              baseOffset: 0,
              extentOffset: _controller.text.length,
            );
          },
          onChanged: _search,
        ),
        if (_showResults && _searchResults.isNotEmpty)
          Container(
            constraints: const BoxConstraints(maxHeight: 200),
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF1a2332),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.grey.shade700),
            ),
            child: ListView(
              shrinkWrap: true,
              children: [
                // Quick options at top
                ListTile(
                  dense: true,
                  title: const Text(
                    'Keep original (from selected album)',
                    style: TextStyle(fontSize: 13),
                  ),
                  onTap: () => _selectArtist(
                    null,
                    'Keep original (from selected album)',
                  ),
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
                const Divider(height: 1),
                // Artists from current merge group
                ...widget.initialOptions.entries.map(
                  (e) => ListTile(
                    dense: true,
                    title: Text(e.value, style: const TextStyle(fontSize: 13)),
                    trailing: const Text(
                      '(in merge)',
                      style: TextStyle(fontSize: 10, color: Colors.grey),
                    ),
                    onTap: () => _selectArtist(e.key, e.value),
                  ),
                ),
                if (widget.initialOptions.isNotEmpty) const Divider(height: 1),
                // Search results
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
