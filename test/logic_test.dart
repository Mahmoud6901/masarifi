import 'package:flutter_test/flutter_test.dart';
import 'package:masarifi/logic.dart';
import 'package:masarifi/models.dart';

InstallmentPlan plan({
  double monthly = 100,
  int total = 6,
  int paid = 0,
  int dueDay = 10,
  bool active = true,
  DateTime? next,
}) => InstallmentPlan(
  id: 'p',
  name: 'Phone',
  provider: 'Tabby',
  kind: 'bnpl',
  monthlyAmount: monthly,
  totalCount: total,
  paidCount: paid,
  dueDay: dueDay,
  active: active,
  nextDueDate: next,
);

Expense expense(double amount, DateTime at) => Expense(
  id: 'e',
  amount: amount,
  merchant: 'Cafe',
  category: 'food',
  source: 'apple_pay',
  spentAt: at,
);

void main() {
  group('computeBudget', () {
    final now = DateTime(2026, 11, 15);

    test('subtracts installments and this month spending from income', () {
      final b = computeBudget(
        income: 5000,
        plans: [plan(monthly: 300), plan(monthly: 200)],
        expenses: [
          expense(100, DateTime(2026, 11, 2)),
          expense(50.5, DateTime(2026, 11, 9)),
        ],
        now: now,
      );
      expect(b.installmentsDue, 500);
      expect(b.spent, 150.5);
      expect(b.safeToSpend, 4349.5);
    });

    test('ignores last month expenses, finished and inactive plans', () {
      final b = computeBudget(
        income: 1000,
        plans: [plan(paid: 6), plan(active: false), plan(monthly: 50)],
        expenses: [expense(999, DateTime(2026, 10, 30))],
        now: now,
      );
      expect(b.installmentsDue, 50);
      expect(b.spent, 0);
      expect(b.safeToSpend, 950);
    });

    test('can go negative when overspent', () {
      final b = computeBudget(
        income: 100,
        plans: [plan(monthly: 150)],
        expenses: const [],
        now: now,
      );
      expect(b.safeToSpend, -50);
    });
  });

  group('installments', () {
    test('remaining balance and count', () {
      final p = plan(monthly: 250, total: 12, paid: 4);
      expect(p.remainingCount, 8);
      expect(p.remainingBalance, 2000);
      expect(p.isFinished, false);
    });

    test('nextDueDate uses the confirmed next unpaid date', () {
      expect(
        nextDueDate(
          plan(dueDay: 20, next: DateTime(2026, 11, 20)),
          DateTime(2026, 11, 15),
        ),
        DateTime(2026, 11, 20),
      );
    });

    test('nextDueDate is today when due today', () {
      expect(
        nextDueDate(
          plan(dueDay: 15, next: DateTime(2026, 11, 15)),
          DateTime(2026, 11, 15, 18),
        ),
        DateTime(2026, 11, 15),
      );
    });

    test('nextDueDate stays overdue and legacy dates stay unknown', () {
      expect(
        nextDueDate(
          plan(dueDay: 5, next: DateTime(2026, 12, 5)),
          DateTime(2026, 12, 15),
        ),
        DateTime(2026, 12, 5),
      );
      expect(nextDueDate(plan(), DateTime(2026, 12, 15)), isNull);
    });

    test('totalRemainingInstallments sums only active unfinished plans', () {
      final total = totalRemainingInstallments([
        plan(monthly: 100, total: 3, paid: 1),
        plan(paid: 6),
        plan(active: false),
      ]);
      expect(total, 200);
    });
  });

  group('parseAmountInput', () {
    test('plain and decimal values', () {
      expect(parseAmountInput('25'), 25);
      expect(parseAmountInput(' 25.50 '), 25.5);
    });

    test('thousands separators and comma decimals', () {
      expect(parseAmountInput('1,250.75'), 1250.75);
      expect(parseAmountInput('25,5'), 25.5);
    });

    test('Arabic-Indic digits', () {
      expect(parseAmountInput('٢٥٫٥٠'), 25.5);
    });

    test('rejects empty, negative and garbage', () {
      expect(parseAmountInput(''), isNull);
      expect(parseAmountInput('-5'), isNull);
      expect(parseAmountInput('abc'), isNull);
    });
  });
}
