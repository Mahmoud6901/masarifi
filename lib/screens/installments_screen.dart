import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data.dart';
import '../format.dart';
import '../logic.dart';
import '../models.dart';
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
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
          children: [
            if (data.error != null) Text(data.error!),
            if (data.loading) const LinearProgressIndicator(),
            for (final currency in currencies)
              Text(
                'Remaining to pay: ${money(totalRemainingInstallments(data.plans, currency: currency), currency)}',
              ),
            const SizedBox(height: 12),
            const Text(
              'Mark paid updates the plan only. Capture the cash payment or add it in Expenses so spending reflects it.',
            ),
            if (active.isEmpty) const Text('No active installment plans.'),
            for (final p in active) _card(context, data, p),
            for (final p in data.plans.where((p) => !p.active || p.isFinished))
              _card(context, data, p),
          ],
        ),
      ),
    );
  }

  Widget _card(BuildContext context, AppData data, InstallmentPlan p) {
    final date = nextDueDate(p);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final busy = data.planBusy(p.id);
    final live = p.active && !p.isFinished;
    final status = p.isFinished
        ? 'Finished'
        : !p.active
        ? 'Inactive'
        : date == null
        ? 'Schedule needed · one provisional monthly reserve'
        : '${date.isBefore(today) ? 'Overdue' : 'Next unpaid'}: ${dayMonth(date)}';
    return Card(
      key: ValueKey(p.id),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${p.name}${p.provider.isEmpty ? '' : ' · ${p.provider}'}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              '${money(p.monthlyAmount, p.currency)} / month · ${p.remainingCount} left',
            ),
            Text('Remaining: ${money(p.remainingBalance, p.currency)}'),
            Text(status),
            if (busy) const LinearProgressIndicator(),
            Wrap(
              spacing: 8,
              children: [
                if (live && date != null)
                  FilledButton.tonal(
                    onPressed: busy ? null : () => _pay(context, data, p),
                    child: Text('Mark ${dayMonth(date)} paid'),
                  ),
                if (live)
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => _form(context, data, plan: p),
                    child: Text(
                      date == null ? 'Confirm schedule' : 'Edit schedule',
                    ),
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

  Future<void> _pay(
    BuildContext context,
    AppData data,
    InstallmentPlan p,
  ) async {
    try {
      final applied = await data.markPlanPaid(p);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              applied
                  ? 'Payment marked paid.'
                  : 'This plan changed. Check the updated payment date.',
            ),
          ),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not mark paid. Reload the plan before retrying.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _form(
    BuildContext context,
    AppData data, {
    InstallmentPlan? plan,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => ProfileRequired(
      data: data,
      builder: (_) => _PlanForm(data: data, plan: plan),
    ),
  );
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
      currency: widget.data.currency,
    );
    final count = int.tryParse(_count.text.trim());
    final paid = int.tryParse(_paid.text.trim());
    if (day == null ||
        day < 1 ||
        day > 31 ||
        (widget.plan != null && month == null) ||
        (widget.plan == null &&
            (_name.text.trim().isEmpty ||
                amount == null ||
                count == null ||
                count < 1 ||
                paid == null ||
                paid < 0 ||
                paid > count ||
                (paid < count && month == null)))) {
      setState(
        () => _error = 'Check the fields, due day 1–31 and next unpaid month (YYYY-MM). Paid cannot exceed total.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (widget.plan case final plan?) {
        await widget.data.setPlanSchedule(plan, dueDay: day, month: month!);
      } else {
        await widget.data.addPlan(
          name: _name.text,
          provider: _provider.text,
          kind: _kind,
          monthlyAmount: amount!,
          totalCount: count!,
          paidCount: paid!,
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
      TextField(
        controller: c,
        enabled: !_busy,
        onChanged: (_) => setState(() {}),
        keyboardType: number
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.text,
        decoration: InputDecoration(labelText: label),
      );
  @override
  Widget build(BuildContext context) {
    final month = _selectedMonth;
    final day = int.tryParse(_day.text.trim());
    final preview = month != null && day != null && day >= 1 && day <= 31
        ? clampedPaymentDate(month.year, month.month, day)
        : null;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.plan == null
                ? 'Add installment plan (${widget.data.currency})'
                : 'Confirm earliest unpaid payment',
          ),
          if (widget.plan == null) ...[
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
            _field(_monthly, 'Monthly amount', number: true),
            _field(_count, 'Total number of payments', number: true),
            _field(_paid, 'Already paid', number: true),
          ],
          _field(_day, 'Due day of month (1–31)', number: true),
          _field(_month, 'Next unpaid month (YYYY-MM)'),
          const Text(
            'Choose the earliest unpaid month, even if overdue. Short months use their last day. Completed plans need no next month.',
          ),
          if (preview != null) Text('Next unpaid: ${dayMonth(preview)}'),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
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
