// Renders each tab to a PNG for visual review. Runs only when PREVIEW_DIR is
// set (and optionally PREVIEW_FONT_DIR for a real text face):
//   PREVIEW_DIR=out flutter test test/ui_preview_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:masarifi/data.dart';
import 'package:masarifi/screens/auth_screen.dart';
import 'package:masarifi/screens/home_screen.dart';
import 'package:masarifi/theme.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _now = DateTime(2026, 11, 15, 12);

String _jwt(String id) {
  String enc(Object v) =>
      base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
  final n = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return '${enc({'alg': 'none'})}.${enc({'sub': id, 'iat': n, 'exp': n + 3600})}.c2ln';
}

Map<String, dynamic> _expense(
  String id,
  String merchant,
  String category,
  double amount,
  int daysAgo, {
  String source = 'apple_pay',
}) => {
  'id': id,
  'user_id': 'u',
  'amount': amount,
  'currency': 'SAR',
  'merchant': merchant,
  'category': category,
  'source': source,
  'spent_at': _now.subtract(Duration(days: daysAgo)).toUtc().toIso8601String(),
};

Map<String, dynamic> _plan(
  String id,
  String name,
  String provider,
  String kind,
  double monthly,
  int total,
  int paid,
  String next,
) => {
  'id': id,
  'user_id': 'u',
  'name': name,
  'provider': provider,
  'kind': kind,
  'monthly_amount': monthly,
  'total_amount': monthly * total,
  'currency': 'SAR',
  'total_count': total,
  'paid_count': paid,
  'due_day': 28,
  'active': true,
  'next_due_date': next,
  'created_at': '2026-01-01T00:00:00Z',
};

Future<void> _loadFonts() async {
  final dir = Platform.environment['PREVIEW_FONT_DIR'];
  if (dir == null) return;
  final loader = FontLoader('Roboto');
  for (final f in ['segoeui.ttf', 'seguisb.ttf', 'segoeuib.ttf']) {
    final file = File('$dir/$f');
    if (file.existsSync()) {
      loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
  }
  await loader.load();
  final icons = File(Platform.environment['PREVIEW_ICON_FONT'] ?? '');
  if (icons.existsSync()) {
    final il = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await il.load();
  }
}

void main() {
  final out = Platform.environment['PREVIEW_DIR'];

  for (final dark in [true, false]) {
    testWidgets(
      'preview ${dark ? 'dark' : 'light'}',
      (tester) async {
        await _loadFonts();
        final expenses = [
          _expense('1', 'Starbucks Olaya', 'food', 28.5, 0),
          _expense('2', 'Panda Hypermarket', 'groceries', 214.75, 1),
          _expense('3', 'Careem', 'transport', 36, 2),
          _expense('4', 'Jarir Bookstore', 'shopping', 389, 3),
          _expense('5', 'Nahdi Pharmacy', 'health', 62.4, 4, source: 'manual'),
        ];
        final plans = [
          _plan('p1', 'iPhone 17', 'Tabby', 'bnpl', 450, 12, 5, '2026-11-28'),
          _plan('p2', 'Car loan', 'Al Rajhi', 'loan', 1350, 48, 20, '2026-11-25'),
        ];
        final client = SupabaseClient(
          'https://example.supabase.co',
          'k',
          httpClient: MockClient((r) async {
            final p = r.url.path;
            http.Response j(Object b, {int? count}) => http.Response(
              jsonEncode(b),
              200,
              request: r,
              headers: {
                'content-type': 'application/json',
                if (count != null) 'content-range': '*/$count',
              },
            );
            if (p.endsWith('/user')) {
              return j({
                'id': 'u',
                'email': 'a@b.c',
                'aud': 'authenticated',
                'app_metadata': {},
                'user_metadata': {},
                'created_at': '2026-01-01T00:00:00Z',
              });
            }
            if (p.endsWith('/profiles')) {
              return j({
                'id': 'u',
                'currency': 'SAR',
                'monthly_income': 14000,
                'ingest_token': 'a' * 48,
              });
            }
            if (p.endsWith('/expenses')) return j(expenses, count: 5);
            if (p.endsWith('/installment_plans')) return j(plans, count: 2);
            return j([]);
          }),
        );
        await client.auth.setSession('r', accessToken: _jwt('u'));
        final data = AppData(client, now: () => _now);
        await tester.runAsync(data.refresh);

        tester.view.physicalSize = const Size(1170, 2532);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        final key = GlobalKey();

        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: masarifiTheme(
                dark ? Brightness.dark : Brightness.light,
                fontFamily: Platform.environment['PREVIEW_FONT_DIR'] == null
                    ? null
                    : 'Roboto',
              ),
              home: ChangeNotifierProvider.value(
                value: data,
                child: const HomeScreen(),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));

        final tabs = {
          'overview': null,
          'expenses': Icons.receipt_long_outlined,
          'installments': Icons.event_repeat_outlined,
          'assistant': Icons.auto_awesome_outlined,
          'settings': Icons.settings_outlined,
        };
        for (final e in tabs.entries) {
          if (e.value != null) {
            await tester.tap(find.byIcon(e.value!));
            await tester.pump(const Duration(milliseconds: 400));
            await tester.pump(const Duration(milliseconds: 400));
          }
          await tester.runAsync(() async {
            final boundary =
                key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File(
              '$out/${dark ? 'dark' : 'light'}-${e.key}.png',
            )..createSync(recursive: true);
            file.writeAsBytesSync(bytes!.buffer.asUint8List());
          });
        }
      },
      skip: out == null,
    );
  }

  for (final dark in [true, false]) {
    testWidgets(
      'auth preview ${dark ? 'dark' : 'light'}',
      (tester) async {
        await _loadFonts();
        tester.view.physicalSize = const Size(1170, 2532);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: masarifiTheme(
                dark ? Brightness.dark : Brightness.light,
                fontFamily: Platform.environment['PREVIEW_FONT_DIR'] == null
                    ? null
                    : 'Roboto',
              ),
              home: const AuthScreen(),
            ),
          ),
        );
        await tester.tap(find.text('Sign in'));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          File('$out/${dark ? 'dark' : 'light'}-auth.png')
            ..createSync(recursive: true)
            ..writeAsBytesSync(bytes!.buffer.asUint8List());
        });
      },
      skip: out == null,
    );
  }
}
