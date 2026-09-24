import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import '../widgets/design_system.dart';

/// Live internet radio — a discovery-style screen (search, rotating featured /
/// most-listened hero, genre-sectioned carousels, genre chips). Tapping a
/// station hands its Icecast/Shoutcast URL to the existing player as a
/// `sourceType: 'station'` Song (direct passthrough).
class StationsScreen extends StatefulWidget {
  final AudioPlayerService audioPlayerService;
  final bool showMiniPlayer;
  const StationsScreen(
      {super.key, required this.audioPlayerService, this.showMiniPlayer = true});

  @override
  State<StationsScreen> createState() => _StationsScreenState();
}

const List<String> _bucketOrder = [
  'Synthwave',
  'Chill & Ambient',
  'Electronic',
  'More Stations',
];

String _bucketFor(String genre) {
  final g = genre.toLowerCase();
  if (g.contains('synth')) return 'Synthwave';
  if (g.contains('vapor') ||
      g.contains('chill') ||
      g.contains('ambient') ||
      g.contains('downtempo') ||
      g.contains('drone') ||
      g.contains('lo-fi') ||
      g.contains('lofi')) {
    return 'Chill & Ambient';
  }
  if (g.contains('electro') ||
      g.contains('techno') ||
      g.contains('house') ||
      g.contains('edm') ||
      g.contains('hack')) {
    return 'Electronic';
  }
  return 'More Stations';
}

/// Neon gradient picked from the station's genre (also the artwork fallback).
List<Color> stationGradient(String? genre) {
  final g = (genre ?? '').toLowerCase();
  if (g.contains('dark')) return const [Color(0xFF8e24aa), Color(0xFFd81b60)];
  if (g.contains('chill')) return const [Color(0xFF00b8d4), Color(0xFF7c4dff)];
  if (g.contains('vapor')) return const [Color(0xFFff80ab), Color(0xFF82b1ff)];
  if (g.contains('synth')) return const [Color(0xFFff4081), Color(0xFF7c4dff)];
  if (g.contains('drone') || g.contains('ambient')) {
    return const [Color(0xFF1de9b6), Color(0xFF2979ff)];
  }
  if (g.contains('electro') || g.contains('hack')) {
    return const [Color(0xFF18ffff), Color(0xFF2962ff)];
  }
  return const [Color(0xFF00d4ff), Color(0xFF7c4dff)];
}

int _intOf(dynamic v) =>
    v is int ? v : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);

String _compact(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '$n';
}

class _StationsScreenState extends State<StationsScreen> {
  final ApiService _api = ApiService();
  final TextEditingController _search = TextEditingController();
  final PageController _heroController = PageController();
  Timer? _heroTimer;
  int _heroPage = 0;
  List<Map<String, dynamic>> _heroList = [];

  List<Map<String, dynamic>> _stations = [];
  String _query = '';
  bool _loading = true;
  String? _error;

  Timer? _searchDebounce;
  List<Map<String, dynamic>> _results = [];
  bool _searching = false;
  String? _searchError;
  String _sort = 'popular';
  int _searchToken = 0;

  // Recent search terms (chips under the search bar), newest first,
  // persisted so "acoustic guitar" is one tap next session.
  static const _searchHistoryKey = 'station_search_history_v1';
  static const _searchHistoryMax = 8;
  List<String> _recentSearches = [];

  @override
  void initState() {
    super.initState();
    _load();
    _loadSearchHistory();
  }

