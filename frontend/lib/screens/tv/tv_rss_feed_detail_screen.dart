import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/rss_feed.dart';
import '../../services/api_service.dart';
import '../../services/audio_player_service.dart';
import '../../widgets/tv_focus.dart';
import '../now_playing_screen.dart';

/// TV-variant podcast feed detail. Shows the feed's episodes as a
/// vertical list of d-pad-focusable rows; tap a row to start playback
/// of that episode (resuming if previously partially played).
class TvRssFeedDetailScreen extends StatefulWidget {
  final RssFeed feed;
  final AudioPlayerService audioPlayerService;

  const TvRssFeedDetailScreen({
    super.key,
    required this.feed,
    required this.audioPlayerService,
  });

  @override
  State<TvRssFeedDetailScreen> createState() => _TvRssFeedDetailScreenState();
}

class _TvRssFeedDetailScreenState extends State<TvRssFeedDetailScreen> {
  final ApiService _apiService = ApiService();

  List<RssEpisode> _episodes = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _apiService.getRssEpisodes(
        widget.feed.id,
        page: 1,
        sort: widget.feed.isOldestFirst ? 'asc' : 'desc',
      );
      final eps = (result['episodes'] as List? ?? const [])
          .map((e) => RssEpisode.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() {
        _episodes = eps;
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

  void _playEpisode(RssEpisode ep) {
    // Direct audio URL when available (skips backend proxy + 1 hop);
    // fall back to the proxy URL if the feed didn't carry a direct one.
    final streamUrl = ep.audioUrl ?? _apiService.getRssStreamUrl(ep.id);
    widget.audioPlayerService.playPodcastEpisode(
      ep,
      streamUrl,
      artworkUrl: ep.artworkUrl ?? widget.feed.artworkUrl,
      podcastAuthor: widget.feed.author,
      podcastTitle: widget.feed.title,
      feedId: widget.feed.id,
      allEpisodes: _episodes,
      introSkipSeconds: widget.feed.introSkipSeconds,
      outroSkipSeconds: widget.feed.outroSkipSeconds,
    );
    NowPlayingScreen.open(
      context,
      audioPlayerService: widget.audioPlayerService,
    );
  }

  /// First episode that's been started but not finished — same logic
  /// as the phone podcast detail's `_resumeEpisode` getter.
  RssEpisode? get _resumeEpisode {
    try {
      return _episodes.firstWhere(
        (e) => e.playedPosition > 0 && !e.isCompleted,
      );
    } catch (_) {
      return null;
    }
  }

  String _formatPublished(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays < 1) return 'Today';
    if (diff.inDays < 2) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    if (diff.inDays < 30) return '${(diff.inDays / 7).floor()}w ago';
    if (diff.inDays < 365) return '${(diff.inDays / 30).floor()}mo ago';
    return '${(diff.inDays / 365).floor()}y ago';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050a14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0d1b2a),
        title: Text(
          widget.feed.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        elevation: 0,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF00d4ff)),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Text(
            'Couldn\'t load episodes: $_error',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 16),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(40, 16, 40, 16),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImage(
                  imageUrl: widget.feed.artworkCached ??
                      widget.feed.artworkUrl ??
                      '',
                  width: 88,
                  height: 88,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(
                    width: 88,
                    height: 88,
                    color: const Color(0xFF1a2332),
                  ),
                  errorWidget: (_, __, ___) => Container(
                    width: 88,
                    height: 88,
                    color: const Color(0xFF1a2332),
                    child: const Icon(
                      Icons.podcasts,
                      color: Color(0xFF00d4ff),
                      size: 44,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.feed.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      [
                        if (widget.feed.author.isNotEmpty) widget.feed.author,
                        '${_episodes.length} episodes',
                      ].join(' · '),
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 14,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              // Resume button — only shown when there's an in-progress
              // episode (started but not completed). Mirrors the phone
              // podcast detail's quick-resume affordance. Autofocuses
              // when present so the natural d-pad action on entry is
              // "keep listening to where I left off."
              if (_resumeEpisode != null) ...[
                const SizedBox(width: 18),
                _TvResumeButton(
                  episode: _resumeEpisode!,
                  onTap: () => _playEpisode(_resumeEpisode!),
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0x1AFFFFFF)),
        if (_episodes.isEmpty)
          const Expanded(
            child: Center(
              child: Text(
                'No episodes yet.',
                style: TextStyle(color: Colors.white38, fontSize: 16),
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
              itemCount: _episodes.length,
              itemBuilder: (context, i) => _TvEpisodeRow(
                episode: _episodes[i],
                publishedText: _formatPublished(_episodes[i].publishedAt),
                fallbackArtwork: widget.feed.artworkCached ??
                    widget.feed.artworkUrl,
                // Resume button autofocuses when present — first row
                // takes focus only when there's no in-progress episode
                // to resume. Avoids two competing autofocus claims.
                autofocus: i == 0 && _resumeEpisode == null,
                onTap: () => _playEpisode(_episodes[i]),
              ),
            ),
          ),
      ],
    );
  }
}

/// Header "Resume" button — visible only when there's an episode that
/// was started but not finished. Shows the episode title beneath the
/// button label so the user can confirm what they're resuming before
/// pressing OK.
class _TvResumeButton extends StatelessWidget {
  final RssEpisode episode;
  final VoidCallback onTap;

