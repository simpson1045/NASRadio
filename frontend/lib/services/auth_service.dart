import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'auth_http_client.dart';
import 'api_service.dart';
import 'app_logger.dart';

/// Owns the login state: the bearer token (in encrypted storage), the current
/// user, and the login/logout flow. A ChangeNotifier so the root widget can
/// swap between the login screen and the app when auth state changes.
class AuthService extends ChangeNotifier {
  AuthService._();
  static final AuthService instance = AuthService._();

  // macOS: the default "data protection" keychain needs a paid Apple
  // developer signature; on our self-signed build every write failed, so
  // the Mac login was never remembered. The regular login keychain works.
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    mOptions: MacOsOptions(useDataProtectionKeyChain: false),
  );
  static const String _tokenKey = 'nasradio_auth_token';

  // Linux: values go into the keyring as "b64:<base64>". Nov 24, 2026: the
  // stored item held raw newlines, and a no-password GNOME login keyring is a
  // plaintext file that writes secret= values unescaped, so the next load
  // rejected Matt's whole login keyring. The newlines came from the plugin's
  // pretty-printed JSON (patched in third_party/); base64 also keeps any
  // value we store to one line of [A-Za-z0-9+/=]. Older raw values still
  // read, and init() rewrites them in this form.
  static const String _b64Prefix = 'b64:';
  static bool get _isLinux =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

  Future<void> _writeToken(String token) {
    final value =
        _isLinux ? '$_b64Prefix${base64.encode(utf8.encode(token))}' : token;
    return _storage.write(key: _tokenKey, value: value);
  }

  /// The stored token, and whether it is still in the old raw form (Linux).
  Future<(String?, bool)> _readToken() async {
    final raw = await _storage.read(key: _tokenKey);
    if (raw == null || !_isLinux) return (raw, false);
    if (raw.startsWith(_b64Prefix)) {
      return (utf8.decode(base64.decode(raw.substring(_b64Prefix.length))), false);
    }
    return (raw, true);
  }

  Map<String, dynamic>? _user;
  bool _initialized = false;

  // Sliding session: the token is traded for a fresh 30-day one on start,
  // on resume and about daily while running (/api/auth/refresh), so a device
  // in use never expires. Oct 26: the phone's non-sliding 30-day token died
  // mid-day and Android Auto showed "playing" with no audio.
  DateTime? _lastRefresh;
  Timer? _refreshTimer;
  static const _refreshEvery = Duration(hours: 20);
  static const _refreshThrottle = Duration(hours: 1);

  /// True after a stored session was rejected (expired/revoked) until the
  /// next sign-in: the login screen says why, and the player/Android Auto
  /// stop pretending to play.
  bool _sessionExpired = false;
  bool get sessionExpired => _sessionExpired;

  Map<String, dynamic>? get user => _user;
  bool get isLoggedIn =>
      appHttpClient.token != null && appHttpClient.token!.isNotEmpty;
  bool get isAdmin => _user != null && _user!['role'] == 'admin';
  bool get initialized => _initialized;

  /// Load any stored token at startup and validate it. Wires the global 401
  /// handler so an expired/revoked token mid-session bounces back to login.
  Future<void> init() async {
    appHttpClient.onUnauthorized = _handleUnauthorized;
    String? token;
    var legacy = false;
    try {
      (token, legacy) = await _readToken();
    } catch (_) {
      token = null;
    }
    // Re-save an old raw value right away: the patched plugin writes the
    // item as one line, and the keyring daemon then rewrites its file clean.
    if (legacy && token != null && token.isNotEmpty) {
      try {
        await _writeToken(token);
        AppLogger.instance.info('🔑 [auth] keyring token re-saved in safe form');
      } catch (e) {
        AppLogger.instance.warning('🔑 [auth] keyring migration failed: $e');
      }
    }
    appHttpClient.setToken(token);
    if (token != null && token.isNotEmpty) {
      await _loadMe();
    }
    _initialized = true;
    notifyListeners();
  }

  Future<void> _loadMe() async {
    try {
      await ApiService.detectNetwork();
      // Bounded: on a timeout the catch below keeps the token and the app
      // carries on instead of sitting on the startup spinner.
      final resp = await appHttpClient
          .get(Uri.parse('${ApiService.baseUrl}/auth/me'))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        _user = jsonDecode(resp.body)['user'] as Map<String, dynamic>;
        await _fetchMediaToken();
        await ApiService.loadClientConfig();
        unawaited(refreshSession(force: true));
        _startRefreshTimer();
      }
      // A 401 here triggers _handleUnauthorized via the client, clearing token.
    } catch (_) {
      // Network error or timeout: keep the token and let the app open. The
      // media token has its own retry ladder, and a successful refresh fills
      // in the user (admin features) later.
      unawaited(_fetchMediaToken());
      _startRefreshTimer();
      unawaited(Future.delayed(const Duration(seconds: 10),
          () => refreshSession(force: true)));
    }
  }

  /// Fetch the read-only media token used in stream/artwork URLs. The fetch
  /// itself lives in ApiService.refreshMediaToken so the player's stream
  /// retry can call it too. A failed attempt retries on a backoff ladder
  /// instead of leaving the app media-dead until the next restart (without a
  /// token every stream/artwork URL 401s, which looks exactly like every
  /// file in the library going missing).
  Future<void> _fetchMediaToken() async {
    if (await ApiService.refreshMediaToken(force: true)) return;
    unawaited(_retryMediaToken());
  }

  Future<void> _retryMediaToken() async {
    const delaysSec = [5, 15, 30, 60, 120, 300];
    for (final d in delaysSec) {
      await Future.delayed(Duration(seconds: d));
      if (ApiService.mediaToken != null) return; // fixed meanwhile
      if (await ApiService.refreshMediaToken(force: true)) return;
    }
  }

  /// Returns null on success, or a user-facing error message.
  Future<String?> login(String username, String password) async {
    try {
      await ApiService.detectNetwork();
      final resp = await appHttpClient.post(
        Uri.parse('${ApiService.baseUrl}/auth/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username, 'password': password}),
      );
      if (resp.statusCode == 200) {
        await _applyLoginResponse(jsonDecode(resp.body));
        return null;
      }
      return _errorFrom(resp.body) ?? 'Login failed (${resp.statusCode})';
    } catch (e) {
      return 'Could not reach the server. Check your connection.';
    }
  }

  /// First run only: create the server's first admin account and sign in as
  /// it. The backend accepts this exactly once (while it has no users), so
  /// a 409 here means someone else already finished setup — show login.
  /// Returns null on success, or a user-facing error message.
  Future<String?> setupAdmin(String username, String password) async {
    try {
      await ApiService.detectNetwork();
      final resp = await appHttpClient.post(
        Uri.parse('${ApiService.baseUrl}/setup/admin'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username, 'password': password}),
      );
      if (resp.statusCode == 200) {
        await _applyLoginResponse(jsonDecode(resp.body));
        return null;
      }
      if (resp.statusCode == 409) {
        return 'This server already has an admin. Sign in instead.';
      }
      return _errorFrom(resp.body) ?? 'Setup failed (${resp.statusCode})';
    } catch (e) {
      return 'Could not reach the server. Check your connection.';
    }
  }

  Future<void> _applyLoginResponse(dynamic data) async {
    final token = data['token'] as String;
    _user = data['user'] as Map<String, dynamic>;
    try {
      await _writeToken(token);
    } catch (_) {}
    appHttpClient.setToken(token);
    _sessionExpired = false;
    _lastRefresh = DateTime.now();
    _startRefreshTimer();
    await _fetchMediaToken();
    await ApiService.loadClientConfig();
    notifyListeners();
  }

  /// Trade the current session token for a fresh one (new 30-day clock) and
  /// re-fetch the 7-day media token. Throttled to once an hour unless
  /// [force]. Called at startup, on app resume and by the ~daily timer. A
  /// 401 here means the token already died: the client's onUnauthorized
  /// handler signs out, same as any other request.
  Future<void> refreshSession({bool force = false}) async {
    if (!isLoggedIn) return;
    final now = DateTime.now();
    if (!force &&
        _lastRefresh != null &&
        now.difference(_lastRefresh!) < _refreshThrottle) {
      return;
    }
    try {
      await ApiService.detectNetwork();
      final resp = await appHttpClient
          .post(Uri.parse('${ApiService.baseUrl}/auth/refresh'))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return;
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final token = body['token'] as String?;
      if (token == null || token.isEmpty) return;
      // Fills in the user when the startup /auth/me timed out.
      if (_user == null && body['user'] is Map) {
        _user = Map<String, dynamic>.from(body['user'] as Map);
        notifyListeners();
      }
      try {
        await _writeToken(token);
      } catch (_) {}
      appHttpClient.setToken(token);
      _lastRefresh = now;
      await ApiService.refreshMediaToken(force: true);
    } catch (_) {
      // Offline: keep the current token, the timer / next resume retries.
    }
  }

  /// Checks hourly; refreshes once the last refresh is ~a day old. Hourly
  /// ticks (not one 20 h timer) survive the device sleeping through it.
  void _startRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(hours: 1), (_) {
      if (_lastRefresh == null ||
          DateTime.now().difference(_lastRefresh!) >= _refreshEvery) {
        refreshSession(force: true);
      }
    });
  }

  String? _errorFrom(String body) {
    try {
      final parsed = jsonDecode(body);
      if (parsed is Map && parsed['error'] is String) return parsed['error'];
    } catch (_) {}
    return null;
  }

  Future<void> logout() async {
    try {
      await _storage.delete(key: _tokenKey);
    } catch (_) {}
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _sessionExpired = false;
    appHttpClient.setToken(null);
    ApiService.mediaToken = null;
    _user = null;
    notifyListeners();
  }

  void _handleUnauthorized() {
    // Only the first 401 counts: after it the token is gone, and the app's
    // other in-flight requests come back 401 too.
    if (!isLoggedIn) return;
    _storage.delete(key: _tokenKey).catchError((_) {});
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _sessionExpired = true;
    appHttpClient.setToken(null);
    ApiService.mediaToken = null;
    _user = null;
    notifyListeners();
  }
}
