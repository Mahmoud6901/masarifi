import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:masarifi/data.dart';
import 'package:masarifi/models.dart';
import 'package:masarifi/screens/assistant_screen.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Observe completion while retaining the real SDK/HTTP path and its JSON isolate.
class _ObservedData extends AppData {
  _ObservedData(super.client, {super.now});
  bool finished = false;
  @override
  Future<String> askAgent(List<Map<String, String>> history) async {
    try {
      return await super.askAgent(history);
    } finally {
      finished = true;
    }
  }
}

class _Fixture {
  late final SupabaseClient client;
  late final _ObservedData data;
  final calls = <Map<String, dynamic>>[];
  Completer<void>? gate;
  bool fail = false;
  DateTime now = DateTime(2026, 11, 15, 12);
  String reply =
      '1. Cafe — rating 4.5 (123 reviews)\nPrice: Moderate (estimate)\nDistance: 1.25 km from approximate Riyadh area centre\nOpen now: unknown\n2. Bakery — rating unknown\nPrice: unknown; distance unknown\nPreferred: Cafe, based on the available rating evidence.';
  static Future<_Fixture> create() async {
    final f = _Fixture();
    String encode(Object v) =>
        base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final token =
        '${encode({'alg': 'none'})}.${encode({'sub': 'user-a', 'exp': now + 3600, 'iat': now})}.c2ln';
    f.client = SupabaseClient(
      'https://example.supabase.co',
      'test-key',
      httpClient: MockClient((r) async {
        http.Response json(Object v, [int status = 200]) => http.Response(
          jsonEncode(v),
          status,
          request: r,
          headers: {'content-type': 'application/json'},
        );
        if (r.url.path.endsWith('/user')) {
          final payload = r.headers['authorization']!
              .split(' ')
              .last
              .split('.')[1];
          final owner = (jsonDecode(
            utf8.decode(base64Url.decode(base64Url.normalize(payload))),
          ) as Map)['sub'];
          return json({
            'id': owner,
            'email': 'test@example.com',
            'aud': 'authenticated',
            'app_metadata': {},
            'user_metadata': {},
            'created_at': '2026-01-01T00:00:00Z',
          });
        }
        if (r.url.path.endsWith('/functions/v1/agent')) {
          f.calls.add(jsonDecode(r.body) as Map<String, dynamic>);
          await f.gate?.future;
          return f.fail
              ? json({'error': 'places_unavailable'}, 503)
              : json({'reply': f.reply});
        }
        throw StateError('Unexpected request ${r.url}');
      }),
    );
    await f.client.auth.setSession('refresh-a', accessToken: token);
    f.data = _ObservedData(f.client, now: () => f.now)
      ..profile = Profile(
        currency: 'KWD',
        monthlyIncome: 5000,
        ingestToken: 'test',
      );
    return f;
  }

  Future<void> dispose() async {
    data.dispose();
    await client.dispose();
  }
}

Future<void> _mount(WidgetTester t, _Fixture f) => t.pumpWidget(
  ChangeNotifierProvider<AppData>.value(
    value: f.data,
    child: const MaterialApp(home: Scaffold(body: AssistantScreen())),
  ),
);
Future<void> _open(WidgetTester t) async {
  await t.tap(find.text('Find a place'));
  await t.pumpAndSettle();
}

Future<void> _fill(WidgetTester t, {String budget = '1.255'}) async {
  await t.enterText(
    find.widgetWithText(TextField, 'What do you need?'),
    'قهوة للعائلة',
  );
  await t.enterText(
    find.widgetWithText(TextField, 'City / area'),
    'Riyadh, Olaya, Saudi Arabia',
  );
  await t.enterText(
    find.widgetWithText(TextField, 'Budget (KWD, optional)'),
    budget,
  );
  await t.ensureVisible(find.text('Find and compare'));
  await t.pumpAndSettle();
}

Future<void> _finish(WidgetTester t, _Fixture f) async {
  await t.pumpWidget(const SizedBox());
  await t.runAsync(f.dispose);
  expect(t.takeException(), isNull);
}

// Real isolate messages need an event-loop turn between fake-clock frames.
Future<void> _until(WidgetTester t, bool Function() ready) async {
  for (var i = 0; i < 500 && !ready(); i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await t.pump();
  }
  expect(ready(), isTrue);
}