  Future<void> _loadSearchHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_searchHistoryKey) ?? [];
      if (mounted && list.isNotEmpty) {
        setState(() => _recentSearches = list);
      }
    } catch (_) {}
  }

  Future<void> _recordSearch(String q) async {
    final term = q.trim();
    if (term.length < 2) return;
    _recentSearches
        .removeWhere((t) => t.toLowerCase() == term.toLowerCase());
    _recentSearches.insert(0, term);
    if (_recentSearches.length > _searchHistoryMax) {
      _recentSearches = _recentSearches.sublist(0, _searchHistoryMax);
    }
    if (mounted) setState(() {});
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_searchHistoryKey, _recentSearches);
    } catch (_) {}
  }

  Future<void> _removeSearchTerm(String term) async {
    _recentSearches.remove(term);
    if (mounted) setState(() {});
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_searchHistoryKey, _recentSearches);
    } catch (_) {}
  }

  @override
  void dispose() {
    _search.dispose();
    _searchDebounce?.cancel();
    _heroTimer?.cancel();
    _heroController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await _api.getStations();
      if (!mounted) return;
      setState(() {
        _stations = s;
        _computeHeroes();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _computeHeroes() {
    final list = List<Map<String, dynamic>>.from(_stations);
    // Most-played first, then featured order (sort_order).
    list.sort((a, b) {
      final pa = _intOf(a['play_count']);
      final pb = _intOf(b['play_count']);
      if (pa != pb) return pb - pa;
      return _intOf(a['sort_order']) - _intOf(b['sort_order']);
    });
    _heroList = list.take(5).toList();
    _heroPage = 0;
    _startHeroTimer();
  }

  void _startHeroTimer() {
    _heroTimer?.cancel();
    if (_heroList.length <= 1) return;
    _heroTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted || !_heroController.hasClients) return;
      final next = (_heroPage + 1) % _heroList.length;
      _heroController.animateToPage(next,
          duration: const Duration(milliseconds: 450), curve: Curves.easeInOut);
    });
  }

  Song _toSong(Map<String, dynamic> s) {
    return Song(
      // radio-browser results have no DB id (null) — derive a stable, unique
      // negative id from the URL so they don't all collide on 0 (which made
      // favorites/now-playing treat every such station as the same item).
      id: s['id'] != null
          ? -_intOf(s['id'])
          : -((s['url'] ?? '').toString().hashCode.abs() % 1000000000 + 1),
      title: (s['name'] ?? 'Station').toString(),
      artistId: 0,
      artistName: (s['genre'] ?? 'Live Radio').toString(),
      albumId: 0,
      albumTitle: 'Stations',
      trackNumber: 0,
      duration: 0,
      filePath: (s['url'] ?? '').toString(),
      fileSize: 0,
      bitrate: 0,
      sourceType: 'station',
      stationArtworkUrl: (s['favicon'] ?? '').toString(),
    );
  }

  void _play(Map<String, dynamic> s) {
    widget.audioPlayerService.playSong(_toSong(s));
    final id = _intOf(s['id']);
    if (id > 0) {
      _api.trackStationPlay(id);
      s['play_count'] = _intOf(s['play_count']) + 1; // optimistic
    }
  }

  bool _isCurrent(Map<String, dynamic> s) {
    final cur = widget.audioPlayerService.currentSong;
    return cur != null &&
        cur.isStation &&
        cur.filePath == (s['url'] ?? '').toString();
  }

  bool _isLive(Map<String, dynamic> s) =>
      _isCurrent(s) && widget.audioPlayerService.isPlaying;

  void _onSearchChanged(String v) {
    setState(() => _query = v);
    _searchDebounce?.cancel();
    final q = v.trim();
    if (q.length < 2) {
      setState(() {
        _results = [];
        _searching = false;
        _searchError = null;
      });
      return;
    }
    setState(() => _searching = true);
    _searchDebounce =
        Timer(const Duration(milliseconds: 450), () => _runSearch(q));
  }

  Future<void> _runSearch(String q) async {
    final token = ++_searchToken;
    try {
      final r = await _api.searchStations(q, sort: _sort);
      // Ignore if a newer query/sort superseded this one.
      if (!mounted || token != _searchToken) return;
      setState(() {
        _results = r;
        _searching = false;
        _searchError = null;
      });
      _recordSearch(q);
    } catch (e) {
      if (!mounted || token != _searchToken) return;
      setState(() {
        _searching = false;
        _searchError = e.toString();
      });
    }
  }

  Future<void> _saveStation(Map<String, dynamic> s) async {
    try {
      await _api.createStation(
        (s['name'] ?? '').toString(),
        (s['url'] ?? '').toString(),
        genre: (s['genre'] ?? '').toString(),
        description: (s['description'] ?? '').toString(),
        homepage: (s['homepage'] ?? '').toString(),
        favicon: (s['favicon'] ?? '').toString(),
      );
      if (!mounted) return;
      setState(() => s['_saved'] = true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Saved "${s['name']}" to your stations'),
        duration: const Duration(seconds: 2),
        backgroundColor: kCardBg,
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not save: $e'),
        backgroundColor: kCardBg,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF1a0b2e), kPageBg],
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          foregroundColor: Colors.white,
          title: const Text('Stations',
              style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        body: Column(
          children: [
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }


  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: kAccent));
    }
    if (_error != null) return _errorView();
    return ListenableBuilder(
      listenable: widget.audioPlayerService,
      builder: (context, _) {
        return RefreshIndicator(
          color: kAccent,
          backgroundColor: kCardBg,
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              _searchBar(),
              if (_query.trim().isEmpty && _recentSearches.isNotEmpty)
                _recentSearchChips(),
              if (_query.trim().isNotEmpty)
                ..._searchSection()
              else
                ..._browse(),
            ],
          ),
        );
      },
    );
  }

  // Recent-search chips: tap to re-run, long-press to remove one,
  // "Clear" wipes them all. Shown only while the search box is empty.
  Widget _recentSearchChips() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final term in _recentSearches)
            GestureDetector(
              onLongPress: () => _removeSearchTerm(term),
              child: ActionChip(
                backgroundColor: kCardBg,
                side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
                avatar: const Icon(Icons.history, size: 16, color: kAccent),
                label: Text(term,
                    style: const TextStyle(color: Colors.white, fontSize: 13)),
                onPressed: () {
                  _search.text = term;
                  _search.selection = TextSelection.fromPosition(
                      TextPosition(offset: term.length));
                  _onSearchChanged(term);
                },
              ),
            ),
          TextButton(
            onPressed: () {
              setState(() => _recentSearches = []);
              SharedPreferences.getInstance()
                  .then((p) => p.remove(_searchHistoryKey));
            },
            child: Text('Clear',
                style: TextStyle(color: Colors.grey[600], fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: TextField(
        controller: _search,
        onChanged: _onSearchChanged,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText: 'Search stations...',
          hintStyle: TextStyle(color: Colors.grey[500]),
          prefixIcon: const Icon(Icons.search, color: kAccent),
          suffixIcon: _query.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, color: Colors.grey),
                  onPressed: () {
                    _search.clear();
                    _onSearchChanged('');
                  },
                )
              : null,
          filled: true,
          fillColor: kCardBg,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
    );
  }

  List<Widget> _searchSection() {
    final head = <Widget>[_sortChips()];
    if (_searching) {
      return [
        ...head,
        const Padding(
          padding: EdgeInsets.all(40),
          child: Center(child: CircularProgressIndicator(color: kAccent)),
        ),
      ];
    }
    if (_searchError != null) {
      return [
        ...head,
        const Padding(
          padding: EdgeInsets.all(40),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.cloud_off, color: Colors.white24, size: 42),
              SizedBox(height: 10),
              Text('Search unavailable',
                  style: TextStyle(color: Colors.white54)),
            ]),
          ),
        ),
      ];
    }
    if (_results.isEmpty) {
      return [
        ...head,
        Padding(
          padding: const EdgeInsets.all(40),
          child: Center(
            child: Text('No stations found for "${_query.trim()}"',
                style: const TextStyle(color: Colors.white54)),
          ),
        ),
      ];
    }
    return [
      ...head,
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
        child: Text(
            '${_results.length} station${_results.length == 1 ? '' : 's'}',
            style: const TextStyle(color: Colors.white54, fontSize: 13)),
      ),
      ..._results.map(_stationRow),
    ];
  }

  Widget _sortChips() {
    const opts = [
      ['popular', 'Popular'],
      ['trending', 'Trending'],
      ['votes', 'Top Rated'],
      ['name', 'A–Z'],
    ];
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
        children: [
          const Padding(
            padding: EdgeInsets.only(right: 8, top: 9),
            child: Text('SORT',
                style: TextStyle(
                    color: Colors.white38, fontSize: 11, letterSpacing: 1)),
          ),
          for (final o in opts)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(o[1]),
                selected: _sort == o[0],
                labelStyle: TextStyle(
                    color: _sort == o[0] ? Colors.black : Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w600),
                selectedColor: kAccent,
                backgroundColor: kCardBg,
                side: BorderSide(color: _sort == o[0] ? kAccent : kCardBorder),
                onSelected: (_) {
                  if (_sort == o[0]) return;
                  setState(() => _sort = o[0]);
                  final q = _query.trim();
                  if (q.length >= 2) {
                    setState(() => _searching = true);
                    _runSearch(q);
                  }
                },
              ),
            ),
        ],
      ),
    );
  }

  String _metaLine(Map<String, dynamic> s) {
    final parts = <String>[];
    final br = _intOf(s['bitrate']);
    if (br > 0) parts.add('${br}k');
    final cc = (s['countrycode'] ?? '').toString();
    final country = cc.isNotEmpty ? cc : (s['country'] ?? '').toString();
    if (country.isNotEmpty) parts.add(country);
    // Show the metric the list is actually sorted by, so the order reads true.
    if (_sort == 'votes') {
      final v = _intOf(s['votes']);
      if (v > 0) parts.add('★ ${_compact(v)}');
    } else if (_sort == 'trending') {
      final t = _intOf(s['clicktrend']);
      if (t > 0) parts.add('🔥 ${_compact(t)}');
    } else if (_sort != 'name') {
      final c = _intOf(s['clickcount']);
      if (c > 0) parts.add('▶ ${_compact(c)}');
    }
    return parts.join('  ·  ');
  }

  List<Widget> _browse() {
    if (_stations.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.all(40),
          child: Center(
              child: Text('No stations yet',
                  style: TextStyle(color: Colors.white54))),
        ),
      ];
    }

    final widgets = <Widget>[_heroCarousel()];

    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final s in _stations) {
      grouped
          .putIfAbsent(_bucketFor((s['genre'] ?? '').toString()), () => [])
          .add(s);
    }
    for (final bucket in _bucketOrder) {
      final list = grouped[bucket];
      if (list == null || list.isEmpty) continue;
      widgets.add(SectionHeader(bucket,
          subtitle: '${list.length} station${list.length == 1 ? '' : 's'}'));
      widgets.add(_carousel(list));
    }

    final genres = <String>{};
    for (final s in _stations) {
      final g = (s['genre'] ?? '').toString();
      if (g.isNotEmpty) genres.add(g);
    }
    if (genres.isNotEmpty) {
      widgets.add(const SectionHeader('Browse by Genre'));
      widgets.add(_genreChips(genres.toList()..sort()));
    }
    return widgets;
  }

  // ── Rotating featured / most-listened hero ──────────────────────────────
  Widget _heroCarousel() {
    if (_heroList.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Column(
        children: [
          SizedBox(
            height: 150,
            child: PageView.builder(
              controller: _heroController,
              itemCount: _heroList.length,
              onPageChanged: (i) => setState(() => _heroPage = i),
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _heroCard(_heroList[i]),
              ),
            ),
          ),
          if (_heroList.length > 1) ...[
            const SizedBox(height: 10),
            _dots(_heroList.length),
          ],
        ],
      ),
    );
  }

  Widget _heroCard(Map<String, dynamic> s) {
    final grad = stationGradient(s['genre']?.toString());
    final isCur = _isCurrent(s);
    final live = _isLive(s);
    final name = (s['name'] ?? '').toString();
    final meta = [s['genre'], s['description']]
        .where((v) => v != null && '$v'.isNotEmpty)
        .join('  ·  ');
    return GestureDetector(
      onTap: () => _play(s),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [grad[0].withOpacity(0.45), grad[1].withOpacity(0.20)],
          ),
          border: Border.all(color: grad[0].withOpacity(0.5)),
          boxShadow: [
            BoxShadow(
                color: grad[0].withOpacity(0.28),
                blurRadius: 22,
                spreadRadius: -6),
          ],
        ),
        child: Row(
          children: [
            SizedBox(
              width: 110,
              height: 110,
              child: _StationArt(
                  station: s, radius: 16, iconSize: 40, live: live, bigBars: true),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      Text(isCur ? 'NOW PLAYING' : 'FEATURED',
                          style: TextStyle(
                              color: Color.lerp(grad[0], Colors.white, 0.55),
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2)),
                      if (live) ...[
                        const SizedBox(width: 8),
                        const _Equalizer(color: Colors.white),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold)),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.8),
                            fontSize: 12)),
                  ],
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.18),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(isCur ? Icons.graphic_eq : Icons.play_arrow,
                            color: Colors.white, size: 16),
                        const SizedBox(width: 5),
                        Text(isCur ? 'Live' : 'Listen',
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 12)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dots(int count) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final active = i == _heroPage;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: active ? 18 : 6,
          height: 6,
          margin: const EdgeInsets.symmetric(horizontal: 3),
          decoration: BoxDecoration(
            color: active ? kAccent : Colors.white24,
            borderRadius: BorderRadius.circular(3),
          ),
        );
      }),
    );
  }

  Widget _carousel(List<Map<String, dynamic>> list) {
    return SizedBox(
      height: 200,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: list.length,
        itemBuilder: (context, i) => _StationCard(
          station: list[i],
          isCurrent: _isCurrent(list[i]),
          isLive: _isLive(list[i]),
          onTap: () => _play(list[i]),
        ),
      ),
    );
  }

  Widget _stationRow(Map<String, dynamic> s) {
    final grad = stationGradient(s['genre']?.toString());
    final isCur = _isCurrent(s);
    final live = _isLive(s);
    final isSaved = s['_saved'] == true || s['saved'] == true;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _play(s),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: kCardBg,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: isCur ? grad[0].withOpacity(0.8) : kCardBorder),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 48,
                  height: 48,
                  child: _StationArt(
                      station: s, radius: 12, iconSize: 22, live: live),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text((s['name'] ?? '').toString(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 15)),
                      const SizedBox(height: 2),
                      Text(
                          (s['tags'] ?? '').toString().isNotEmpty
                              ? s['tags'].toString()
                              : (s['genre'] ?? '').toString(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12)),
                      if (_metaLine(s).isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(_metaLine(s),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 11)),
                      ],
                    ],
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if ((s['source'] ?? '') == 'radio-browser')
                      IconButton(
                        icon: Icon(
                          isSaved
                              ? Icons.check_circle
                              : Icons.add_circle_outline,
                          color: isSaved
                              ? Colors.greenAccent
                              : Colors.white60,
                        ),
                        tooltip: isSaved
                            ? 'Saved'
                            : 'Save to your stations',
                        onPressed: isSaved ? null : () => _saveStation(s),
                      ),
                    isCur
                        ? const _LiveBadge()
                        : Icon(Icons.play_circle_fill,
                            color: grad[0], size: 30),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _genreChips(List<String> genres) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: genres.map((g) {
          final grad = stationGradient(g);
          return ActionChip(
            label: Text(g),
            labelStyle: TextStyle(
                color: Color.lerp(grad[0], Colors.white, 0.4),
                fontWeight: FontWeight.w600,
                fontSize: 12),
            backgroundColor: grad[0].withOpacity(0.16),
            side: BorderSide(color: grad[0].withOpacity(0.4)),
            onPressed: () {
              _search.text = g;
              _onSearchChanged(g);
            },
          );
        }).toList(),
      ),
    );
  }

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.radio, color: Colors.white24, size: 48),
              const SizedBox(height: 12),
              const Text('Could not load stations',
                  style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 4),
              Text(_error ?? '',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white38, fontSize: 12)),
              const SizedBox(height: 16),
              TextButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
}

