import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data.dart';
import '../format.dart';
import '../logic.dart';
import '../models.dart';
import '../theme.dart';
import 'plan_swipe_card.dart';
import 'profile_required.dart';

class InstallmentsScreen extends StatelessWidget {
  const InstallmentsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final data = context.watch<AppData>();
    final active = data.plans.where((p) => p.active && !p.isFinished).toList()
      ..sort((a, b) {
        final left = nextDueDate(a);
        final right = nextDueDate(b);
        if (left == null) return right == null ? a.id.compareTo(b.id) : 1;
        return right == null ? -1 : left.compareTo(right);
      });
    final currencies = active.map((p) => p.currency).toSet().toList()..sort();
    final theme = Theme.of(context);
    final c = context.mc;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _form(context, data),
        icon: const Icon(Icons.add),
        label: const Text('Add plan'),
      ),
      body: RefreshIndicator(
        onRefresh: data.refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsetsDirectional.fromSTEB(20, 24, 20, 100),
          children: [
            if (data.error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  data.error!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: c.negative,
                  ),
                ),
              ),
            if (data.loading)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (currencies.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Total remaining to pay',
                        style: theme.textTheme.labelMedium,
                      ),
                      for (final currency in currencies) ...[
                        const SizedBox(height: 10),
                        Text(
                          money(
                            totalRemainingInstallments(
                              data.plans,
                              currency: currency,
                            ),
                            currency,
                          ),
                          style: theme.textTheme.displaySmall,
                        ),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        'Across ${active.length} active ${active.length == 1 ? 'plan' : 'plans'}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 10),
            Text(
              'Swipe right when paid, left when not paid. This updates the plan only; it doesn\'t add an expense.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            if (active.isEmpty)
              Text(
                'No active installment plans.',
                style: theme.textTheme.bodyMedium?.copyWith(color: c.muted),
              ),
            for (final p in active) ...[
              _plan(context, data, p),
              const SizedBox(height: 12),
            ],
            for (final p in data.plans.where(
              (p) => !p.active || p.isFinished,
            )) ...[_card(context, data, p), const SizedBox(height: 12)],
          ],
        ),
      ),
    );
  }

  /// A scheduled plan is a swipe card: right = paid, left = not paid. Only the
  /// payment due this month (or overdue) can be decided; later ones stay
  /// locked until their month starts.
  Widget _plan(BuildContext context, AppData data, InstallmentPlan p) {
    final date = nextDueDate(p);
    if (date == null) return _card(context, data, p);
    return PlanSwipeCard(
      key: ValueKey('swipe-${p.id}'),
      enabled: isPaymentOpen(p, data.now()) && !data.planBusy(p.id),
      peek: p.remainingCount > 1
          ? _UpNext(plan: p, month: followingPaymentDate(date, p.dueDay))
          : null,
      onDecide: (paid) => _swipe(context, data, p, paid),
      builder: (context, decide) => _card(context, data, p, decide: decide),
    );
  }

  Widget _card(
    BuildContext context,
    AppData data,
    InstallmentPlan p, {
    void Function(bool paid)? decide,
  }) {
    final theme = Theme.of(context);
    final c = context.mc;
    final date = nextDueDate(p);
    final now = data.now();
    final today = DateTime(now.year, now.month, now.day);
    final busy = data.planBusy(p.id);
    final live = p.active && !p.isFinished;
    final open = decide != null && isPaymentOpen(p, now);
    final status = p.isFinished
        ? 'Finished'
        : !p.active
        ? 'Inactive'
        : date == null
        ? 'Schedule needed · one provisional monthly reserve'
        : '${date.isBefore(today) ? 'Overdue' : 'Next unpaid'}: ${dayMonth(date)}';
    // Overdue, unscheduled, or due within a week reads as the one warm signal.
    final soon = live && (date == null || date.difference(today).inDays <= 7);
    final subtitle = p.provider.isEmpty ? p.kind : '${p.provider} · ${p.kind}';
    final progress = p.totalCount <= 0
        ? 0.0
        : (p.paidCount / p.totalCount).clamp(0.0, 1.0);
    return Card(
      key: ValueKey(p.id),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.name, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(subtitle, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Edit plan',
                  visualDensity: VisualDensity.compact,
                  onPressed: busy ? null : () => _form(context, data, plan: p),
                  icon: Icon(Icons.edit_outlined, size: 20, color: c.muted),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: money(p.monthlyAmount, p.currency),
                          style: theme.textTheme.titleLarge,
                        ),
                        TextSpan(
                          text: ' / month',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
                Text(
                  '${p.remainingCount} left',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: Text(
                    'Remaining to pay',
                    style: theme.textTheme.bodyMedium?.copyWith(color: c.muted),
                  ),
                ),
                Text(
                  money(p.remainingBalance, p.currency),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: live ? c.ink : c.muted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: SizedBox(
                height: 4,
                child: Stack(
                  children: [
                    Positioned.fill(child: ColoredBox(color: c.well)),
                    Positioned.fill(
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: FractionallySizedBox(
                          widthFactor: progress,
                          heightFactor: 1,
                          child: ColoredBox(color: c.ink),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: c.well,
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Text(
                    status,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: soon ? c.warm : c.muted,
                    ),
                  ),
                ),
              ],
            ),
            if (busy)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            const SizedBox(height: 12),
            if (live && date != null && decide != null) ...[
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: busy || !open ? null : () => decide(true),
                      icon: const Icon(Icons.check, size: 18),
                      label: const Text('Paid'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: busy || !open ? null : () => decide(false),
                      child: const Text('Not paid'),
                    ),
                  ),
                ],
              ),
              if (!open)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Opens on ${dayMonth(DateTime(date.year, date.month))}',
                    style: theme.textTheme.bodySmall?.copyWith(color: c.muted),
                  ),
                ),
              const SizedBox(height: 4),
            ],
            Row(
              children: [
                if (live && date == null)
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => _form(context, data, plan: p),
                    child: const Text('Confirm schedule'),
                  ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => showDialog<void>(
                          context: context,
                          builder: (_) =>
                              _DeletePlanDialog(data: data, plan: p),
                        ),
                  child: const Text('Delete'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Saves one swipe and offers Undo for a few seconds. Returns true when the
  /// plan moved on, so the card shows the next month.
  Future<bool> _swipe(
    BuildContext context,
    AppData data,
    InstallmentPlan p,
    bool paid,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final month = monthYear(p.nextDueDate!);
    try {
      final InstallmentPlan? after;
      if (paid) {
        if (!await data.markPlanPaid(p)) {
          messenger.showSnackBar(
            const SnackBar(
              content: Text(
                'This plan changed. Check the updated payment date.',
              ),
            ),
          );
          return false;
        }
        after = data.plans.where((x) => x.id == p.id).firstOrNull;
      } else {
        after = await data.deferPlan(p);
      }
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 5),
            persist: false,
            content: Text(
              paid ? '$month marked paid' : '$month moved to the end',
            ),
            action: after == null
                ? null
                : SnackBarAction(
                    label: 'Undo',
                    onPressed: () => _undo(messenger, data, p, after!),
                  ),
          ),
        );
      return true;
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Could not update. Reload and try again.'),
        ),
      );
      return false;
    }
  }

  Future<void> _undo(
    ScaffoldMessengerState messenger,
    AppData data,
    InstallmentPlan before,
    InstallmentPlan after,
  ) async {
    try {
      await data.restorePlan(before, after);
    } catch (_) {
      if (messenger.mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Could not undo. Reload the plan.')),
        );
      }
    }
  }

  Future<void> _form(
    BuildContext context,
    AppData data, {
    InstallmentPlan? plan,
  }) => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(
          leading: const BackButton(),
          // Back always works, including while the profile is still loading.
        ),
        body: SafeArea(
          child: ProfileRequired(
            data: data,
            builder: (_) => _PlanForm(data: data, plan: plan),
          ),
        ),
      ),
    ),
  );
}