void main() {
  test('AppData bounds wire history before sending and retains the caller-owned history', () async {
    final f = await _Fixture.create();
    try {
      final history = List.generate(
        45,
        (i) => {
          'role': i.isEven ? 'user' : 'assistant',
          'content': '$i ${'x' * 5000}',
        },
      );
      final before = jsonEncode(history);
      await f.data.askAgent(history);
      final sent = f.calls.single['messages'] as List;
      expect(sent, hasLength(20));
      expect((sent.first as Map)['content'], startsWith('25 '));
      expect(
        sent.every((m) => (m['content'] as String).length <= 4000),
        isTrue,
      );
      expect(jsonEncode(history), before);
    } finally {
      await f.dispose();
    }
  });
  testWidgets(
    'failed follow-up and Retry preserve successful history without local error prose',
    (t) async {
      final f = (await t.runAsync(_Fixture.create))!;
      f.reply = 'Income 5000.000 KWD.';
      await _mount(t, f);
      await t.enterText(find.byType(TextField), 'Income?');
      await t.tap(find.byIcon(Icons.send));
      await t.pump();
      await _until(t, () => f.data.finished);
      await t.pumpAndSettle();
      f.fail = true;
      f.data.finished = false;
      await t.enterText(find.byType(TextField), 'Simulate a purchase');
      await t.tap(find.byIcon(Icons.send));
      await t.pump();
      await _until(t, () => f.data.finished);
      await t.pumpAndSettle();
      f.fail = false;
      f.data.finished = false;
      final retry = t
          .widget<TextButton>(find.widgetWithText(TextButton, 'Retry'))
          .onPressed!;
      retry();
      retry();
      await t.pump();
      await _until(t, () => f.data.finished);
      await t.pumpAndSettle();
      expect(f.calls, hasLength(3));
      expect(f.calls.last['messages'], [
        {'role': 'user', 'content': 'Income?'},
        {'role': 'assistant', 'content': 'Income 5000.000 KWD.'},
        {'role': 'user', 'content': 'Simulate a purchase'},
      ]);
      await _finish(t, f);
    },
  );
  testWidgets(
    'an account change rejects a late assistant result and prevents retry under the old owner',
    (t) async {
      final f = (await t.runAsync(_Fixture.create))!;
      f.gate = Completer<void>();
      await _mount(t, f);
      await t.enterText(find.byType(TextField), 'Budget?');
      await t.tap(find.byIcon(Icons.send));
      await t.pump();
      await _until(t, () => f.calls.length == 1);
      String encode(Object value) =>
          base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
      final seconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final token =
          '${encode({'alg': 'none'})}.${encode({'sub': 'user-b', 'iat': seconds, 'exp': seconds + 3600})}.c2ln';
      await t.runAsync(
        () => f.client.auth.setSession('refresh-b', accessToken: token),
      );
      f.gate!.complete();
      await _until(t, () => f.data.finished);
      await t.pumpAndSettle();
      expect(find.text(f.reply), findsNothing);
      expect(f.data.profile, isNull);
      f.data.finished = false;
      await t.tap(find.text('Retry'));
      await t.pump();
      await _until(t, () => f.data.finished);
      await t.pumpAndSettle();
      expect(f.calls, hasLength(1));
      await _finish(t, f);
    },
  );
  testWidgets(
    'Retry keeps one user request, excludes local errors and captures a fresh calendar',
    (t) async {
      final f = (await t.runAsync(_Fixture.create))!;
      f.fail = true;
      await _mount(t, f);
      await t.enterText(find.byType(TextField), 'Plan my month');
      await t.tap(find.byIcon(Icons.send));
      await t.pump();
      await _until(t, () => f.data.finished);
      await t.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);
      expect(f.calls.single['messages'], [
        {'role': 'user', 'content': 'Plan my month'},
      ]);
      expect(f.calls.single['calendar'], {
        'asOf': f.now.toUtc().toIso8601String(),
        'monthStart': DateTime(
          f.now.year,
          f.now.month,
        ).toUtc().toIso8601String(),
        'year': 2026,
        'month': 11,
      });
      f.now = DateTime(2026, 12, 1, 0, 1);
      f.fail = false;
      f.data.finished = false;
      f.gate = Completer<void>();
      await t.tap(find.text('Retry'));
      await t.pump();
      await _until(t, () => f.calls.length == 2);
      expect(f.calls.last['messages'], f.calls.first['messages']);
      expect(f.calls.last['calendar'], {
        'asOf': f.now.toUtc().toIso8601String(),
        'monthStart': DateTime(2026, 12).toUtc().toIso8601String(),
        'year': 2026,
        'month': 12,
      });
      expect(
        t
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send))
            .onPressed,
        isNull,
      );
      f.gate!.complete();
      await _until(t, () => f.data.finished);
      await t.pumpAndSettle();
      expect(find.text('Retry'), findsNothing);
      expect(find.text(f.reply), findsOneWidget);
      await _finish(t, f);
    },
  );
  testWidgets(
    'installment prompt uses loaded currency and cannot guess before profile load',
    (t) async {
      final f = (await t.runAsync(_Fixture.create))!;
      await _mount(t, f);
      await t.tap(find.text('Can I afford a new installment?'));
      await t.pump();
      expect(
        t.widget<TextField>(find.byType(TextField)).controller!.text,
        contains('KWD'),
      );
      f.data.profile = null;
      await t.pumpWidget(const SizedBox());
      await _mount(t, f);
      await t.pump();
      expect(
        t
            .widget<ActionChip>(
              find.widgetWithText(
                ActionChip,
                'Can I afford a new installment?',
              ),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('Load profile currency'), findsOneWidget);
      await _finish(t, f);
    },
  );
  testWidgets(
    'place form validates need, area and a nonempty optional currency budget',
    (t) async {
      final f = (await t.runAsync(_Fixture.create))!;
      await _mount(t, f);
      await _open(t);
      await t.runAsync(() => t.tap(find.text('Find and compare')));
      await t.pump();
      expect(
        find.text('Enter a need and city/area, up to 200 characters each.'),
        findsOneWidget,
      );
      await _fill(t, budget: '1.2555');
      await t.runAsync(() => t.tap(find.text('Find and compare')));
      await t.pump();
      expect(
        find.text('Enter a valid optional budget in KWD.'),
        findsOneWidget,
      );
      expect(f.calls, isEmpty);
      await _fill(t, budget: '١٫٢٥٥');
      await t.runAsync(() => t.tap(find.text('Find and compare')));
      await t.pump();

      await _until(t, () => f.data.finished);
      await t.pumpAndSettle();
      final content =
          ((f.calls.single['messages'] as List).last as Map)['content']
              as String;
      final fields = jsonDecode(
        content.substring(content.indexOf('{'), content.lastIndexOf('}') + 1),
      );
      expect(fields, {
        'query': 'قهوة للعائلة',
        'area': 'Riyadh, Olaya, Saudi Arabia',
        'budget': 1.255,
        'currency': 'KWD',
      });
      expect(content, contains('numbered blocks'));
      expect(content, contains('estimates'));
      await _finish(t, f);
    },
  );
  testWidgets(
    'pending place requests cannot duplicate and a failed request can be retried',
    (t) async {
      final f = (await t.runAsync(_Fixture.create))!;
      await _mount(t, f);
      await _open(t);
      await _fill(t, budget: '');
      f.gate = Completer<void>();
      f.fail = true;
      await t.runAsync(() => t.tap(find.text('Find and compare')));
      await t.pump(const Duration(milliseconds: 400));
      await t.pump();
      await _until(t, () => f.calls.isNotEmpty);
      expect(
        t
            .widget<ActionChip>(find.widgetWithText(ActionChip, 'Find a place'))
            .onPressed,
        isNull,
      );
      expect(f.calls, hasLength(1));
      f.gate!.complete();

      await _until(t, () => f.data.finished);
      await t.pumpAndSettle();
      expect(find.textContaining('assistant is unavailable'), findsOneWidget);
      f.fail = false;
      f.data.finished = false;
      await _open(t);
      await _fill(t, budget: '');
      await t.runAsync(() => t.tap(find.text('Find and compare')));
      await t.pump();

      await _until(t, () => f.data.finished);
      await t.pumpAndSettle();
      expect(f.calls, hasLength(2));
      final content =
          ((f.calls.last['messages'] as List).last as Map)['content'] as String;
      expect(content, isNot(contains('"budget"')));
      expect(find.text(f.reply), findsOneWidget);
      await _finish(t, f);
    },
  );
  testWidgets(
    'dismissing the place sheet sends nothing; a late reply after disposal is ignored',
    (t) async {
      final f = (await t.runAsync(_Fixture.create))!;
      await _mount(t, f);
      await _open(t);
      await _fill(t);
      Navigator.of(t.element(find.text('Find and compare'))).pop();
      await t.pumpAndSettle();
      expect(f.calls, isEmpty);
      await _open(t);
      await _fill(t);
      f.gate = Completer<void>();
      await t.runAsync(() => t.tap(find.text('Find and compare')));
      await t.pump();
      await _until(t, () => f.calls.isNotEmpty);
      await t.pumpWidget(const SizedBox());
      f.gate!.complete();

      await _until(t, () => f.data.finished);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await t.runAsync(f.dispose);
    },
  );
  testWidgets(
    'place entry waits for profile currency instead of labelling an unknown budget SAR',
    (t) async {
      final f = (await t.runAsync(_Fixture.create))!;
      f.data.profile = null;
      await _mount(t, f);
      await _open(t);
      expect(find.text('Reload profile'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.textContaining('Budget (SAR'), findsNothing);
      expect(f.calls, isEmpty);
      await _finish(t, f);
    },
  );
  testWidgets(
    'numbered recommendations wrap at narrow width with Arabic and missing evidence',
    (t) async {
      t.view.physicalSize = const Size(360, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final f = (await t.runAsync(_Fixture.create))!;
      f.reply = '1. مقهى العائلة\nالتقييم: 4.5 (123 مراجعة)\nالسعر: متوسط (تقديري)\nالمسافة: 1.25 كم من مركز منطقة الرياض التقريبي\n2. مخبز\nالتقييم والسعر والمسافة غير متوفرة\nالتوصية: المقهى بناء على المعلومات المتاحة.';
      await _mount(t, f);
      await _open(t);
      await _fill(t);
      await t.runAsync(() => t.tap(find.text('Find and compare')));
      await t.pump();

      await _until(t, () => f.data.finished);
      await t.pumpAndSettle();
      expect(find.text(f.reply), findsOneWidget);
      expect(t.takeException(), isNull);
      await _finish(t, f);
    },
  );
}
