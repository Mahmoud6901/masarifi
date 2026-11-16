import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../backend_config.dart';
import '../theme.dart';

/// Where the setup guide lives: how to create the Supabase project.
const setupGuideUrl = 'github.com/Mahmoud6901/masarifi';

/// First launch of the public app: connect your own Supabase project.
/// Your expenses live there, not with the app's author.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({required this.onConnected, this.client, super.key});

  /// Called once the project answered and was saved on this device.
  final Future<void> Function(BackendConfig config) onConnected;

  /// For tests; the real app uses a fresh client.
  final http.Client? client;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _url = TextEditingController();
  final _key = TextEditingController();
  bool _busy = false;
  String? _message;

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_busy) return;
    final url = normalizeBackendUrl(_url.text);
    final keyProblem = anonKeyProblem(_key.text);
    if (url == null) {
      setState(
        () => _message =
            'Enter your project URL, like https://abcd1234.supabase.co',
      );
      return;
    }
    if (keyProblem != null) {
      setState(() => _message = keyProblem);
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    final config = BackendConfig(url, _key.text.trim());
    try {
      if (!await backendAnswers(config, client: widget.client)) {
        if (mounted) {
          setState(
            () => _message =
                'Could not reach this project with this key. Check both and your connection.',
          );
        }
        return;
      }
      await saveBackend(config);
      await widget.onConnected(config);
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'Could not save the project. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.mc;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsetsDirectional.fromSTEB(28, 24, 28, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('مصاريفي', style: theme.textTheme.displayMedium),
                  const SizedBox(height: 10),
                  Text(
                    'Connect your backend',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: c.muted,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Masarifi keeps your expenses in your own free Supabase '
                    'project. Set one up with the guide at $setupGuideUrl, '
                    'then paste its Project URL and anon key from '
                    'Project Settings › API.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _url,
                    enabled: !_busy,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Project URL',
                      hintText: 'https://abcd1234.supabase.co',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _key,
                    enabled: !_busy,
                    autocorrect: false,
                    enableSuggestions: false,
                    maxLines: 1,
                    decoration: const InputDecoration(labelText: 'Anon key'),
                    onSubmitted: (_) => _connect(),
                  ),
                  if (_message != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _message!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: c.negative,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy ? null : _connect,
                    child: Text(_busy ? 'Connecting…' : 'Connect'),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Never paste the service_role or secret key: the app '
                    'refuses them.',
                    style: theme.textTheme.bodySmall?.copyWith(color: c.muted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