/// Station artwork: the favicon image when present, gradient + radio-icon
/// fallback otherwise, with a scrim + equalizer overlay when it's live.
class _StationArt extends StatelessWidget {
  final Map<String, dynamic> station;
  final double radius;
  final double iconSize;
  final bool live;
  final bool bigBars;

  const _StationArt({
    required this.station,
    this.radius = 12,
    this.iconSize = 26,
    this.live = false,
    this.bigBars = false,
  });

  @override
  Widget build(BuildContext context) {
    final grad = stationGradient(station['genre']?.toString());
    final fav = (station['favicon'] ?? '').toString();
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                  colors: grad,
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight),
            ),
          ),
          if (fav.isNotEmpty)
            CachedNetworkImage(
              imageUrl: fav,
              fit: BoxFit.cover,
              fadeInDuration: const Duration(milliseconds: 250),
              placeholder: (_, __) => Center(
                  child: Icon(Icons.radio,
                      color: Colors.white.withOpacity(0.7), size: iconSize)),
              errorWidget: (_, __, ___) => Center(
                  child: Icon(Icons.radio, color: Colors.white, size: iconSize)),
            )
          else
            Center(
                child: Icon(Icons.radio, color: Colors.white, size: iconSize)),
          if (live) ...[
            Container(color: Colors.black.withOpacity(0.42)),
            Center(child: _Equalizer(color: Colors.white, big: bigBars)),
          ],
        ],
      ),
    );
  }
}

