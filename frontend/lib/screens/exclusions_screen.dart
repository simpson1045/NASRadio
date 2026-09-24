import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';

class ExclusionsScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;
  final bool showMiniPlayer;

  const ExclusionsScreen({
    super.key,
    required this.audioPlayerService,
    this.showMiniPlayer = true,
  });

  @override
  State<ExclusionsScreen> createState() => _ExclusionsScreenState();
}

class _ExclusionsScreenState extends State<ExclusionsScreen> {
  final ApiService _apiService = ApiService();
  final TextEditingController _searchController = TextEditingController();

  List<Map<String, dynamic>> _exclusions = [];
  List<Map<String, dynamic>> _filteredExclusions = [];
  bool _isLoading = true;
  String? _error;
  String _searchQuery = '';
  bool _selectMode = false;
  Set<int> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _loadExclusions();
  }

  Future<void> _loadExclusions() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final exclusions = await _apiService.getExcludedPaths();
      setState(() {
        _exclusions = exclusions;
        _filteredExclusions = exclusions;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _filterExclusions(String query) {
    setState(() {
      _searchQuery = query.toLowerCase();
      if (_searchQuery.isEmpty) {
        _filteredExclusions = _exclusions;
      } else {
        _filteredExclusions = _exclusions.where((exclusion) {
          final title = (exclusion['original_title'] ?? '').toLowerCase();
          final artist = (exclusion['original_artist'] ?? '').toLowerCase();
          final album = (exclusion['original_album'] ?? '').toLowerCase();
          return title.contains(_searchQuery) ||
              artist.contains(_searchQuery) ||
              album.contains(_searchQuery);
        }).toList();
      }
    });
  }

  Future<void> _restoreSelected() async {
    final count = _selectedIds.length;
    try {
      for (final id in _selectedIds) {
        await _apiService.restoreExcludedPath(id);
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Restored $count files - will be imported on next scan',
          ),
          backgroundColor: Colors.green,
        ),
      );
      setState(() {
        _selectMode = false;
        _selectedIds.clear();
      });
      _loadExclusions();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to restore: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _restoreExclusion(int exclusionId, String title) async {
    try {
      await _apiService.restoreExcludedPath(exclusionId);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Restored "$title" - will be imported on next scan'),
          backgroundColor: Colors.green,
        ),
      );
      _loadExclusions();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to restore: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _clearAllExclusions() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1b2838),
        title: const Text('Clear All Exclusions?'),
        content: Text(
          'This will allow all ${_exclusions.length} excluded files to be re-imported on the next scan.\n\nThis cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _apiService.clearAllExclusions();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('All exclusions cleared'),
            backgroundColor: Colors.green,
          ),
        );
        _loadExclusions();
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to clear exclusions: $e'),
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
        title: const Text('Excluded Files'),
        backgroundColor: const Color(0xFF0d1b2a),
        actions: [
          if (_exclusions.isNotEmpty) ...[
            IconButton(
              icon: Icon(_selectMode ? Icons.close : Icons.checklist),
              tooltip: _selectMode ? 'Cancel Selection' : 'Select Multiple',
              onPressed: () {
                setState(() {
                  _selectMode = !_selectMode;
                  _selectedIds.clear();
                });
              },
            ),
            if (!_selectMode)
              IconButton(
                icon: const Icon(Icons.delete_sweep),
                tooltip: 'Clear All Exclusions',
                onPressed: _clearAllExclusions,
              ),
          ],
        ],
      ),
      body: Column(
        children: [
          // Search bar
          if (!_isLoading && _exclusions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search by title, artist, or album...',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchController.clear();
                            _filterExclusions('');
                          },
                        )
                      : null,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  filled: true,
                  fillColor: const Color(0xFF1a2332),
                ),
                onChanged: _filterExclusions,
              ),
            ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('Error: $_error'),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: _loadExclusions,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  )
                : _filteredExclusions.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _searchQuery.isNotEmpty
                              ? Icons.search_off
                              : Icons.check_circle_outline,
                          size: 80,
                          color: Colors.grey,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _searchQuery.isNotEmpty
                              ? 'No results for "$_searchQuery"'
                              : 'No excluded files',
                          style: const TextStyle(
                            fontSize: 18,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _searchQuery.isNotEmpty
                              ? 'Try a different search term'
                              : 'Deleted songs will appear here',
                          style: const TextStyle(
                            fontSize: 14,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _loadExclusions,
                    child: ListView.builder(
                      itemCount: _filteredExclusions.length,
                      itemBuilder: (context, index) {
                        final exclusion = _filteredExclusions[index];
                        final title = exclusion['original_title'] ?? 'Unknown';
                        final artist =
                            exclusion['original_artist'] ?? 'Unknown';
                        final album = exclusion['original_album'] ?? 'Unknown';

                        final isSelected = _selectedIds.contains(
                          exclusion['id'],
                        );
                        return ListTile(
                          leading: _selectMode
                              ? Checkbox(
                                  value: isSelected,
                                  onChanged: (value) {
                                    setState(() {
                                      if (value == true) {
                                        _selectedIds.add(exclusion['id']);
                                      } else {
                                        _selectedIds.remove(exclusion['id']);
                                      }
                                    });
                                  },
                                  activeColor: const Color(0xFF00d4ff),
                                )
                              : const Icon(
                                  Icons.block,
                                  size: 40,
                                  color: Colors.red,
                                ),
                          title: Text(title),
                          subtitle: Text('$artist • $album'),
                          trailing: _selectMode
                              ? null
                              : IconButton(
                                  icon: const Icon(
                                    Icons.restore,
                                    color: Color(0xFF00d4ff),
                                  ),
                                  tooltip: 'Restore (allow re-import)',
                                  onPressed: () =>
                                      _restoreExclusion(exclusion['id'], title),
                                ),
                          onTap: _selectMode
                              ? () {
                                  setState(() {
                                    if (isSelected) {
                                      _selectedIds.remove(exclusion['id']);
                                    } else {
                                      _selectedIds.add(exclusion['id']);
                                    }
                                  });
                                }
                              : null,
                        );
                      },
                    ),
                  ),
          ),
          // Selection action bar
          if (_selectMode)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              color: const Color(0xFF1a2332),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _selectedIds = _filteredExclusions
                            .map((e) => e['id'] as int)
                            .toSet();
                      });
                    },
                    child: const Text('Select All'),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _selectedIds.clear();
                      });
                    },
                    child: const Text('Select None'),
                  ),
                  const Spacer(),
                  Text(
                    '${_selectedIds.length} selected',
                    style: const TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton.icon(
                    onPressed: _restoreSelected,
                    icon: const Icon(Icons.restore, size: 18),
                    label: const Text('Restore'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00d4ff),
                      foregroundColor: Colors.black,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
