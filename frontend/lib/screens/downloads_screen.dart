import 'package:flutter/material.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';

class DownloadsScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;

  const DownloadsScreen({super.key, required this.audioPlayerService});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  final ApiService _apiService = ApiService();
  final TextEditingController _searchController = TextEditingController();

  List<Map<String, dynamic>> _torrents = [];
  bool _isLoading = true;
  String? _error;
  Timer? _refreshTimer;
  Timer? _autoStopTimer;

  // Settings
  int _maxSeedMinutes = 30;
  int _refreshIntervalSeconds = 5;
  bool _autoStopEnabled = true;

  // Sort & Filter
  String _sortBy = 'added'; // status, name, progress, size, added
  bool _sortAscending = false; // false = descending (newest first)
  String _filterStatus = 'all'; // all, downloading, seeding, stopped
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadTorrents();
    _startTimers();
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _autoStopTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _maxSeedMinutes = prefs.getInt('downloads_max_seed_minutes') ?? 30;
      _refreshIntervalSeconds = prefs.getInt('downloads_refresh_interval') ?? 5;
      _autoStopEnabled = prefs.getBool('downloads_auto_stop_enabled') ?? true;
      _sortBy = prefs.getString('downloads_sort_by') ?? 'added';
      _sortAscending = prefs.getBool('downloads_sort_ascending') ?? false;
      _filterStatus = prefs.getString('downloads_filter_status') ?? 'all';
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('downloads_max_seed_minutes', _maxSeedMinutes);
    await prefs.setInt('downloads_refresh_interval', _refreshIntervalSeconds);
    await prefs.setBool('downloads_auto_stop_enabled', _autoStopEnabled);
    await prefs.setString('downloads_sort_by', _sortBy);
    await prefs.setBool('downloads_sort_ascending', _sortAscending);
    await prefs.setString('downloads_filter_status', _filterStatus);
  }

  void _startTimers() {
    _refreshTimer?.cancel();
    _autoStopTimer?.cancel();

    // Refresh timer
    _refreshTimer = Timer.periodic(Duration(seconds: _refreshIntervalSeconds), (
      _,
    ) {
      _loadTorrents(showLoading: false);
    });

    // Auto-stop seeding timer (check every minute)
    if (_autoStopEnabled) {
      _autoStopTimer = Timer.periodic(const Duration(minutes: 1), (_) {
        _stopOldSeeders();
      });
    }
  }

  Future<void> _stopOldSeeders() async {
    if (!_autoStopEnabled) return;

    try {
      final result = await _apiService.stopOldSeeders(_maxSeedMinutes);
      if (result['stopped_count'] > 0) {
        _loadTorrents(showLoading: false);
      }
    } catch (e) {
      // Silent fail
    }
  }

  Future<void> _loadTorrents({bool showLoading = true}) async {
    if (showLoading) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }

    try {
      final result = await _apiService.getTransmissionTorrents();
      // setState-after-dispose guard — caught a 2026-05-25 crash at this
      // exact callsite. See favorite_button.dart for the broader pattern.
      if (!mounted) return;
      if (result['success'] == true) {
        setState(() {
          _torrents = List<Map<String, dynamic>>.from(result['torrents'] ?? []);
          _isLoading = false;
        });
      } else {
        throw Exception(result['error'] ?? 'Unknown error');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _filteredAndSortedTorrents {
    var filtered = _torrents.where((t) {
      // Apply status filter
      if (_filterStatus != 'all') {
        final status = t['status'] as String? ?? '';
        if (_filterStatus == 'downloading' &&
            !['downloading', 'download_wait'].contains(status)) {
          return false;
        }
        if (_filterStatus == 'seeding' &&
            !['seeding', 'seed_wait'].contains(status)) {
          return false;
        }
        if (_filterStatus == 'stopped' && status != 'stopped') {
          return false;
        }
      }

      // Apply search filter
      if (_searchQuery.isNotEmpty) {
        final name = (t['name'] as String? ?? '').toLowerCase();
        if (!name.contains(_searchQuery.toLowerCase())) {
          return false;
        }
      }

      return true;
    }).toList();

    // Sort
    filtered.sort((a, b) {
      int compare;
      switch (_sortBy) {
        case 'name':
          compare = (a['name'] as String? ?? '').compareTo(
            b['name'] as String? ?? '',
          );
          break;
        case 'progress':
          compare = (a['percent_done'] as num? ?? 0).compareTo(
            b['percent_done'] as num? ?? 0,
          );
          break;
        case 'size':
          compare = (a['total_size'] as num? ?? 0).compareTo(
            b['total_size'] as num? ?? 0,
          );
          break;
        case 'added':
          compare = (a['added_date'] as num? ?? 0).compareTo(
            b['added_date'] as num? ?? 0,
          );
          break;
        case 'status':
        default:
          // Custom status order: downloading > seeding > stopped > other
          final statusOrder = {
            'downloading': 0,
            'download_wait': 1,
            'seeding': 2,
            'seed_wait': 3,
            'stopped': 4,
          };
          final aOrder = statusOrder[a['status']] ?? 5;
          final bOrder = statusOrder[b['status']] ?? 5;
          compare = aOrder.compareTo(bOrder);
          break;
      }
      return _sortAscending ? compare : -compare;
    });

    return filtered;
  }

  String _formatSize(int bytes) {
    if (bytes == 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    int unitIndex = 0;
    double size = bytes.toDouble();

    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }

    return '${size.toStringAsFixed(1)} ${units[unitIndex]}';
  }

  String _formatSpeed(int bytesPerSecond) {
    if (bytesPerSecond == 0) return '';
    return '${_formatSize(bytesPerSecond)}/s';
  }

  String _formatEta(int seconds) {
    if (seconds < 0) return '';
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${seconds ~/ 60}m';
    if (seconds < 86400) {
      return '${seconds ~/ 3600}h ${(seconds % 3600) ~/ 60}m';
    }
    return '${seconds ~/ 86400}d';
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'downloading':
      case 'download_wait':
        return const Color(0xFF00d4ff);
      case 'seeding':
      case 'seed_wait':
        return Colors.green;
      case 'stopped':
        return Colors.grey;
      case 'checking':
      case 'check_wait':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  IconData _getStatusIcon(String status) {
    switch (status) {
      case 'downloading':
      case 'download_wait':
        return Icons.download;
      case 'seeding':
      case 'seed_wait':
        return Icons.upload;
      case 'stopped':
        return Icons.pause;
      case 'checking':
      case 'check_wait':
        return Icons.sync;
      default:
        return Icons.help_outline;
    }
  }

  void _showSettingsModal() {
    int tempMaxSeed = _maxSeedMinutes;
    int tempRefresh = _refreshIntervalSeconds;
    bool tempAutoStop = _autoStopEnabled;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1a2332),
          title: const Text('Download Settings'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Auto-stop seeding toggle
                SwitchListTile(
                  title: const Text('Auto-stop seeding'),
                  subtitle: const Text('Stop torrents after seed time limit'),
                  value: tempAutoStop,
                  activeThumbColor: const Color(0xFF00d4ff),
                  onChanged: (value) {
                    setDialogState(() => tempAutoStop = value);
                  },
                ),
                const SizedBox(height: 16),

                // Seed time limit
                Text(
                  'Seed time limit: $tempMaxSeed minutes',
                  style: const TextStyle(fontSize: 14),
                ),
                Slider(
                  value: tempMaxSeed.toDouble(),
                  min: 5,
                  max: 120,
                  divisions: 23,
                  activeColor: const Color(0xFF00d4ff),
                  label: '$tempMaxSeed min',
                  onChanged: tempAutoStop
                      ? (value) {
                          setDialogState(() => tempMaxSeed = value.round());
                        }
                      : null,
                ),
                const SizedBox(height: 16),

                // Refresh interval
                Text(
                  'Refresh interval: $tempRefresh seconds',
                  style: const TextStyle(fontSize: 14),
                ),
                Slider(
                  value: tempRefresh.toDouble(),
                  min: 2,
                  max: 30,
                  divisions: 14,
                  activeColor: const Color(0xFF00d4ff),
                  label: '${tempRefresh}s',
                  onChanged: (value) {
                    setDialogState(() => tempRefresh = value.round());
                  },
                ),
                const SizedBox(height: 16),

                // Manual stop old seeders button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      Navigator.pop(context);
                      final result = await _apiService.stopOldSeeders(
                        tempMaxSeed,
                      );
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Stopped ${result['stopped_count']} torrents',
                            ),
                            backgroundColor: Colors.green,
                          ),
                        );
                        _loadTorrents(showLoading: false);
                      }
                    },
                    icon: const Icon(Icons.stop),
                    label: const Text('Stop Old Seeders Now'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.white,
                    ),
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
              onPressed: () {
                setState(() {
                  _maxSeedMinutes = tempMaxSeed;
                  _refreshIntervalSeconds = tempRefresh;
                  _autoStopEnabled = tempAutoStop;
                });
                _saveSettings();
                _startTimers();
                Navigator.pop(context);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00d4ff),
                foregroundColor: Colors.black,
              ),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _showSortFilterModal() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1a2332),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Sort & Filter',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),

              // Filter by status
              const Text(
                'Filter by Status',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  _buildFilterChip('All', 'all', setSheetState),
                  _buildFilterChip('Downloading', 'downloading', setSheetState),
                  _buildFilterChip('Seeding', 'seeding', setSheetState),
                  _buildFilterChip('Stopped', 'stopped', setSheetState),
                ],
              ),
              const SizedBox(height: 16),

              // Sort by
              const Text(
                'Sort by',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  _buildSortChip('Status', 'status', setSheetState),
                  _buildSortChip('Name', 'name', setSheetState),
                  _buildSortChip('Progress', 'progress', setSheetState),
                  _buildSortChip('Size', 'size', setSheetState),
                  _buildSortChip('Added', 'added', setSheetState),
                ],
              ),
              const SizedBox(height: 16),

              // Sort direction
              Row(
                children: [
                  const Text(
                    'Direction: ',
                    style: TextStyle(color: Colors.grey),
                  ),
                  ChoiceChip(
                    label: const Text('Ascending'),
                    selected: _sortAscending,
                    selectedColor: const Color(0xFF00d4ff),
                    onSelected: (selected) {
                      setSheetState(() => _sortAscending = true);
                      setState(() {});
                      _saveSettings();
                    },
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('Descending'),
                    selected: !_sortAscending,
                    selectedColor: const Color(0xFF00d4ff),
                    onSelected: (selected) {
                      setSheetState(() => _sortAscending = false);
                      setState(() {});
                      _saveSettings();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilterChip(
    String label,
    String value,
    StateSetter setSheetState,
  ) {
    final isSelected = _filterStatus == value;
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      selectedColor: const Color(0xFF00d4ff),
      checkmarkColor: Colors.black,
      onSelected: (selected) {
        setSheetState(() => _filterStatus = value);
        setState(() {});
        _saveSettings();
      },
    );
  }

  Widget _buildSortChip(String label, String value, StateSetter setSheetState) {
    final isSelected = _sortBy == value;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      selectedColor: const Color(0xFF00d4ff),
      onSelected: (selected) {
        setSheetState(() => _sortBy = value);
        setState(() {});
        _saveSettings();
      },
    );
  }

  Future<void> _stopTorrent(Map<String, dynamic> torrent) async {
    try {
      await _apiService.stopTorrent(torrent['id']);
      _loadTorrents(showLoading: false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Stopped: ${torrent['name']}'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _clearCompleted() async {
    // Count completed torrents first
    final completedCount = _torrents
        .where((t) => t['percent_done'] >= 100 && t['status'] == 'stopped')
        .length;

    if (completedCount == 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No completed torrents to clear'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: const Text('Clear Completed'),
        content: Text(
          'Remove $completedCount completed torrent${completedCount == 1 ? '' : 's'} from Transmission?\n\nThis will NOT delete the downloaded files.',
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
            child: const Text('Clear'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final result = await _apiService.clearCompletedTorrents();
      _loadTorrents(showLoading: false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Cleared ${result['removed_count']} torrent${result['removed_count'] == 1 ? '' : 's'}',
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _removeTorrent(
    Map<String, dynamic> torrent, {
    bool deleteData = false,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: const Text('Remove Torrent'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Remove "${torrent['name']}"?'),
            if (deleteData) ...[
              const SizedBox(height: 8),
              const Text(
                'Warning: This will also delete the downloaded files!',
                style: TextStyle(color: Colors.red, fontSize: 12),
              ),
            ],
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
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _apiService.removeTorrent(torrent['id'], deleteData: deleteData);
      _loadTorrents(showLoading: false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Removed: ${torrent['name']}'),
            backgroundColor: Colors.green,
          ),
        );
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
    final filteredTorrents = _filteredAndSortedTorrents;

    // Categorize for stats
    final downloading = _torrents
        .where((t) => ['downloading', 'download_wait'].contains(t['status']))
        .toList();
    final seeding = _torrents
        .where((t) => ['seeding', 'seed_wait'].contains(t['status']))
        .toList();

    return Scaffold(
      backgroundColor: const Color(0xFF0a1929),
      appBar: AppBar(
        title: const Text('Downloads'),
        backgroundColor: const Color(0xFF0d1b2a),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            onPressed: _clearCompleted,
            tooltip: 'Clear Completed',
          ),
          IconButton(
            icon: const Icon(Icons.filter_list),
            onPressed: _showSortFilterModal,
            tooltip: 'Sort & Filter',
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showSettingsModal,
            tooltip: 'Settings',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _loadTorrents(),
          ),
        ],
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search downloads...',
                hintStyle: TextStyle(color: Colors.grey[600]),
                prefixIcon: const Icon(Icons.search, color: Color(0xFF00d4ff)),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, color: Colors.grey),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                filled: true,
                fillColor: const Color(0xFF1a2332),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
              style: const TextStyle(color: Colors.white),
              onChanged: (value) {
                setState(() => _searchQuery = value);
              },
            ),
          ),

          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: Color(0xFF00d4ff)),
                  )
                : _error != null
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.error_outline,
                          color: Colors.red,
                          size: 48,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Error: $_error',
                          style: const TextStyle(color: Colors.red),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: _loadTorrents,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _loadTorrents,
                    child: ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      children: [
                        // Stats header
                        _buildStatsHeader(downloading, seeding),
                        const SizedBox(height: 12),

                        // Active filters indicator
                        if (_filterStatus != 'all' || _searchQuery.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              children: [
                                Text(
                                  'Showing ${filteredTorrents.length} of ${_torrents.length}',
                                  style: TextStyle(
                                    color: Colors.grey[500],
                                    fontSize: 12,
                                  ),
                                ),
                                const Spacer(),
                                if (_filterStatus != 'all' ||
                                    _searchQuery.isNotEmpty)
                                  TextButton(
                                    onPressed: () {
                                      setState(() {
                                        _filterStatus = 'all';
                                        _searchQuery = '';
                                        _searchController.clear();
                                      });
                                    },
                                    child: const Text(
                                      'Clear filters',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                  ),
                              ],
                            ),
                          ),

                        // Torrent list
                        if (filteredTorrents.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(32),
                            child: Center(
                              child: Column(
                                children: [
                                  Icon(
                                    Icons.search_off,
                                    size: 48,
                                    color: Colors.grey[700],
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    _torrents.isEmpty
                                        ? 'No downloads'
                                        : 'No matching downloads',
                                    style: TextStyle(color: Colors.grey[600]),
                                  ),
                                ],
                              ),
                            ),
                          )
                        else
                          ...filteredTorrents.map(_buildTorrentCard),

                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsHeader(
    List<Map<String, dynamic>> downloading,
    List<Map<String, dynamic>> seeding,
  ) {
    final totalDownSpeed = _torrents.fold<int>(
      0,
      (sum, t) => sum + (t['download_speed'] as int? ?? 0),
    );
    final totalUpSpeed = _torrents.fold<int>(
      0,
      (sum, t) => sum + (t['upload_speed'] as int? ?? 0),
    );

    // Count by health status
    final alive = _torrents.where((t) {
      final h = t['health'] as String? ?? '';
      return ['downloading', 'alive', 'seeding'].contains(h);
    }).length;
    final dead = _torrents.where((t) => t['health'] == 'dead').length;
    final meta = _torrents.where((t) => t['health'] == 'metadata').length;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1a2332),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF00d4ff).withOpacity(0.2)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildStatItem(
            Icons.list,
            Colors.white,
            '${_torrents.length}',
            'Total',
          ),
          _buildStatItem(
            Icons.check_circle_outline,
            Colors.green,
            '$alive',
            'Alive',
          ),
          if (dead > 0)
            _buildStatItem(
              Icons.cancel_outlined,
              Colors.red,
              '$dead',
              'Dead',
            ),
          if (meta > 0)
            _buildStatItem(
              Icons.hourglass_top,
              const Color(0xFF9c27b0),
              '$meta',
              'Meta',
            ),
          _buildStatItem(
            Icons.arrow_downward,
            const Color(0xFF00d4ff),
            _formatSpeed(totalDownSpeed),
            'Down',
          ),
          _buildStatItem(
            Icons.arrow_upward,
            Colors.green,
            _formatSpeed(totalUpSpeed),
            'Up',
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(
    IconData icon,
    Color color,
    String value,
    String label,
  ) {
    return Column(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 4),
        Text(
          value.isEmpty ? '-' : value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(label, style: TextStyle(color: Colors.grey[500], fontSize: 11)),
      ],
    );
  }

  Color _getHealthColor(String health) {
    switch (health) {
      case 'seeding':
        return Colors.green;
      case 'downloading':
        return const Color(0xFF00d4ff);
      case 'alive':
        return Colors.amber;
      case 'metadata':
        return const Color(0xFF9c27b0);
      case 'stalled':
        return Colors.orange;
      case 'dead':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  String _getHealthLabel(String health, {double metadataPercent = 100}) {
    switch (health) {
      case 'seeding':
        return 'SEEDING';
      case 'downloading':
        return 'ACTIVE';
      case 'alive':
        return 'ALIVE';
      case 'metadata':
        return 'META ${metadataPercent.toStringAsFixed(0)}%';
      case 'stalled':
        return 'STALLED';
      case 'dead':
        return 'DEAD';
      default:
        return health.toUpperCase();
    }
  }

  Widget _buildTorrentCard(Map<String, dynamic> torrent) {
    final name = torrent['name'] as String? ?? 'Unknown';
    final status = torrent['status'] as String? ?? 'unknown';
    final percentDone = (torrent['percent_done'] as num?)?.toDouble() ?? 0;
    final totalSize = torrent['total_size'] as int? ?? 0;
    final downloadSpeed = torrent['download_speed'] as int? ?? 0;
    final uploadSpeed = torrent['upload_speed'] as int? ?? 0;
    final eta = torrent['eta'] as int? ?? -1;
    final isFinished = torrent['is_finished'] as bool? ?? false;
    final error = torrent['error'] as String? ?? '';

    // New health fields
    final health = torrent['health'] as String? ?? '';
    final seeders = torrent['seeders'] as int? ?? 0;
    final leechers = torrent['leechers'] as int? ?? 0;
    final metadataPercent = (torrent['metadata_percent'] as num?)?.toDouble() ?? 100;
    final peers = torrent['peers_connected'] as int? ?? 0;
    // Red "0 peers" only when the torrent is actually trying (not stopped,
    // not done) — that's when nobody-home is the problem.
    final isActive = !isFinished && status != 'stopped' && percentDone < 100;
    final peersColor = peers > 0
        ? Colors.grey[500]
        : (isActive ? Colors.red[300] : Colors.grey[600]);

    final statusColor = _getStatusColor(status);
    final statusIcon = _getStatusIcon(status);
    final healthColor = health.isNotEmpty ? _getHealthColor(health) : statusColor;

    // Use health color for card border when health data is available
    final borderColor = health.isNotEmpty ? healthColor : statusColor;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1a2332),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor.withOpacity(0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Name and status
            Row(
              children: [
                Icon(statusIcon, color: statusColor, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // Actions menu
                PopupMenuButton<String>(
                  icon: Icon(
                    Icons.more_vert,
                    color: Colors.grey[600],
                    size: 20,
                  ),
                  color: const Color(0xFF1a2332),
                  onSelected: (value) {
                    switch (value) {
                      case 'stop':
                        _stopTorrent(torrent);
                        break;
                      case 'remove':
                        _removeTorrent(torrent);
                        break;
                      case 'remove_data':
                        _removeTorrent(torrent, deleteData: true);
                        break;
                    }
                  },
                  itemBuilder: (context) => [
                    if (status != 'stopped')
                      const PopupMenuItem(
                        value: 'stop',
                        child: Row(
                          children: [
                            Icon(Icons.stop, size: 18),
                            SizedBox(width: 8),
                            Text('Stop'),
                          ],
                        ),
                      ),
                    const PopupMenuItem(
                      value: 'remove',
                      child: Row(
                        children: [
                          Icon(Icons.delete_outline, size: 18),
                          SizedBox(width: 8),
                          Text('Remove'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'remove_data',
                      child: Row(
                        children: [
                          Icon(
                            Icons.delete_forever,
                            size: 18,
                            color: Colors.red,
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Remove + Delete Files',
                            style: TextStyle(color: Colors.red),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),

            // Error message if any
            if (error.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                error,
                style: const TextStyle(color: Colors.red, fontSize: 11),
              ),
            ],

            // Health info row
            if (health.isNotEmpty && status != 'seeding' && percentDone < 100) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  // Health badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: healthColor.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: healthColor.withOpacity(0.5), width: 1),
                    ),
                    child: Text(
                      _getHealthLabel(health, metadataPercent: metadataPercent),
                      style: TextStyle(
                        color: healthColor,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  // Seeders badge
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: (seeders > 0 ? Colors.green : Colors.red).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.arrow_upward, size: 10,
                          color: seeders > 0 ? Colors.green : Colors.red[300]),
                        const SizedBox(width: 2),
                        Text(
                          '$seeders seed',
                          style: TextStyle(
                            color: seeders > 0 ? Colors.green : Colors.red[300],
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Leechers badge
                  if (leechers > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
                            style: TextStyle(color: Colors.grey[500], fontSize: 10),
                          ),
                        ],
                      ),
                    ),
                  // Peers badge — always shown. Tracker seeder counts are
                  // claims; "0 peers" on an active torrent is the one number
                  // that proves nobody has actually shown up.
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: (peers > 0 || !isActive ? Colors.grey : Colors.red)
                          .withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.people, size: 10, color: peersColor),
                        const SizedBox(width: 2),
                        Text(
                          '$peers peers',
                          style: TextStyle(color: peersColor, fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],

            const SizedBox(height: 10),

            // Progress bar (show metadata progress if still getting metadata)
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: health == 'metadata'
                    ? metadataPercent / 100
                    : percentDone / 100,
                backgroundColor: Colors.grey[800],
                valueColor: AlwaysStoppedAnimation<Color>(
                  isFinished || percentDone >= 100
                      ? Colors.green
                      : (health == 'metadata' ? const Color(0xFF9c27b0) : statusColor),
                ),
                minHeight: 6,
              ),
            ),

            const SizedBox(height: 8),

            // Stats row
            Row(
              children: [
                // Percent
                Text(
                  health == 'metadata'
                      ? 'Meta ${metadataPercent.toStringAsFixed(0)}%'
                      : '${percentDone.toStringAsFixed(1)}%',
                  style: TextStyle(
                    color: health == 'metadata' ? const Color(0xFF9c27b0) : statusColor,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 12),

                // Size (only show if we have metadata)
                if (totalSize > 0) ...[
                  Icon(Icons.storage, size: 12, color: Colors.grey[600]),
                  const SizedBox(width: 4),
                  Text(
                    _formatSize(totalSize),
                    style: TextStyle(color: Colors.grey[500], fontSize: 11),
                  ),
                ],

                const Spacer(),

                // Download speed
                if (downloadSpeed > 0) ...[
                  Icon(
                    Icons.arrow_downward,
                    size: 12,
                    color: const Color(0xFF00d4ff),
                  ),
                  const SizedBox(width: 2),
                  Text(
                    _formatSpeed(downloadSpeed),
                    style: const TextStyle(
                      color: Color(0xFF00d4ff),
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],

                // Upload speed
                if (uploadSpeed > 0) ...[
                  Icon(Icons.arrow_upward, size: 12, color: Colors.green),
                  const SizedBox(width: 2),
                  Text(
                    _formatSpeed(uploadSpeed),
                    style: const TextStyle(color: Colors.green, fontSize: 11),
                  ),
                  const SizedBox(width: 8),
                ],

                // ETA
                if (eta > 0) ...[
                  Icon(Icons.schedule, size: 12, color: Colors.grey[600]),
                  const SizedBox(width: 4),
                  Text(
                    _formatEta(eta),
                    style: TextStyle(color: Colors.grey[500], fontSize: 11),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
