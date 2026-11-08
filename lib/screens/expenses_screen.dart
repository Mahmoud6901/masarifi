import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data.dart';
import '../logic.dart';
import '../models.dart';
import '../money.dart';
import '../theme.dart';
import 'expense_tile.dart';
import 'profile_required.dart';

class ExpensesScreen extends StatelessWidget {
  const ExpensesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final data = context.watch<AppData>();
    final theme = Theme.of(context);
    final c = context.mc;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addExpense(context),
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
      body: RefreshIndicator(
        onRefresh: data.refresh,
        child: data.expenses.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsetsDirectional.fromSTEB(20, 24, 20, 24),
                children: [
                  Text(
                    'No expenses yet.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: c.muted),
                  ),
                ],
              )
            : ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsetsDirectional.fromSTEB(20, 24, 20, 100),
                itemCount: data.expenses.length,
                itemBuilder: (context, i) {
                  final e = data.expenses[i];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Dismissible(
                      key: ValueKey(e.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        decoration: BoxDecoration(
                          color: c.negative,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        alignment: AlignmentDirectional.centerEnd,
                        padding: const EdgeInsetsDirectional.only(end: 20),
                        child: Icon(Icons.delete_outline, color: c.canvas),
                      ),
                      confirmDismiss: (_) async {
                        try {
                          await data.deleteExpense(e.id);
                          return true;
                        } catch (_) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Could not delete. Try again.'),
                              ),
                            );
                          }
                          return false;
                        }
                      },
                      child: ExpenseTile(
                        e,
                        card: data.cardFor(e.cardId),
                        onDelete: () => confirmDeleteExpense(context, data, e),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }

  Future<void> _addExpense(BuildContext context) async {
    final data = context.read<AppData>();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ProfileRequired(
        data: data,
        builder: (_) => _AddExpenseSheet(data: data),
      ),
    );
  }
}

class _AddExpenseSheet extends StatefulWidget {
  const _AddExpenseSheet({required this.data});

  final AppData data;

  @override
  State<_AddExpenseSheet> createState() => _AddExpenseSheetState();
}

class _AddExpenseSheetState extends State<_AddExpenseSheet> {
  final _amount = TextEditingController();
  final _merchant = TextEditingController();
  String _category = 'other';
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _merchant.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    final amount = parseAmountInput(
      _amount.text,
      currency: widget.data.currency,
    );
    final merchant = _merchant.text.trim();
    if (amount == null ||
        !isValidExpenseAmount(amount, currency: widget.data.currency) ||
        merchant.isEmpty ||
        merchant.runes.length > 200) {
      setState(
        () => _error =
            'Enter a place (up to 200 characters) and an amount with up to ${currencyDecimals(widget.data.currency)} decimals.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.data.addExpense(
        amount: amount,
        merchant: merchant,
        category: _category,
      );
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not save. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        8,
        20,
        24 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _merchant,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: 'Place'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _amount,
            enabled: !_busy,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Amount'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _category,
            items: [
              for (final c in expenseCategories)
                DropdownMenuItem(value: c, child: Text(c)),
            ],
            onChanged: _busy
                ? null
                : (v) => setState(() => _category = v ?? 'other'),
            decoration: const InputDecoration(labelText: 'Category'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(color: context.mc.negative),
              ),
            ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(_busy ? 'Saving…' : 'Save'),
          ),
        ],
      ),
    ),
  );
}