  const _TvResumeButton({required this.episode, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final progress = (episode.audioDuration != null &&
            episode.audioDuration! > 0)
        ? (episode.playedPosition / episode.audioDuration!).clamp(0.0, 1.0)
        : 0.0;
    return TvFocusable(
      onTap: onTap,
      autofocus: true,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 240),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF00d4ff),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.play_arrow, color: Colors.black, size: 20),
                SizedBox(width: 6),
                Text(
                  'Resume',
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              episode.title,
              style: const TextStyle(
                color: Colors.black87,
                fontSize: 12,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            // Mini progress bar so the user can see how far in they are.
            Container(
              height: 3,
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(2),
              ),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: progress,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TvEpisodeRow extends StatelessWidget {
  final RssEpisode episode;
  final String publishedText;
  final String? fallbackArtwork;
  final bool autofocus;
  final VoidCallback onTap;

  const _TvEpisodeRow({
    required this.episode,
    required this.publishedText,
    required this.fallbackArtwork,
    required this.onTap,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final artUrl = episode.artworkUrl ?? fallbackArtwork ?? '';
    final progress = (episode.audioDuration != null && episode.audioDuration! > 0)
        ? (episode.playedPosition / episode.audioDuration!).clamp(0.0, 1.0)
        : 0.0;
    final inProgress = !episode.isCompleted && progress > 0.01;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TvFocusable(
        onTap: onTap,
        autofocus: autofocus,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF0d1b2a),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: CachedNetworkImage(
                  imageUrl: artUrl,
                  width: 56,
                  height: 56,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(
                    width: 56,
                    height: 56,
                    color: const Color(0xFF1a2332),
                  ),
                  errorWidget: (_, __, ___) => Container(
                    width: 56,
                    height: 56,
                    color: const Color(0xFF1a2332),
                    child: const Icon(
                      Icons.podcasts,
                      color: Color(0xFF00d4ff),
                      size: 24,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      episode.title,
                      style: TextStyle(
                        color: episode.isCompleted
                            ? Colors.white54
                            : Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (publishedText.isNotEmpty) ...[
                          Text(
                            publishedText,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Text(
                          episode.durationFormatted,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                        if (episode.isCompleted) ...[
                          const SizedBox(width: 10),
                          const Icon(
                            Icons.check_circle,
                            color: Color(0xFF66bb6a),
                            size: 14,
                          ),
                        ] else if (inProgress) ...[
                          const SizedBox(width: 10),
                          Container(
                            width: 80,
                            height: 4,
                            decoration: BoxDecoration(
                              color: Colors.white12,
                              borderRadius: BorderRadius.circular(2),
                            ),
                            child: FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: progress,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: const Color(0xFF00d4ff),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
