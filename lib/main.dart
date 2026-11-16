import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'backend_config.dart';
import 'data.dart';
import 'screens/auth_screen.dart';
import 'screens/connect_screen.dart';
import 'screens/home_screen.dart';
import 'theme.dart';

// Optional, for personal/dev builds: --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
// The public IPA has neither; each person connects their own project in the app.
const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

Future<void> main() => startApp();

Future<void> startApp({
  String url = supabaseUrl,
  String anonKey = supabaseAnonKey,
  Future<void> Function()? initialize,
  Future<BackendConfig?> Function() loadSaved = loadSavedBackend,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (url.trim().isNotEmpty && anonKey.trim().isNotEmpty) {
    backendChosenInApp = false;
    await _launch(BackendConfig(url.trim(), anonKey.trim()), initialize);
    return;
  }
  final saved = await loadSaved();
  if (saved != null) {
    backendChosenInApp = true;
    await _launch(saved, initialize);
    return;
  }
  _showConnect(initialize);
}

/// Shows the Connect screen; Settings comes back here after disconnecting.
void _showConnect(Future<void> Function()? initialize) {
  reconnectBackend = () async => _showConnect(initialize);
  runApp(
    _ConnectApp(
      onConnected: (config) async {
        backendChosenInApp = true;
        await _launch(config, initialize);
      },
    ),
  );
}

Future<void> _launch(
  BackendConfig config,
  Future<void> Function()? initialize,
) async {
  try {
    final uri = Uri.tryParse(config.url);
    if (uri == null ||
        !uri.hasAuthority ||
        !['https', 'http'].contains(uri.scheme)) {
      throw const FormatException('Invalid backend URL');
    }
    if (initialize != null) {
      await initialize();
    } else {
      await Supabase.initialize(
        url: config.url,
        publishableKey: config.anonKey,
      );
    }
  } catch (_) {
    runApp(
      _ConfigErrorApp(
        message:
            'Could not initialize Masarifi. Check the backend configuration and restart the app.',
        onReset: backendChosenInApp
            ? () async {
                await forgetBackend();
                _showConnect(initialize);
              }
            : null,
      ),
    );
    return;
  }
  activeBackendUrl = config.url;
  reconnectBackend = () async {
    // Lets a different project be initialized afterwards.
    await Supabase.instance.dispose();
    _showConnect(initialize);
  };
  runApp(const MasarifiApp());
}

class _ConnectApp extends StatelessWidget {
  const _ConnectApp({required this.onConnected});

  final Future<void> Function(BackendConfig config) onConnected;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Masarifi مصاريفي',
    debugShowCheckedModeBanner: false,
    theme: masarifiTheme(Brightness.light),
    darkTheme: masarifiTheme(Brightness.dark),
    themeMode: ThemeMode.system,
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    supportedLocales: const [Locale('en'), Locale('ar')],
    home: ConnectScreen(onConnected: onConnected),
  );
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
  const _ConfigErrorApp({required this.message, this.onReset});

  final String message;

  /// Offered when the project was chosen in the app: connect another one.
  final Future<void> Function()? onReset;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(message, textAlign: TextAlign.center),
                if (onReset != null) ...[
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: onReset,
                    child: const Text('Connect another project'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
