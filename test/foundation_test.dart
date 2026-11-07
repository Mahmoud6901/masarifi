import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:masarifi/data.dart';
import 'package:masarifi/main.dart' as app;
import 'package:masarifi/models.dart';
import 'package:masarifi/screens/auth_screen.dart';
import 'package:masarifi/screens/home_screen.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _url = 'https://example.supabase.co';
const _key = 'test-anon-key';

String _jwt(String userId) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String encode(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${encode({'alg': 'none', 'typ': 'JWT'})}.${encode({'sub': userId, 'role': 'authenticated', 'iat': now, 'exp': now + 3600})}.${base64Url.encode(utf8.encode('signature')).replaceAll('=', '')}';
}

Map<String, Object?> _user(String id, String email) => {
  'id': id,
  'aud': 'authenticated',
  'role': 'authenticated',
  'email': email,
  'app_metadata': {
    'provider': 'email',
    'providers': ['email'],
  },
  'user_metadata': {},
  'identities': [],
  'created_at': DateTime.now().toUtc().toIso8601String(),
};

String _requestUser(http.Request request) {
  final token = request.headers['authorization']!.split(' ').last;
  final payload = jsonDecode(
    utf8.decode(base64Url.decode(base64Url.normalize(token.split('.')[1]))),
  ) as Map<String, dynamic>;
  return payload['sub'] as String;
}

Map<String, Object?> _profile(String userId, {String currency = 'SAR'}) => {
  'id': userId,
  'currency': currency,
  'monthly_income': 5000,
  'ingest_token': 'token-$userId',
};

Map<String, Object?> _session(String id) => {
  'access_token': _jwt(id),
  'refresh_token': 'refresh-$id',
  'token_type': 'bearer',
  'expires_in': 3600,
  'user': _user(id, '$id@example.com'),
};

http.Response _json(Object? body, {int status = 200, http.Request? request}) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: {
        'content-type': 'application/json',
        if (body is List) 'content-range': '*/${body.length}',
      },
      // Held responses still need request metadata for Postgrest's parser.
      request: request ?? http.Request('GET', Uri.parse(_url)),
    );

Future<SupabaseClient> _signedInClient(
  MockClient transport, {
  String userId = 'user-a',
}) async {
  final client = SupabaseClient(_url, _key, httpClient: transport);
  await client.auth.setSession('refresh-$userId', accessToken: _jwt(userId));
  return client;
}

