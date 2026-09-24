import 'package:flutter/material.dart';
import '../models/artist.dart';
import '../services/api_service.dart';

class ManualMergeScreen extends StatefulWidget {
  const ManualMergeScreen({super.key});

  @override
  State<ManualMergeScreen> createState() => _ManualMergeScreenState();
}

class _ManualMergeScreenState extends State<ManualMergeScreen> {
  final ApiService _apiService = ApiService();
  List<Artist> _allArtists = [];
  final Set<int> _selectedArtistIds = {};
  bool _isLoading = true;
  String? _error;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadArtists();
  }

  Future<void> _loadArtists() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final artists = await _apiService.getArtists();
      setState(() {
        _allArtists = artists;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  List<Artist> get _filteredArtists {
    if (_searchQuery.isEmpty) return _allArtists;
    return _allArtists
        .where(
          (artist) =>
              artist.name.toLowerCase().contains(_searchQuery.toLowerCase()),
        )
        .toList();
  }

  Future<void> _showMergeDialog() async {
    if (_selectedArtistIds.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select at least 2 artists to merge')),
      );
      return;
    }

    final selectedArtists = _allArtists
        .where((a) => _selectedArtistIds.contains(a.id))
        .toList();

    int? targetArtistId;
    final TextEditingController nameController = TextEditingController();

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Merge Artists'),
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Merging ${selectedArtists.length} artists:',
                  style: const TextStyle(fontSize: 14, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                ...selectedArtists.map(
                  (artist) => Padding(
                    padding: const EdgeInsets.only(left: 16, bottom: 4),
                    child: Text(
                      '• ${artist.name} (${artist.albumCount} albums, ${artist.songCount} songs)',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Divider(),
                const SizedBox(height: 16),
                const Text(
                  'Choose merge method:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                RadioListTile<String>(
                  title: const Text('Pick existing artist from list'),
                  value: 'existing',
                  groupValue: targetArtistId != null ? 'existing' : 'custom',
                  onChanged: (value) {
                    setDialogState(() {
                      nameController.clear();
                    });
                  },
                ),
                if (targetArtistId != null || nameController.text.isEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    margin: const EdgeInsets.only(left: 32),
                    constraints: const BoxConstraints(maxHeight: 200),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: ListView(
                      shrinkWrap: true,
                      children: selectedArtists.map((artist) {
                        return RadioListTile<int>(
                          dense: true,
                          title: Text(artist.name),
                          subtitle: Text(
                            '${artist.albumCount} albums • ${artist.songCount} songs',
                            style: const TextStyle(fontSize: 11),
                          ),
                          value: artist.id,
                          groupValue: targetArtistId,
                          onChanged: (value) {
                            setDialogState(() {
                              targetArtistId = value;
                              nameController.clear();
                            });
                          },
                        );
                      }).toList(),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                RadioListTile<String>(
                  title: const Text('Enter custom name'),
                  value: 'custom',
                  groupValue: nameController.text.isNotEmpty
                      ? 'custom'
                      : 'existing',
                  onChanged: (value) {
                    setDialogState(() {
                      targetArtistId = null;
                    });
                  },
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(left: 32),
                  child: TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: 'Custom artist name',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) {
                      setDialogState(() {
                        if (value.isNotEmpty) {
                          targetArtistId = null;
                        }
                      });
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed:
                  (targetArtistId == null && nameController.text.trim().isEmpty)
                  ? null
                  : () async {
                      Navigator.pop(context);
                      await _performMerge(
                        targetArtistId,
                        nameController.text.trim(),
                        selectedArtists,
                      );
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00d4ff),
                foregroundColor: Colors.black,
              ),
              child: const Text('Merge'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _performMerge(
    int? targetId,
    String customName,
    List<Artist> selectedArtists,
  ) async {
    try {
      int finalTargetId;

      if (customName.isNotEmpty) {
        // Create new artist by renaming the first selected artist
        final firstArtist = selectedArtists.first;
        await _apiService.editArtist(firstArtist.id, customName);
        finalTargetId = firstArtist.id;

        // Merge the rest into it
        final sourceIds = selectedArtists.skip(1).map((a) => a.id).toList();

        if (sourceIds.isNotEmpty) {
          await _apiService.mergeArtists(finalTargetId, sourceIds);
        }
      } else if (targetId != null) {
        // Merge all others into selected target
        final sourceIds = selectedArtists
            .where((a) => a.id != targetId)
            .map((a) => a.id)
            .toList();

        await _apiService.mergeArtists(targetId, sourceIds);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Merged ${selectedArtists.length} artists successfully',
            ),
            backgroundColor: Colors.green,
          ),
        );
      }

      // Clear selection and reload
      setState(() {
        _selectedArtistIds.clear();
      });
      _loadArtists();
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Manual Artist Merge'),
        backgroundColor: const Color(0xFF0d1b2a),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search artists...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                filled: true,
                fillColor: const Color(0xFF1a2332),
              ),
              onChanged: (value) {
                setState(() {
                  _searchQuery = value;
                });
              },
            ),
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Error: $_error'),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _loadArtists,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                if (_selectedArtistIds.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.all(16),
                    color: const Color(0xFF1a2332),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${_selectedArtistIds.length} artists selected',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF00d4ff),
                            ),
                          ),
                        ),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.merge),
                          label: const Text('Merge Selected'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00d4ff),
                            foregroundColor: Colors.black,
                          ),
                          onPressed: _showMergeDialog,
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: () {
                            setState(() {
                              _selectedArtistIds.clear();
                            });
                          },
                          child: const Text('Clear'),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: ListView.builder(
                    itemCount: _filteredArtists.length,
                    itemBuilder: (context, index) {
                      final artist = _filteredArtists[index];
                      final isSelected = _selectedArtistIds.contains(artist.id);

                      return CheckboxListTile(
                        value: isSelected,
                        onChanged: (checked) {
                          setState(() {
                            if (checked == true) {
                              _selectedArtistIds.add(artist.id);
                            } else {
                              _selectedArtistIds.remove(artist.id);
                            }
                          });
                        },
                        title: Text(artist.name),
                        subtitle: Text(
                          '${artist.albumCount} albums • ${artist.songCount} songs',
                        ),
                        secondary:
                            artist.imagePath != null &&
                                artist.imagePath!.isNotEmpty
                            ? ClipOval(
                                child: Image.network(
                                  _apiService.getArtistImageUrl(artist.id),
                                  width: 40,
                                  height: 40,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) {
                                    return const Icon(
                                      Icons.person,
                                      size: 40,
                                      color: Color(0xFF00d4ff),
                                    );
                                  },
                                ),
                              )
                            : const Icon(
                                Icons.person,
                                size: 40,
                                color: Color(0xFF00d4ff),
                              ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}
