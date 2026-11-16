import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../backend_config.dart';
import '../data.dart';
import '../logic.dart';
import '../format.dart';
import '../models.dart';
import '../theme.dart';

/// A prompt the user pastes into Siri or Shortcuts to build the capture
/// Shortcut. It carries the private token, so it is copied, never shown.
String siriPrompt(String ingestUrl, String token) =>
    'Create a shortcut named Masarifi. It receives any input, and if there is '
    'no input it continues. Add one action: Get Contents of URL with URL '
    '$ingestUrl, method POST, header x-ingest-token = $token, and a JSON '
    'request body with exactly two text fields: text = Shortcut Input, and '
    'time = Current Date formatted as ISO 8601 including the time. Then add '
    'Show Notification showing the Contents of URL. Do not add any other actions.';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.supabaseUrl});

  /// The project's base URL; defaults to the one connected at startup.
  final String? supabaseUrl;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _regenerating = false;
  bool _openingShortcut = false;
  bool _savingCurrency = false;
  int _currencyVersion = 0;

  static const _currencies = ['SAR', 'AED', 'KWD', 'QAR', 'BHD', 'OMR'];

  @override
  Widget build(BuildContext context) {
    final data = context.watch<AppData>();
    final profile = data.profile;
    final baseUrl = (widget.supabaseUrl ?? activeBackendUrl).trim().replaceFirst(
      RegExp(r'/+$'),
      '',
    );
    final uri = Uri.tryParse(baseUrl);
    final ingestUrl =
        uri != null &&
            uri.host.isNotEmpty &&
            ['https', 'http'].contains(uri.scheme)
        ? '$baseUrl/functions/v1/ingest'
        : null;

    final theme = Theme.of(context);
    final c = context.mc;

    return ListView(
      padding: const EdgeInsetsDirectional.fromSTEB(20, 24, 20, 32),
      children: [
        Text('Account', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: ListTile(
              title: Text(data.accountEmail),
              trailing: TextButton(
                onPressed: () async {
                  try {
                    await data.signOut();
                  } catch (_) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Could not sign out. Try again.'),
                        ),
                      );
                    }
                  }
                },
                child: const Text('Sign out'),
              ),
            ),
          ),
        ),
        const SizedBox(height: 32),
        Text('Budget', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              children: [
                DropdownButtonFormField<String>(
                  key: ValueKey('${data.currency}-$_currencyVersion'),
                  initialValue: _currencies.contains(data.currency)
                      ? data.currency
                      : 'SAR',
                  items: [
                    for (final cur in _currencies)
                      DropdownMenuItem(value: cur, child: Text(cur)),
                  ],
                  onChanged: profile == null || _savingCurrency
                      ? null
                      : (v) async {
                          if (v == null) return;
                          setState(() => _savingCurrency = true);
                          try {
                            await data.updateProfile(currency: v);
                          } catch (_) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Could not change currency. Income must fit its precision; no conversion or rounding is performed.',
                                  ),
                                ),
                              );
                            }
                          } finally {
                            if (mounted) {
                              setState(() {
                                _savingCurrency = false;
                                _currencyVersion++;
                              });
                            }
                          }
                        },
                  decoration: const InputDecoration(labelText: 'Currency'),
                ),
                const SizedBox(height: 4),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Monthly income'),
                  subtitle: Text(
                    money(profile?.monthlyIncome ?? 0, data.currency),
                  ),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: profile == null || _savingCurrency
                      ? null
                      : () => _editIncome(context, data),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 32),
        Text('Cards', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: data.cards.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: _Prose(
                      'Your cards appear here by themselves after your first '
                      'Apple Pay tap or bank SMS.',
                    ),
                  )
                : Column(
                    children: [
                      for (final card in data.cards)
                        ListTile(
                          leading: const Icon(Icons.credit_card),
                          title: Text(card.displayName),
                          subtitle: card.nickname == null
                              ? null
                              : Text(
                                  [
                                    card.walletName ?? card.bank,
                                    if (card.last4 != null) '··${card.last4}',
                                  ].whereType<String>().join(' '),
                                ),
                          trailing: IconButton(
                            tooltip: 'Rename card',
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => _renameCard(context, data, card),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 32),
        Text('Payment capture', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Prose(
                  'One Shortcut saves Apple Pay taps and bank SMS from every card. '
                  'New cards are added for you, and bank refunds are matched to '
                  'the original payment.',
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: profile == null || _openingShortcut
                          ? null
                          : () => _addShortcut(data, profile.ingestToken),
                      icon: const Icon(Icons.bolt),
                      label: Text(
                        _openingShortcut ? 'Opening…' : 'Add the Shortcut',
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: profile == null || ingestUrl == null
                          ? null
                          : () => _copy(
                              context,
                              siriPrompt(ingestUrl, profile.ingestToken),
                              'Prompt copied. It contains your private token.',
                            ),
                      icon: const Icon(Icons.mic_none),
                      label: const Text('Copy Siri prompt'),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                for (var i = 0; i < _steps.length; i++) ...[
                  _Step(i + 1, _steps[i]),
                  const SizedBox(height: 14),
                ],
                _Prose(
                  'A payment seen by both Apple Pay and SMS is saved once. '
                  'Check your next payment in Expenses.',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (ingestUrl != null)
          _CopyTile(label: 'Ingest URL', value: ingestUrl)
        else
          Text(
            'Backend URL unavailable. Check the app configuration.',
            style: theme.textTheme.bodyMedium?.copyWith(color: c.muted),
          ),
        if (profile != null) ...[
          const SizedBox(height: 8),
          _CopyTile(
            label: 'Your token (keep private)',
            value: profile.ingestToken,
          ),
        ],
        if (profile == null) ...[
          const SizedBox(height: 8),
          Text(
            data.loading
                ? 'Loading your private token…'
                : 'Your private token is unavailable. Reload your profile.',
            style: theme.textTheme.bodyMedium?.copyWith(color: c.muted),
          ),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton(
              onPressed:
                  profile == null || _regenerating || data.rotatingIngestToken
                  ? null
                  : () => _regenerate(data),
              child: Text(
                _regenerating || data.rotatingIngestToken
                    ? 'Regenerating…'
                    : 'Regenerate token',
              ),
            ),
            TextButton(
              onPressed:
                  data.loading || _regenerating || data.rotatingIngestToken
                  ? null
                  : () async {
                      await data.refresh();
                      if (context.mounted && data.error != null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Could not reload your token. Try again.',
                            ),
                          ),
                        );
                      }
                    },
              child: Text(data.loading ? 'Loading token…' : 'Reload token'),
            ),
          ],
        ),
        if (backendChosenInApp && uri != null && uri.host.isNotEmpty) ...[
          const SizedBox(height: 32),
          Text('Backend', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: ListTile(
                title: Text(uri.host),
                subtitle: const Text('Your Supabase project'),
                trailing: TextButton(
                  onPressed: () => _disconnect(data),
                  child: const Text('Disconnect'),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Signs out, forgets the project on this device and returns to Connect.
  /// The data stays in the project.
  Future<void> _disconnect(AppData data) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disconnect this project?'),
        content: const Text(
          'You will be signed out and can connect another Supabase project. '
          'Your data stays in this project.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await data.signOut();
      await forgetBackend();
      await reconnectBackend?.call();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not disconnect. Try again.')),
        );
      }
    }
  }

  static const _steps = [
    'Tap "Copy Siri prompt" and paste it into "Describe a shortcut" in the '
        'Shortcuts app. It builds the Masarifi shortcut with your token.',
    'Apple Pay: make a shortcut that starts with "When Any Card is tapped", '
        'then a Dictionary of amount, merchant and card from the Wallet input, '
        'then Run Shortcut Masarifi with the Dictionary as input.',
    'Bank SMS: save each bank\'s SMS sender as a contact. Make a shortcut that '
        'starts with "When I receive a message" where Sender is your banks, '
        'then Run Shortcut Masarifi with the Message as input.',
    'In-app and online payments are caught by the bank SMS. The notification '
        'shows what was saved, like "✓ 10 SAR · HungerStation".',
  ];

  Future<void> _copy(BuildContext context, String text, String done) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(done)));
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not copy. Try again.')),
        );
      }
    }
  }

  Future<void> _addShortcut(AppData data, String token) async {
    setState(() => _openingShortcut = true);
    try {
      // The Shortcut asks for the token on import; have it ready to paste.
      await Clipboard.setData(ClipboardData(text: token));
      final link = await data.shortcutLink();
      final opened =
          link != null &&
          await launchUrl(link, mode: LaunchMode.externalApplication);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            opened
                ? 'Token copied. Paste it when Shortcuts asks.'
                : 'The Shortcut link is not ready yet. Use "Copy Siri prompt".',
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open Shortcuts. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _openingShortcut = false);
    }
  }

  Future<void> _renameCard(
    BuildContext context,
    AppData data,
    PaymentCard card,
  ) async {
    final controller = TextEditingController(text: card.nickname ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Card name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 60,
          decoration: InputDecoration(hintText: card.displayName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null) return;
    try {
      await data.renameCard(card.id, name);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not rename. Try again.')),
        );
      }
    }
  }

  Future<void> _regenerate(AppData data) async {
    if (_regenerating) return;
    setState(() => _regenerating = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Regenerate your token?'),
          content: const Text(
            'Your previous token will stop working. Update x-ingest-token in your Shortcut with the new token.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Regenerate'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      await data.rotateIngestToken();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('New token ready. Update your Shortcut header.'),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not regenerate. Reload your token before retrying.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _regenerating = false);
    }
  }

  Future<void> _editIncome(BuildContext context, AppData data) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _IncomeDialog(data: data),
    );
  }
}

