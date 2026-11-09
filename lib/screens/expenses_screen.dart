import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data.dart';
import '../format.dart';
import '../logic.dart';
import '../models.dart';
import '../money.dart';
import '../theme.dart';
import 'expense_tile.dart';
import 'profile_required.dart';

class ExpensesScreen extends StatelessWidget {
  const ExpensesScreen({super.key});

  /// Calendar months on this page, the current one included. Older payments
  /// stay saved; they are only hidden here.
  static const monthsShown = 5;

  @override
  Widget build(BuildContext context) {
    final data = context.watch<AppData>();
    final theme = Theme.of(context);
    final c = context.mc;
    final now = data.now();
    final current = DateTime(now.year, now.month);
    final oldest = DateTime(now.year, now.month - (monthsShown - 1));
    // data.expenses is newest first, so each month keeps that order.
    final byMonth = <DateTime, List<Expense>>{};
    for (final e in data.expenses) {
      if (e.spentAt.isBefore(oldest)) continue;
      (byMonth[DateTime(e.spentAt.year, e.spentAt.month)] ??= []).add(e);
    }
    final months = {current, ...byMonth.keys}.toList()
      ..sort((a, b) => b.compareTo(a));

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addExpense(context),
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
      body: RefreshIndicator(
        onRefresh: data.refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsetsDirectional.fromSTEB(20, 24, 20, 100),
          children: [
            Text('Last five months', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 14),
            if (data.loading && data.expenses.isEmpty)
              const Center(child: CircularProgressIndicator())
            else if (byMonth.isEmpty)
              Text(
                'No expenses in the last five months.',
                style: theme.textTheme.bodyMedium?.copyWith(color: c.muted),
              )
            else
              for (final month in months)
                _MonthSection(
                  key: ValueKey('month-${month.year}-${month.month}'),
                  month: month,
                  expenses: byMonth[month] ?? const [],
                  data: data,
                  initiallyOpen: month == current,
                ),
          ],
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

/// One calendar month: a tappable header with the month's total after refunds
/// and where it went, then that month's payments when open.
class _MonthSection extends StatefulWidget {
  const _MonthSection({
    required this.month,
    required this.expenses,
    required this.data,
    required this.initiallyOpen,
    super.key,
  });

  final DateTime month;
  final List<Expense> expenses;
  final AppData data;
  final bool initiallyOpen;

  @override
  State<_MonthSection> createState() => _MonthSectionState();
}

class _MonthSectionState extends State<_MonthSection> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.mc;
    final data = widget.data;
    final cur = data.currency;
    final perCategory = <String, int>{};
    var total = 0;
    for (final e in widget.expenses) {
      if (e.currency != cur) continue;
      final units = moneyUnits(e.netAmount, cur);
      total += units;
      perCategory.update(e.category, (v) => v + units, ifAbsent: () => units);
    }
    final categories = perCategory.entries.where((x) => x.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final count = widget.expenses.length;
    final summary = categories.isNotEmpty
        ? categories
              .map(
                (x) =>
                    '${x.key} ${compactAmount(moneyFromUnits(x.value, cur))}',
              )
              .join(' · ')
        : count == 0
        ? 'No payments'
        : '$count ${count == 1 ? 'payment' : 'payments'}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: _open,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => setState(() => _open = !_open),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            monthYear(widget.month),
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            summary,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: c.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      money(moneyFromUnits(total, cur), cur),
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      _open ? Icons.expand_less : Icons.expand_more,
                      color: c.muted,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_open) ...[
            const SizedBox(height: 6),
            for (final e in widget.expenses)
              Padding(
                key: ValueKey(e.id),
                padding: const EdgeInsets.only(bottom: 8),
                child: ExpenseTile(
                  e,
                  card: data.cardFor(e.cardId),
                  onDelete: () => confirmDeleteExpense(context, data, e),
                ),
              ),
          ],
        ],
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
