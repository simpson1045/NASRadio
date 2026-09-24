import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'auth_http_client.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';

enum LogLevel { info, warning, error }

class LogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String message;

  LogEntry({required this.timestamp, required this.level, required this.message});

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'level': level.name,
    'message': message,
  };

  factory LogEntry.fromJson(Map<String, dynamic> json) => LogEntry(
    timestamp: DateTime.parse(json['timestamp']),
    level: LogLevel.values.firstWhere(
      (l) => l.name == json['level'],
      orElse: () => LogLevel.info,
    ),
    message: json['message'] ?? '',
  );
}

/// Persistent frontend logger for debugging.
///
/// Three layers:
///   1. In-memory ring buffer (fast reads for the in-app log viewer).
///   2. Debounced on-device file (crash survival; loaded on next launch).
///   3. Periodic ship to the backend's /api/logs/ingest endpoint, so a
///      multi-device incident can be reassembled from a single combined
///      log file on the server. Error-level entries ship immediately.
///
/// Access via AppLogger.instance.
class AppLogger {
  static final AppLogger instance = AppLogger._();

  AppLogger._();

  static const int _maxEntries = 2000;
  static const Duration _saveDebounce = Duration(seconds: 5);
  static const Duration _shipInterval = Duration(seconds: 30);
  // Cap the payload so a big burst of logs doesn't produce a multi-MB
  // POST. Anything beyond is kept locally and ships on the next tick.
  static const int _shipBatchMax = 500;

  final List<LogEntry> _entries = [];
  final StreamController<LogEntry> _streamController = StreamController<LogEntry>.broadcast();
  Timer? _saveTimer;
  Timer? _shipTimer;
  String? _logFilePath;
  // Forensic crash file — separate from the rolling debug log so a
  // crash mid-flush of the main log doesn't lose itself. recordCrash
  // appends to this file synchronously (flush: true) the moment an
  // uncaught error fires; on the NEXT successful boot, init() ships
  // any pending contents to the backend via the error-level path
  // (which flushes immediately) and then deletes the file. Lets us
  // see crash traces for the "black screen → bounced to home" pattern
  // that otherwise leaves no trace in combined.log because the app
  // dies before AppLogger's debounced save tick fires.
  String? _crashFilePath;
  bool _initialized = false;
  // Entries added since the last successful ship. Kept as a list rather
  // than an index because _entries can drop old items at the cap.
  final List<LogEntry> _unshipped = [];
  bool _shipInFlight = false;
  String _deviceName = 'DEVICE';

  List<LogEntry> get entries => List.unmodifiable(_entries);
  Stream<LogEntry> get stream => _streamController.stream;

