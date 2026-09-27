import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'api_service.dart';
import 'auth_http_client.dart';

class SongRecognitionResult {
  final String title;
  final String artist;
  final String album;
  final String source; // "shazam" or "acoustid"
  final String? genre;
  final String? coverUrl;

  SongRecognitionResult({
    required this.title,
    required this.artist,
    required this.album,
    required this.source,
    this.genre,
    this.coverUrl,
  });

  String get prowlarrQuery => '$artist $album';
}

class SongRecognitionService {
  static const int _sampleRate = 16000;

  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _pcmSub;
  StreamSubscription? _amplitudeSub;
  BytesBuilder _pcm = BytesBuilder(copy: false);
  bool _isRecording = false;
  bool get isRecording => _isRecording;

  /// Normalized amplitude 0.0 (silence) to 1.0 (loud). Updated ~15x/sec while recording.
  final StreamController<double> _amplitudeController = StreamController<double>.broadcast();
  Stream<double> get amplitudeStream => _amplitudeController.stream;

  Future<bool> requestMicPermission() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  /// Start the mic as a raw PCM stream that keeps filling [_pcm] until
  /// [cancelRecording]. The mic never stops between identify attempts, so
  /// each attempt sends everything heard so far.
  Future<void> _startListening() async {
    if (_isRecording) return;
    if (!await requestMicPermission()) {
      throw Exception('Microphone permission denied');
    }

    _pcm = BytesBuilder(copy: false);
    _recorder = AudioRecorder();

    RecordConfig config(AndroidAudioSource source) => RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _sampleRate,
          numChannels: 1,
          // UNPROCESSED skips the voice noise-suppression some phones apply to
          // the default mic, which strips out exactly the music we want.
          androidConfig: AndroidRecordConfig(audioSource: source),
        );

    Stream<Uint8List> stream;
    try {
      stream = await _recorder!.startStream(config(AndroidAudioSource.unprocessed));
    } catch (_) {
      // Phone doesn't offer an unprocessed source. VOICE_RECOGNITION is the
      // universal fallback that Android's CDD says runs without noise
      // suppression or AGC.
      stream = await _recorder!.startStream(config(AndroidAudioSource.voiceRecognition));
    }
    _pcmSub = stream.listen(_pcm.add);
    _isRecording = true;

    // Some phones "start" UNPROCESSED but deliver pure silence. Check after a
    // second and switch to VOICE_RECOGNITION if nothing is coming through.
    if (Platform.isAndroid) {
      await Future.delayed(const Duration(milliseconds: 1200));
      if (_isRecording && _peak(_pcm.toBytes()) < 40) {
        await _pcmSub?.cancel();
        await _recorder!.stop();
        _pcm = BytesBuilder(copy: false);
        stream = await _recorder!.startStream(config(AndroidAudioSource.voiceRecognition));
        _pcmSub = stream.listen(_pcm.add);
      }
    }