class _IncomeDialog extends StatefulWidget {
  const _IncomeDialog({required this.data});
  final AppData data;
  @override
  State<_IncomeDialog> createState() => _IncomeDialogState();
}

class _IncomeDialogState extends State<_IncomeDialog> {
  late final _controller = TextEditingController(
    text: '${widget.data.profile?.monthlyIncome ?? 0}',
  );
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    final value = parseAmountInput(
      _controller.text,
      currency: widget.data.currency,
    );
    if (value == null) {
      setState(
        () => _error =
            'Enter an amount in ${widget.data.currency} without extra decimals.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.data.updateProfile(income: value);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not save income. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Monthly income (${widget.data.currency})'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _controller,
          enabled: !_busy,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: TextStyle(color: context.mc.negative)),
          ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: _busy ? null : _save,
        child: Text(_busy ? 'Saving…' : 'Save'),
      ),
    ],
  );
}

class _Prose extends StatelessWidget {
  const _Prose(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(context).textTheme.bodyMedium
        ?.copyWith(color: context.mc.muted, height: 1.6),
  );
}

class _Step extends StatelessWidget {
  const _Step(this.number, this.text);
  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.mc;
    final lines = text.split('\n');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 28,
          child: Text('$number.', style: theme.textTheme.titleSmall),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < lines.length; i++)
                Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 4),
                  child: Text(
                    lines[i],
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: c.muted,
                      height: 1.6,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CopyTile extends StatelessWidget {
  const _CopyTile({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.mc;
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(18, 12, 6, 12),
      decoration: BoxDecoration(
        color: c.well,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.bodySmall),
                const SizedBox(height: 4),
                SelectableText(value, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy $label',
            onPressed: () async {
              try {
                await Clipboard.setData(ClipboardData(text: value));
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('Copied')));
                }
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Could not copy. Try again.')),
                  );
                }
              }
            },
          ),
        ],
      ),
    );
  }
}
