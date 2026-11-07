import 'package:flutter_test/flutter_test.dart';
import 'package:masarifi/format.dart';
import 'package:masarifi/logic.dart';
import 'package:masarifi/models.dart';
import 'package:masarifi/money.dart';

InstallmentPlan _plan({
  DateTime? next,
  int day = 31,
  int total = 12,
  int paid = 0,
  bool active = true,
  double amount = 100,
  String currency = 'SAR',
}) => InstallmentPlan(
  id: 'p',
  name: 'Phone',
  provider: '',
  kind: 'bnpl',
  monthlyAmount: amount,
  totalCount: total,
  paidCount: paid,
  dueDay: day,
  active: active,
  currency: currency,
  nextDueDate: next,
);

Expense _expense(double amount, DateTime date, {String currency = 'SAR'}) =>
    Expense(
      id: 'e',
      amount: amount,
      merchant: 'Shop',
      category: 'other',
      source: 'manual',
      spentAt: date,
      currency: currency,
    );

void main() {
  test('month clamping restores nominal day through leap and short months', () {
    expect(clampedPaymentDate(2026, 2, 31), DateTime(2026, 2, 28));
    expect(clampedPaymentDate(2024, 2, 31), DateTime(2024, 2, 29));
    expect(clampedPaymentDate(2026, 4, 31), DateTime(2026, 4, 30));
    expect(
      followingPaymentDate(DateTime(2026, 2, 28), 31),
      DateTime(2026, 3, 31),
    );
    expect(
      followingPaymentDate(DateTime(2026, 12, 31), 31),
      DateTime(2027, 1, 31),
    );
    expect(() => clampedPaymentDate(2026, 1, 32), throwsRangeError);
  });

  test('next date is earliest unpaid, not rolled forward with today', () {
    final now = DateTime(2026, 11, 15);
    expect(
      nextDueDate(_plan(next: DateTime(2026, 11, 5), day: 5), now),
      DateTime(2026, 11, 5),
    );
    expect(
      nextDueDate(_plan(next: DateTime(2026, 12, 31)), now),
      DateTime(2026, 12, 31),
    );
    expect(nextDueDate(_plan(), now), isNull);
    expect(
      nextDueDate(_plan(next: DateTime(2026, 11, 30), paid: 12), now),
      isNull,
    );
  });

  test('overdue slots through month-end are capped by remaining count', () {
    final now = DateTime(2026, 11, 15);
    expect(reservedPaymentCount(_plan(next: DateTime(2026, 9, 30)), now), 3);
    expect(
      reservedPaymentCount(_plan(next: DateTime(2026, 9, 30), total: 2), now),
      2,
    );
    expect(reservedPaymentCount(_plan(next: DateTime(2026, 12, 31)), now), 0);
    expect(reservedPaymentCount(_plan(next: DateTime(2026, 11, 30)), now), 1);
    expect(reservedPaymentCount(_plan(active: false), now), 0);
    expect(reservedPaymentCount(_plan(paid: 12), now), 0);
    expect(reservedPaymentCount(_plan(), now), 1);
  });

  test(
    'budget includes complete MTD same-currency spending and overdue reserves',
    () {
      final now = DateTime(2026, 11, 15, 12);
      final b = computeBudget(
        income: 5000,
        now: now,
        plans: [
          _plan(next: DateTime(2026, 9, 30)),
          _plan(next: DateTime(2026, 12, 31)),
          _plan(next: DateTime(2026, 11, 30), currency: 'KWD'),
          _plan(active: false),
          _plan(paid: 12),
        ],
        expenses: [
          _expense(20, DateTime(2026, 11, 1)),
          _expense(30, now),
          _expense(999, DateTime(2026, 10, 31)),
          _expense(999, DateTime(2026, 11, 16)),
          _expense(999, DateTime(2026, 11, 2), currency: 'KWD'),
        ],
      );
      expect(b.installmentsDue, 300);
      expect(b.spent, 50);
      expect(b.safeToSpend, 4650);
      expect(b.provisional, isFalse);
    },
  );

  test(
    'legacy unset dates reserve one payment and mark budget provisional',
    () {
      final b = computeBudget(
        income: 50,
        plans: [_plan()],
        expenses: [],
        now: DateTime(2026, 11, 15),
      );
      expect(b.installmentsDue, 100);
      expect(b.safeToSpend, -50);
      expect(b.provisional, isTrue);
    },
  );

  test('fils arithmetic and remaining balance use minor units', () {
    final plan = _plan(currency: 'KWD', amount: 0.001, total: 5, paid: 2);
    expect(plan.remainingCount, 3);
    expect(plan.remainingBalance, 0.003);
    final b = computeBudget(
      income: 1.255,
      currency: 'KWD',
      plans: [plan],
      expenses: [
        _expense(0.001, DateTime(2026, 11, 1), currency: 'KWD'),
        _expense(0.002, DateTime(2026, 11, 2), currency: 'KWD'),
      ],
      now: DateTime(2026, 11, 15),
    );
    expect(b.spent, 0.003);
    expect(b.safeToSpend, 1.251);
    expect(totalRemainingInstallments([plan], currency: 'KWD'), 0.003);
    expect(totalRemainingInstallments([plan], currency: 'SAR'), 0);
  });

  test('currency-aware parsing accepts genuine fils without changing grouping marks', () {
    expect(parseAmountInput('١٫٢٥٥', currency: 'KWD'), 1.255);
    expect(parseAmountInput('1.255', currency: 'SAR'), isNull);
    expect(parseAmountInput('25,000', currency: 'OMR'), 25);
    expect(parseAmountInput('25,000', currency: 'SAR'), 25000);
    expect(parseAmountInput('١٬٢٥٠', currency: 'BHD'), 1250);
    expect(parseAmountInput('1.2555', currency: 'BHD'), isNull);
    expect(isValidMoney(1.255, 'BHD'), isTrue);
    expect(isValidMoney(1.255, 'SAR'), isFalse);
    expect(isValidMoney(99999999999.999, 'KWD'), isTrue);
    expect(isValidMoney(100000000000, 'KWD'), isFalse);
    expect(isValidMoney(double.nan, 'SAR'), isFalse);
  });

  test(
    'display and model decoding retain currency and date-only schedules',
    () {
      expect(money(1.255, 'KWD'), '1.255 KWD');
      expect(money(1.25, 'SAR'), '1.25 SAR');
      final plan = InstallmentPlan.fromJson({
        'id': 'p',
        'name': 'Phone',
        'provider': '',
        'kind': 'card',
        'monthly_amount': 1.255,
        'total_amount': 5.020,
        'total_count': 4,
        'paid_count': 1,
        'due_day': 31,
        'next_due_date': '2026-02-28',
        'active': true,
        'currency': 'BHD',
      });
      expect(plan.currency, 'BHD');
      expect(plan.nextDueDate, DateTime(2026, 2, 28));
      expect(plan.totalAmount, 5.02);
      expect(plan.remainingBalance, 3.765);
      final expense = Expense.fromJson({
        'id': 'e',
        'amount': 1.255,
        'merchant': 'Shop',
        'category': 'other',
        'source': 'manual',
        'spent_at': '2026-11-01T12:00:00Z',
        'currency': 'OMR',
      });
      expect(expense.currency, 'OMR');
    },
  );
}