    // Stream amplitude ~15x/sec for reactive UI
    _amplitudeSub = _recorder!
        .onAmplitudeChanged(const Duration(milliseconds: 66))
        .listen((amp) {
      // amp.current is dBFS: -160 (silence) to 0 (max)
      // Phone mics in a room typically range -40dB (quiet) to -5dB (loud)
      // Map that range aggressively to 0.0-1.0 so the UI visibly reacts
      final normalized = ((amp.current + 35) / 25).clamp(0.0, 1.0);
      _amplitudeController.add(normalized);
    });
  }

  Future<void> cancelRecording() async {
    _amplitudeSub?.cancel();
    _amplitudeSub = null;
    final recorder = _recorder;
    _recorder = null;
    _isRecording = false;
    if (recorder != null) {
      try {
        await recorder.stop();
      } catch (_) {}
      await _pcmSub?.cancel();
      _pcmSub = null;
      await recorder.dispose();
    }
  }

  /// Largest absolute 16-bit sample, to tell a live mic from dead silence.
  int _peak(Uint8List pcm) {
    final samples = pcm.buffer.asByteData(pcm.offsetInBytes, pcm.lengthInBytes & ~1);
    var peak = 0;
    for (var i = 0; i + 1 < samples.lengthInBytes; i += 2) {
      final v = samples.getInt16(i, Endian.little).abs();
      if (v > peak) peak = v;
    }
    return peak;
  }

  /// 16-bit mono PCM -> a WAV file in memory.
  Uint8List _wav(Uint8List pcm) {
    final header = ByteData(44);
    void ascii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        header.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    header.setUint32(4, 36 + pcm.length, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little); // fmt chunk size
    header.setUint16(20, 1, Endian.little); // PCM
    header.setUint16(22, 1, Endian.little); // mono
    header.setUint32(24, _sampleRate, Endian.little);
    header.setUint32(28, _sampleRate * 2, Endian.little); // byte rate
    header.setUint16(32, 2, Endian.little); // block align
    header.setUint16(34, 16, Endian.little); // bits per sample
    ascii(36, 'data');
    header.setUint32(40, pcm.length, Endian.little);
    return (BytesBuilder(copy: false)
          ..add(header.buffer.asUint8List())
          ..add(pcm))
        .toBytes();
  }

  Future<SongRecognitionResult> identify(String audioFilePath) async {
    final file = File(audioFilePath);
    if (!await file.exists()) {
      throw Exception('Recording file not found');
    }
    return _identifyBytes(await file.readAsBytes());
  }

  Future<SongRecognitionResult> _identifyBytes(List<int> wavBytes) async {
    final baseUrl = ApiService.baseUrl;
    final uri = Uri.parse('$baseUrl/recognize');

    final request = http.MultipartRequest('POST', uri);
    request.files.add(http.MultipartFile.fromBytes(
      'audio',
      wavBytes,
      filename: 'recording.wav',
    ));

    // Route through appHttpClient so the auth bearer token is attached —
    // MultipartRequest.send() uses its own tokenless client and gets 401'd
    // by the API auth gate.
    final streamedResponse = await appHttpClient
        .send(request)
        .timeout(const Duration(seconds: 30));
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode == 404) {
      final data = json.decode(response.body);
      throw Exception(data['error'] ?? 'No match found');
    }

    if (response.statusCode != 200) {
      throw Exception('Server error: ${response.statusCode}');
    }

    final data = json.decode(response.body);

    return SongRecognitionResult(
      title: data['title'] ?? 'Unknown',
      artist: data['artist'] ?? 'Unknown Artist',
      album: data['album'] ?? '',
      source: data['source'] ?? 'unknown',
      genre: data['genre'],
      coverUrl: data['cover_url'],
    );
  }

  /// Listen continuously and try early and often: first at 3 s, then a new
  /// attempt 2 s after the previous one started (never two in flight), up to
  /// 20 s. Each attempt sends the whole recording so far and the mic keeps
  /// going meanwhile, so an early miss costs nothing: a loud chorus matches
  /// in a few seconds, a noisy passage just takes longer. Every 2 s stays
  /// polite to Shazam's unofficial API.
  Future<SongRecognitionResult> recordAndIdentify({
    void Function(int secondsElapsed, int maxSeconds)? onProgress,
    void Function(String status)? onStatus,
  }) async {
    const firstTry = 3;
    const gap = 2;
    const maxSeconds = 20;

    await _startListening();
    final clock = Stopwatch()..start();
    int secs() => clock.elapsed.inSeconds;
    // Progress keeps ticking while an attempt is in flight.
    final ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final s = secs();
      onProgress?.call(s > maxSeconds ? maxSeconds : s, maxSeconds);
    });
    onStatus?.call('Listening...');

    Object? lastError;
    try {
      var nextTry = firstTry;
      while (true) {
        while (secs() < nextTry) {
          await Future.delayed(const Duration(milliseconds: 100));
          if (!_isRecording) throw Exception('Cancelled');
        }
        final startedAt = secs();
        try {
          return await _identifyBytes(_wav(_pcm.toBytes()));
        } catch (e) {
          lastError = e;
        }
        if (!_isRecording) throw Exception('Cancelled');
        if (startedAt >= maxSeconds) break;
        final next = startedAt + gap;
        nextTry = next > maxSeconds ? maxSeconds : next;
      }
    } finally {
      ticker.cancel();
      await cancelRecording();
    }
    throw lastError; // the loop only exits here after a failed attempt
  }
}
