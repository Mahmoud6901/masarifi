import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:masarifi/data.dart';
import 'package:masarifi/format.dart';
import 'package:masarifi/models.dart';
import 'package:masarifi/screens/installments_screen.dart';
import 'package:masarifi/screens/expenses_screen.dart';
import 'package:masarifi/screens/settings_screen.dart';
import 'package:masarifi/screens/home_screen.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _url = 'https://example.supabase.co';
const _token = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
final _now = DateTime(2026, 11, 15, 12);
String _jwt(String id) {
  String encode(Object v) =>
      base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return '${encode({'alg': 'none'})}.${encode({'sub': id, 'iat': now, 'exp': now + 3600})}.c2ln';
}

Map<String, dynamic> _plan({
  String id = 'p',
  String currency = 'SAR',
  String? date = '2026-11-30',
  int paid = 0,
  int total = 3,
  double amount = 50,
  bool active = true,
}) => {
  'id': id,
  'user_id': 'user-a',
  'name': 'Phone $id',
  'provider': 'Bank',
  'kind': 'loan',
  'monthly_amount': amount,
  'total_amount': amount * total,
  'currency': currency,
  'total_count': total,
  'paid_count': paid,
  'due_day': 31,
  'active': active,
  'next_due_date': date,
  'created_at': '2026-01-01T00:00:00Z',
};
Map<String, dynamic> _expense({
  String id = 'e',
  String currency = 'SAR',
  double amount = 1,
  DateTime? date,
}) => {
  'id': id,
  'user_id': 'user-a',
  'amount': amount,
  'currency': currency,
  'merchant': 'Cafe',
  'category': 'other',
  'source': 'manual',
  'spent_at': (date ?? _now).toUtc().toIso8601String(),
};

// The real Supabase SDK uses a local transport; this is not live SQL evidence.
class _Fixture {
  late final SupabaseClient client;
  late final AppData data;
  final requests = <http.Request>[];
  final plans = <Map<String, dynamic>>[];
  final expenses = <Map<String, dynamic>>[];
  Map<String, dynamic> profile = {
    'id': 'user-a',
    'currency': 'SAR',
    'monthly_income': 5000,
    'ingest_token': _token,
  };
  int pageCap = 100;
  int? failExpenseOffset;
  bool failReads = false;
  bool failWrites = false;
  bool failAfterWrite = false;
  bool disposedData = false;
  DateTime serverNow = _now;
  DateTime clientNow = _now;
  Completer<void>? profileGate;
  Completer<void>? gate;
  Map<String, dynamic>? rpcResponse;
  static Future<_Fixture> create({bool refresh = true}) async {
    final f = _Fixture();
    f.client = SupabaseClient(
      _url,
      'test-key',
      httpClient: MockClient(f.respond),
    );
    await f.client.auth.setSession('refresh-a', accessToken: _jwt('user-a'));
    f.data = AppData(f.client, now: () => f.clientNow);
    if (refresh) await f.data.refresh();
    return f;
  }

