import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data.dart';
import '../format.dart';
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
        child: IndexedStack(index: _tab, children: _pages),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            label: 'Overview',
          ),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            label: 'Expenses',
          ),
          NavigationDestination(
            icon: Icon(Icons.event_repeat_outlined),
            label: 'Installments',
          ),
          NavigationDestination(
            icon: Icon(Icons.auto_awesome_outlined),
            label: 'Assistant',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            label: 'Settings',
          ),
        ],
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
    final negative = b.safeToSpend < 0;

    return RefreshIndicator(
      onRefresh: data.refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          if (data.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                data.error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          Card(
            color: negative
                ? theme.colorScheme.errorContainer
                : theme.colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Safe to spend this month',
                    style: theme.textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    data.budgetReady
                        ? money(b.safeToSpend, cur)
                        : 'Budget unavailable',
                    style: theme.textTheme.headlineMedium,
                  ),
                  if (data.loading) const LinearProgressIndicator(),
                  if (data.budgetReady && data.budgetStale)
                    const Text('Previous budget · reload needed'),
                  if (data.budgetAsOf case final date?)
                    Text(
                      'As of ${date.toLocal()} · $cur only; no currency conversion',
                    ),
                  if (b.provisional)
                    const Text(
                      'Provisional: confirm legacy plan schedules. One monthly payment is reserved for each unset schedule.',
                    ),
                  TextButton(
                    onPressed: data.loading ? null : data.refresh,
                    child: const Text('Reload budget'),
                  ),
                  if (data.budgetReady && b.income == 0)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'Set your monthly income in Settings to see this.',
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (data.budgetReady) ...[
            _StatRow('Monthly income', money(b.income, cur)),
            _StatRow(
              'Due by month-end (includes overdue)',
              money(b.installmentsDue, cur),
            ),
            _StatRow('Spent month-to-date', money(b.spent, cur)),
          ],
          const SizedBox(height: 16),
          Text('Recent payments', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (data.loading && data.expenses.isEmpty)
            const Center(child: CircularProgressIndicator())
          else if (data.expenses.isEmpty)
            const Text('No payments yet. Set up Apple Pay capture in Settings.')
          else
            for (final e in data.expenses.take(5))
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(e.merchant),
                subtitle: Text('${e.category} · ${shortDate(e.spentAt)}'),
                trailing: Text(money(e.amount, e.currency)),
              ),
        ],
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(child: Text(label)),
        const SizedBox(width: 12),
        Text(value),
      ],
    ),
  );
}
