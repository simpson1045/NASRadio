import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/rss_feed.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import '../main.dart' show globalDeviceSyncService;
import '../widgets/design_system.dart';
import 'rss_feeds_screen.dart';
import 'rss_feed_detail_screen.dart';

class PodcastDiscoveryScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;

  const PodcastDiscoveryScreen({super.key, required this.audioPlayerService});

  @override
  State<PodcastDiscoveryScreen> createState() => _PodcastDiscoveryScreenState();
}

class _PodcastDiscoveryScreenState extends State<PodcastDiscoveryScreen> {
  final ApiService _apiService = ApiService();

  // Data
  List<dynamic> _trending = [];
  List<dynamic> _searchResults = [];
  List<RssEpisode> _newEpisodes = [];
  List<RssEpisode> _continueListening = [];
  List<RssFeed> _myPodcasts = [];
  List<dynamic> _categories = [];
  List<dynamic> _recommendations = [];

  // Per-section error tracking — keyed by the same short names used in
  // _retrySection. Previously load failures were silently printed and
  // sections just vanished; users had no way to know something failed
  // or how to retry without reloading the whole app.
  final Map<String, String> _sectionErrors = {};

  // State
  bool _isLoading = true;
  bool _isSearching = false;
  String? _searchQuery;
  String? _selectedCategory;
  String? _recommendationSource;
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;

  // Trending carousel
  final PageController _carouselController = PageController(viewportFraction: 0.85);
  Timer? _carouselTimer;
  int _carouselPage = 0;

  // Detach handle for cross-device episode update listener.
  VoidCallback? _removeEpisodeListener;

