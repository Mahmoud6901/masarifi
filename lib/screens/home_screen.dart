import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data.dart';
import '../format.dart';
import '../models.dart';
import '../theme.dart';
import 'assistant_screen.dart';
import 'expenses_screen.dart';
import 'installments_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  static const _pages = <Widget>[
    _OverviewTab(),
    ExpensesScreen(),
    InstallmentsScreen(),
    AssistantScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: IndexedStack(index: _tab, children: _pages),
      ),
      bottomNavigationBar: _Dock(
        index: _tab,
        onSelect: (i) => setState(() => _tab = i),
      ),
    );
  }
}

class _DockItem {
  const _DockItem(this.icon, this.label);
  final IconData icon;
  final String label;
}

/// Floating pill dock. The active item is marked by a 2px signal-blue
/// underline; everything else stays quiet.
class _Dock extends StatelessWidget {
  const _Dock({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  static const _items = [
    _DockItem(Icons.home_outlined, 'Overview'),
    _DockItem(Icons.receipt_long_outlined, 'Expenses'),
    _DockItem(Icons.event_repeat_outlined, 'Installments'),
    _DockItem(Icons.auto_awesome_outlined, 'Assistant'),
    _DockItem(Icons.settings_outlined, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.mc;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(20, 6, 20, 10),
        child: Container(
          height: 64,
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(99),
            border: Border.all(color: c.hairline),
            boxShadow: [
              BoxShadow(
                color: Color(
                  Theme.of(context).brightness == Brightness.dark
                      ? 0x80000000
                      : 0x1F000000,
                ),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              for (var i = 0; i < _items.length; i++)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: i == index,
                    label: _items[i].label,
                    child: ExcludeSemantics(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onSelect(i),
                        child: SizedBox(
                          height: 64,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                _items[i].icon,
                                size: 24,
                                color: i == index ? c.ink : c.muted,
                              ),
                              const SizedBox(height: 5),
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                curve: Curves.easeOutCubic,
                                height: 2,
                                width: i == index ? 18 : 0,
                                color: c.signal,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OverviewTab extends StatelessWidget {
  const _OverviewTab();

  @override
  Widget build(BuildContext context) {
    final data = context.watch<AppData>();
    final b = data.budget;
    final cur = b.currency;
    final theme = Theme.of(context);
    final c = context.mc;
    final negative = b.safeToSpend < 0;

    return RefreshIndicator(
      onRefresh: data.refresh,
      color: c.ink,
      backgroundColor: c.card,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsetsDirectional.fromSTEB(20, 24, 20, 24),
        children: [
          if (data.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                data.error!,
                style: theme.textTheme.bodyMedium?.copyWith(color: c.negative),
              ),
            ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Safe to spend this month',
                    style: theme.textTheme.labelMedium,
                  ),
                  const SizedBox(height: 10),
                  if (data.budgetReady)
                    _Amount(
                      full: money(b.safeToSpend, cur),
                      currency: cur,
                      color: negative ? c.negative : c.ink,
                    )
                  else
                    Text(
                      'Budget unavailable',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        color: c.muted,
                      ),
                    ),
                  if (data.loading)
                    const Padding(
                      padding: EdgeInsets.only(top: 14),
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  if (data.budgetReady && data.budgetStale)
                    _Note('Previous budget · reload needed', c.warm),
                  if (data.budgetAsOf case final date?)
                    _Note(
                      'As of ${date.toLocal()} · $cur only; no currency conversion',
                      c.muted,
                    ),
                  if (b.provisional)
                    _Note(
                      'Provisional: confirm legacy plan schedules. One monthly payment is reserved for each unset schedule.',
                      c.warm,
                    ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      onPressed: data.loading ? null : data.refresh,
                      child: const Text('Reload budget'),
                    ),
                  ),
                  if (data.budgetReady && b.income == 0)
                    const _Note(
                      'Set your monthly income in Settings to see this.',
                      null,
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (data.budgetReady)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    _StatRow('Monthly income', money(b.income, cur)),
                    const SizedBox(height: 14),
                    _StatRow(
                      'Due by month-end (includes overdue)',
                      money(b.installmentsDue, cur),
                      valueColor: b.installmentsDue > 0 ? c.warm : null,
                    ),
                    const SizedBox(height: 14),
                    _StatRow('Spent month-to-date', money(b.spent, cur)),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 36),
          Text('Recent payments', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 14),
          if (data.loading && data.expenses.isEmpty)
            const Center(child: CircularProgressIndicator())
          else if (data.expenses.isEmpty)
            Text(
              'No payments yet. Set up Apple Pay capture in Settings.',
              style: theme.textTheme.bodyMedium?.copyWith(color: c.muted),
            )
          else
            for (final e in data.expenses.take(5)) ...[
              _PaymentTile(e),
              const SizedBox(height: 8),
            ],
        ],
      ),
    );
  }
}

/// The hero figure: compressed tracking, the currency set small beside it.
class _Amount extends StatelessWidget {
  const _Amount({
    required this.full,
    required this.currency,
    required this.color,
  });

  final String full;
  final String currency;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.mc;
    final hasSuffix = full.endsWith(' $currency');
    final number = hasSuffix
        ? full.substring(0, full.length - currency.length - 1)
        : full;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: number,
            style: theme.textTheme.displayLarge?.copyWith(color: color),
          ),
          if (hasSuffix)
            TextSpan(
              text: ' $currency',
              style: theme.textTheme.titleMedium?.copyWith(color: c.muted),
            ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text, this.color);

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
    ),
  );
}

class _StatRow extends StatelessWidget {
  const _StatRow(this.label, this.value, {this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(color: context.mc.muted),
          ),
        ),
        const SizedBox(width: 16),
        Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(color: valueColor),
        ),
      ],
    );
  }
}

class _PaymentTile extends StatelessWidget {
  const _PaymentTile(this.expense);

  final Expense expense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.mc;
    final applePay = expense.source == 'apple_pay';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: c.well, shape: BoxShape.circle),
              child: Icon(
                applePay ? Icons.apple : Icons.edit_note_outlined,
                size: 20,
                color: c.ink,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    expense.merchant,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                  Text(
                    '${expense.category} · ${shortDate(expense.spentAt)}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              money(expense.amount, expense.currency),
              style: theme.textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}