/// The card waiting behind a plan: the month that comes after this one.
class _UpNext extends StatelessWidget {
  const _UpNext({required this.plan, required this.month});

  final InstallmentPlan plan;
  final DateTime month;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.mc;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.well,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.hairline),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Up next',
              style: theme.textTheme.labelMedium?.copyWith(color: c.muted),
            ),
            const SizedBox(height: 6),
            Text(monthYear(month), style: theme.textTheme.titleLarge),
            const SizedBox(height: 2),
            Text(
              money(plan.monthlyAmount, plan.currency),
              style: theme.textTheme.bodySmall?.copyWith(color: c.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanForm extends StatefulWidget {
  const _PlanForm({required this.data, this.plan});
  final AppData data;
  final InstallmentPlan? plan;
  @override
  State<_PlanForm> createState() => _PlanFormState();
}

class _PlanFormState extends State<_PlanForm> {
  final _name = TextEditingController();
  final _provider = TextEditingController();
  final _monthly = TextEditingController();
  final _count = TextEditingController();
  final _paid = TextEditingController(text: '0');
  final _day = TextEditingController(text: '1');
  final _month = TextEditingController();
  String _kind = 'bnpl';
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    final plan = widget.plan;
    if (plan != null) {
      _name.text = plan.name;
      _provider.text = plan.provider;
      _kind = installmentKinds.contains(plan.kind) ? plan.kind : 'other';
      _monthly.text = plan.monthlyAmount == plan.monthlyAmount.roundToDouble()
          ? plan.monthlyAmount.toStringAsFixed(0)
          : '${plan.monthlyAmount}';
      _count.text = '${plan.totalCount}';
      _paid.text = '${plan.paidCount}';
      _day.text = '${plan.dueDay}';
      final date = plan.nextDueDate;
      if (date != null) {
        _month.text =
            '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}';
      }
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _provider, _monthly, _count, _paid, _day, _month]) {
      c.dispose();
    }
    super.dispose();
  }

  DateTime? get _selectedMonth {
    final value = _month.text.trim();
    if (!RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(value)) return null;
    final year = int.parse(value.substring(0, 4));
    return year < 1 ? null : DateTime(year, int.parse(value.substring(5)));
  }

  Future<void> _save() async {
    if (_busy) return;
    final day = int.tryParse(_day.text.trim());
    final month = _selectedMonth;
    final amount = parseAmountInput(
      _monthly.text,
      currency: widget.plan?.currency ?? widget.data.currency,
    );
    final count = int.tryParse(_count.text.trim());
    final paid = int.tryParse(_paid.text.trim());
    if (day == null ||
        day < 1 ||
        day > 31 ||
        _name.text.trim().isEmpty ||
        amount == null ||
        count == null ||
        count < 1 ||
        paid == null ||
        paid < 0 ||
        paid > count ||
        (paid < count && month == null)) {
      setState(
        () => _error = paid != null && count != null && paid > count
            ? 'Payments already made (count) cannot exceed the total number of payments.'
            : 'Check the fields, due day 1–31 and next unpaid month (YYYY-MM).',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.plan case final plan?) {
        await widget.data.updatePlan(
          plan,
          name: _name.text,
          provider: _provider.text,
          kind: _kind,
          monthlyAmount: amount,
          totalCount: count,
          paidCount: paid,
          dueDay: day,
          nextPaymentMonth: month,
        );
      } else {
        await widget.data.addPlan(
          name: _name.text,
          provider: _provider.text,
          kind: _kind,
          monthlyAmount: amount,
          totalCount: count,
          paidCount: paid,
          dueDay: day,
          nextPaymentMonth: month,
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not save. Check the amounts and schedule, then retry. If the plan changed, reload it.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(TextEditingController c, String label, {bool number = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          enabled: !_busy,
          onChanged: (_) => setState(() => _error = null),
          keyboardType: number
              ? const TextInputType.numberWithOptions(decimal: true)
              : TextInputType.text,
          decoration: InputDecoration(labelText: label),
        ),
      );
  @override
  Widget build(BuildContext context) {
    final month = _selectedMonth;
    final day = int.tryParse(_day.text.trim());
    final preview = month != null && day != null && day >= 1 && day <= 31
        ? clampedPaymentDate(month.year, month.month, day)
        : null;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                widget.plan == null
                    ? 'Add installment plan (${widget.data.currency})'
                    : 'Edit installment plan',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
          ),
          ...[
            _field(_name, 'What is it for?'),
            _field(_provider, 'Provider (bank, Tabby, ...)'),
            DropdownButtonFormField<String>(
              initialValue: _kind,
              items: [
                for (final k in installmentKinds)
                  DropdownMenuItem(value: k, child: Text(k)),
              ],
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _kind = v ?? 'other'),
              decoration: const InputDecoration(labelText: 'Type'),
            ),
            const SizedBox(height: 12),
            _field(_monthly, 'Monthly amount', number: true),
            _field(_count, 'Total number of payments', number: true),
            _field(
              _paid,
              'Payments already made (count, e.g. 6)',
              number: true,
            ),
          ],
          _field(_day, 'Due day of month (1–31)', number: true),
          _field(_month, 'Next unpaid month (YYYY-MM)'),
          Text(
            'Choose the earliest unpaid month, even if overdue. Short months use their last day. Completed plans need no next month.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (preview != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Next unpaid: ${dayMonth(preview)}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          if (_error != null)
            Text(_error!, style: TextStyle(color: context.mc.negative)),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(_busy ? 'Saving…' : 'Save'),
          ),
        ],
      ),
    );
  }
}

class _DeletePlanDialog extends StatefulWidget {
  const _DeletePlanDialog({required this.data, required this.plan});
  final AppData data;
  final InstallmentPlan plan;
  @override
  State<_DeletePlanDialog> createState() => _DeletePlanDialogState();
}

class _DeletePlanDialogState extends State<_DeletePlanDialog> {
  bool _busy = false;
  String? _error;
  Future<void> _delete() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.data.deletePlan(widget.plan.id);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not delete. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Delete "${widget.plan.name}"?'),
    content: _error == null ? null : Text(_error!),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _busy ? null : _delete,
        child: Text(_busy ? 'Deleting…' : 'Delete'),
      ),
    ],
  );
}
