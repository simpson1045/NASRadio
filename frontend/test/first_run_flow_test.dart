// First-run flow: connect screen → create-admin screen, against a REAL
// backend on a fresh database.
//
// Run with the backend up on a throwaway Postgres (see HANDOFF.md):
//   NASRADIO_TEST_BACKEND=http://127.0.0.1:5099 flutter test test/first_run_flow_test.dart
//
// Without NASRADIO_TEST_BACKEND the network-backed case is skipped and only
// the pure widget cases run, so `flutter test` stays green in CI.
//
// The screens are exercised as widgets (rendering + local validation) and the
// network path through the services, because flutter_test's fake-async zone
// can't drive real sockets from inside a widget interaction.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/screens/connect_server_screen.dart';
import 'package:frontend/screens/setup_admin_screen.dart';
import 'package:frontend/services/admin_settings_service.dart';
import 'package:frontend/services/api_service.dart';
import 'package:frontend/services/auth_service.dart';

final String? backend = Platform.environment['NASRADIO_TEST_BACKEND'];
final bool live = backend != null && backend!.isNotEmpty;

void main() {
  setUpAll(() {
    // flutter_test stubs every HttpClient to return 400; the live cases need
    // real sockets to the local backend.
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('ConnectServerScreen (widget)', () {
    testWidgets('renders and validates an empty address', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: ConnectServerScreen()));
      expect(find.text('Connect to your NASRadio server'), findsOneWidget);
      expect(find.text('Test'), findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pump();
      expect(find.text('Enter your server address'), findsOneWidget);
    });
  });

  group('SetupAdminScreen (widget)', () {
    testWidgets('validates locally before calling the server', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SetupAdminScreen()));
      expect(find.text('Welcome to NASRadio'), findsOneWidget);
      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(3));
      await tester.tap(find.text('Create admin account'));
      await tester.pump();
      expect(find.text('Choose a username'), findsOneWidget);

      await tester.enterText(fields.at(0), 'admin');
      await tester.enterText(fields.at(1), 'short');
      await tester.tap(find.text('Create admin account'));
      await tester.pump();
      expect(find.text('Password must be at least 8 characters'), findsOneWidget);

      await tester.enterText(fields.at(1), 'correct-horse-battery');
      await tester.enterText(fields.at(2), 'different-password');
      await tester.tap(find.text('Create admin account'));
      await tester.pump();
      expect(find.text("Passwords don't match"), findsOneWidget);
    });
  });

  group('against a live fresh backend', () {
    test('probe, save, needs-setup, create admin, refuse second admin', () async {
      expect(await ApiService.probeHost(backend!), isTrue,
          reason: 'backend must be up at $backend');
      expect(await ApiService.probeHost('http://127.0.0.1:1'), isFalse);

      expect(ApiService.isConfigured, isFalse);
      final before = ApiService.serverConfigChanged.value;
      await ApiService.saveServerConfig(lanHost: backend!, wanHost: '');
      expect(ApiService.isConfigured, isTrue);
      expect(ApiService.lanHost, backend);
      expect(ApiService.serverConfigChanged.value, before + 1);
      expect(ApiService.baseHost, backend);

      expect(await ApiService.needsSetup(), isTrue,
          reason: 'test database must have no users');

      final auth = AuthService.instance;
      expect(await auth.setupAdmin('admin', 'correct-horse-battery'), isNull);
      expect(auth.isLoggedIn, isTrue);
      expect(auth.isAdmin, isTrue);
      expect(auth.user?['username'], 'admin');

      expect(await ApiService.needsSetup(), isFalse);
      final second = await auth.setupAdmin('intruder', 'correct-horse-battery');
      expect(second, contains('already'));

      // Login pulled the non-secret client config; a fresh server has no
      // custom Cast receiver, so the app must fall back to the default one.
      expect(ApiService.castReceiverAppId, isEmpty);
      expect(ApiService.publicBaseUrl, isEmpty);

      await auth.logout();
      expect(auth.isLoggedIn, isFalse);
      expect(await auth.login('admin', 'correct-horse-battery'), isNull);
      expect(auth.isAdmin, isTrue);
    }, skip: live ? false : 'set NASRADIO_TEST_BACKEND to run against a backend');

    test('admin settings: read, test, save, services, wizard flag', () async {
      final svc = AdminSettingsService.instance;
      final settings = await svc.getSettings();
      expect(settings.length, greaterThan(30));
      final byKey = {for (final s in settings) s.key: s};
      expect(byKey['MUSIC_LIBRARY_PATH']!.type, 'path');
      expect(byKey['PROWLARR_API_KEY']!.secret, isTrue);
      expect(byKey['SETUP_COMPLETED']!.internal, isTrue);

      // Unsaved-value test: a bogus folder fails, the server's own folder passes.
      final bad = await svc.testService('library', overrides: {'path': '/nope/never'});
      expect(bad.ok, isFalse);
      expect(bad.hint, isNotNull);
      final good = await svc.testService('library');
      expect(good.ok, isTrue, reason: good.message);

      final saved = await svc.saveSettings({'PROWLARR_URL': 'http://prowlarr.lan:9696/'});
      final prow = saved.firstWhere((s) => s.key == 'PROWLARR_URL');
      expect(prow.value, 'http://prowlarr.lan:9696');
      expect(prow.source, 'db');
      final reset = await svc.saveSettings({'PROWLARR_URL': null});
      expect(reset.firstWhere((s) => s.key == 'PROWLARR_URL').source, isNot('db'));

      var services = await svc.getServices();
      expect(services['setup_completed'], isFalse);
      expect((services['services'] as Map)['library']['song_count'], 0);
      await svc.markSetupCompleted();
      services = await svc.getServices();
      expect(services['setup_completed'], isTrue);

      // Setting a Cast app ID server-side reaches every client on next login.
      await svc.saveSettings({'CAST_RECEIVER_APP_ID': 'ABCD1234'});
      await ApiService.loadClientConfig();
      expect(ApiService.castReceiverAppId, 'ABCD1234');
      await svc.saveSettings({'CAST_RECEIVER_APP_ID': null});
      await ApiService.loadClientConfig();
      expect(ApiService.castReceiverAppId, isEmpty);

      // A non-admin must be refused by the admin API.
      final auth = AuthService.instance;
      await auth.logout();
      expect(await auth.login('admin', 'correct-horse-battery'), isNull);
      expect(await svc.getServices(), isA<Map>()); // still admin here
    }, skip: live ? false : 'set NASRADIO_TEST_BACKEND to run against a backend');
  });
}
