import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:masarifi/data.dart';
import 'package:masarifi/logic.dart';
import 'package:masarifi/screens/expenses_screen.dart';
import 'package:masarifi/screens/settings_screen.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _url = 'https://example.supabase.co';
const _oldToken = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _newToken = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

String _jwt(String id) {
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return '${encode({'alg': 'none'})}.${encode({'sub': id, 'iat': now, 'exp': now + 3600})}.c2ln';
}

Map<String, dynamic> _expense({
  String id = 'expense-1',
  String merchant = 'Cafe',
}) => {
  'id': id,
  'user_id': 'user-a',
  'amount': 12.5,
  'currency': 'SAR',
  'merchant': merchant,
  'category': 'other',
  'source': 'manual',
  'spent_at': '2026-11-01T12:00:00Z',
};

/// Exercises the real SDK and AppData against a local HTTP transport only.
class _Fixture {
  late final SupabaseClient client;
  late final AppData data;
  final requests = <http.Request>[];
  final rows = <Map<String, dynamic>>[];
  String token = _oldToken;
  bool failReads = false;
  bool failWrite = false;
  bool failDelete = false;
  bool failRotation = false;
  Completer<void>? writeGate;
  Completer<void>? deleteGate;
  Completer<void>? rotationGate;
  Completer<void>? profileGate;

  static Future<_Fixture> create({DateTime Function()? now}) async {
    final f = _Fixture();
    f.client = SupabaseClient(
      _url,
      'test-key',
      httpClient: MockClient(f._respond),
    );
    await f.client.auth.setSession('refresh-a', accessToken: _jwt('user-a'));
    f.data = AppData(f.client, now: now);
    await f.data.refresh();
    return f;
  }

  int count(String method, String suffix) => requests
      .where((r) => r.method == method && r.url.path.endsWith(suffix))
      .length;

  Future<http.Response> _respond(http.Request request) async {
    requests.add(request);
    http.Response json(Object? value, [int status = 200]) => http.Response(
      jsonEncode(value),
      status,
      request: request,
      headers: {
        'content-type': 'application/json',
        if (value is List) 'content-range': '*/${value.length}',
      },
    );
    http.Response error() =>
        json({'message': 'Rejected', 'code': 'test_error'}, 400);
    final path = request.url.path;
    if (path.endsWith('/user')) {
      final raw = request.headers['authorization']!
          .split(' ')
          .last
          .split('.')[1];
      final id = (jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(raw))),
      ) as Map)['sub'];
      return json({
        'id': id,
        'email': '$id@example.com',
        'aud': 'authenticated',
        'app_metadata': {},
        'user_metadata': {},
        'created_at': '2026-01-01T00:00:00Z',
      });
    }
    if (path.endsWith('/logout')) {
      return http.Response('', 204, request: request);
    }
    if (path.endsWith('/rpc/rotate_ingest_token')) {
      await rotationGate?.future;
      if (failRotation) return error();
      token = _newToken;
      return json(token);
    }
    if (path.endsWith('/profiles')) {
      final snapshot = {
        'id': 'user-a',
        'currency': 'SAR',
        'monthly_income': 5000,
        'ingest_token': token,
      };
      await profileGate?.future;
      return failReads ? error() : json(snapshot);
    }
    if (path.endsWith('/expenses')) {
      if (request.method == 'POST') {
        await writeGate?.future;
        if (failWrite) return error();
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        final row = {..._expense(id: 'expense-${rows.length + 1}'), ...payload};
        rows.add(row);
        return json(row, 201);
      }
      if (request.method == 'DELETE') {
        await deleteGate?.future;
        if (failDelete) return error();
        final id = request.url.queryParameters['id']!.substring(3);
        rows.removeWhere((r) => r['id'] == id);
        return http.Response('', 204, request: request);
      }
      return failReads ? error() : json(rows);
    }
    if (path.endsWith('/installment_plans')) return json([]);
    fail('Unexpected request ${request.method} $path');
  }

  Future<void> dispose() async {
    data.dispose();
    await client.dispose();
  }
}

