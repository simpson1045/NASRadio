import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
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
  AudioRecorder? _recorder;
  StreamSubscription? _amplitudeSub;
  bool _isRecording = false;
  bool get isRecording => _isRecording;

  /// Normalized amplitude 0.0 (silence) to 1.0 (loud). Updated ~15x/sec while recording.
  final StreamController<double> _amplitudeController = StreamController<double>.broadcast();
  Stream<double> get amplitudeStream => _amplitudeController.stream;

  Future<bool> requestMicPermission() async {
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  Future<String> _getRecordingPath() async {
    final dir = await getTemporaryDirectory();
    return '${dir.path}/song_recognition.wav';
  }

  Future<void> startRecording() async {
    if (_isRecording) return;

    final hasPermission = await requestMicPermission();
    if (!hasPermission) {
      throw Exception('Microphone permission denied');
    }

    _recorder = AudioRecorder();
    final path = await _getRecordingPath();

    await _recorder!.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );
    _isRecording = true;

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

  Future<String> stopRecording() async {
    if (!_isRecording || _recorder == null) {
      throw Exception('Not recording');
    }
    _amplitudeSub?.cancel();
    _amplitudeSub = null;
    final path = await _recorder!.stop();
    _isRecording = false;
    await _recorder!.dispose();
    _recorder = null;
    if (path == null) throw Exception('Recording failed — no file produced');
    return path;
  }

  void cancelRecording() async {
    _amplitudeSub?.cancel();
    _amplitudeSub = null;
    if (_isRecording && _recorder != null) {
      await _recorder!.stop();
      _isRecording = false;
      await _recorder!.dispose();
      _recorder = null;
    }
  }

  Future<SongRecognitionResult> identify(String audioFilePath) async {
    final file = File(audioFilePath);
    if (!await file.exists()) {
      throw Exception('Recording file not found');
    }

    final fileBytes = await file.readAsBytes();
    final baseUrl = ApiService.baseUrl;
    final uri = Uri.parse('$baseUrl/recognize');

    final request = http.MultipartRequest('POST', uri);
    request.files.add(http.MultipartFile.fromBytes(
      'audio',
      fileBytes,
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

  /// Chunked flow: record 5s → try identify → if no match, record 5 more → try again → hard cap at 15s
  Future<SongRecognitionResult> recordAndIdentify({
    void Function(int secondsElapsed, int maxSeconds)? onProgress,
    void Function(String status)? onStatus,
  }) async {
    const int chunkSeconds = 5;
    const int maxSeconds = 15;

    await startRecording();

    for (int elapsed = 1; elapsed <= maxSeconds; elapsed++) {
      onProgress?.call(elapsed, maxSeconds);
      await Future.delayed(const Duration(seconds: 1));

      // Try identification at each chunk boundary
      if (elapsed % chunkSeconds == 0) {
        onStatus?.call('Identifying...');

        // Stop recording, grab what we have
        final path = await stopRecording();

        try {
          final result = await identify(path);
          return result; // Match found
        } catch (_) {
          // No match yet — keep recording if we haven't hit the cap
          if (elapsed < maxSeconds) {
            onStatus?.call('Listening...');
            await startRecording();
          } else {
            rethrow; // Final attempt failed, propagate the error
          }
        }
      }
    }

    // Should not reach here, but safety net
    throw Exception('Could not identify the song after ${maxSeconds}s');
  }
}
