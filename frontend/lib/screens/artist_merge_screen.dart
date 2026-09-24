import 'package:flutter/material.dart';
import '../models/artist.dart';
import '../services/api_service.dart';

class ArtistMergeScreen extends StatefulWidget {
  const ArtistMergeScreen({super.key});

  @override
  State<ArtistMergeScreen> createState() => _ArtistMergeScreenState();
}

class _ArtistMergeScreenState extends State<ArtistMergeScreen> {
  final ApiService _apiService = ApiService();
  List<List<Artist>> _suggestions = [];
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
      final suggestions = await _apiService.findSimilarArtists();
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

  Future<void> _showMergeDialog(List<Artist> group) async {
    int? selectedTarget;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Merge Artists'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Select the artist to keep (others will be merged into it):',
                  style: TextStyle(fontSize: 14, color: Colors.grey),
                ),
                const SizedBox(height: 16),
                ...group.map((artist) {
                  return Row(
                    children: [
                      Expanded(
                        child: RadioListTile<int>(
                          title: Text(artist.name),
                          subtitle: Text(
                            '${artist.albumCount} albums • ${artist.songCount} songs',
                            style: const TextStyle(fontSize: 12),
                          ),
                          value: artist.id,
                          groupValue: selectedTarget,
                          onChanged: (value) {
                            setDialogState(() {
                              selectedTarget = value;
                            });
                          },
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit, size: 18),
                        tooltip: 'Rename',
                        onPressed: () async {
                          Navigator.pop(context); // Close merge dialog first
                          await _showRenameDialog(artist);
                          // Refresh suggestions after rename/merge
                          _loadSuggestions();
                        },
                      ),
                    ],
                  );
                }),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: selectedTarget == null
                  ? null
                  : () async {
                      Navigator.pop(context);
                      await _performMerge(selectedTarget!, group);
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

  Future<void> _showRenameDialog(Artist artist) async {
    final TextEditingController controller = TextEditingController(
      text: artist.name,
    );

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Artist'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Artist Name',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
          onSubmitted: (value) => Navigator.pop(context, value),
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
            child: const Text('Rename'),
          ),
        ],
      ),
    );

    if (result == null || result.isEmpty) return;

    final newName = result;

    try {
      await _apiService.editArtist(artist.id, newName);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Renamed to "$newName"'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      // Check if error is about duplicate name
      if (e.toString().contains('already exists')) {
        if (mounted) {
          // Show merge confirmation dialog
          final shouldMerge = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Artist Already Exists'),
              content: Text(
                'An artist named "$newName" already exists.\n\n'
                'Would you like to merge "${artist.name}" into "$newName"?',
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
                  child: const Text('Merge'),
                ),
              ],
            ),
          );

          if (shouldMerge == true && mounted) {
            // Find the target artist by name
            try {
              final artists = await _apiService.getArtists();
              final targetArtist = artists.firstWhere((a) => a.name == newName);

              // Perform merge
              await _apiService.mergeArtists(targetArtist.id, [artist.id]);

              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Merged into "$newName"'),
                    backgroundColor: Colors.green,
                  ),
                );
              }
            } catch (mergeError) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Merge failed: $mergeError'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            }
          }
        }
      } else {
        // Other error
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  Future<void> _performMerge(int targetId, List<Artist> group) async {
    // Get source IDs (all except target)
    final sourceIds = group
        .where((artist) => artist.id != targetId)
        .map((artist) => artist.id)
        .toList();

    try {
      await _apiService.mergeArtists(targetId, sourceIds);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Merged ${sourceIds.length} artists successfully'),
            backgroundColor: Colors.green,
          ),
        );
      }

      // Reload suggestions
      _loadSuggestions();
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
        title: const Text('Merge Duplicate Artists'),
        backgroundColor: const Color(0xFF0d1b2a),
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
                  Icon(Icons.check_circle, size: 80, color: Colors.green),
                  SizedBox(height: 16),
                  Text(
                    'No duplicate artists found!',
                    style: TextStyle(fontSize: 18),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Your library is clean.',
                    style: TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
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
                              Icons.warning,
                              color: Colors.orange,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Possible duplicates (${group.length} variants)',
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF00d4ff),
                                ),
                              ),
                            ),
                            ElevatedButton.icon(
                              onPressed: () => _showMergeDialog(group),
                              icon: const Icon(Icons.merge, size: 16),
                              label: const Text('Merge'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF00d4ff),
                                foregroundColor: Colors.black,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        ...group.map((artist) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                const SizedBox(width: 28),
                                const Icon(
                                  Icons.person,
                                  size: 16,
                                  color: Colors.white54,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    artist.name,
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                ),
                                Text(
                                  '${artist.albumCount} albums • ${artist.songCount} songs',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
