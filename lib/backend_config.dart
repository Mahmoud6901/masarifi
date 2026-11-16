import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Which Supabase project this copy of Masarifi talks to.
///
/// The public IPA has no project built in: each person connects their own on
/// first launch, and it is kept on the device. A build made with
/// `--dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...` skips
/// that step.
class BackendConfig {
  const BackendConfig(this.url, this.anonKey);

  final String url;
  final String anonKey;
}

/// The project in use, set once at startup. Settings builds the ingest URL
/// from it.
String activeBackendUrl = '';

/// True when the project was connected in the app (not built in), so Settings
/// can offer to disconnect it.
bool backendChosenInApp = false;

/// Set at startup: closes the current project and shows the Connect screen.
/// Settings calls it after signing out and forgetting the saved project.
Future<void> Function()? reconnectBackend;

const _urlKey = 'masarifi.backend_url';
const _anonKey = 'masarifi.backend_anon_key';

/// A pasted project URL without trailing slashes, or null when it is not a
/// project address. Plain http is accepted only for a local Supabase.
String? normalizeBackendUrl(String raw) {
  final value = raw.trim().replaceFirst(RegExp(r'/+$'), '');
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.host.isEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.userInfo.isNotEmpty ||
      uri.path.isNotEmpty) {
    return null;
  }
  final local = const {'localhost', '127.0.0.1', '10.0.2.2'}.contains(uri.host);
  if (uri.scheme == 'https' || (uri.scheme == 'http' && local)) return value;
  return null;
}

/// Why a pasted key cannot be used, or null when it is a public client key.
///
/// Secret and service_role keys bypass row-level security, so they must never
/// be stored on a phone; they are refused here.
String? anonKeyProblem(String raw) {
  final key = raw.trim();
  if (key.isEmpty) return 'Paste your project\'s anon key.';
  if (key.startsWith('sb_secret_')) {
    return 'That is a secret key. Use the anon (publishable) key instead.';
  }
  if (key.startsWith('sb_publishable_')) return null;
  final parts = key.split('.');
  if (parts.length == 3) {
    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      );
      if (payload is Map) {
        if (payload['role'] == 'service_role') {
          return 'That is the service_role key. Use the anon key instead.';
        }
        if (payload['role'] == 'anon') return null;
      }
    } catch (_) {
      // Falls through to the generic message.
    }
  }
  return 'This does not look like a Supabase anon key.';
}

/// The project saved on this device, or null when none is (or storage fails).
Future<BackendConfig?> loadSavedBackend() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(_urlKey);
    final key = prefs.getString(_anonKey);
    if (url == null || key == null) return null;
    final clean = normalizeBackendUrl(url);
    if (clean == null || anonKeyProblem(key) != null) return null;
    return BackendConfig(clean, key);
  } catch (_) {
    return null;
  }
}

Future<void> saveBackend(BackendConfig config) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_urlKey, config.url);
  await prefs.setString(_anonKey, config.anonKey);
}

Future<void> forgetBackend() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_urlKey);
  await prefs.remove(_anonKey);
}

/// Whether the project answers with this key. Supabase Auth's public
/// settings endpoint needs only the anon key and returns 200 when both match.
Future<bool> backendAnswers(BackendConfig config, {http.Client? client}) async {
  final http.Client c = client ?? http.Client();
  try {
    final response = await c
        .get(
          Uri.parse('${config.url}/auth/v1/settings'),
          headers: {'apikey': config.anonKey},
        )
        .timeout(const Duration(seconds: 15));
    return response.statusCode == 200;
  } catch (_) {
    return false;
  } finally {
    if (client == null) c.close();
  }
}
