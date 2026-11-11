import 'package:http/http.dart' as http;
import 'app_logger.dart';

/// An http.Client that attaches the auth bearer token to every outgoing
/// request and reports session expiry. Routing all of ApiService's calls
/// through this single client means the token is injected in one place
/// instead of on 135 call sites.
class AuthHttpClient extends http.BaseClient {
  final http.Client _inner = http.Client();

  String? _token;

  /// Called when a request that *carried* a token comes back 401 — i.e. the
  /// token is expired/revoked and the user must re-login. NOT fired for 401s
  /// on requests without a token (e.g. a failed login attempt), so a bad
  /// password doesn't masquerade as a session timeout.
  void Function()? onUnauthorized;

  void setToken(String? token) => _token = token;

  String? get token => _token;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final hadToken = _token != null && _token!.isNotEmpty;
    if (hadToken) {
      request.headers['Authorization'] = 'Bearer $_token';
    }
    // Slow-request trail: an app that "sat there dead" (Oct 27) left no clue
    // which call was stuck. Time to response headers (a streamed body isn't
    // counted); the log-ship call itself is skipped to avoid a feedback loop.
    final sw = Stopwatch()..start();
    final path = request.url.path;
    final http.StreamedResponse response;
    try {
      response = await _inner.send(request);
    } catch (e) {
      if (sw.elapsedMilliseconds > 3000 && !path.endsWith('/logs/ingest')) {
        AppLogger.instance.warning(
            '🐢 [http] ${request.method} $path FAILED after ${_secs(sw)}: $e');
      }
      rethrow;
    }
    if (sw.elapsedMilliseconds > 3000 && !path.endsWith('/logs/ingest')) {
      AppLogger.instance.warning(
          '🐢 [http] ${request.method} $path -> ${response.statusCode} in ${_secs(sw)} '
          '(${request.url.host})');
    }
    if (response.statusCode == 401 && hadToken) {
      onUnauthorized?.call();
    }
    return response;
  }

  static String _secs(Stopwatch sw) =>
      '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s';

  @override
  void close() {
    _inner.close();
    super.close();
  }
}

/// App-wide singleton so both static and instance code in ApiService can route
/// through the same token-injecting client.
final AuthHttpClient appHttpClient = AuthHttpClient();
