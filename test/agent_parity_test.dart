import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:masarifi/logic.dart';
import 'package:masarifi/models.dart';
import 'package:masarifi/money.dart';

void main() {
  final fixtures = jsonDecode(
    File('test/fixtures/agent_finance.json').readAsStringSync(),
  ) as List;
  double amount(dynamic value) => double.parse('$value');
  for (final raw in fixtures) {
    final f = raw as Map<String, dynamic>;
    test('agent/Dart parity: ${f['name']}', () {
      final profile = f['profile'] as Map;
      final currency = profile['currency'] as String;
      final plans = (f['plans'] as List)
          .map(
            (dynamic r) => InstallmentPlan(
              id: r['id'] as String? ?? 'p',
              name: r['name'] as String? ?? 'Plan',
              provider: r['provider'] as String? ?? '',
              kind: r['kind'] as String? ?? 'other',
              monthlyAmount: amount(r['monthly_amount']),
              totalCount: r['total_count'] as int,
              paidCount: r['paid_count'] as int,
              dueDay: r['due_day'] as int,
              active: r['active'] as bool,
              currency: r['currency'] as String,
              nextDueDate: r['next_due_date'] == null
                  ? null
                  : DateTime.parse(r['next_due_date'] as String),
            ),
          )
          .toList();
      final expenses = (f['expenses'] as List)
          .map(
            (dynamic r) => Expense(
              id: 'e',
              amount: amount(r['amount']),
              merchant: 'Shop',
              category: 'other',
              source: 'manual',
              currency: r['currency'] as String,
              spentAt: DateTime.parse(r['spent_at'] as String),
            ),
          )
          .toList();
      final summary = computeBudget(
        income: amount(profile['monthly_income']),
        plans: plans,
        expenses: expenses,
        now: DateTime.parse(f['calendar']['asOf'] as String),
        currency: currency,
      );
      String canonical(double value) =>
          value.toStringAsFixed(currencyDecimals(currency));
      expect({
        'currency': summary.currency,
        'monthly_income': canonical(summary.income),
        'installments_due_this_month': canonical(summary.installmentsDue),
        'spent_this_month': canonical(summary.spent),
        'safe_to_spend_this_month': canonical(summary.safeToSpend),
        'provisional': summary.provisional,
      }, f['expected']);
    });
  }
}
