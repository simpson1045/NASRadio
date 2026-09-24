import 'dart:async';
import 'dart:convert';

import 'api_service.dart';
import 'auth_http_client.dart';

/// One setting as the backend describes it (see backend/app/settings.py):
/// what to show, what it is now, and where the value comes from.
class AdminSetting {
  final String key;
  final String group;
  final String label;
  final String help;
  final String type; // str | url | path | int | bool
  final bool secret;
  final bool internal;
  final String source; // db | env | default
  final dynamic value;
  final bool isSet;

  const AdminSetting({
    required this.key,
    required this.group,
    required this.label,
    required this.help,
    required this.type,
    required this.secret,
    required this.internal,
    required this.source,
    required this.value,
    required this.isSet,
  });

  factory AdminSetting.fromJson(Map<String, dynamic> j) => AdminSetting(
        key: j['key'] as String,
        group: (j['group'] ?? '') as String,
        label: (j['label'] ?? j['key']) as String,
        help: (j['help'] ?? '') as String,
        type: (j['type'] ?? 'str') as String,
        secret: j['secret'] == true,
        internal: j['internal'] == true,
        source: (j['source'] ?? 'default') as String,
        value: j['value'],
        isSet: j['is_set'] == true,
      );

  String get valueText => value == null ? '' : value.toString();
}

/// Result of a connection test: `ok`, a one-line message, and details.
class ServiceTestResult {
  final bool ok;
  final String message;
  final Map<String, dynamic> details;
  const ServiceTestResult(this.ok, this.message, this.details);

  String? get hint => details['hint'] as String?;
}

/// Admin-only settings API (backend/app/admin_settings.py). Every call
/// throws on transport failure or a non-2xx answer with the server's message.
class AdminSettingsService {
  AdminSettingsService._();
  static final AdminSettingsService instance = AdminSettingsService._();

  String get _base => '${ApiService.baseUrl}/admin';

  Never _fail(String what, int status, String body) {
    String msg = '$what failed ($status)';
    try {
      final parsed = jsonDecode(body);
      if (parsed is Map && parsed['error'] is String) msg = parsed['error'];
    } catch (_) {}
    throw Exception(msg);
  }

  Future<List<AdminSetting>> getSettings() async {
    final resp = await appHttpClient
        .get(Uri.parse('$_base/settings'))
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) _fail('Loading settings', resp.statusCode, resp.body);
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return (data['settings'] as List)
        .map((e) => AdminSetting.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// Save {KEY: value}. null resets a key to its env/default value; a secret
  /// sent as '' is ignored by the server (never wipes a stored key).
  Future<List<AdminSetting>> saveSettings(Map<String, dynamic> values) async {
    final resp = await appHttpClient
        .put(Uri.parse('$_base/settings'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(values))
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) _fail('Saving settings', resp.statusCode, resp.body);
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return (data['settings'] as List)
        .map((e) => AdminSetting.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// Try to reach [service] with the saved values, or with the unsaved
  /// [overrides] ({url, api_key, user, password, path, host, ...}).
  Future<ServiceTestResult> testService(String service,
      {Map<String, dynamic>? overrides}) async {
    try {
      final resp = await appHttpClient
          .post(Uri.parse('$_base/settings/test/$service'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(overrides ?? const {}))
          .timeout(const Duration(seconds: 20));
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (resp.statusCode != 200) {
        return ServiceTestResult(false, (data['error'] ?? 'Test failed').toString(), const {});
      }
      return ServiceTestResult(
        data['ok'] == true,
        (data['message'] ?? '').toString(),
        Map<String, dynamic>.from(data['details'] ?? const {}),
      );
    } on TimeoutException {
      return const ServiceTestResult(false, 'The server took too long to answer', {});
    } catch (e) {
      return ServiceTestResult(false, 'Could not reach the server: $e', const {});
    }
  }

  /// Configured/reachable summary plus library song count and whether the
  /// first-run wizard has been completed on this server.
  Future<Map<String, dynamic>> getServices() async {
    final resp = await appHttpClient
        .get(Uri.parse('$_base/services'))
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) _fail('Loading services', resp.statusCode, resp.body);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<void> markSetupCompleted() => saveSettings({'SETUP_COMPLETED': true});

  /// Kick off a full library scan (admin). Returns the operation id.
  Future<String?> startLibraryScan() async {
    final resp = await appHttpClient
        .post(Uri.parse('${ApiService.baseUrl}/rescan'))
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) _fail('Starting the scan', resp.statusCode, resp.body);
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return data['operation_id'] as String?;
  }
}