  /// Initialize the logger — loads previous session's logs from disk.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    try {
      final dir = await getApplicationDocumentsDirectory();
      _logFilePath = '${dir.path}/nasradio_debug.log';
      _crashFilePath = '${dir.path}/nasradio_crash.log';
      await _loadFromDisk();
      // Pick up any crash recorded on the previous run BEFORE the
      // session-start line below — that way the crash entry is
      // chronologically attached to its own session rather than
      // appearing to belong to the new one.
      await _flushPendingCrashFile();
    } catch (e) {
      print('AppLogger init error: $e');
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final savedName = prefs.getString('device_name');
      if (savedName != null && savedName.isNotEmpty) {
        _deviceName = savedName;
      } else if (Platform.isAndroid) {
        _deviceName = 'Android';
      } else if (Platform.isWindows) {
        _deviceName = 'Windows';
      } else if (Platform.isIOS) {
        _deviceName = 'iOS';
      }
    } catch (_) {
      // Device name stays as default fallback — not worth failing startup.
    }

    // Log the session start
    info('--- Session started ($_deviceName) ---');

    // Kick off the periodic shipper. First ship happens after the
    // interval, NOT immediately — lets the session settle and avoids a
    // flurry of init logs dominating the initial batch.
    _shipTimer = Timer.periodic(_shipInterval, (_) => _shipToServer());
  }

  void info(String message) => _log(LogLevel.info, message);
  void warning(String message) => _log(LogLevel.warning, message);
  void error(String message) => _log(LogLevel.error, message);

  /// Record an uncaught error to a separate, immediately-flushed file
  /// so the next successful boot can ship it to the backend log. This
  /// catches the "app dies before debounced save fires" failure mode
  /// where a crash leaves no breadcrumb in combined.log at all.
  ///
  /// Designed to never throw — the worst-case fallback is a console
  /// print. Returns when the bytes hit disk (`flush: true`) so even
  /// if the next instruction is an exit, the crash trace survives.
  ///
  /// [where] is a short marker for which handler caught the error
  /// (e.g. "FlutterError", "PlatformDispatcher", "runZonedGuarded") so
  /// we can tell from the recovered log which code path failed.
  Future<void> recordCrash(
    Object error,
    StackTrace stack, {
    String? where,
  }) async {
    final marker = where ?? 'unknown';
    final ts = DateTime.now().toIso8601String();
    final entry =
        '=== CRASH at $ts ($marker) ===\n'
        '$error\n'
        '$stack\n'
        '=== END CRASH ===\n';

    // Best-effort console print so debug builds + adb logcat still
    // surface the error even if the disk write fails.
    print('🔥 [AppLogger] $entry');

    try {
      String? path = _crashFilePath;
      if (path == null) {
        // Crash fired before init() — resolve the path on demand. This
        // is essentially free (path_provider caches its lookup).
        try {
          final dir = await getApplicationDocumentsDirectory();
          path = '${dir.path}/nasradio_crash.log';
          _crashFilePath ??= path;
        } catch (_) {
          // Can't resolve a path — bail with the console print only.
          return;
        }
      }
      // Append so multiple crashes in the same run all survive.
      // flush: true forces the bytes to disk before the future
      // completes; without it, an immediate process exit can lose
      // the trace.
      await File(path).writeAsString(
        entry,
        mode: FileMode.append,
        flush: true,
      );
    } catch (e) {
      print('🔥 [AppLogger] Failed to write crash file: $e');
    }
  }

  /// Read any crash file written by the previous run and ship it to
  /// the backend log as error-level entries (which the existing ship
  /// path flushes immediately). Deletes the file once forwarded so
  /// crashes don't re-ship on every boot.
  Future<void> _flushPendingCrashFile() async {
    final path = _crashFilePath;
    if (path == null) return;
    final file = File(path);
    if (!await file.exists()) return;
    try {
      final content = await file.readAsString();
      if (content.trim().isNotEmpty) {
        // Use error() so the existing ship-on-error path fires this
        // off to the backend within the next tick instead of waiting
        // for the 30s ship interval.
        error('🔥 Recovered crash from previous run:\n$content');
      }
      await file.delete();
    } catch (e) {
      print('AppLogger crash-recover error: $e');
    }
  }

  void _log(LogLevel level, String message) {
    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: level,
      message: message,
    );

    _entries.add(entry);
    _unshipped.add(entry);

    // Cap at max entries — _unshipped is bounded separately by the batch
    // send so we don't mirror this cap there.
    while (_entries.length > _maxEntries) {
      _entries.removeAt(0);
    }

    // Notify listeners
    _streamController.add(entry);

    // Also print so it shows up in debug console when available
    print('[${level.name.toUpperCase()}] $message');

    // Debounced save to disk
    _scheduleSave();

    // Error entries jump the queue — ship right away so a crash log
    // reaches the server before the next interval tick (or before the
    // app itself dies).
    if (level == LogLevel.error) {
      _shipToServer();
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDebounce, _saveToDisk);
  }

  Future<void> _saveToDisk() async {
    if (_logFilePath == null) return;
    try {
      final jsonList = _entries.map((e) => e.toJson()).toList();
      await File(_logFilePath!).writeAsString(json.encode(jsonList));
    } catch (e) {
      print('AppLogger save error: $e');
    }
  }

  Future<void> _loadFromDisk() async {
    if (_logFilePath == null) return;
    try {
      final file = File(_logFilePath!);
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.isNotEmpty) {
          final List<dynamic> jsonList = json.decode(content);
          final loaded = jsonList
              .map((j) => LogEntry.fromJson(j as Map<String, dynamic>))
              .toList();
          // Only keep the most recent entries
          if (loaded.length > _maxEntries) {
            _entries.addAll(loaded.sublist(loaded.length - _maxEntries));
          } else {
            _entries.addAll(loaded);
          }
          print('AppLogger: loaded ${_entries.length} entries from previous session');
        }
      }
    } catch (e) {
      print('AppLogger load error: $e');
    }
  }

  /// Clear all logs and delete the file.
  Future<void> clear() async {
    _entries.clear();
    if (_logFilePath != null) {
      try {
        final file = File(_logFilePath!);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }
  }

  /// Force save now (call before app exit).
  Future<void> flush() async {
    _saveTimer?.cancel();
    await _saveToDisk();
    await _shipToServer();
  }

  /// Ship queued log entries to the backend. Called from the periodic
  /// timer and, greedily, on any error-level entry. Safe to call at
  /// any time; a lock prevents concurrent ships from duplicating.
  Future<void> _shipToServer() async {
    if (_shipInFlight || _unshipped.isEmpty) return;
    _shipInFlight = true;
    // Take a snapshot of what we're shipping so new entries added
    // during the await don't get lost or double-counted.
    final batch = _unshipped.length > _shipBatchMax
        ? _unshipped.sublist(0, _shipBatchMax)
        : List<LogEntry>.from(_unshipped);
    try {
      final payload = {
        'device_name': _deviceName,
        'entries': batch.map((e) => e.toJson()).toList(),
      };
      final response = await appHttpClient
          .post(
            Uri.parse('${ApiService.baseUrl}/logs/ingest'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(payload),
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        // Success — remove the shipped batch from the queue. Using
        // removeRange so any entries added during the await stay in
        // the queue for the next ship.
        _unshipped.removeRange(0, batch.length);
      }
    } catch (_) {
      // Network error — leave the queue alone, next tick will retry.
      // We deliberately don't log this since logging the failure would
      // create a feedback loop of log-shipping-failures.
    } finally {
      _shipInFlight = false;
    }
  }
}
