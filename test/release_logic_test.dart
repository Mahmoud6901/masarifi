import 'package:flutter_test/flutter_test.dart';
import 'package:masarifi/format.dart';
import 'package:masarifi/logic.dart';
import 'package:masarifi/models.dart';
import 'package:masarifi/money.dart';

InstallmentPlan _plan({
  required DateTime? next,
  int day = 31,
  int total = 1,
  int paid = 0,
  bool active = true,
  double amount = 12.34,
  String currency = 'SAR',
}) => InstallmentPlan(
  id: 'boundary',
  name: 'Boundary plan',
  provider: 'Bank',
  kind: 'loan',
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
      id: 'boundary',
      amount: amount,
      merchant: 'Shop',
      category: 'other',
      source: 'manual',
      spentAt: date,
      currency: currency,
    );

void main() {
  group('money input boundaries', () {
    test('Arabic digits, Arabic separators and currency precision', () {
      expect(parseAmountInput('١٬٢٣٤٫٥٦', currency: 'SAR'), 1234.56);
      expect(parseAmountInput('١٬٢٣٤٫٥٦٧', currency: 'KWD'), 1234.567);
      expect(parseAmountInput('١٢٫٣٤٥', currency: 'SAR'), isNull);
      expect(parseAmountInput('١٢٫٣٤٥٦', currency: 'KWD'), isNull);
      expect(parseAmountInput('12,345', currency: 'KWD'), 12.345);
      expect(parseAmountInput('12,345', currency: 'SAR'), 12345);
    });

    test(
      'accepts the largest valid minor-unit value and rejects invalid values',
      () {
        expect(isValidMoney(99999999999.99, 'SAR'), isTrue);
        expect(isValidMoney(99999999999.999, 'KWD'), isTrue);
        expect(isValidMoney(100000000000, 'SAR'), isFalse);
        expect(isValidMoney(double.infinity, 'KWD'), isFalse);
        expect(isValidMoney(double.negativeInfinity, 'SAR'), isFalse);
        expect(isValidMoney(-0.01, 'SAR'), isFalse);
        expect(parseAmountInput('100000000000', currency: 'KWD'), isNull);
        expect(parseAmountInput('1e3', currency: 'SAR'), isNull);
      },
    );

    test(
      'round trips exact minor units and formats negative display values',
      () {
        for (final (currency, text, value) in [
          ('SAR', '12,345.67 SAR', 12345.67),
          ('KWD', '12,345.678 KWD', 12345.678),
        ]) {
          expect(money(value, currency), text);
          expect(moneyFromUnits(moneyUnits(value, currency), currency), value);
        }
        expect(money(-1234.5, 'SAR'), '-1,234.50 SAR');
      },
    );

    test('zero and formatted input round trip in every offered currency', () {
      for (final currency in ['SAR', 'AED', 'KWD', 'QAR', 'BHD', 'OMR']) {
        final decimals = currencyDecimals(currency);
        expect(money(0, currency), '0.${'0' * decimals} $currency');
        final maximum = moneyFromUnits(maxMoneyUnits(currency), currency);
        for (final value in [0.0, 1 / currencyScale(currency), maximum]) {
          final numericText = money(value, currency).split(' ').first;
          expect(parseAmountInput(numericText, currency: currency), value);
          expect(
            moneyUnits(value, currency),
            lessThanOrEqualTo(maxMoneyUnits(currency)),
          );
        }
      }
    });
  });

  group('calendar boundaries', () {
    test(
      'month starts retain UTC or local calendar context across a new year',
      () {
        expect(
          monthStart(DateTime.utc(2027, 1, 31, 23)),
          DateTime.utc(2027, 1),
        );
        expect(monthStart(DateTime.utc(2027, 1, 31)).isUtc, isTrue);
        expect(monthStart(DateTime(2027, 1, 31, 23)), DateTime(2027, 1));
        expect(monthStart(DateTime(2027, 1, 31)).isUtc, isFalse);
      },
    );

    test('clamps century leap rules and restores the nominal day', () {
      expect(clampedPaymentDate(2000, 2, 31), DateTime(2000, 2, 29));
      expect(clampedPaymentDate(1900, 2, 31), DateTime(1900, 2, 28));
      expect(clampedPaymentDate(2100, 2, 30), DateTime(2100, 2, 28));
      expect(
        followingPaymentDate(DateTime(2026, 2, 28), 30),
        DateTime(2026, 3, 30),
      );
      expect(
        followingPaymentDate(DateTime(2026, 4, 30), 31),
        DateTime(2026, 5, 31),
      );
      expect(
        followingPaymentDate(DateTime(2026, 12, 31), 30),
        DateTime(2027, 1, 30),
      );
    });

    test(
      'budget month edges are inclusive and preserve same-currency sums',
      () {
        final start = DateTime(2026, 12, 1);
        final asOf = DateTime(2026, 12, 31, 23, 59);
        final summary = computeBudget(
          income: 1000,
          currency: 'SAR',
          now: asOf,
          plans: [
            _plan(next: DateTime(2026, 12, 31), day: 31),
            _plan(next: DateTime(2027, 1, 31), day: 31),
            _plan(next: DateTime(2026, 12, 1), day: 1, currency: 'KWD'),
          ],
          expenses: [
            _expense(1.25, start),
            _expense(2.5, asOf),
            _expense(50, DateTime(2026, 11, 30, 23, 59)),
            _expense(75, DateTime(2027, 1, 1)),
            _expense(90, DateTime(2026, 12, 1), currency: 'KWD'),
          ],
        );
        expect(summary.installmentsDue, 12.34);
        expect(summary.spent, 3.75);
        expect(summary.safeToSpend, 983.91);
        expect(summary.provisional, isFalse);
      },
    );

    test('short month boundaries and remaining balance endpoints', () {
      final p = _plan(
        next: DateTime(2024, 2, 29),
        day: 31,
        total: 4,
        paid: 3,
        amount: 0.007,
        currency: 'KWD',
      );
      expect(nextDueDate(p), DateTime(2024, 2, 29));
      expect(p.remainingCount, 1);
      expect(p.remainingBalance, 0.007);
      expect(_plan(next: null).remainingBalance, 12.34);
      expect(
        _plan(next: null, total: 4, paid: 4, active: false).remainingBalance,
        0,
      );
    });
  });

  test('date format helpers produce stable calendar text', () {
    expect(dayMonth(DateTime(2024, 2, 29)), '29 Feb 2024');
    expect(shortDate(DateTime(2026, 12, 31, 23, 5)), '31 Dec, 23:05');
  });
}
