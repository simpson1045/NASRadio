import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'auth_http_client.dart';
import 'api_service.dart';

/// Owns the login state: the bearer token (in encrypted storage), the current
/// user, and the login/logout flow. A ChangeNotifier so the root widget can
/// swap between the login screen and the app when auth state changes.
class AuthService extends ChangeNotifier {
  AuthService._();
  static final AuthService instance = AuthService._();

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  static const String _tokenKey = 'nasradio_auth_token';

  Map<String, dynamic>? _user;
  bool _initialized = false;

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
    try {
      token = await _storage.read(key: _tokenKey);
    } catch (_) {
      token = null;
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
      final resp = await appHttpClient
          .get(Uri.parse('${ApiService.baseUrl}/auth/me'));
      if (resp.statusCode == 200) {
        _user = jsonDecode(resp.body)['user'] as Map<String, dynamic>;
        await _fetchMediaToken();
        await ApiService.loadClientConfig();
      }
      // A 401 here triggers _handleUnauthorized via the client, clearing token.
    } catch (_) {
      // Network error — keep the token; we'll validate on next use.
    }
  }

  /// Fetch the read-only media token used in stream/artwork URLs. Best-effort:
  /// if it fails, media just won't load until the next attempt.
  Future<void> _fetchMediaToken() async {
    try {
      final resp = await appHttpClient
          .get(Uri.parse('${ApiService.baseUrl}/auth/media-token'));
      if (resp.statusCode == 200) {
        ApiService.mediaToken = jsonDecode(resp.body)['media_token'] as String?;
      }
    } catch (_) {}
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
      await _storage.write(key: _tokenKey, value: token);
    } catch (_) {}
    appHttpClient.setToken(token);
    await _fetchMediaToken();
    await ApiService.loadClientConfig();
    notifyListeners();
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
    appHttpClient.setToken(null);
    ApiService.mediaToken = null;
    _user = null;
    notifyListeners();
  }

  void _handleUnauthorized() {
    _storage.delete(key: _tokenKey).catchError((_) {});
    appHttpClient.setToken(null);
    ApiService.mediaToken = null;
    _user = null;
    notifyListeners();
  }
}
