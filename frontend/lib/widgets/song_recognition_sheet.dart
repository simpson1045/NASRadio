import 'dart:async';
import 'package:flutter/material.dart';
import '../services/song_recognition_service.dart';
import '../services/api_service.dart';
import '../services/audio_player_service.dart';
import '../models/song.dart';
import '../screens/now_playing_screen.dart';

/// Shows the song recognition bottom sheet. Returns a SongRecognitionResult
/// if a song was identified and user wants to search, or null if dismissed.
Future<SongRecognitionResult?> showSongRecognitionSheet(
  BuildContext context,
  SongRecognitionService service, {
  AudioPlayerService? audioPlayerService,
}) {
  return showModalBottomSheet<SongRecognitionResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _SongRecognitionSheet(
      service: service,
      audioPlayerService: audioPlayerService,
    ),
  );
}

enum _RecognitionState { listening, identifying, result, error }

class _SongRecognitionSheet extends StatefulWidget {
  final SongRecognitionService service;
  final AudioPlayerService? audioPlayerService;
  const _SongRecognitionSheet({required this.service, this.audioPlayerService});

  @override
  State<_SongRecognitionSheet> createState() => _SongRecognitionSheetState();
}

class _SongRecognitionSheetState extends State<_SongRecognitionSheet> {
  _RecognitionState _state = _RecognitionState.listening;
  int _secondsElapsed = 0;
  int _maxSeconds = 15;
  String _statusText = 'Listening...';
  String _errorMessage = '';
  SongRecognitionResult? _result;

  // Library match
  final ApiService _apiService = ApiService();
  Song? _libraryMatch;
  List<Song>? _libraryMatches;

  // Live amplitude from mic (0.0 to 1.0)
  double _amplitude = 0.0;
  StreamSubscription<double>? _ampSub;

  @override
  void initState() {
    super.initState();

    // Listen to real-time amplitude from the recorder
    _ampSub = widget.service.amplitudeStream.listen((amp) {
      if (mounted) setState(() => _amplitude = amp);
    });

    _startRecognition();
  }

  @override
  void dispose() {
    _ampSub?.cancel();
    widget.service.cancelRecording();
    super.dispose();
  }

