import 'dart:io';
import 'package:flutter/material.dart';
import '../models/rss_feed.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import 'rss_feed_detail_screen.dart';

class RssFeedsScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;
  final bool showMiniPlayer;

  const RssFeedsScreen({
    super.key,
    required this.audioPlayerService,
    this.showMiniPlayer = true,
  });

  @override
  State<RssFeedsScreen> createState() => _RssFeedsScreenState();
}

class _RssFeedsScreenState extends State<RssFeedsScreen> {
  final ApiService _apiService = ApiService();
  List<RssFeed> _feeds = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadFeeds();
  }

  Future<void> _loadFeeds() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final feeds = await _apiService.getRssFeeds();
      setState(() {
        _feeds = feeds.map((f) => RssFeed.fromJson(f)).toList();
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  /// Surfaces the OPML export URL so the user can open it in a browser
  /// and save the file. Could use url_launcher to auto-open, but showing
  /// the URL also lets the user curl it from a desktop if they'd rather
  /// back up that way.
  Future<void> _showExportOpmlDialog() async {
    final url = _apiService.opmlExportUrl;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: const Text('Export subscriptions',
            style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Open this URL in a browser to download your subscriptions as an OPML file (every podcast app reads OPML):',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(4),
              ),
              child: SelectableText(
                url,
                style: const TextStyle(
                  color: Color(0xFF00d4ff),
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close', style: TextStyle(color: Color(0xFF00d4ff))),
          ),
        ],
      ),
    );
  }

  /// Accepts either a URL to a remote OPML file (most common — export
  /// from another podcast app, give us the link) or raw pasted OPML XML.
  /// Backend dedupes against existing subscriptions.
  Future<void> _showImportOpmlDialog() async {
    final urlController = TextEditingController();
    final textController = TextEditingController();
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: const Text('Import subscriptions',
            style: TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Paste an OPML URL (your other podcast app can export one):',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: urlController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'https://example.com/subscriptions.opml',
                  hintStyle: TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: Colors.black26,
                  border: OutlineInputBorder(borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Or paste the OPML XML directly:',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: textController,
                maxLines: 5,
                style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  hintText: '<opml>...</opml>',
                  hintStyle: TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: Colors.black26,
                  border: OutlineInputBorder(borderSide: BorderSide.none),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx, {
                'url': urlController.text.trim(),
                'text': textController.text.trim(),
              });
            },
            child: const Text('Import', style: TextStyle(color: Color(0xFF00d4ff))),
          ),
        ],
      ),
    );
    if (result == null) return;
    if ((result['url']?.isEmpty ?? true) && (result['text']?.isEmpty ?? true)) return;

    try {
      final response = await _apiService.importOpml(
        opmlUrl: result['url'],
        opmlText: result['text'],
      );
      if (!mounted) return;
      final added = (response['added'] as List?)?.length ?? 0;
      final skipped = (response['skipped_already_subscribed'] as List?)?.length ?? 0;
      final failed = (response['failed'] as List?)?.length ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Added $added • Already subscribed: $skipped • Failed: $failed',
          ),
          backgroundColor: Colors.green.shade800,
          duration: const Duration(seconds: 4),
        ),
      );
      _loadFeeds();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Import failed: $e'),
          backgroundColor: Colors.red.shade800,
        ),
      );
    }
  }

  Future<void> _showAddFeedDialog() async {
    final controller = TextEditingController();
    bool isAdding = false;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1a2332),
          title: const Text('Add Podcast', style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Paste RSS feed URL...',
                  hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
                  filled: true,
                  fillColor: const Color(0xFF0d1b2a),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                  prefixIcon: const Icon(Icons.rss_feed, color: Colors.orange),
                ),
              ),
              if (isAdding)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange),
                      ),
                      SizedBox(width: 12),
                      Text('Fetching feed...', style: TextStyle(color: Colors.white70)),
                    ],
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: isAdding
                  ? null
                  : () async {
                      final url = controller.text.trim();
                      if (url.isEmpty) return;

                      setDialogState(() => isAdding = true);

                      try {
                        final result = await _apiService.addRssFeed(url);
                        if (result['success'] == true) {
                          Navigator.pop(context);
                          _loadFeeds();
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Subscribed to ${result['title']} (${result['episodes_added']} episodes)',
                                ),
                                backgroundColor: Colors.green,
                              ),
                            );
                          }
                        } else {
                          setDialogState(() => isAdding = false);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(result['error'] ?? 'Failed to subscribe'),
                                backgroundColor: Colors.red,
                              ),
                            );
                          }
                        }
                      } catch (e) {
                        setDialogState(() => isAdding = false);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Error: $e'),
                              backgroundColor: Colors.red,
                            ),
                          );
                        }
                      }
                    },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
              child: const Text('Subscribe'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(RssFeed feed) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a2332),
        title: const Text('Unsubscribe', style: TextStyle(color: Colors.white)),
        content: Text(
          'Unsubscribe from "${feed.title}"? All episodes will be removed.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Unsubscribe'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _apiService.deleteRssFeed(feed.id);
      _loadFeeds();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEmbedded = !widget.showMiniPlayer; // Embedded in Library tab

    return Scaffold(
      backgroundColor: const Color(0xFF0a1929),
      appBar: isEmbedded
          ? null
          : AppBar(
              title: const Text('Podcasts'),
              backgroundColor: const Color(0xFF0d1b2a),
              actions: [
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh all feeds',
                  onPressed: () async {
                    final result = await _apiService.refreshAllRssFeeds();
                    _loadFeeds();
                    if (mounted) {
                      final count = result['new_episodes'] ?? 0;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(count > 0
                              ? '$count new episodes found'
                              : 'All feeds up to date'),
                        ),
                      );
                    }
                  },
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  color: const Color(0xFF1a2332),
                  onSelected: (value) {
                    if (value == 'export_opml') _showExportOpmlDialog();
                    if (value == 'import_opml') _showImportOpmlDialog();
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: 'export_opml',
                      child: ListTile(
                        leading: Icon(Icons.download, color: Colors.white),
                        title: Text('Export subscriptions (OPML)',
                            style: TextStyle(color: Colors.white)),
                        contentPadding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    PopupMenuItem(
                      value: 'import_opml',
                      child: ListTile(
                        leading: Icon(Icons.upload, color: Colors.white),
                        title: Text('Import subscriptions (OPML)',
                            style: TextStyle(color: Colors.white)),
                        contentPadding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddFeedDialog,
        backgroundColor: Colors.orange,
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: Colors.orange));
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.red.shade300),
            const SizedBox(height: 16),
            Text(_error!, style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _loadFeeds, child: const Text('Retry')),
          ],
        ),
      );
    }

    if (_feeds.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.podcasts, size: 64, color: Colors.white.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            Text(
              'No podcasts yet',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Tap + to subscribe to a podcast feed',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.3)),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadFeeds,
      child: ListView.builder(
        padding: EdgeInsets.only(
          top: 8,
          bottom: Platform.isAndroid ? 100 : 16,
        ),
        itemCount: _feeds.length,
        itemBuilder: (context, index) => _buildFeedTile(_feeds[index]),
      ),
    );
  }

  Widget _buildFeedTile(RssFeed feed) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: feed.artworkUrl != null
            ? Image.network(
                feed.artworkUrl!,
                width: 56,
                height: 56,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _buildPlaceholder(),
              )
            : _buildPlaceholder(),
      ),
      title: Text(
        feed.title,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        feed.author.isNotEmpty ? feed.author : '${feed.episodeCount} episodes',
        style: const TextStyle(color: Colors.white54, fontSize: 13),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (feed.unplayedCount > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: Colors.orange,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${feed.unplayedCount}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.grey, size: 20),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () => _confirmDelete(feed),
            tooltip: 'Unsubscribe',
          ),
        ],
      ),
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => RssFeedDetailScreen(
              feed: feed,
              audioPlayerService: widget.audioPlayerService,
            ),
          ),
        );
        _loadFeeds(); // Refresh unplayed counts
      },
      onLongPress: () => _confirmDelete(feed),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      width: 56,
      height: 56,
      color: const Color(0xFF1a2332),
      child: const Icon(Icons.podcasts, color: Colors.orange, size: 28),
    );
  }
}