  http.Response json(
    http.Request r,
    Object? body, {
    int status = 200,
    int? count,
  }) => http.Response(
    jsonEncode(body),
    status,
    request: r,
    headers: {
      'content-type': 'application/json',
      if (count != null) 'content-range': '*/$count',
    },
  );
  http.Response error(http.Request r) =>
      json(r, {'message': 'Rejected', 'code': 'test'}, status: 400);
  List<http.Request> calls(String method, String suffix) => requests
      .where((r) => r.method == method && r.url.path.endsWith(suffix))
      .toList();
  Future<http.Response> respond(http.Request r) async {
    requests.add(r);
    final path = r.url.path;
    final q = r.url.queryParameters;
    if (path.endsWith('/user')) {
      final token = r.headers['authorization']!.split(' ').last.split('.')[1];
      final id = (jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(token))),
      ) as Map)['sub'];
      return json(r, {
        'id': id,
        'email': '$id@example.com',
        'aud': 'authenticated',
        'app_metadata': {},
        'user_metadata': {},
        'created_at': '2026-01-01T00:00:00Z',
      });
    }
    if (path.endsWith('/logout')) return http.Response('', 204, request: r);
    if (path.endsWith('/profiles')) {
      if (r.method == 'PATCH') {
        await gate?.future;
        if (failWrites) return error(r);
        profile.addAll(jsonDecode(r.body) as Map<String, dynamic>);
        failReads = failAfterWrite;
        return http.Response('', 204, request: r);
      }
      await profileGate?.future;
      return failReads ? error(r) : json(r, profile);
    }
    if (path.endsWith('/rpc/mark_installment_paid')) {
      await gate?.future;
      if (failWrites) return error(r);
      final response = rpcResponse!;
      final row = response['plan'] as Map<String, dynamic>;
      final index = plans.indexWhere((p) => p['id'] == row['id']);
      if (index >= 0) plans[index] = {...row};
      failReads = failAfterWrite;
      return json(r, response);
    }
    if (path.endsWith('/installment_plans') || path.endsWith('/expenses')) {
      final isPlan = path.endsWith('/installment_plans');
      final rows = isPlan ? plans : expenses;
      if (r.method == 'POST') {
        await gate?.future;
        if (failWrites) return error(r);
        final payload = jsonDecode(r.body) as Map<String, dynamic>;
        final id = 'new-${rows.length}';
        final row = {
          ...(isPlan ? _plan(id: id) : _expense(id: id, date: serverNow)),
          ...payload,
        };
        rows.add(row);
        failReads = failAfterWrite;
        return json(r, row, status: 201);
      }
      if (r.method == 'DELETE') {
        await gate?.future;
        if (failWrites) return error(r);
        rows.removeWhere((p) => 'eq.${p['id']}' == q['id']);
        failReads = failAfterWrite;
        return http.Response('', 204, request: r);
      }
      if (r.method == 'PATCH') {
        await gate?.future;
        if (failWrites) return error(r);
        final index = rows.indexWhere((p) => 'eq.${p['id']}' == q['id']);
        final row = {
          ...rows[index],
          ...jsonDecode(r.body) as Map<String, dynamic>,
        };
        rows[index] = row;
        failReads = failAfterWrite;
        return json(r, row);
      }
      if (failReads) return error(r);
      var filtered = rows
          .where((p) => 'eq.${p['user_id']}' == q['user_id'])
          .toList();
      if (q['currency'] != null) {
        filtered = filtered
            .where((p) => 'eq.${p['currency']}' == q['currency'])
            .toList();
      }
      if (q['spent_at'] != null) {
        final bounds = r.url.queryParametersAll['spent_at']!;
        final lower = DateTime.parse(
          bounds.firstWhere((s) => s.startsWith('gte.')).substring(4),
        );
        final upper = DateTime.parse(
          bounds.firstWhere((s) => s.startsWith('lte.')).substring(4),
        );
        filtered = filtered.where((p) {
          final d = DateTime.parse(p['spent_at'] as String);
          return !d.isBefore(lower) && !d.isAfter(upper);
        }).toList();
      }
      final offset = int.tryParse(q['offset'] ?? '') ?? 0;
      if (!isPlan && q['currency'] != null && offset == failExpenseOffset) {
        return error(r);
      }
      final limit = math.min(
        int.tryParse(q['limit'] ?? '') ?? pageCap,
        pageCap,
      );
      return json(
        r,
        filtered.skip(offset).take(limit).toList(),
        count: filtered.length,
      );
    }
    throw StateError('Unexpected request ${r.method} ${r.url}');
  }

  Future<void> dispose() async {
    if (!disposedData) data.dispose();
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

Future<void> _show(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    220,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.widgetWithText(TextField, label);

void main() {
  for (final loading in [true, false]) {
    test(
      'new writes require the owner profile during ${loading ? 'loading' : 'a failed first load'}',
      () async {
        final f = await _Fixture.create(refresh: false);
        addTearDown(f.dispose);
        f.profile['currency'] = 'KWD';
        f.profileGate = loading ? Completer<void>() : null;
        f.failReads = !loading;
        final pending = f.data.refresh();
        if (!loading) await pending;
        expect(f.data.profile, isNull);
        await expectLater(
          f.data.addExpense(amount: 1.25, merchant: 'Shop', category: 'other'),
          throwsStateError,
        );
        await expectLater(
          f.data.addPlan(
            name: 'Phone',
            provider: '',
            kind: 'card',
            monthlyAmount: 1.25,
            totalCount: 3,
            paidCount: 0,
            dueDay: 31,
            nextPaymentMonth: DateTime(2026, 11),
          ),
          throwsStateError,
        );
        expect(f.requests.where((r) => r.method == 'POST'), isEmpty);
        f.failReads = false;
        if (loading) {
          f.profileGate!.complete();
          await pending;
        } else {
          await f.data.refresh();
        }
        await f.data.addExpense(
          amount: 1.255,
          merchant: 'Shop',
          category: 'other',
        );
        await f.data.addPlan(
          name: 'Phone',
          provider: '',
          kind: 'card',
          monthlyAmount: 1.255,
          totalCount: 3,
          paidCount: 0,
          dueDay: 31,
          nextPaymentMonth: DateTime(2026, 11),
        );
        expect(f.expenses.single['currency'], 'KWD');
        expect(f.plans.single['currency'], 'KWD');
        expect(f.data.budget.spent, 1.255);
        expect(f.data.budget.installmentsDue, 1.255);
      },
    );

    for (final planForm in [false, true]) {
      testWidgets(
        '${planForm ? 'plan' : 'expense'} sheet offers profile retry during ${loading ? 'loading' : 'a failed first load'}',
        (tester) async {
          final f = (await tester.runAsync(
            () => _Fixture.create(refresh: false),
          ))!;
          f.profile['currency'] = 'KWD';
          f.profileGate = loading ? Completer<void>() : null;
          f.failReads = !loading;
          final pending = f.data.refresh();
          if (!loading) await tester.runAsync(() => pending);
          await _mount(
            tester,
            f,
            planForm ? const InstallmentsScreen() : const ExpensesScreen(),
          );
          await tester.tap(find.text(planForm ? 'Add plan' : 'Add'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.byType(TextField), findsNothing);
          expect(find.textContaining('SAR'), findsNothing);
          if (loading) {
            expect(
              find.text('Loading your profile and currency…'),
              findsOneWidget,
            );
            expect(
              tester
                  .widget<TextButton>(
                    find.widgetWithText(TextButton, 'Reload profile'),
                  )
                  .onPressed,
              isNull,
            );
          } else {
            expect(
              find.text(
                'Load your profile and currency before adding a payment or plan.',
              ),
              findsOneWidget,
            );
            final reads = f.calls('GET', '/profiles').length;
            await tester.tap(find.text('Reload profile'));
            await tester.pumpAndSettle();
            expect(f.calls('GET', '/profiles').length, reads + 1);
            expect(
              find.text('Could not load your profile. Try again.'),
              findsOneWidget,
            );
          }
          f.failReads = false;
          if (loading) {
            f.profileGate!.complete();
            await tester.runAsync(() => pending);
          } else {
            await tester.tap(find.text('Reload profile'));
          }
          await tester.pumpAndSettle();
          expect(f.data.currency, 'KWD');
          expect(find.byType(TextField), findsWidgets);
          expect(find.text('Reload profile'), findsNothing);
          if (planForm) {
            expect(find.text('Add installment plan (KWD)'), findsOneWidget);
          }
          expect(f.requests.where((r) => r.method == 'POST'), isEmpty);
          await _finish(tester, f);
        },
      );
    }
  }

  for (final skew in [
    Duration.zero,
    const Duration(milliseconds: 300),
    const Duration(seconds: 2),
    const Duration(seconds: 30),
  ]) {
    test(
      'manual expenses stay in the current budget with server clock ahead by $skew',
      () async {
        final f = await _Fixture.create(refresh: false);
        addTearDown(f.dispose);
        // A server ahead by 300ms or more has already crossed into next month.
        f.clientNow = DateTime(2026, 11, 30, 23, 59, 59, 900);
        f.serverNow = f.clientNow.add(skew);
        await f.data.refresh();
        await f.data.addExpense(
          amount: 10,
          merchant: 'Shop',
          category: 'other',
        );
        final payload =
            jsonDecode(f.calls('POST', '/expenses').single.body) as Map;
        expect(
          DateTime.parse(payload['spent_at'] as String),
          f.clientNow.toUtc(),
        );
        expect(f.data.expenses.single.spentAt, f.clientNow);
        expect(f.data.budget.spent, 10);
        expect(f.data.budget.safeToSpend, 4990);
        expect(f.data.budgetAsOf, f.clientNow);
        expect(f.data.budgetStale, isFalse);
        expect(f.data.error, isNull);
      },
    );
  }

  test('new plan requests guard duplicates and signed-out plan writes stop before HTTP', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    Future<void> add() => f.data.addPlan(
      name: 'Phone',
      provider: '',
      kind: 'card',
      monthlyAmount: 50,
      totalCount: 3,
      paidCount: 0,
      dueDay: 31,
      nextPaymentMonth: DateTime(2026, 12),
    );
    f.gate = Completer<void>();
    final pending = add();
    await expectLater(add(), throwsStateError);
    f.gate!.complete();
    await pending;
    expect(f.calls('POST', '/installment_plans'), hasLength(1));
    final plan = f.data.plans.single;
    await f.client.auth.signOut();
    final count = f.requests.length;
    await expectLater(add(), throwsStateError);
    await expectLater(f.data.markPlanPaid(plan), throwsStateError);
    await expectLater(
      f.data.setPlanSchedule(plan, dueDay: 1, month: DateTime(2026, 12)),
      throwsStateError,
    );
    await expectLater(f.data.deletePlan(plan.id), throwsStateError);
    expect(f.requests.length, count);
  });

  testWidgets(
    'manual expense and income accept fils and a rejected currency change resets the form',
    (tester) async {
      final f = (await tester.runAsync(_Fixture.create))!;
      f.profile['currency'] = 'KWD';
      await tester.runAsync(f.data.refresh);
      await _mount(tester, f, const ExpensesScreen());
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('Place'), 'Shop');
      await tester.enterText(_field('Amount'), '١٫٢٥٥');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(f.expenses.single['amount'], 1.255);
      expect(f.expenses.single['currency'], 'KWD');
      expect(find.text(money(1.255, 'KWD')), findsOneWidget);
      await _mount(tester, f, const SettingsScreen());
      await tester.tap(find.text('Monthly income'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '12.345');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(f.data.profile?.monthlyIncome, 12.345);
      expect(find.text(money(12.345, 'KWD')), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SAR').last);
      await tester.pumpAndSettle();
      expect(f.data.currency, 'KWD');
      expect(find.textContaining('Could not change currency.'), findsOneWidget);
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byType(DropdownButtonFormField<String>),
            )
            .initialValue,
        'KWD',
      );
      await _finish(tester, f);
    },
  );

  test(
    'budget reads every page beyond 1000 rows and a smaller server cap',
    () async {
      final f = await _Fixture.create(refresh: false);
      addTearDown(f.dispose);
      f.plans.addAll(List.generate(1005, (i) => _plan(id: 'p$i', amount: 1)));
      f.expenses.addAll(List.generate(1101, (i) => _expense(id: 'e$i')));
      f.expenses.addAll([
        _expense(id: 'foreign', currency: 'KWD', amount: 900),
        _expense(
          id: 'future',
          amount: 900,
          date: _now.add(const Duration(days: 1)),
        ),
        _expense(id: 'old', amount: 900, date: DateTime(2026, 10, 31)),
        _expense(id: 'boundary', amount: 2, date: DateTime(2026, 11, 1)),
        {..._expense(id: 'other'), 'user_id': 'user-b'},
      ]);
      await f.data.refresh();
      expect(f.data.error, isNull);
      expect(f.data.plans, hasLength(1005));
      expect(f.data.expenses, hasLength(100));
      expect(f.data.budget.spent, 1103);
      expect(f.data.budget.installmentsDue, 1005);
      expect(f.data.budget.safeToSpend, 2892);
      expect(f.data.budgetStale, isFalse);
      expect(
        f
            .calls('GET', '/expenses')
            .where((r) => r.url.queryParameters['currency'] != null)
            .length,
        12,
      );
      for (final r in f.calls('GET', '/installment_plans')) {
        expect(
          r.url.queryParameters['order'],
          'created_at.desc.nullslast,id.desc.nullslast',
        );
        expect(r.headers['prefer'], contains('count=exact'));
      }
    },
  );

  test(
    'a failed later page keeps the last complete profile and budget snapshot',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.dispose);
      final date = f.data.budgetAsOf;
      f.profile['currency'] = 'KWD';
      f.profile['monthly_income'] = 6000;
      f.expenses.addAll(
        List.generate(101, (i) => _expense(id: 'e$i', currency: 'KWD')),
      );
      f.failExpenseOffset = 100;
      await f.data.refresh();
      expect(f.data.currency, 'SAR');
      expect(f.data.budget.currency, 'SAR');
      expect(f.data.budget.income, 5000);
      expect(f.data.budgetAsOf, date);
      expect(f.data.budgetStale, isTrue);
      expect(f.data.error, isNotNull);
      f.failExpenseOffset = null;
      await f.data.refresh();
      expect(f.data.currency, 'KWD');
      expect(f.data.budget.spent, 101);
      expect(f.data.budgetStale, isFalse);
    },
  );

  test('CAS uses displayed state and caches stale/final responses without creating expenses', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    f.plans.add(_plan(date: '2026-10-31'));
    await f.data.refresh();
    final original = f.data.plans.single;
    final initial = f.data.budget.safeToSpend;
    f.rpcResponse = {'applied': true, 'plan': _plan(paid: 1)};
    f.expenses.add(_expense(amount: 50));
    expect(await f.data.markPlanPaid(original), isTrue);
    expect(f.data.budget.safeToSpend, initial);
    final call = f.calls('POST', '/rpc/mark_installment_paid').single;
    expect(jsonDecode(call.body), {
      'p_plan_id': 'p',
      'p_expected_paid_count': 0,
      'p_expected_next_due_date': '2026-10-31',
    });
    expect(f.calls('POST', '/expenses'), isEmpty);
    f.rpcResponse = {'applied': false, 'plan': _plan(paid: 1)};
    expect(await f.data.markPlanPaid(original), isFalse);
    expect(f.data.plans.single.paidCount, 1);
    f.rpcResponse = {
      'applied': true,
      'plan': _plan(paid: 3, date: null, active: false),
    };
    f.failAfterWrite = true;
    expect(await f.data.markPlanPaid(f.data.plans.single), isTrue);
    expect(f.data.plans.single.active, isFalse);
    expect(f.data.plans.single.nextDueDate, isNull);
    expect(f.data.plans.single.remainingBalance, 0);
    expect(f.data.budgetStale, isTrue);
    expect(await f.data.markPlanPaid(f.data.plans.single), isFalse);
    expect(f.calls('POST', '/rpc/mark_installment_paid'), hasLength(3));
  });

  test('final remaining payment sends the displayed CAS fields and caches completion', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    f.plans.add(_plan(id: 'last', date: '2026-11-30', total: 1, amount: 75));
    await f.data.refresh();
    final displayed = f.data.plans.single;
    f.rpcResponse = {
      'applied': true,
      'plan': _plan(
        id: 'last',
        date: null,
        total: 1,
        paid: 1,
        active: false,
        amount: 75,
      ),
    };

    expect(await f.data.markPlanPaid(displayed), isTrue);
    expect(f.data.plans.single.paidCount, 1);
    expect(f.data.plans.single.remainingCount, 0);
    expect(f.data.plans.single.remainingBalance, 0);
    expect(f.data.plans.single.active, isFalse);
    expect(
      jsonDecode(f.calls('POST', '/rpc/mark_installment_paid').single.body),
      {
        'p_plan_id': 'last',
        'p_expected_paid_count': 0,
        'p_expected_next_due_date': '2026-11-30',
      },
    );
    expect(f.calls('POST', '/expenses'), isEmpty);
  });

  test(
    'inactive, completed and unscheduled plans do not call the payment RPC',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.dispose);
      f.plans.addAll([
        _plan(id: 'inactive', active: false),
        _plan(id: 'completed', total: 2, paid: 2, active: false, date: null),
        _plan(id: 'legacy', date: null),
      ]);
      await f.data.refresh();
      final inactive = f.data.plans.singleWhere((p) => p.id == 'inactive');
      final completed = f.data.plans.singleWhere((p) => p.id == 'completed');
      final legacy = f.data.plans.singleWhere((p) => p.id == 'legacy');

      expect(await f.data.markPlanPaid(inactive), isFalse);
      expect(await f.data.markPlanPaid(completed), isFalse);
      await expectLater(f.data.markPlanPaid(legacy), throwsStateError);
      expect(f.calls('POST', '/rpc/mark_installment_paid'), isEmpty);
    },
  );

  test('pending and failed payments preserve state and block a second plan mutation', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    f.plans.add(_plan());
    await f.data.refresh();
    final plan = f.data.plans.single;
    f.gate = Completer<void>();
    f.failWrites = true;
    final pending = f.data.markPlanPaid(plan);
    expect(f.data.planBusy('p'), isTrue);
    await expectLater(f.data.markPlanPaid(plan), throwsStateError);
    await expectLater(f.data.deletePlan('p'), throwsStateError);
    f.gate!.complete();
    await expectLater(pending, throwsA(isA<PostgrestException>()));
    expect(f.data.planBusy('p'), isFalse);
    expect(f.data.plans.single.paidCount, 0);
  });

  test('plan creation validates terms and retains all kinds, fils, initial counts and completion', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    f.profile['currency'] = 'KWD';
    await f.data.refresh();
    for (final kind in installmentKinds) {
      await f.data.addPlan(
        name: kind,
        provider: 'Bank',
        kind: kind,
        monthlyAmount: 1.255,
        totalCount: 4,
        paidCount: 1,
        dueDay: 31,
        nextPaymentMonth: DateTime(2024, 2),
      );
      final row = f.plans.last;
      expect(row['currency'], 'KWD');
      expect(row['total_amount'], 5.02);
      expect(row['next_due_date'], '2024-02-29');
      expect(row['paid_count'], 1);
    }
    await f.data.addPlan(
      name: 'Done',
      provider: '',
      kind: 'other',
      monthlyAmount: 1.255,
      totalCount: 2,
      paidCount: 2,
      dueDay: 31,
    );
    expect(f.plans.last['active'], isFalse);
    expect(f.plans.last['next_due_date'], isNull);
    final before = f.calls('POST', '/installment_plans').length;
    for (final amount in [1.0001, double.nan, -1.0, 99999999999.999]) {
      await expectLater(
        f.data.addPlan(
          name: 'Bad',
          provider: '',
          kind: 'loan',
          monthlyAmount: amount,
          totalCount: 2,
          paidCount: 0,
          dueDay: 31,
          nextPaymentMonth: DateTime(2026, 11),
        ),
        throwsArgumentError,
      );
    }
    await expectLater(
      f.data.addPlan(
        name: 'No schedule',
        provider: '',
        kind: 'card',
        monthlyAmount: 1,
        totalCount: 2,
        paidCount: 0,
        dueDay: 1,
      ),
      throwsArgumentError,
    );
    expect(f.calls('POST', '/installment_plans').length, before);
  });

  test('legacy schedule confirmation is owner-scoped and cached despite reload failure', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    f.plans.add(_plan(date: null));
    await f.data.refresh();
    final plan = f.data.plans.single;
    await expectLater(f.data.markPlanPaid(plan), throwsStateError);
    expect(f.data.budget.provisional, isTrue);
    f.failAfterWrite = true;
    await f.data.setPlanSchedule(plan, dueDay: 31, month: DateTime(2026, 2));
    expect(f.data.plans.single.nextDueDate, DateTime(2026, 2, 28));
    final r = f.calls('PATCH', '/installment_plans').single;
    expect(r.url.queryParameters, containsPair('user_id', 'eq.user-a'));
    expect(r.url.queryParameters, containsPair('next_due_date', 'is.null'));
    expect(r.url.queryParameters, containsPair('paid_count', 'eq.0'));
    expect(r.url.queryParameters, containsPair('active', 'eq.true'));
    f.failWrites = true;
    await expectLater(
      f.data.deletePlan('p'),
      throwsA(isA<PostgrestException>()),
    );
    expect(f.data.plans, hasLength(1));
    f.failWrites = false;
    await f.data.deletePlan('p');
    expect(f.data.plans, isEmpty);
  });

  for (final signOut in [false, true]) {
    test(
      'pending plan response cannot publish after ${signOut ? 'account change' : 'disposal'}',
      () async {
        final f = await _Fixture.create();
        addTearDown(f.dispose);
        f.plans.add(_plan());
        await f.data.refresh();
        f.gate = Completer<void>();
        f.rpcResponse = {'applied': true, 'plan': _plan(paid: 1)};
        var notifications = 0;
        f.data.addListener(() => notifications++);
        final pending = f.data.markPlanPaid(f.data.plans.single);
        if (signOut) {
          await f.client.auth.setSession(
            'refresh-b',
            accessToken: _jwt('user-b'),
          );
          await Future<void>.delayed(Duration.zero);
        } else {
          f.data.dispose();
          f.disposedData = true;
        }
        final before = notifications;
        f.gate!.complete();
        await expectLater(pending, throwsStateError);
        expect(notifications, before);
        expect(f.data.plans.every((p) => p.paidCount == 0), isTrue);
      },
    );
  }

  test('currency preference never relabels existing plans and rejects income precision loss', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    f.plans.add(_plan(currency: 'SAR'));
    await f.data.refresh();
    await f.data.updateProfile(currency: 'KWD', income: 100.125);
    expect(f.data.budget.currency, 'KWD');
    expect(f.data.budget.installmentsDue, 0);
    expect(f.data.plans.single.currency, 'SAR');
    final count = f.calls('PATCH', '/profiles').length;
    await expectLater(
      f.data.updateProfile(currency: 'SAR'),
      throwsArgumentError,
    );
    expect(f.calls('PATCH', '/profiles').length, count);
    expect(f.data.currency, 'KWD');
  });

  testWidgets(
    'foreign expenses and plans render their own currency and unknown schedules need confirmation',
    (tester) async {
      final f = (await tester.runAsync(_Fixture.create))!;
      f.plans.addAll([
        _plan(currency: 'KWD', amount: 1.255, date: null),
        _plan(id: 'inactive', active: false),
      ]);
      f.expenses.add(_expense(currency: 'BHD', amount: 2.125));
      await tester.runAsync(f.data.refresh);
      await _mount(tester, f, const ExpensesScreen());
      expect(find.text(money(2.125, 'BHD')), findsOneWidget);
      await _mount(tester, f, const InstallmentsScreen());
      expect(
        find.text('Schedule needed · one provisional monthly reserve'),
        findsOneWidget,
      );
      expect(find.text('Inactive'), findsOneWidget);
      expect(find.textContaining('Mark '), findsOneWidget);
      await tester.tap(find.text('Confirm schedule'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('Due day of month (1–31)'), '31');
      await tester.enterText(_field('Next unpaid month (YYYY-MM)'), '2026-02');
      await tester.pump();
      expect(
        find.text('Next unpaid: ${dayMonth(DateTime(2026, 2, 28))}'),
        findsOneWidget,
      );
      f.failWrites = true;
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not save.'), findsOneWidget);
      f.failWrites = false;
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
        f.data.plans.firstWhere((p) => p.id == 'p').nextDueDate,
        DateTime(2026, 2, 28),
      );
      await _finish(tester, f);
    },
  );

  testWidgets(
    'add plan guards pending save and dismissal while retaining confirmed write',
    (tester) async {
      final f = (await tester.runAsync(_Fixture.create))!;
      await _mount(tester, f, const InstallmentsScreen());
      await tester.tap(find.text('Add plan'));
      await tester.pumpAndSettle();
      await tester.enterText(_field('What is it for?'), 'Phone');
      await tester.enterText(_field('Monthly amount'), '50');
      await tester.enterText(_field('Total number of payments'), '3');
      await tester.enterText(_field('Due day of month (1–31)'), '31');
      await tester.enterText(_field('Next unpaid month (YYYY-MM)'), '2026-12');
      f.gate = Completer<void>();
      await _show(tester, find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Saving…'))
            .onPressed,
        isNull,
      );
      expect(f.calls('POST', '/installment_plans'), hasLength(1));
      Navigator.of(tester.element(find.text('Saving…'))).pop();
      await tester.pumpAndSettle();
      f.failAfterWrite = true;
      f.gate!.complete();
      await tester.pumpAndSettle();
      expect(f.data.plans.single.name, 'Phone');
      expect(f.data.plans.single.nextDueDate, DateTime(2026, 12, 31));
      await _finish(tester, f);
    },
  );

  testWidgets(
    'delete plan retains failure feedback, guards pending retry and removes after success',
    (tester) async {
      final f = (await tester.runAsync(_Fixture.create))!;
      f.plans.add(_plan());
      await tester.runAsync(f.data.refresh);
      await _mount(tester, f, const InstallmentsScreen());
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      f.failWrites = true;
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Could not delete. Try again.'), findsOneWidget);
      expect(f.data.plans, hasLength(1));
      f.failWrites = false;
      f.gate = Completer<void>();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Deleting…'),
            )
            .onPressed,
        isNull,
      );
      f.gate!.complete();
      await tester.pumpAndSettle();
      expect(f.data.plans, isEmpty);
      await _finish(tester, f);
    },
  );

  testWidgets(
    'token reload is available with an existing token and reports failure',
    (tester) async {
      final f = (await tester.runAsync(_Fixture.create))!;
      await _mount(tester, f, const SettingsScreen());
      await _show(tester, find.text('Reload token'));
      f.failReads = true;
      await tester.tap(find.text('Reload token'));
      await tester.pumpAndSettle();
      expect(
        find.text('Could not reload your token. Try again.'),
        findsOneWidget,
      );
      expect(f.data.profile?.ingestToken, _token);
      f.failReads = false;
      f.profile['ingest_token'] =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      await tester.tap(find.text('Reload token'));
      await tester.pumpAndSettle();
      expect(f.data.profile?.ingestToken, f.profile['ingest_token']);
      await _finish(tester, f);
    },
  );

  testWidgets('overview labels complete, provisional and stale budgets', (
    tester,
  ) async {
    final f = (await tester.runAsync(_Fixture.create))!;
    f.plans.add(_plan(date: null));
    await tester.runAsync(f.data.refresh);
    await _mount(tester, f, const HomeScreen());
    expect(find.textContaining('Provisional:'), findsOneWidget);
    expect(find.text('Due by month-end (includes overdue)'), findsOneWidget);
    f.failReads = true;
    await tester.runAsync(f.data.refresh);
    await tester.pump();
    expect(find.text('Previous budget · reload needed'), findsOneWidget);
    await _finish(tester, f);
  });
}
