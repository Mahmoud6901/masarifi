import 'package:flutter/material.dart';

import '../format.dart';
import '../models.dart';
import '../theme.dart';

/// One payment row: where it came from, which card, and any bank refund.
class ExpenseTile extends StatelessWidget {
  const ExpenseTile(this.expense, {this.card, super.key});

  final Expense expense;
  final PaymentCard? card;

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
          ],
        ),
      ),
    );
  }
}
