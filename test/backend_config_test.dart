import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:masarifi/backend_config.dart';
import 'package:masarifi/screens/connect_screen.dart';
import 'package:masarifi/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A Supabase-style key whose payload carries [role] (signature is fake).
String _jwt(String role) {
  String part(Object v) =>
      base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
  return '${part({'alg': 'HS256'})}.${part({'iss': 'supabase', 'role': role})}.c2ln';
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('project URLs are cleaned and only https (or local http) pass', () {
    expect(
      normalizeBackendUrl(' https://abcd1234.supabase.co/ '),
      'https://abcd1234.supabase.co',
    );
    expect(
      normalizeBackendUrl('http://localhost:54321'),
      'http://localhost:54321',
    );
    for (final bad in [
      '',
      'abcd1234.supabase.co',
      'http://abcd1234.supabase.co',
      'https://abcd1234.supabase.co/rest/v1',
      'https://abcd1234.supabase.co?x=1',
      'ftp://abcd1234.supabase.co',
    ]) {
      expect(normalizeBackendUrl(bad), isNull, reason: bad);
    }
  });

  test('only public client keys are accepted; secret keys are refused', () {
    expect(anonKeyProblem(_jwt('anon')), isNull);
    expect(anonKeyProblem('sb_publishable_abc123'), isNull);
    expect(anonKeyProblem(_jwt('service_role')), contains('service_role'));
    expect(anonKeyProblem('sb_secret_abc123'), contains('secret key'));
    expect(anonKeyProblem(''), isNotNull);
    expect(anonKeyProblem('not-a-key'), isNotNull);
  });

  test('a connected project is saved, read back and forgotten', () async {
    expect(await loadSavedBackend(), isNull);
    await saveBackend(BackendConfig('https://abcd1234.supabase.co', _jwt('anon')));
    final saved = await loadSavedBackend();
    expect(saved?.url, 'https://abcd1234.supabase.co');
    expect(saved?.anonKey, _jwt('anon'));
    await forgetBackend();
    expect(await loadSavedBackend(), isNull);
  });

  test('a saved service_role key is never used', () async {
    SharedPreferences.setMockInitialValues({
      'masarifi.backend_url': 'https://abcd1234.supabase.co',
      'masarifi.backend_anon_key': _jwt('service_role'),
    });
    expect(await loadSavedBackend(), isNull);
  });

  test('the project check calls Auth settings with the anon key', () async {
    final seen = <http.Request>[];
    final ok = MockClient((r) async {
      seen.add(r);
      return http.Response('{}', 200);
    });
    final config = BackendConfig('https://abcd1234.supabase.co', _jwt('anon'));
    expect(await backendAnswers(config, client: ok), isTrue);
    expect(
      seen.single.url.toString(),
      'https://abcd1234.supabase.co/auth/v1/settings',
    );
    expect(seen.single.headers['apikey'], _jwt('anon'));
    expect(
      await backendAnswers(
        config,
        client: MockClient((_) async => http.Response('no', 401)),
      ),
      isFalse,
    );
    expect(
      await backendAnswers(
        config,
        client: MockClient((_) async => throw http.ClientException('offline')),
      ),
      isFalse,
    );
  });

  testWidgets('Connect checks the inputs, the project, then saves it', (
    tester,
  ) async {
    var status = 401;
    BackendConfig? connected;
    await tester.pumpWidget(
      MaterialApp(
        theme: masarifiTheme(Brightness.dark),
        home: ConnectScreen(
          client: MockClient((_) async => http.Response('{}', status)),
          onConnected: (c) async => connected = c,
        ),
      ),
    );
    Finder field(String label) => find.widgetWithText(TextField, label);

    await tester.enterText(field('Project URL'), 'abcd1234.supabase.co');
    await tester.enterText(field('Anon key'), _jwt('anon'));
    await tester.tap(find.text('Connect'));
    await tester.pump();
    expect(find.textContaining('Enter your project URL'), findsOneWidget);

    await tester.enterText(
      field('Project URL'),
      'https://abcd1234.supabase.co/',
    );
    await tester.enterText(field('Anon key'), _jwt('service_role'));
    await tester.tap(find.text('Connect'));
    await tester.pump();
    expect(find.textContaining('service_role key'), findsOneWidget);

    await tester.enterText(field('Anon key'), _jwt('anon'));
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not reach this project'), findsOneWidget);
    expect(connected, isNull);
    expect(await tester.runAsync(loadSavedBackend), isNull);

    status = 200;
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(connected?.url, 'https://abcd1234.supabase.co');
    final saved = await tester.runAsync(loadSavedBackend);
    expect(saved?.url, 'https://abcd1234.supabase.co');
  });
}