/// Square, artwork-forward card for the genre carousels.
class _StationCard extends StatelessWidget {
  final Map<String, dynamic> station;
  final bool isCurrent;
  final bool isLive;
  final VoidCallback onTap;

  const _StationCard({
    required this.station,
    required this.isCurrent,
    required this.isLive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final grad = stationGradient(station['genre']?.toString());
    final name = (station['name'] ?? 'Station').toString();
    final genre = (station['genre'] ?? '').toString();
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 150,
        margin: const EdgeInsets.only(right: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 150,
              height: 150,
              child: Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: isCurrent
                          ? [
                              BoxShadow(
                                  color: grad[0].withOpacity(0.5),
                                  blurRadius: 18,
                                  spreadRadius: -2)
                            ]
                          : null,
                      border: isCurrent
                          ? Border.all(
                              color: Colors.white.withOpacity(0.9), width: 2)
                          : null,
                    ),
                    child: _StationArt(
                        station: station,
                        radius: 16,
                        iconSize: 46,
                        live: isLive,
                        bigBars: true),
                  ),
                  if (isCurrent)
                    const Positioned(top: 8, right: 8, child: _LiveBadge()),
                  if (!isCurrent)
                    Positioned(
                      bottom: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.45),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.play_arrow,
                            color: Colors.white, size: 22),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(genre,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white54, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.9),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, color: Colors.white, size: 7),
          SizedBox(width: 4),
          Text('LIVE',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5)),
        ],
      ),
    );
  }
}

/// Animated equalizer bars — the "this is playing" cue.
class _Equalizer extends StatefulWidget {
  final Color color;
  final bool big;
  const _Equalizer({this.color = Colors.white, this.big = false});
  @override
  State<_Equalizer> createState() => _EqualizerState();
}

class _EqualizerState extends State<_Equalizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 950))
      ..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = widget.big ? 11.0 : 7.0;
    final span = widget.big ? 28.0 : 16.0;
    final w = widget.big ? 5.0 : 4.0;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: List.generate(4, (i) {
            final phase = (_c.value * 2 * math.pi) + i * 0.85;
            final h = base + (math.sin(phase).abs() * span);
            return Container(
              width: w,
              height: h,
              margin: const EdgeInsets.symmetric(horizontal: 1.5),
              decoration: BoxDecoration(
                color: widget.color,
                borderRadius: BorderRadius.circular(2),
              ),
            );
          }),
        );
      },
    );
  }
}