void main() {
  group('authentication form', () {
    testWidgets('signup confirmation instructions appear without a session', (
      tester,
    ) async {
      var signups = 0;
      final auth = GoTrueClient(
        url: '$_url/auth/v1',
        flowType: AuthFlowType.implicit,
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/signup')) {
            signups++;
            return _json({
              'user': _user('new-user', 'person@example.com'),
              'session': null,
            });
          }
          fail('Unexpected request ${request.url}');
        }),
      );
      await tester.pumpWidget(MaterialApp(home: AuthScreen(auth: auth)));
      await tester.tap(find.text('New here? Create an account'));
      await tester.pump();
      await tester.enterText(
        find.byType(TextField).at(0),
        'person@example.com',
      );
      await tester.enterText(find.byType(TextField).at(1), 'password-123');
      await tester.tap(find.text('Create account'));
      await tester.pumpAndSettle();
      expect(signups, 1);
      expect(auth.currentSession, isNull);
      expect(
        find.text('Check your email to confirm your account, then sign in.'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    });

    testWidgets(
      'sign-in errors are shown and a pending submit cannot duplicate',
      (tester) async {
        final response = Completer<http.Response>();
        var attempts = 0;
        final auth = GoTrueClient(
          url: '$_url/auth/v1',
          httpClient: MockClient((request) async {
            if (request.url.path.endsWith('/token')) {
              attempts++;
              return response.future;
            }
            fail('Unexpected request ${request.url}');
          }),
        );
        await tester.pumpWidget(MaterialApp(home: AuthScreen(auth: auth)));
        await tester.enterText(
          find.byType(TextField).at(0),
          'person@example.com',
        );
        await tester.enterText(find.byType(TextField).at(1), 'password-123');
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText).at(0))
              .controller
              .text,
          'person@example.com',
        );
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText).at(1))
              .controller
              .text,
          'password-123',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(attempts, 1);
        response.complete(
          _json({
            'msg': 'Invalid login credentials',
            'code': 'invalid_credentials',
          }, status: 400),
        );
        await tester.pumpAndSettle();
        expect(find.text('Invalid login credentials'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        auth.dispose();
      },
    );
  });

  group('data and schema models', () {
    test(
      'profile and row models decode schema values with SAR as the app default',
      () {
        final profile = Profile.fromJson({
          'currency': 'SAR',
          'monthly_income': 5000,
          'ingest_token': 'server-token',
        });
        final expense = Expense.fromJson({
          'id': 'expense-1',
          'amount': 12.5,
          'currency': 'SAR',
          'merchant': 'Cafe',
          'category': 'food',
          'source': 'manual',
          'spent_at': '2026-11-01T12:00:00Z',
        });
        final plan = InstallmentPlan.fromJson({
          'id': 'plan-1',
          'name': 'Phone',
          'provider': null,
          'kind': 'bnpl',
          'monthly_amount': 100,
          'total_amount': 400,
          'currency': 'SAR',
          'total_count': 4,
          'paid_count': 1,
          'due_day': 10,
          'active': true,
        });
        expect(profile.currency, 'SAR');
        expect(profile.monthlyIncome, 5000);
        expect(expense.amount, 12.5);
        expect(plan.provider, '');
        final client = SupabaseClient(_url, _key);
        final data = AppData(client);
        expect(data.currency, 'SAR');
        data.dispose();
        client.auth.dispose();
      },
    );

    test('refresh after disposal does not notify listeners', () async {
      final profileResponse = Completer<http.Response>();
      final client = await _signedInClient(
        MockClient((request) async {
          if (request.url.path.endsWith('/user')) {
            return _json(_user('user-a', 'user-a@example.com'));
          }
          if (request.url.path.endsWith('/rest/v1/profiles')) {
            return profileResponse.future;
          }
          fail('Unexpected request ${request.url}');
        }),
      );
      final data = AppData(client);
      var notifications = 0;
      data.addListener(() => notifications++);
      final refresh = data.refresh();
      data.dispose();
      profileResponse.complete(
        _json({
          'id': 'user-a',
          'currency': 'SAR',
          'monthly_income': 0,
          'ingest_token': 'token',
        }),
      );
      await refresh;
      expect(notifications, 1); // Initial loading notification only.
      expect(data.profile, isNull);
      client.auth.dispose();
    });

    test('signed-out writes fail in a controlled way', () async {
      var requests = 0;
      final client = SupabaseClient(
        _url,
        _key,
        httpClient: MockClient((_) async {
          requests++;
          return _json([]);
        }),
      );
      final data = AppData(client);
      await expectLater(
        data.addExpense(amount: 10, merchant: 'Cafe', category: 'food'),
        throwsA(isA<StateError>()),
      );
      await expectLater(data.deleteExpense('expense'), throwsStateError);
      await expectLater(data.deletePlan('plan'), throwsStateError);
      await expectLater(data.updateProfile(income: 100), throwsStateError);
      await expectLater(
        data.addPlan(
          name: 'Phone',
          provider: '',
          kind: 'bnpl',
          monthlyAmount: 10,
          totalCount: 2,
          paidCount: 0,
          dueDay: 1,
        ),
        throwsStateError,
      );
      await expectLater(
        data.markPlanPaid(
          InstallmentPlan(
            id: 'plan',
            name: 'Phone',
            provider: '',
            kind: 'bnpl',
            monthlyAmount: 10,
            totalCount: 2,
            paidCount: 0,
            dueDay: 1,
            active: true,
          ),
        ),
        throwsStateError,
      );
      await expectLater(data.askAgent([]), throwsStateError);
      expect(requests, 0);
      data.dispose();
      client.auth.dispose();
    });

    test('newer refresh wins when an older response completes last', () async {
      final first = Completer<http.Response>();
      var profileCalls = 0;
      final requests = <String>[];
      final client = await _signedInClient(
        MockClient((request) async {
          requests.add('${request.method} ${request.url}');
          if (request.url.path.endsWith('/user')) {
            return _json(_user('user-a', 'user-a@example.com'));
          }
          if (request.url.path.endsWith('/rest/v1/profiles')) {
            profileCalls++;
            if (profileCalls == 1) return first.future;
            return _json({
              'id': 'user-a',
              'currency': 'USD',
              'monthly_income': 20,
              'ingest_token': 't',
            }, request: request);
          }
          if (request.url.path.endsWith('/rest/v1/expenses') ||
              request.url.path.endsWith('/rest/v1/installment_plans')) {
            return _json([], request: request);
          }
          fail('Unexpected request ${request.url}');
        }),
      );
      final data = AppData(client);
      final older = data.refresh();
      await Future<void>.delayed(Duration.zero);
      final newer = data.refresh();
      await newer;
      first.complete(
        _json({
          'id': 'user-a',
          'currency': 'EUR',
          'monthly_income': 10,
          'ingest_token': 't',
        }),
      );
      await older;
      expect(
        data.profile?.currency,
        'USD',
        reason: 'refresh error: ${data.error}; requests: $requests',
      );
      data.dispose();
      client.auth.dispose();
    });

    test('auth account change clears the previous account data', () async {
      final client = await _signedInClient(
        MockClient((request) async {
          if (request.url.path.endsWith('/user')) {
            final id = _requestUser(request);
            return _json(_user(id, '$id@example.com'));
          }
          if (request.url.path.endsWith('/token')) return _json({});
          fail('Unexpected request ${request.url}');
        }),
      );
      final data = AppData(client)
        ..profile = Profile(
          currency: 'SAR',
          monthlyIncome: 1,
          ingestToken: 'secret',
        );
      await client.auth.setSession(
        'refresh-user-b',
        accessToken: _jwt('user-b'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(data.profile, isNull);
      expect(data.expenses, isEmpty);
      await expectLater(
        data.addExpense(amount: 1, merchant: 'Cafe', category: 'food'),
        throwsA(isA<StateError>()),
      );
      data.dispose();
      client.auth.dispose();
    });

    test(
      'sign-out discards an in-flight response and clears loaded values',
      () async {
        final response = Completer<http.Response>();
        final client = await _signedInClient(
          MockClient((request) async {
            if (request.url.path.endsWith('/user')) {
              return _json(_user('user-a', 'a@example.com'));
            }
            if (request.url.path.endsWith('/profiles')) return response.future;
            if (request.url.path.endsWith('/logout')) {
              return http.Response('', 204);
            }
            fail('Unexpected request ${request.url}');
          }),
        );
        final data = AppData(client)
          ..profile = Profile(
            currency: 'USD',
            monthlyIncome: 100,
            ingestToken: 'secret',
          );
        final pending = data.refresh();
        await data.signOut();
        await Future<void>.delayed(Duration.zero);
        expect(data.profile, isNull);
        expect(data.loading, isFalse);
        response.complete(_json(_profile('user-a')));
        await pending;
        expect(data.profile, isNull);
        expect(data.currency, 'SAR');
        expect(data.error, isNull);
        await expectLater(data.updateProfile(income: 5), throwsStateError);
        data.dispose();
        await client.dispose();
      },
    );
  });

  group('startup and account gate', () {
    testWidgets(
      'retryable refresh failures preserve the gate, data and replay subscribers',
      (tester) async {
        var offline = true;
        var refreshAttempts = 0;
        final client = (await tester.runAsync(
          () => _signedInClient(
            MockClient((request) async {
              if (request.url.path.endsWith('/user')) {
                return _json(
                  _user('user-a', 'user-a@example.com'),
                  request: request,
                );
              }
              if (request.url.path.endsWith('/token')) {
                refreshAttempts++;
                if (offline) throw http.ClientException('offline');
                return _json(_session('user-a'), request: request);
              }
              if (request.url.path.endsWith('/profiles')) {
                return _json(_profile('user-a'), request: request);
              }
              if (request.url.path.endsWith('/expenses')) {
                return _json([
                  {
                    'id': 'expense-1',
                    'amount': 12,
                    'currency': 'SAR',
                    'merchant': 'Cafe',
                    'category': 'food',
                    'source': 'manual',
                    'spent_at': '2026-11-01T12:00:00Z',
                  },
                ], request: request);
              }
              if (request.url.path.endsWith('/installment_plans')) {
                return _json([
                  {
                    'id': 'plan-1',
                    'name': 'Phone',
                    'provider': '',
                    'kind': 'bnpl',
                    'monthly_amount': 100,
                    'total_amount': 400,
                    'currency': 'SAR',
                    'total_count': 4,
                    'paid_count': 1,
                    'due_day': 10,
                    'active': true,
                  },
                ], request: request);
              }
              if (request.url.path.endsWith('/logout')) {
                return http.Response('', 204);
              }
              fail('Unexpected request ${request.url}');
            }),
          ),
        ))!;
        await tester.pumpWidget(app.MasarifiApp(client: client));
        await tester.pumpAndSettle();
        final original = tester
            .element(find.byType(HomeScreen))
            .read<AppData>();
        final profile = original.profile;
        final expenses = original.expenses;
        final plans = original.plans;
        expect(profile?.ingestToken, 'token-user-a');
        expect(expenses.single.id, 'expense-1');
        expect(plans.single.id, 'plan-1');

        // Catch the direct rethrow; the gate and AppData must each consume the
        // separate stream error without treating a temporary failure as sign-out.
        await tester.runAsync(
          () => expectLater(
            client.auth.refreshSession(),
            throwsA(isA<AuthRetryableFetchException>()),
          ),
        );
        await tester.pumpAndSettle();
        expect(refreshAttempts, greaterThan(0));
        expect(tester.takeException(), isNull);
        expect(client.auth.currentSession?.user.id, 'user-a');
        expect(
          tester.element(find.byType(HomeScreen)).read<AppData>(),
          same(original),
        );
        expect(original.profile, same(profile));
        expect(original.expenses, same(expenses));
        expect(original.plans, same(plans));
        expect(original.error, isNull);

        // GoTrue replays its last error to a listener created after the failure.
        final replayed = AppData(client);
        await replayed.refresh();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(replayed.profile?.ingestToken, 'token-user-a');
        expect(replayed.expenses.single.id, 'expense-1');
        expect(replayed.plans.single.id, 'plan-1');

        // The error handlers must leave both subscriptions listening to later
        // refresh and sign-out events, rather than cancelling them on error.
        offline = false;
        await client.auth.refreshSession();
        await tester.pumpAndSettle();
        expect(
          tester.element(find.byType(HomeScreen)).read<AppData>(),
          same(original),
        );
        expect(original.profile, same(profile));
        await original.signOut();
        await tester.pumpAndSettle();
        expect(find.byType(AuthScreen), findsOneWidget);
        expect(replayed.profile, isNull);
        expect(replayed.expenses, isEmpty);
        expect(replayed.plans, isEmpty);
        replayed.dispose();
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(client.dispose);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('missing config does not initialize the backend', (
      tester,
    ) async {
      var initialized = false;
      await app.startApp(
        url: '',
        anonKey: '',
        initialize: () async {
          initialized = true;
        },
      );
      await tester.pumpAndSettle();
      expect(initialized, isFalse);
      expect(
        find.text(
          'Missing SUPABASE_URL / SUPABASE_ANON_KEY build configuration.',
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'invalid config and initialization errors display no key material',
      (tester) async {
        var initialized = false;
        await app.startApp(
          url: 'invalid-url',
          anonKey: 'secret-test-key',
          initialize: () async {
            initialized = true;
          },
        );
        await tester.pumpAndSettle();
        expect(initialized, isFalse);
        expect(
          find.textContaining('Could not initialize Masarifi'),
          findsOneWidget,
        );
        await app.startApp(
          url: _url,
          anonKey: 'secret-test-key',
          initialize: () async {
            throw StateError('secret-test-key');
          },
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Could not initialize Masarifi'),
          findsOneWidget,
        );
        expect(find.textContaining('secret-test-key'), findsNothing);
      },
    );

    testWidgets('login, account switching and sign-out isolate provider state', (
      tester,
    ) async {
      final transport = MockClient((request) async {
        if (request.url.path.endsWith('/token')) {
          return _json(_session('user-a'));
        }
        if (request.url.path.endsWith('/user')) {
          final id = _requestUser(request);
          return _json(_user(id, '$id@example.com'));
        }
        if (request.url.path.endsWith('/profiles')) {
          final id = _requestUser(request);
          expect(request.url.queryParameters['id'], 'eq.$id');
          return _json(_profile(id, currency: id == 'user-a' ? 'SAR' : 'AED'));
        }
        if (request.url.path.endsWith('/expenses') ||
            request.url.path.endsWith('/installment_plans')) {
          expect(
            request.url.queryParameters['user_id'],
            'eq.${_requestUser(request)}',
          );
          return _json([]);
        }
        if (request.url.path.endsWith('/logout')) {
          return http.Response('', 204);
        }
        fail('Unexpected request ${request.url}');
      });
      // Construct Supabase's JSON worker outside fake async so it can finish
      // initializing during client disposal, too.
      final client = (await tester.runAsync(
        () async => SupabaseClient(_url, _key, httpClient: transport),
      ))!;
      await tester.pumpWidget(app.MasarifiApp(client: client));
      await tester.pumpAndSettle();
      expect(find.byType(AuthScreen), findsOneWidget);
      await tester.enterText(
        find.byType(TextField).at(0),
        'user-a@example.com',
      );
      await tester.enterText(find.byType(TextField).at(1), 'password-123');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      final first = tester.element(find.byType(HomeScreen)).read<AppData>();
      expect(
        first.profile?.ingestToken,
        'token-user-a',
        reason:
            'loading=${first.loading}, error=${first.error}, email=${first.accountEmail}',
      );

      await client.auth.setSession(
        'refresh-user-b',
        accessToken: _jwt('user-b'),
      );
      await tester.pumpAndSettle();
      final second = tester.element(find.byType(HomeScreen)).read<AppData>();
      expect(identical(first, second), isFalse);
      expect(second.profile?.ingestToken, 'token-user-b');
      expect(second.currency, 'AED');
      await expectLater(first.updateProfile(income: 1), throwsStateError);

      // Both transitions happen before the next frame, even for the same user.
      await client.auth.signOut();
      await client.auth.setSession(
        'refresh-user-b',
        accessToken: _jwt('user-b'),
      );
      await tester.pumpAndSettle();
      final third = tester.element(find.byType(HomeScreen)).read<AppData>();
      expect(identical(second, third), isFalse);
      expect(third.profile?.ingestToken, 'token-user-b');

      await third.signOut();
      await tester.pumpAndSettle();
      expect(find.byType(AuthScreen), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(client.dispose);
      expect(tester.takeException(), isNull);
    });
  });
}