  @override
  void initState() {
    super.initState();
    _loadAll();
    // Cross-device episode progress updates should flow into Continue
    // Listening while this screen is on top. Without this, playing an
    // episode on another device would leave stale progress bars here
    // until the user navigates away and back.
    _removeEpisodeListener = globalDeviceSyncService.addPodcastEpisodeListener(
      _handleEpisodeUpdated,
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchDebounce?.cancel();
    _carouselTimer?.cancel();
    _carouselController.dispose();
    _removeEpisodeListener?.call();
    super.dispose();
  }

  void _handleEpisodeUpdated(int episodeId, int position, bool? isCompleted) {
    if (!mounted) return;

    // In-place update for snappy UI feedback when the episode is already
    // in the list (progress bar moves immediately, doesn't have to wait
    // for the round-trip).
    final idx = _continueListening.indexWhere((e) => e.id == episodeId);
    if (idx >= 0) {
      setState(() {
        _continueListening[idx] = _continueListening[idx].copyWith(
          playedPosition: position,
          isCompleted: isCompleted ?? _continueListening[idx].isCompleted,
        );
      });
    }

    // Then re-fetch the whole section. The in-place update alone left the
    // list stale in two ways: (1) completed episodes were not removed,
    // so the Resume banner kept pointing at the freshly-finished episode
    // instead of the new in-progress one, and (2) starting a brand-new
    // episode that wasn't previously in the list never appeared until
    // the user left and returned. The re-fetch handles both — completed
    // episodes drop out, new in-progress episodes get added, and the
    // ordering reflects the latest last_played_at.
    _loadContinueListening();
  }

  Future<void> _loadAll() async {
    setState(() => _isLoading = true);

    await Future.wait([
      _loadTrending(),
      _loadNewEpisodes(),
      _loadContinueListening(),
      _loadMyPodcasts(),
      _loadCategories(),
    ]);

    if (mounted) setState(() => _isLoading = false);

    // Start carousel auto-scroll
    _startCarouselTimer();

    // Load recommendations in background (slow due to Spotify lookups)
    if (_myPodcasts.isNotEmpty) {
      _loadRecommendations();
    }
  }

  /// Short user-facing error message for a failed section load.
  /// Strips the exception type prefix and caps length for display.
  String _friendlyError(Object e) {
    var msg = e.toString();
    if (msg.startsWith('Exception: ')) msg = msg.substring('Exception: '.length);
    if (msg.length > 120) msg = '${msg.substring(0, 117)}...';
    return msg;
  }

  void _recordSectionError(String section, Object e) {
    if (!mounted) return;
    setState(() => _sectionErrors[section] = _friendlyError(e));
  }

  void _clearSectionError(String section) {
    if (_sectionErrors.containsKey(section)) {
      _sectionErrors.remove(section);
    }
  }

  /// Retry loading a single failed section. Wired from each section's
  /// error tile's retry button.
  Future<void> _retrySection(String section) async {
    _clearSectionError(section);
    if (mounted) setState(() {});
    switch (section) {
      case 'trending':
        await _loadTrending();
        break;
      case 'new_episodes':
        await _loadNewEpisodes();
        break;
      case 'continue_listening':
        await _loadContinueListening();
        break;
      case 'my_podcasts':
        await _loadMyPodcasts();
        break;
      case 'categories':
        await _loadCategories();
        break;
      case 'recommendations':
        await _loadRecommendations();
        break;
    }
  }

  Future<void> _loadTrending() async {
    try {
      final feeds = await _apiService.getPodcastTrending(
        max: 10,
        category: _selectedCategory,
      );
      if (mounted) {
        setState(() {
          _trending = feeds;
          _clearSectionError('trending');
        });
      }
    } catch (e) {
      _recordSectionError('trending', e);
    }
  }

  Future<void> _loadNewEpisodes() async {
    try {
      final episodes = await _apiService.getRecentEpisodes(limit: 20);
      if (mounted) {
        setState(() {
          _newEpisodes = episodes.map((e) => RssEpisode.fromJson(e)).toList();
          _clearSectionError('new_episodes');
        });
      }
    } catch (e) {
      _recordSectionError('new_episodes', e);
    }
  }

  Future<void> _loadContinueListening() async {
    try {
      final episodes = await _apiService.getRecentlyPlayedEpisodes(limit: 10);
      if (mounted) {
        setState(() {
          _continueListening = episodes.map((e) => RssEpisode.fromJson(e)).toList();
          _clearSectionError('continue_listening');
        });
      }
    } catch (e) {
      _recordSectionError('continue_listening', e);
    }
  }

  Future<void> _loadMyPodcasts() async {
    try {
      final feeds = await _apiService.getRssFeeds();
      if (mounted) {
        setState(() {
          _myPodcasts = feeds.map((f) => RssFeed.fromJson(f)).toList();
          _clearSectionError('my_podcasts');
        });
      }
    } catch (e) {
      _recordSectionError('my_podcasts', e);
    }
  }

  Future<void> _loadCategories() async {
    try {
      final cats = await _apiService.getPodcastCategories();
      if (mounted) {
        setState(() {
          _categories = cats;
          _clearSectionError('categories');
        });
      }
    } catch (e) {
      _recordSectionError('categories', e);
    }
  }

  Future<void> _loadRecommendations() async {
    if (_myPodcasts.isEmpty) return;
    try {
      final data = await _apiService.getPodcastRecommendations();
      if (mounted) {
        setState(() {
          _recommendationSource = data['source'] as String?;
          _recommendations = List<dynamic>.from(data['feeds'] ?? []);
          _clearSectionError('recommendations');
        });
      }
    } catch (e) {
      _recordSectionError('recommendations', e);
    }
  }

  void _onSearchChanged(String query) {
    _searchDebounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _searchQuery = null;
        _isSearching = false;
      });
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 500), () {
      _performSearch(query.trim());
    });
  }

  Future<void> _performSearch(String query) async {
    setState(() {
      _isSearching = true;
      _searchQuery = query;
    });
    try {
      final results = await _apiService.searchPodcasts(query);
      if (mounted) setState(() => _searchResults = results);
    } catch (e) {
      print('Search error: $e');
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  void _startCarouselTimer() {
    _carouselTimer?.cancel();
    if (_trending.length <= 1) return;
    _carouselTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || _trending.isEmpty) return;
      _carouselPage = (_carouselPage + 1) % _trending.length;
      _carouselController.animateToPage(
        _carouselPage,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    });
  }

  Future<void> _subscribeToPodcast(dynamic feed) async {
    final url = feed['url'] as String?;
    if (url == null || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No feed URL available')),
      );
      return;
    }
    try {
      await _apiService.addRssFeed(url);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Subscribed to ${feed['title'] ?? 'podcast'}')),
        );
        _loadMyPodcasts(); // Refresh subscriptions
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Subscribe failed: $e')),
        );
      }
    }
  }

  void _openFeedDetail(RssFeed feed) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RssFeedDetailScreen(
          feed: feed,
          audioPlayerService: widget.audioPlayerService,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0a1929),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0d1b2a),
        title: const Text('Podcasts'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadAll,
          ),
        ],
      ),
      body: SafeArea(
        bottom: false, // AppBottomNav handles its own safe-area padding
        child: Column(
          children: [
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFF00d4ff)))
                  : RefreshIndicator(
                      onRefresh: _loadAll,
                      child: SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildSearchBar(),
                            if (_searchQuery != null && _searchQuery!.isNotEmpty)
                              _buildSearchResults()
                            else ...[
                              // Each section: show content if loaded, show
                              // inline error tile with retry if the load
                              // failed, show nothing if it legitimately has
                              // no data. No more silent failures.
                              if (_sectionErrors.containsKey('trending'))
                                _buildSectionError('Trending', 'trending', _sectionErrors['trending']!)
                              else if (_trending.isNotEmpty)
                                _buildTrendingCarousel(),
                              if (_sectionErrors.containsKey('new_episodes'))
                                _buildSectionError('New Episodes', 'new_episodes', _sectionErrors['new_episodes']!)
                              else if (_newEpisodes.isNotEmpty) ...[
                                _buildSectionHeader('New Episodes'),
                                _buildEpisodeRow(_newEpisodes),
                              ],
                              if (_sectionErrors.containsKey('continue_listening'))
                                _buildSectionError('Continue Listening', 'continue_listening', _sectionErrors['continue_listening']!)
                              else if (_continueListening.isNotEmpty) ...[
                                _buildSectionHeader('Continue Listening'),
                                _buildEpisodeRow(_continueListening, showProgress: true),
                              ],
                              if (_sectionErrors.containsKey('recommendations'))
                                _buildSectionError('Recommendations', 'recommendations', _sectionErrors['recommendations']!)
                              else if (_recommendations.isNotEmpty) ...[
                                _buildSectionHeader('Because You Listen to $_recommendationSource'),
                                _buildPodcastRow(_recommendations),
                              ],
                              if (_sectionErrors.containsKey('categories'))
                                _buildSectionError('Browse by Category', 'categories', _sectionErrors['categories']!)
                              else if (_categories.isNotEmpty) ...[
                                _buildSectionHeader('Browse by Category'),
                                _buildCategoryChips(),
                              ],
                              if (_sectionErrors.containsKey('my_podcasts'))
                                _buildSectionError('Your Podcasts', 'my_podcasts', _sectionErrors['my_podcasts']!)
                              else if (_myPodcasts.isNotEmpty) ...[
                                _buildSectionHeader('Your Podcasts', onViewAll: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (context) => RssFeedsScreen(
                                        audioPlayerService: widget.audioPlayerService,
                                      ),
                                    ),
                                  );
                                }),
                                _buildMyPodcastsRow(),
                              ],
                            ],
                          ],
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Widgets ───────────────────────────────────

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: TextField(
        controller: _searchController,
        onChanged: _onSearchChanged,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText: 'Search podcasts...',
          hintStyle: TextStyle(color: Colors.grey[500]),
          prefixIcon: const Icon(Icons.search, color: Color(0xFF00d4ff)),
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, color: Colors.grey),
                  onPressed: () {
                    _searchController.clear();
                    _onSearchChanged('');
                  },
                )
              : null,
          filled: true,
          fillColor: const Color(0xFF1a2332),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
    );
  }

  Widget _buildSearchResults() {
    if (_isSearching) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator(color: Color(0xFF00d4ff))),
      );
    }
    if (_searchResults.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: Text(
            'No results for "$_searchQuery"',
            style: TextStyle(color: Colors.grey[500]),
          ),
        ),
      );
    }

    final myUrls = _myPodcasts.map((p) => p.feedUrl).toSet();

    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _searchResults.length,
      itemBuilder: (context, index) {
        final feed = _searchResults[index];
        final title = feed['title'] ?? 'Unknown';
        final author = feed['author'] ?? '';
        final artwork = feed['artwork'] ?? feed['image'] ?? '';
        final feedUrl = feed['url'] ?? '';
        final isSubscribed = myUrls.contains(feedUrl);

        return ListTile(
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: artwork.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: artwork,
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                    errorWidget: (_, __, ___) => _podcastPlaceholder(56),
                  )
                : _podcastPlaceholder(56),
          ),
          title: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            author,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Colors.grey[400], fontSize: 12),
          ),
          trailing: isSubscribed
              ? const Icon(Icons.check_circle, color: Color(0xFF00d4ff), size: 24)
              : IconButton(
                  icon: const Icon(Icons.add_circle_outline, color: Color(0xFF00d4ff)),
                  onPressed: () => _subscribeToPodcast(feed),
                ),
        );
      },
    );
  }

  Widget _buildTrendingCarousel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader('Trending'),
        SizedBox(
          height: 200,
          child: PageView.builder(
            controller: _carouselController,
            itemCount: _trending.length,
            onPageChanged: (i) {
              setState(() => _carouselPage = i);
              _startCarouselTimer(); // Reset auto-scroll on manual swipe
            },
            itemBuilder: (context, index) {
              final feed = _trending[index];
              final title = feed['title'] ?? 'Unknown';
              final author = feed['author'] ?? '';
              final artwork = feed['artwork'] ?? feed['image'] ?? '';
              final feedUrl = feed['url'] ?? '';
              final isSubscribed = _myPodcasts.any((p) => p.feedUrl == feedUrl);

              return GestureDetector(
                onTap: () => _showPodcastPreview(feed),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: const Color(0xFF1a2332),
                  ),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: const BorderRadius.horizontal(left: Radius.circular(12)),
                        child: artwork.isNotEmpty
                            ? CachedNetworkImage(
                                imageUrl: artwork,
                                width: 180,
                                height: 200,
                                fit: BoxFit.cover,
                                errorWidget: (_, __, ___) => _podcastPlaceholder(180),
                              )
                            : _podcastPlaceholder(180),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF00d4ff).withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  '#${index + 1} Trending',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: Color(0xFF00d4ff),
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                author,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[400],
                                ),
                              ),
                              const SizedBox(height: 12),
                              if (isSubscribed)
                                const Row(
                                  children: [
                                    Icon(Icons.check_circle, color: Color(0xFF00d4ff), size: 16),
                                    SizedBox(width: 4),
                                    Text('Subscribed', style: TextStyle(color: Color(0xFF00d4ff), fontSize: 12)),
                                  ],
                                )
                              else
                                OutlinedButton.icon(
                                  onPressed: () => _subscribeToPodcast(feed),
                                  icon: const Icon(Icons.add, size: 14),
                                  label: const Text('Subscribe', style: TextStyle(fontSize: 11), overflow: TextOverflow.visible, softWrap: false),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: const Color(0xFF00d4ff),
                                    side: const BorderSide(color: Color(0xFF00d4ff)),
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                                    minimumSize: Size.zero,
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        // Carousel dots
        if (_trending.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_trending.length, (i) {
                return Container(
                  width: 6,
                  height: 6,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i == _carouselPage
                        ? const Color(0xFF00d4ff)
                        : Colors.grey.withOpacity(0.3),
                  ),
                );
              }),
            ),
          ),
      ],
    );
  }

  Widget _buildEpisodeRow(List<RssEpisode> episodes, {bool showProgress = false}) {
    return SizedBox(
      height: 210,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: episodes.length,
        itemBuilder: (context, index) {
          final episode = episodes[index];
          final artwork = episode.artworkUrl ?? episode.feedArtworkUrl ?? '';

          return GestureDetector(
            onTap: () {
              // Find matching feed to navigate to detail
              final feed = _myPodcasts.where((f) => f.id == episode.feedId).firstOrNull;
              if (feed != null) {
                _openFeedDetail(feed);
              }
            },
            child: Container(
              width: 140,
              margin: const EdgeInsets.only(right: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF1a2332),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    children: [
                      ClipRRect(
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                        child: artwork.isNotEmpty
                            ? CachedNetworkImage(
                                imageUrl: artwork,
                                width: 140,
                                height: 140,
                                fit: BoxFit.cover,
                                errorWidget: (_, __, ___) => _podcastPlaceholder(140),
                              )
                            : _podcastPlaceholder(140),
                      ),
                      if (showProgress && episode.audioDuration != null && episode.audioDuration! > 0)
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: LinearProgressIndicator(
                            value: episode.playedPosition / episode.audioDuration!,
                            backgroundColor: Colors.black54,
                            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00d4ff)),
                            minHeight: 3,
                          ),
                        ),
                      if (episode.isCompleted)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: const BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.check_circle, color: Color(0xFF00d4ff), size: 16),
                          ),
                        ),
                    ],
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            episode.title,
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            episode.feedTitle ?? '',
                            style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPodcastRow(List<dynamic> feeds) {
    return SizedBox(
      height: 200,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: feeds.length,
        itemBuilder: (context, index) {
          final feed = feeds[index];
          final title = feed['title'] ?? 'Unknown';
          final author = feed['author'] ?? '';
          final artwork = feed['artwork'] ?? feed['image'] ?? '';

          return GestureDetector(
            onTap: () => _showPodcastPreview(feed),
            child: Container(
              width: 140,
              margin: const EdgeInsets.only(right: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF1a2332),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                    child: artwork.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: artwork.toString(),
                            width: 140,
                            height: 140,
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) => _podcastPlaceholder(140),
                          )
                        : _podcastPlaceholder(140),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            author,
                            style: TextStyle(fontSize: 10, color: Colors.grey[400]),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCategoryChips() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: _categories.take(15).map((cat) {
          final name = cat['name'] ?? '';
          final isSelected = _selectedCategory == name;
          return FilterChip(
            label: Text(name),
            selected: isSelected,
            onSelected: (selected) {
              setState(() {
                _selectedCategory = selected ? name : null;
              });
              _loadTrending();
            },
            selectedColor: const Color(0xFF00d4ff).withOpacity(0.3),
            checkmarkColor: const Color(0xFF00d4ff),
            backgroundColor: const Color(0xFF1a2332),
            labelStyle: TextStyle(
              color: isSelected ? const Color(0xFF00d4ff) : Colors.grey[400],
              fontSize: 12,
            ),
            side: BorderSide(
              color: isSelected
                  ? const Color(0xFF00d4ff).withOpacity(0.5)
                  : Colors.transparent,
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildMyPodcastsRow() {
    return SizedBox(
      height: 160,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _myPodcasts.length,
        itemBuilder: (context, index) {
          final feed = _myPodcasts[index];
          final artwork = feed.artworkCached != null
              ? '${ApiService.baseHost}${feed.artworkCached}'
              : feed.artworkUrl ?? '';

          return GestureDetector(
            onTap: () => _openFeedDetail(feed),
            child: Container(
              width: 110,
              margin: const EdgeInsets.only(right: 12),
              child: Column(
                children: [
                  Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: artwork.isNotEmpty
                            ? CachedNetworkImage(
                                imageUrl: artwork,
                                width: 110,
                                height: 110,
                                fit: BoxFit.cover,
                                errorWidget: (_, __, ___) => _podcastPlaceholder(110),
                              )
                            : _podcastPlaceholder(110),
                      ),
                      if (feed.unplayedCount > 0)
                        Positioned(
                          top: 4,
                          right: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.orange,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '${feed.unplayedCount}',
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    feed.title,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Error tile shown in place of a section's content when its load failed.
  /// Includes the section title, a compact error message, and a retry
  /// button that re-runs just that section's loader.
  Widget _buildSectionError(String title, String section, String message) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader(title),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF2a1a1a),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.redAccent.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.redAccent, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Couldn't load this section",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: () => _retrySection(section),
                  icon: const Icon(Icons.refresh, size: 18, color: Color(0xFF00d4ff)),
                  label: const Text('Retry', style: TextStyle(color: Color(0xFF00d4ff))),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Migrated to the shared SectionHeader in widgets/design_system.dart
  // for consistency with the rest of the app. Old per-screen
  // implementations get replaced over time; this thin wrapper keeps
  // existing call sites compiling without edits.
  Widget _buildSectionHeader(String title, {VoidCallback? onViewAll}) {
    return SectionHeader(title, onViewAll: onViewAll);
  }

  void _showPodcastPreview(dynamic show) {
    final title = show['title'] ?? 'Unknown';
    final author = show['author'] ?? '';
    final artwork = show['artwork'] ?? show['image'] ?? '';
    final description = stripHtml((show['description'] ?? '').toString());
    final episodeCount = show['episodeCount'] ?? 0;
    final feedUrl = show['url'] ?? '';
    final categories = show['categories'] as Map<String, dynamic>? ?? {};
    final totalRatings = show['totalRatings'] ?? 0;
    final averageRating = (show['averageRating'] ?? 0).toDouble();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0d1b2a),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => SingleChildScrollView(
          controller: scrollController,
          padding: EdgeInsets.only(
            left: 20, right: 20, top: 16,
            bottom: Platform.isAndroid ? 40 : 16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.grey[600],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: artwork.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: artwork.toString(),
                            width: 120, height: 120, fit: BoxFit.cover,
                            errorWidget: (_, __, ___) => _podcastPlaceholder(120),
                          )
                        : _podcastPlaceholder(120),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        Text(author, style: TextStyle(fontSize: 14, color: Colors.grey[400])),
                        const SizedBox(height: 8),
                        if (episodeCount > 0)
                          Text('$episodeCount episodes', style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                        if (totalRatings > 0) ...[
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              const Icon(Icons.star, color: Colors.amber, size: 14),
                              const SizedBox(width: 4),
                              Text(
                                '${averageRating > 0 ? averageRating.toStringAsFixed(1) : "?"} (${_formatCount(totalRatings)} ratings)',
                                style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                              ),
                            ],
                          ),
                        ],
                        if (categories.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: categories.values.map((cat) => Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFF00d4ff).withOpacity(0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                cat.toString(),
                                style: const TextStyle(fontSize: 10, color: Color(0xFF00d4ff)),
                              ),
                            )).toList(),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              if (feedUrl.isNotEmpty)
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      try {
                        await _apiService.addRssFeed(feedUrl);
                        if (mounted) {
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Subscribed to $title')),
                          );
                          _loadMyPodcasts();
                        }
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('$e')),
                          );
                        }
                      }
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Subscribe'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00d4ff),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              const SizedBox(height: 20),
              if (description.isNotEmpty) ...[
                const Text('About', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF00d4ff))),
                const SizedBox(height: 8),
                Text(
                  description.trim(),
                  style: TextStyle(fontSize: 13, color: Colors.grey[300], height: 1.5),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _formatCount(int count) {
    if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}K';
    return count.toString();
  }

  Widget _podcastPlaceholder(double size) {
    return Container(
      width: size,
      height: size,
      color: const Color(0xFF0d1b2a),
      child: Icon(
        Icons.podcasts,
        color: const Color(0xFF00d4ff).withOpacity(0.4),
        size: size * 0.4,
      ),
    );
  }
}