  Future<void> _startRecognition() async {
    setState(() {
      _state = _RecognitionState.listening;
      _secondsElapsed = 0;
      _amplitude = 0.0;
      _statusText = 'Listening...';
    });

    try {
      final result = await widget.service.recordAndIdentify(
        onProgress: (elapsed, max) {
          if (mounted) setState(() {
            _secondsElapsed = elapsed;
            _maxSeconds = max;
          });
        },
        onStatus: (status) {
          if (mounted) setState(() {
            _statusText = status;
            if (status == 'Identifying...') {
              _state = _RecognitionState.identifying;
              _amplitude = 0.0;
            } else {
              _state = _RecognitionState.listening;
            }
          });
        },
      );

      if (mounted) {
        setState(() {
          _result = result;
          _state = _RecognitionState.result;
        });
        _searchLibrary(result);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().replaceFirst('Exception: ', '');
          _state = _RecognitionState.error;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1a2332),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + MediaQuery.of(context).viewPadding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey[700],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),
          _buildContent(),
        ],
      ),
    );
  }

  Future<void> _searchLibrary(SongRecognitionResult result) async {
    try {
      // Search by title + artist for best match
      final searchResult = await _apiService.search('${result.title} ${result.artist}');
      final songs = (searchResult['songs'] as List?)
          ?.map((s) => Song.fromJson(s))
          .toList() ?? [];

      // Only offer a song that really is the one Shazam heard: same title
      // (ignoring accents, punctuation, "(Remastered)"/"feat." tails) AND at
      // least one credited artist in common. Search is fuzzy — "ROSÉ" alone
      // pulled up "Black Rose" — so no confident match means no Listen Now.
      final wantTitle = _norm(_stripTail(result.title));
      final wantArtists = _artists(result.artist);
      final matches = songs.where((s) {
        if (_norm(_stripTail(s.title)) != wantTitle) return false;
        final have = _artists(s.artistName);
        return wantArtists.any(have.contains);
      }).toList();

      if (matches.isNotEmpty && mounted) {
        setState(() {
          _libraryMatch = matches.first;
          _libraryMatches = matches;
        });
      }
    } catch (_) {}
  }

  static const _accents = {
    'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a',
    'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
    'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i',
    'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', 'ø': 'o',
    'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u', 'ñ': 'n', 'ç': 'c',
  };

  /// Lowercase, accents folded, only letters/digits kept.
  static String _norm(String s) {
    final lower = s.toLowerCase().replaceAll('&', 'and');
    final folded = lower.split('').map((c) => _accents[c] ?? c).join();
    return folded.replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  /// Drop trailing "(Remastered 2011)", "[Live]", "- Single Version", "feat. X".
  static String _stripTail(String title) => title
      .replaceAll(RegExp(r'\s*[\(\[].*?[\)\]]'), '')
      .replaceAll(RegExp(r'\s+-\s+.*$'), '')
      .replaceAll(RegExp(r'\s+(feat\.?|ft\.?|featuring)\s+.*$', caseSensitive: false), '')
      .trim();

  /// "ROSÉ & Bruno Mars" / "A feat. B" / "A, B" -> {"rose", "brunomars"}.
  static Set<String> _artists(String artist) => artist
      .split(RegExp(r'\s*(?:&|,|/|\bx\b|\band\b|\bwith\b|\bfeat\.?|\bft\.?|\bfeaturing\b)\s*',
          caseSensitive: false))
      .map(_norm)
      .where((a) => a.isNotEmpty)
      .toSet();

  Widget _buildContent() {
    switch (_state) {
      case _RecognitionState.listening:
        return _buildListening();
      case _RecognitionState.identifying:
        return _buildIdentifying();
      case _RecognitionState.result:
        return _buildResult();
      case _RecognitionState.error:
        return _buildError();
    }
  }

  Widget _buildListening() {
    // Mic icon scales with live amplitude — big, obvious movement
    final micScale = 1.0 + (_amplitude * 0.6);
    final glowOpacity = 0.1 + (_amplitude * 0.4);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedScale(
          scale: micScale,
          duration: const Duration(milliseconds: 80),
          child: Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF00d4ff).withOpacity(glowOpacity),
            ),
            child: const Icon(Icons.mic, color: Color(0xFF00d4ff), size: 40),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          _statusText,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '${_secondsElapsed}s / ${_maxSeconds}s',
          style: TextStyle(color: Colors.grey[400], fontSize: 14),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: LinearProgressIndicator(
            value: _maxSeconds > 0 ? _secondsElapsed / _maxSeconds : 0,
            backgroundColor: const Color(0xFF0d1b2a),
            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00d4ff)),
            minHeight: 3,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(height: 12),
        // Live amplitude bars
        SizedBox(
          height: 40,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(9, (i) {
              // Each bar gets a slightly different amplitude based on position
              // Center bars are tallest, edges shorter — creates a wave shape
              final centerDistance = (i - 4).abs() / 4.0; // 0 at center, 1 at edges
              final barAmp = _amplitude * (1.0 - centerDistance * 0.5);
              final barHeight = 6.0 + (barAmp * 34.0); // 6px min, 40px max
              return AnimatedContainer(
                duration: const Duration(milliseconds: 80),
                width: 4,
                height: barHeight,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  color: Color(0xFF00d4ff).withOpacity(0.5 + barAmp * 0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 16),
        TextButton(
          onPressed: () {
            widget.service.cancelRecording();
            Navigator.pop(context);
          },
          child: Text('Cancel', style: TextStyle(color: Colors.grey[500])),
        ),
      ],
    );
  }

  Widget _buildIdentifying() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 50,
          height: 50,
          child: CircularProgressIndicator(
            color: Color(0xFF00d4ff),
            strokeWidth: 3,
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Identifying...',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildResult() {
    final r = _result!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Show cover art if available, otherwise music note icon
        if (r.coverUrl != null && r.coverUrl!.isNotEmpty)
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              r.coverUrl!,
              width: 80,
              height: 80,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  const Icon(Icons.music_note, color: Color(0xFF00d4ff), size: 40),
            ),
          )
        else
          const Icon(Icons.music_note, color: Color(0xFF00d4ff), size: 40),
        const SizedBox(height: 12),
        Text(
          r.title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text(
          r.artist,
          style: const TextStyle(color: Color(0xFF00d4ff), fontSize: 16),
          textAlign: TextAlign.center,
        ),
        if (r.album.isNotEmpty || r.year != null) ...[
          const SizedBox(height: 2),
          Text(
            [if (r.album.isNotEmpty) r.album, if (r.year != null) r.year!].join(' · '),
            style: TextStyle(color: Colors.grey[400], fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 4),
        Text(
          'Identified via ${r.source == "shazam" ? "Shazam" : "AcoustID"}',
          style: TextStyle(color: Colors.grey[600], fontSize: 11),
        ),
        const SizedBox(height: 20),
        // "Listen Now" button if song is in library
        if (_libraryMatch != null && widget.audioPlayerService != null) ...[
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                final player = widget.audioPlayerService!;
                final queue = _libraryMatches ?? [_libraryMatch!];
                final startIndex = queue.indexWhere((s) => s.id == _libraryMatch!.id);
                player.setQueue(queue, startIndex >= 0 ? startIndex : 0);
                Navigator.pop(context);
                NowPlayingScreen.open(
                  context,
                  audioPlayerService: player,
                );
              },
              icon: const Icon(Icons.play_arrow),
              // Two lines, library title ellipsized: long titles ("It's Five
              // O' Clock Somewhere (Alan Jackson and Jimmy Buffett)") used to
              // overflow the pill.
              label: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Listen Now', style: TextStyle(fontWeight: FontWeight.w600)),
                  Text(
                    _libraryMatch!.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400),
                  ),
                ],
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00d4ff),
                foregroundColor: const Color(0xFF0d1b2a),
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 20),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        SizedBox(
          width: double.infinity,
          child: _libraryMatch != null
              ? OutlinedButton.icon(
                  onPressed: () => Navigator.pop(context, r),
                  icon: const Icon(Icons.search, size: 18),
                  label: const Text('Search Prowlarr'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF00d4ff),
                    side: const BorderSide(color: Color(0xFF00d4ff)),
                  ),
                )
              : ElevatedButton.icon(
                  onPressed: () => Navigator.pop(context, r),
                  icon: const Icon(Icons.search),
                  label: const Text('Search Prowlarr'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00d4ff),
                    foregroundColor: const Color(0xFF0d1b2a),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _startRecognition,
                icon: const Icon(Icons.mic, size: 18),
                label: const Text('Try Again'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF00d4ff),
                  side: const BorderSide(color: Color(0xFF00d4ff)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.grey[400],
                  side: BorderSide(color: Colors.grey[600]!),
                ),
                child: const Text('Dismiss'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildError() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline, color: Colors.orange, size: 40),
        const SizedBox(height: 12),
        const Text(
          'Could not identify',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _errorMessage,
          style: TextStyle(color: Colors.grey[400], fontSize: 14),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _startRecognition,
                icon: const Icon(Icons.mic, size: 18),
                label: const Text('Try Again'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00d4ff),
                  foregroundColor: const Color(0xFF0d1b2a),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.grey[400],
                  side: BorderSide(color: Colors.grey[600]!),
                ),
                child: const Text('Dismiss'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