Future<void> _mount(WidgetTester tester, _Fixture f, Widget screen) =>
    tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: f.data,
        child: MaterialApp(home: Scaffold(body: screen)),
      ),
    );

Future<void> _finish(WidgetTester tester, _Fixture f) async {
  await tester.pumpWidget(const SizedBox());
  await tester.runAsync(f.dispose);
  expect(tester.takeException(), isNull);
}

Future<void> _openForm(WidgetTester tester) async {
  await tester.tap(find.text('Add'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).at(0), '  Cafe  ');
  await tester.enterText(find.byType(TextField).at(1), '١٢٫٥٠');
}

Future<void> _show(WidgetTester tester, Finder finder) async {
  ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first))
      .clearSnackBars();
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    finder,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

void main() {
  test('localized amount parsing preserves intended values and rejects malformed separators', () {
    for (final raw in ['١٬٢٥٠٫٧٥', '1,250.75']) {
      expect(parseAmountInput(raw), 1250.75);
    }
    expect(parseAmountInput('٢٥,٥'), 25.5);
    for (final raw in [
      '-5',
      'NaN',
      'Infinity',
      '1,2,3',
      '1٬2',
      'text25',
      '1e2',
    ]) {
      expect(parseAmountInput(raw), isNull, reason: raw);
    }
    expect(isValidExpenseAmount(9999999999.99), isTrue);
    expect(isValidExpenseAmount(0), isTrue);
    expect(isValidExpenseAmount(1.001), isFalse);
  });

  test(
    'manual expense validation rejects invalid writes before HTTP',
    () async {
      final f = await _Fixture.create();
      for (final amount in [
        -1.0,
        double.nan,
        double.infinity,
        1.001,
        100000000000.0,
      ]) {
        await expectLater(
          f.data.addExpense(
            amount: amount,
            merchant: 'Cafe',
            category: 'other',
          ),
          throwsArgumentError,
        );
      }
      for (final merchant in ['', ' ' * 2, 'x' * 201]) {
        await expectLater(
          f.data.addExpense(amount: 1, merchant: merchant, category: 'other'),
          throwsArgumentError,
        );
      }
      await expectLater(
        f.data.addExpense(amount: 1, merchant: 'Cafe', category: 'unknown'),
        throwsArgumentError,
      );
      expect(f.count('POST', '/expenses'), 0);
      await f.dispose();
    },
  );

  test(
    'confirmed add/delete update the cache even if reloading fails',
    () async {
      final time = DateTime.utc(2026, 11, 15, 12);
      final f = await _Fixture.create(now: () => time);
      f.failReads = true;
      await f.data.addExpense(
        amount: 12.5,
        merchant: ' Cafe ',
        category: 'food',
      );
      final request = f.requests.singleWhere(
        (r) => r.method == 'POST' && r.url.path.endsWith('/expenses'),
      );
      expect(jsonDecode(request.body), {
        'user_id': 'user-a',
        'amount': 12.5,
        'currency': 'SAR',
        'merchant': 'Cafe',
        'category': 'food',
        'source': 'manual',
        'spent_at': time.toIso8601String(),
      });
      expect(f.data.expenses.single.merchant, 'Cafe');
      expect(f.data.error, isNotNull);
      await f.data.deleteExpense(f.data.expenses.single.id);
      expect(f.data.expenses, isEmpty);
      final deletion = f.requests.singleWhere((r) => r.method == 'DELETE');
      expect(deletion.url.queryParameters['user_id'], 'eq.user-a');
      expect(f.data.error, isNotNull);
      await f.dispose();
    },
  );

  test('rotation returns the new token without a reload and invalidates older loads', () async {
    final f = await _Fixture.create();
    f.profileGate = Completer<void>();
    final older = f.data.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(await f.data.rotateIngestToken(), _newToken);
    f.profileGate!.complete();
    await older;
    expect(f.data.profile?.ingestToken, _newToken);
    expect(f.data.loading, isFalse);
    expect(f.count('POST', '/rpc/rotate_ingest_token'), 1);
    expect(f.requests.where((r) => r.method == 'PATCH'), isEmpty);
    await f.dispose();
  });

  test('failed rotation keeps the old token and repeated pending rotations are rejected', () async {
    final f = await _Fixture.create();
    f.rotationGate = Completer<void>();
    f.failRotation = true;
    final pending = f.data.rotateIngestToken();
    await expectLater(f.data.rotateIngestToken(), throwsStateError);
    final failure = expectLater(pending, throwsA(isA<PostgrestException>()));
    f.rotationGate!.complete();
    await failure;
    expect(f.data.profile?.ingestToken, _oldToken);
    expect(f.data.rotatingIngestToken, isFalse);
    expect(f.count('POST', '/rpc/rotate_ingest_token'), 1);
    await f.dispose();
  });

  for (final dispose in [false, true]) {
    test(
      'late rotation does not publish after ${dispose ? 'disposal' : 'account change'}',
      () async {
        final f = await _Fixture.create();
        final data = AppData(f.client)..profile = f.data.profile;
        f.rotationGate = Completer<void>();
        final pending = data.rotateIngestToken();
        var notifications = 0;
        data.addListener(() => notifications++);
        if (dispose) {
          data.dispose();
        } else {
          await f.client.auth.setSession(
            'refresh-b',
            accessToken: _jwt('user-b'),
          );
          await Future<void>.delayed(Duration.zero);
        }
        final before = notifications;
        final failure = expectLater(pending, throwsStateError);
        f.rotationGate!.complete();
        await failure;
        expect(notifications, before);
        expect(data.profile?.ingestToken, isNot(_newToken));
        if (!dispose) data.dispose();
        await f.dispose();
      },
    );
  }

  test('rotation rejects a missing profile and signed-out session', () async {
    final f = await _Fixture.create();
    f.data.profile = null;
    await expectLater(f.data.rotateIngestToken(), throwsStateError);
    await f.client.auth.signOut();
    await expectLater(f.data.rotateIngestToken(), throwsStateError);
    expect(f.count('POST', '/rpc/rotate_ingest_token'), 0);
    await f.dispose();
  });

  testWidgets('manual save accepts Arabic digits once while pending', (
    tester,
  ) async {
    final f = (await tester.runAsync(_Fixture.create))!;
    f.writeGate = Completer<void>();
    await _mount(tester, f, const ExpensesScreen());
    await _openForm(tester);
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Saving…'))
          .onPressed,
      isNull,
    );
    expect(f.count('POST', '/expenses'), 1);
    f.writeGate!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(f.rows.single['amount'], 12.5);
    expect(f.rows.single['merchant'], 'Cafe');
    await _finish(tester, f);
  });

  testWidgets('invalid and rejected saves remain retryable', (tester) async {
    final f = (await tester.runAsync(_Fixture.create))!;
    await _mount(tester, f, const ExpensesScreen());
    await _openForm(tester);
    await tester.enterText(find.byType(TextField).at(1), '-5');
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.textContaining('Enter a place ('), findsOneWidget);
    expect(f.count('POST', '/expenses'), 0);
    await tester.enterText(find.byType(TextField).at(1), '١٢٫٥٠');
    f.failWrite = true;
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Could not save. Try again.'), findsOneWidget);
    f.failWrite = false;
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(f.rows, hasLength(1));
    await _finish(tester, f);
  });

  testWidgets(
    'closing the sheet during a failed save causes no state-after-dispose error',
    (tester) async {
      final f = (await tester.runAsync(_Fixture.create))!;
      f.writeGate = Completer<void>();
      f.failWrite = true;
      await _mount(tester, f, const ExpensesScreen());
      await _openForm(tester);
      await tester.tap(find.text('Save'));
      await tester.pump();
      Navigator.of(tester.element(find.byType(TextField).first)).pop();
      await tester.pumpAndSettle();
      f.writeGate!.complete();
      await tester.pumpAndSettle();
      expect(f.rows, isEmpty);
      await _finish(tester, f);
    },
  );

  testWidgets(
    'delete button waits for deletion, keeps rejected rows and removes a confirmed row',
    (tester) async {
      final f = (await tester.runAsync(
        () => _Fixture.create(now: () => DateTime(2026, 11, 15, 12)),
      ))!;
      f.rows.add(_expense());
      await tester.runAsync(f.data.refresh);
      f.deleteGate = Completer<void>();
      f.failDelete = true;
      await _mount(tester, f, const ExpensesScreen());
      Future<void> deleteCafe() async {
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('expense-1')),
            matching: find.byTooltip('Delete payment'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'Delete'));
        await tester.pumpAndSettle();
      }

      // Swiping no longer deletes.
      await tester.drag(
        find.byKey(const ValueKey('expense-1')),
        const Offset(-800, 0),
      );
      await tester.pumpAndSettle();
      expect(f.count('DELETE', '/expenses'), 0);
      await deleteCafe();
      expect(find.text('Cafe'), findsOneWidget);
      f.deleteGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Cafe'), findsOneWidget);
      expect(find.text('Could not delete. Try again.'), findsOneWidget);
      f.failDelete = false;
      f.failReads = true;
      await deleteCafe();
      expect(find.text('Cafe'), findsNothing);
      expect(f.data.expenses, isEmpty);
      await _finish(tester, f);
    },
  );

  testWidgets('setup copies URL/token and confirms guarded regeneration', (
    tester,
  ) async {
    final f = (await tester.runAsync(_Fixture.create))!;
    final copied = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await _mount(tester, f, const SettingsScreen(supabaseUrl: '$_url/'));
    await _show(tester, find.byTooltip('Copy Ingest URL'));
    await tester.tap(find.byTooltip('Copy Ingest URL'));
    await tester.pump();
    await _show(tester, find.byTooltip('Copy Your token (keep private)'));
    await tester.tap(find.byTooltip('Copy Your token (keep private)'));
    await tester.pump();
    expect(copied, ['$_url/functions/v1/ingest', _oldToken]);
    await _show(tester, find.text('Regenerate token'));
    await tester.tap(find.text('Regenerate token'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('previous token will stop working'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(f.count('POST', '/rpc/rotate_ingest_token'), 0);
    await tester.tap(find.text('Regenerate token'));
    await tester.pumpAndSettle();
    f.rotationGate = Completer<void>();
    await tester.tap(find.text('Regenerate'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Regenerating…'),
          )
          .onPressed,
      isNull,
    );
    f.rotationGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text(_newToken), findsOneWidget);
    expect(f.count('POST', '/rpc/rotate_ingest_token'), 1);
    await _finish(tester, f);
  });

  testWidgets(
    'setup handles clipboard and rotation failures without discarding the token',
    (tester) async {
      final f = (await tester.runAsync(_Fixture.create))!;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          throw PlatformException(code: 'unavailable');
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await _mount(tester, f, const SettingsScreen(supabaseUrl: _url));
      await _show(tester, find.byTooltip('Copy Your token (keep private)'));
      await tester.tap(find.byTooltip('Copy Your token (keep private)'));
      await tester.pumpAndSettle();
      expect(find.text('Could not copy. Try again.'), findsOneWidget);
      await _show(tester, find.text('Regenerate token'));
      f.failRotation = true;
      await tester.tap(find.text('Regenerate token'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Regenerate'));
      await tester.pumpAndSettle();
      expect(find.text(_oldToken), findsOneWidget);
      expect(
        find.text('Could not regenerate. Reload your token before retrying.'),
        findsOneWidget,
      );
      await _finish(tester, f);
    },
  );

  testWidgets('setup handles unavailable profile and loading state', (
    tester,
  ) async {
    final f = (await tester.runAsync(_Fixture.create))!;
    f.data.profile = null;
    f.data.loading = true;
    await _mount(tester, f, const SettingsScreen());
    await _show(tester, find.text('Regenerate token'));
    expect(find.text('Loading your private token…'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Regenerate token'),
          )
          .onPressed,
      isNull,
    );
    expect(find.byTooltip('Copy Ingest URL'), findsNothing);
    f.data.loading = false;
    await _mount(tester, f, const SettingsScreen());
    await tester.pump();
    expect(
      find.text('Your private token is unavailable. Reload your profile.'),
      findsOneWidget,
    );
    await _finish(tester, f);
  });
}
