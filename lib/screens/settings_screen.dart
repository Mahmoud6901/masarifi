import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data.dart';
import '../logic.dart';
import '../format.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.supabaseUrl = const String.fromEnvironment('SUPABASE_URL'),
  });

  final String supabaseUrl;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _regenerating = false;
  bool _savingCurrency = false;
  int _currencyVersion = 0;

  static const _currencies = ['SAR', 'AED', 'KWD', 'QAR', 'BHD', 'OMR'];

  @override
  Widget build(BuildContext context) {
    final data = context.watch<AppData>();
    final profile = data.profile;
    final baseUrl = widget.supabaseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(baseUrl);
    final ingestUrl =
        uri != null &&
            uri.host.isNotEmpty &&
            ['https', 'http'].contains(uri.scheme)
        ? '$baseUrl/functions/v1/ingest'
        : null;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Account', style: Theme.of(context).textTheme.titleMedium),
        ListTile(
          contentPadding: EdgeInsets.zero,
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
        const Divider(),
        DropdownButtonFormField<String>(
          key: ValueKey('${data.currency}-$_currencyVersion'),
          initialValue: _currencies.contains(data.currency)
              ? data.currency
              : 'SAR',
          items: [
            for (final c in _currencies)
              DropdownMenuItem(value: c, child: Text(c)),
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
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Monthly income'),
          subtitle: Text(money(profile?.monthlyIncome ?? 0, data.currency)),
          trailing: const Icon(Icons.edit_outlined),
          onTap: profile == null || _savingCurrency
              ? null
              : () => _editIncome(context, data),
        ),
        const Divider(),
        Text(
          'Apple Pay capture',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        const Text(
          'Apple does not let apps read Wallet history, so use a Shortcuts automation:\n\n'
          '1. Open Shortcuts > Automation > + > Transaction.\n'
          '2. Choose your cards, then set "Run Immediately".\n'
          '   If your iOS version shows "Ask Before Running", turn it off.\n'
          '3. Capture the transaction date, or Current Date, once when triggered. '
          'Format it as ISO 8601 with a time zone. Keep that same time if you retry.\n'
          '4. Add "Get Contents of URL" and use the URL below. Choose POST and JSON body:\n'
          '   amount = Shortcut Input > Amount\n'
          '   merchant = Shortcut Input > Merchant\n'
          '   time = the formatted date from step 3\n'
          '5. Add the header x-ingest-token with your private token below. '
          'Do not put it in the URL.\n'
          '6. Check the result: ok: true means saved; duplicate: true means already saved. '
          'An error means it was not confirmed. Check your connection, URL and token, '
          'then retry with the same time. You can also add a payment in Expenses.\n\n'
          'Field names can vary by iOS version. Check your next payment in Expenses. '
          'Identical payments at the same place within two minutes are treated as one; '
          'add a separate payment manually if needed.',
        ),
        const SizedBox(height: 12),
        if (ingestUrl != null)
          _CopyTile(label: 'Ingest URL', value: ingestUrl)
        else
          const Text('Backend URL unavailable. Check the app configuration.'),
        if (profile != null)
          _CopyTile(
            label: 'Your token (keep private)',
            value: profile.ingestToken,
          ),
        if (profile == null) ...[
          Text(
            data.loading
                ? 'Loading your private token…'
                : 'Your private token is unavailable. Reload your profile.',
          ),
        ],
        TextButton(
          onPressed: data.loading || _regenerating || data.rotatingIngestToken
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
      ],
    );
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
        if (_error != null) Text(_error!),
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

class _CopyTile extends StatelessWidget {
  const _CopyTile({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(label),
    subtitle: SelectableText(value),
    trailing: IconButton(
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
  );
}
