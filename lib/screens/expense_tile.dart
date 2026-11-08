import 'package:flutter/material.dart';

import '../data.dart';
import '../format.dart';
import '../models.dart';
import '../theme.dart';

/// Asks first, then deletes the payment; a failure leaves it in place.
Future<void> confirmDeleteExpense(
  BuildContext context,
  AppData data,
  Expense expense,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete payment?'),
      content: Text(
        '${expense.merchant} · ${money(expense.amount, expense.currency)}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text('Delete', style: TextStyle(color: ctx.mc.negative)),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  try {
    await data.deleteExpense(expense.id);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not delete. Try again.')),
      );
    }
  }
}

/// One payment row: where it came from, which card, and any bank refund.
class ExpenseTile extends StatelessWidget {
  const ExpenseTile(this.expense, {this.card, this.onDelete, super.key});

  final Expense expense;
  final PaymentCard? card;

  /// Shows a delete button when set.
  final VoidCallback? onDelete;

  IconData get _icon => switch (expense.source) {
    'apple_pay' => Icons.apple,
    'sms' => Icons.sms_outlined,
    _ => Icons.edit_note_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = context.mc;
    final e = expense;
    final details = [
      e.category,
      if (card != null) card!.displayName,
      shortDate(e.spentAt),
    ].join(' · ');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: c.well, shape: BoxShape.circle),
              child: Icon(_icon, size: 20, color: c.ink),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.merchant,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                  Text(
                    details,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                  if (e.isRefunded)
                    Text(
                      e.isFullyRefunded
                          ? 'Refunded'
                          : 'Refunded ${money(e.refundedAmount, e.currency)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: c.growth,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  money(e.netAmount, e.currency),
                  style: theme.textTheme.titleMedium,
                ),
                if (e.isRefunded)
                  Text(
                    money(e.amount, e.currency),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: c.muted,
                      decoration: TextDecoration.lineThrough,
                    ),
                  ),
              ],
            ),
            if (onDelete != null)
              IconButton(
                tooltip: 'Delete payment',
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsetsDirectional.only(start: 8),
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                icon: Icon(Icons.delete_outline, size: 20, color: c.muted),
                onPressed: onDelete,
              ),
          ],
        ),
      ),
    );
  }
}
