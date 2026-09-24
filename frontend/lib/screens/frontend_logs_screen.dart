import 'package:flutter/material.dart';
import 'dart:async';
import '../services/app_logger.dart';

class FrontendLogsScreen extends StatefulWidget {
  const FrontendLogsScreen({super.key});

  @override
  State<FrontendLogsScreen> createState() => _FrontendLogsScreenState();
}

class _FrontendLogsScreenState extends State<FrontendLogsScreen> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  List<LogEntry> _filteredLogs = [];
  LogLevel? _levelFilter;
  bool _autoScroll = true;
  StreamSubscription<LogEntry>? _logSubscription;

  @override
  void initState() {
    super.initState();
    _applyFilter();
    // Initial open: jump to bottom (latest log entries). Done as a
    // post-frame callback so the ListView has had a chance to lay out.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    _logSubscription = AppLogger.instance.stream.listen((_) {
      if (mounted) {
        _applyFilter();
        if (_autoScroll) {
          _scrollToBottom();
        }
      }
    });
    _scrollController.addListener(() {
      if (_scrollController.hasClients) {
        final maxScroll = _scrollController.position.maxScrollExtent;
        final currentScroll = _scrollController.position.pixels;
        if (maxScroll - currentScroll > 100) {
          _autoScroll = false;
        }
      }
    });
  }

  /// Recursive jump-to-bottom. `ListView.builder` is lazy — its
  /// `maxScrollExtent` only reflects items currently built into the
  /// viewport, not the full list. Each `jumpTo` builds more items;
  /// we keep jumping until the position is stable (pixels ==
  /// maxScrollExtent), then stop.
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

  @override
  void dispose() {
    _logSubscription?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _applyFilter() {
    final search = _searchController.text.toLowerCase();
    setState(() {
      _filteredLogs = AppLogger.instance.entries.where((entry) {
        if (_levelFilter != null && entry.level != _levelFilter) return false;
        if (search.isNotEmpty && !entry.message.toLowerCase().contains(search)) return false;
        return true;
      }).toList();
    });
  }

  Color _levelColor(LogLevel level) {
    switch (level) {
      case LogLevel.error:
        return const Color(0xFFFF6B6B);
      case LogLevel.warning:
        return const Color(0xFFFFD93D);
      case LogLevel.info:
        return const Color(0xFFE0E0E0);
    }
  }

  IconData _levelIcon(LogLevel level) {
    switch (level) {
      case LogLevel.error:
        return Icons.error_outline;
      case LogLevel.warning:
        return Icons.warning_amber;
      case LogLevel.info:
        return Icons.info_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0a0e14),
      appBar: AppBar(
        title: const Text('Frontend Logs'),
        backgroundColor: const Color(0xFF0d1b2a),
        actions: [
          IconButton(
            icon: const Icon(Icons.vertical_align_top),
            tooltip: 'Jump to top (oldest)',
            onPressed: () {
              _autoScroll = false;
              _scrollToTop();
            },
          ),
          IconButton(
            icon: const Icon(Icons.vertical_align_bottom),
            tooltip: 'Jump to bottom (newest)',
            onPressed: () {
              setState(() => _autoScroll = true);
              _scrollToBottom();
            },
          ),
          IconButton(
            icon: Icon(
              _autoScroll ? Icons.play_arrow : Icons.pause,
              color: _autoScroll ? const Color(0xFF00d4ff) : Colors.grey,
            ),
            tooltip: _autoScroll ? 'Auto-scrolling' : 'Paused',
            onPressed: () {
              setState(() => _autoScroll = !_autoScroll);
              if (_autoScroll) {
                _scrollToBottom();
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear logs',
            onPressed: () async {
              await AppLogger.instance.clear();
              _applyFilter();
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _autoScroll = true;
              _applyFilter();
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
                _buildFilterChip('All', null),
                const SizedBox(width: 6),
                _buildFilterChip('Errors', LogLevel.error),
                const SizedBox(width: 6),
                _buildFilterChip('Warnings', LogLevel.warning),
                const SizedBox(width: 12),
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
                        hintStyle: TextStyle(color: Colors.grey[600], fontSize: 13),
                        prefixIcon: Icon(Icons.search, size: 18, color: Colors.grey[600]),
                        suffixIcon: _searchController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 16),
                                onPressed: () {
                                  _searchController.clear();
                                  _applyFilter();
                                },
                              )
                            : null,
                        filled: true,
                        fillColor: const Color(0xFF1a2332),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      onSubmitted: (_) => _applyFilter(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Log entries
          Expanded(
            child: _filteredLogs.isEmpty
                ? Center(
                    child: Text('No logs found', style: TextStyle(color: Colors.grey[600])),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: _filteredLogs.length,
                    padding: const EdgeInsets.all(8),
                    itemBuilder: (context, index) {
                      final entry = _filteredLogs[index];
                      final time = '${entry.timestamp.hour.toString().padLeft(2, '0')}:${entry.timestamp.minute.toString().padLeft(2, '0')}:${entry.timestamp.second.toString().padLeft(2, '0')}';

                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              time,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                                color: Colors.grey[600],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(_levelIcon(entry.level), size: 14, color: _levelColor(entry.level)),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                entry.message,
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                  color: _levelColor(entry.level),
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
                    '${_filteredLogs.length} entries (${AppLogger.instance.entries.length} total)',
                    style: TextStyle(color: Colors.grey[500], fontSize: 11, fontFamily: 'monospace'),
                  ),
                  const Spacer(),
                  Icon(Icons.circle, size: 8, color: Colors.green),
                  const SizedBox(width: 4),
                  Text(
                    'Local',
                    style: TextStyle(color: Colors.grey[500], fontSize: 11, fontFamily: 'monospace'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, LogLevel? level) {
    final isSelected = _levelFilter == level;
    return GestureDetector(
      onTap: () {
        setState(() => _levelFilter = level);
        _applyFilter();
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
