import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'data.dart';
import 'screens/auth_screen.dart';
import 'screens/home_screen.dart';
import 'theme.dart';

// Provided at build time: --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

Future<void> main() => startApp();

Future<void> startApp({
  String url = supabaseUrl,
  String anonKey = supabaseAnonKey,
  Future<void> Function()? initialize,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (url.trim().isEmpty || anonKey.trim().isEmpty) {
    runApp(
      const _ConfigErrorApp(
        message:
            'Missing SUPABASE_URL / SUPABASE_ANON_KEY build configuration.',
      ),
    );
    return;
  }
  try {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !uri.hasAuthority ||
        !['https', 'http'].contains(uri.scheme)) {
      throw const FormatException('Invalid backend URL');
    }
    if (initialize != null) {
      await initialize();
    } else {
      await Supabase.initialize(url: url, publishableKey: anonKey);
    }
  } catch (_) {
    runApp(
      const _ConfigErrorApp(
        message: 'Could not initialize Masarifi. Check the backend configuration and restart the app.',
      ),
    );
    return;
  }
  runApp(const MasarifiApp());
}

class MasarifiApp extends StatelessWidget {
  const MasarifiApp({super.key, this.client});

  final SupabaseClient? client;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Masarifi مصاريفي',
      debugShowCheckedModeBanner: false,
      theme: masarifiTheme(Brightness.light),
      darkTheme: masarifiTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('en'), Locale('ar')],
      home: AuthGate(client: client),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key, this.client});

  final SupabaseClient? client;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late SupabaseClient _client;
  late StreamSubscription<AuthState> _subscription;
  Session? _session;
  int _accountVersion = 0;

  void _listen() {
    _client = widget.client ?? Supabase.instance.client;
    _session = _client.auth.currentSession;
    _subscription = _client.auth.onAuthStateChange.listen(
      (state) {
        if (!mounted) return;
        setState(() {
          // Count every identity transition, even if multiple events arrive
          // before the next frame (including sign-out and back into the same user).
          if (_session?.user.id != state.session?.user.id) _accountVersion++;
          _session = state.session;
        });
      },
      onError: (Object error, StackTrace stackTrace) {
        // GoTrue already logs refresh errors. Keep the current session while
        // it retries; a definitive auth failure arrives as a signedOut event.
      },
    );
  }

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(AuthGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client) {
      unawaited(_subscription.cancel());
      _accountVersion++;
      _listen();
    }
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    if (session == null) return AuthScreen(auth: _client.auth);
    return ChangeNotifierProvider(
      key: ValueKey((session.user.id, _accountVersion)),
      create: (_) => AppData(_client)..refresh(),
      child: const HomeScreen(),
    );
  }
}

class _ConfigErrorApp extends StatelessWidget {
  const _ConfigErrorApp({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(message, textAlign: TextAlign.center),
          ),
        ),
      ),
    );
  }
}
