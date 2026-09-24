import 'package:flutter/material.dart';
import 'dart:async';
import '../services/api_service.dart';

class SystemLogsScreen extends StatefulWidget {
  const SystemLogsScreen({super.key});

  @override
  State<SystemLogsScreen> createState() => _SystemLogsScreenState();
}

class _SystemLogsScreenState extends State<SystemLogsScreen> {
  final ApiService _apiService = ApiService();
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  List<Map<String, dynamic>> _logs = [];
  String? _levelFilter;
  bool _isLoading = true;
  bool _autoScroll = true;
  Timer? _refreshTimer;
  String? _error;
  Map<String, dynamic>? _poolInfo;
  bool _essentia = false;
  bool _transcode = false;

  @override
  void initState() {
    super.initState();
    _loadLogs();
    _loadHealth();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) {
        _loadLogs();
        _loadHealth();
      },
    );
    _scrollController.addListener(() {
      // Disable auto-scroll if user scrolls up
      if (_scrollController.hasClients) {
        final maxScroll = _scrollController.position.maxScrollExtent;
        final currentScroll = _scrollController.position.pixels;
        if (maxScroll - currentScroll > 100) {
          _autoScroll = false;
        }
      }
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// Jump the scroll view to the very end of the list. Called recursively
  /// via `addPostFrameCallback` because `ListView.builder` is lazy — its
  /// `maxScrollExtent` only reflects items currently built into the
  /// viewport (~10-15), not the full 500-item list. Each `jumpTo` builds
  /// more items, extending `maxScrollExtent`. We keep jumping until the
  /// scroll position is stable (pixels == maxScrollExtent), then stop.
  /// Without this recursion, the previous single-call `jumpTo` barely
  /// moved past the first viewport's worth of items.
  void _scrollToBottom() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      if (max > _scrollController.position.pixels + 1) {
        _scrollController.jumpTo(max);
        _scrollToBottom();
      }
    });
  }

  void _scrollToTop() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _loadLogs() async {
    try {
      final result = await _apiService.getLogs(
        lines: 500,
        level: _levelFilter,
        search: _searchController.text.isEmpty ? null : _searchController.text,
      );
      if (mounted) {
        setState(() {
          _logs = List<Map<String, dynamic>>.from(result['logs'] ?? []);
          _isLoading = false;
          _error = null;
        });
        if (_autoScroll) {
          _scrollToBottom();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadHealth() async {
    try {
      final result = await _apiService.getHealth();
      if (mounted) {
        setState(() {
          _poolInfo = result['pool'] as Map<String, dynamic>?;
          _essentia = result['essentia'] == true;
          _transcode = result['transcode'] == true;
        });
      }
    } catch (_) {}
  }

  Color _levelColor(String level) {
    switch (level) {
      case 'error':
        return const Color(0xFFFF6B6B);
      case 'warning':
        return const Color(0xFFFFD93D);
      default:
        return const Color(0xFFE0E0E0);
    }
  }

  IconData _levelIcon(String level) {
    switch (level) {
      case 'error':
        return Icons.error_outline;
      case 'warning':
        return Icons.warning_amber;
      default:
        return Icons.info_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0a0e14),
      appBar: AppBar(
        title: const Text('System Logs'),
        backgroundColor: const Color(0xFF0d1b2a),
        actions: [
          // Jump to top
          IconButton(
            icon: const Icon(Icons.vertical_align_top),
            tooltip: 'Jump to top (oldest)',
            onPressed: () {
              _autoScroll = false;
              _scrollToTop();
            },
          ),
          // Jump to bottom (also flips auto-scroll back on, since you
          // clearly want to be following the tail again)
          IconButton(
            icon: const Icon(Icons.vertical_align_bottom),
            tooltip: 'Jump to bottom (newest)',
            onPressed: () {
              setState(() => _autoScroll = true);
              _scrollToBottom();
            },
          ),
          // Auto-scroll toggle
          IconButton(
            icon: Icon(
              _autoScroll ? Icons.play_arrow : Icons.pause,
              color: _autoScroll ? const Color(0xFF00d4ff) : Colors.grey,
            ),
            tooltip: _autoScroll ? 'Auto-scrolling' : 'Paused',
            onPressed: () {
              setState(() {
                _autoScroll = !_autoScroll;
              });
              if (_autoScroll) {
                _scrollToBottom();
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _autoScroll = true;
              _loadLogs();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Filter bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: const Color(0xFF111820),
            child: Row(
              children: [
                // Level filter chips
                _buildFilterChip('All', null),
                const SizedBox(width: 6),
                _buildFilterChip('Errors', 'error'),
                const SizedBox(width: 6),
                _buildFilterChip('Warnings', 'warning'),
                const SizedBox(width: 12),
                // Search
                Expanded(
                  child: SizedBox(
                    height: 36,
                    child: TextField(
                      controller: _searchController,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontFamily: 'monospace',
                      ),
                      decoration: InputDecoration(
                        hintText: 'Search logs...',
                        hintStyle: TextStyle(
                          color: Colors.grey[600],
                          fontSize: 13,
                        ),
                        prefixIcon: Icon(
                          Icons.search,
                          size: 18,
                          color: Colors.grey[600],
                        ),
                        suffixIcon: _searchController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 16),
                                onPressed: () {
                                  _searchController.clear();
                                  _loadLogs();
                                },
                              )
                            : null,
                        filled: true,
                        fillColor: const Color(0xFF1a2332),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                      ),
                      onSubmitted: (_) => _loadLogs(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Log entries
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Text(
                          'Error: $_error',
                          style: const TextStyle(color: Colors.red),
                        ),
                      )
                    : _logs.isEmpty
                        ? Center(
                            child: Text(
                              'No logs found',
                              style: TextStyle(color: Colors.grey[600]),
                            ),
                          )
                        : ListView.builder(
                            controller: _scrollController,
                            itemCount: _logs.length,
                            padding: const EdgeInsets.all(8),
                            itemBuilder: (context, index) {
                              final log = _logs[index];
                              final level = log['level'] ?? 'info';
                              final message = log['message'] ?? '';
                              final timestamp = log['timestamp'] ?? '';
                              // Extract just the time portion
                              final time = timestamp.length >= 19
                                  ? timestamp.substring(11, 19)
                                  : timestamp;

                              return Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 1),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // Timestamp
                                    Text(
                                      time,
                                      style: TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 11,
                                        color: Colors.grey[600],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    // Level indicator
                                    Icon(
                                      _levelIcon(level),
                                      size: 14,
                                      color: _levelColor(level),
                                    ),
                                    const SizedBox(width: 6),
                                    // Message
                                    Expanded(
                                      child: Text(
                                        message,
                                        style: TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 12,
                                          color: _levelColor(level),
                                          height: 1.4,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
          ),
          // Status bar — SafeArea keeps it above the Android system nav bar
          SafeArea(
            top: false,
            left: false,
            right: false,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: const Color(0xFF111820),
              child: Row(
                children: [
                  Text(
                    '${_logs.length} entries',
                    style: TextStyle(
                      color: Colors.grey[500],
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                  if (_poolInfo != null) ...[
                    const SizedBox(width: 16),
                    Icon(Icons.storage, size: 12, color: Colors.grey[600]),
                    const SizedBox(width: 4),
                    Text(
                      'PG ${_poolInfo!['checked_out'] ?? 0} active, ${_poolInfo!['total_created'] ?? '?'}/${_poolInfo!['maxconn'] ?? '?'} pool',
                      style: TextStyle(
                        color: Colors.grey[500],
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                  const SizedBox(width: 16),
                  Icon(Icons.psychology, size: 12,
                    color: _essentia ? Colors.green : Colors.red),
                  const SizedBox(width: 3),
                  Text('Essentia',
                    style: TextStyle(
                      color: _essentia ? Colors.grey[400] : Colors.grey[600],
                      fontSize: 11, fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Icon(Icons.swap_horiz, size: 12,
                    color: _transcode ? Colors.green : Colors.red),
                  const SizedBox(width: 3),
                  Text('Transcode',
                    style: TextStyle(
                      color: _transcode ? Colors.grey[400] : Colors.grey[600],
                      fontSize: 11, fontFamily: 'monospace',
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    Icons.circle,
                    size: 8,
                    color: _error == null ? Colors.green : Colors.red,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _error == null ? 'Live' : 'Disconnected',
                    style: TextStyle(
                      color: Colors.grey[500],
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, String? level) {
    final isSelected = _levelFilter == level;
    return GestureDetector(
      onTap: () {
        setState(() {
          _levelFilter = level;
        });
        _loadLogs();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF00d4ff) : const Color(0xFF1a2332),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.black : Colors.grey[400],
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}
