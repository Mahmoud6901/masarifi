import 'models.dart';
import 'money.dart';

class BudgetSummary {
  const BudgetSummary({
    required this.income,
    required this.installmentsDue,
    required this.spent,
    this.provisional = false,
    this.currency = 'SAR',
  });

  final double income;
  final double installmentsDue;
  final double spent;
  final bool provisional;
  final String currency;

  double get safeToSpend => moneyFromUnits(
    moneyUnits(income, currency) -
        moneyUnits(installmentsDue, currency) -
        moneyUnits(spent, currency),
    currency,
  );
}

/// Reserve all unpaid slots through month-end, capped at the remaining count.
int reservedPaymentCount(InstallmentPlan plan, DateTime now) {
  if (!plan.active || plan.isFinished) return 0;
  final date = nextDueDate(plan);
  if (date == null) return 1; // Explicitly provisional legacy reserve.
  final months = (now.year - date.year) * 12 + now.month - date.month + 1;
  return months.clamp(0, plan.remainingCount);
}

DateTime monthStart(DateTime now) => now.isUtc
    ? DateTime.utc(now.year, now.month)
    : DateTime(now.year, now.month);

/// Month-to-date actual expenses plus all same-currency unpaid slots by month-end.
BudgetSummary computeBudget({
  required double income,
  required List<InstallmentPlan> plans,
  required List<Expense> expenses,
  required DateTime now,
  String currency = 'SAR',
}) {
  final matching = plans.where(
    (p) => p.currency == currency && p.active && !p.isFinished,
  );
  final due = matching.fold<int>(
    0,
    (s, p) =>
        s +
        moneyUnits(p.monthlyAmount, currency) * reservedPaymentCount(p, now),
  );
  final spent = expenses
      .where(
        (e) =>
            e.currency == currency &&
            !e.spentAt.isBefore(monthStart(now)) &&
            !e.spentAt.isAfter(now),
      )
      // Refunds lower what a purchase cost.
      .fold<int>(
        0,
        (s, e) =>
            s +
            moneyUnits(e.amount, currency) -
            moneyUnits(e.refundedAmount, currency),
      );
  return BudgetSummary(
    income: moneyFromUnits(moneyUnits(income, currency), currency),
    installmentsDue: moneyFromUnits(due, currency),
    spent: moneyFromUnits(spent, currency),
    provisional: matching.any((p) => p.nextDueDate == null),
    currency: currency,
  );
}

DateTime clampedPaymentDate(int year, int month, int dueDay) {
  if (dueDay < 1 || dueDay > 31) {
    throw RangeError.range(dueDay, 1, 31, 'dueDay');
  }
  final first = DateTime(year, month);
  if (first.year < 1 || first.year > 9999) {
    throw RangeError('Payment year must be 1-9999.');
  }
  return DateTime(
    year,
    month,
    dueDay.clamp(1, DateTime(year, month + 1, 0).day),
  );
}

DateTime followingPaymentDate(DateTime date, int dueDay) =>
    clampedPaymentDate(date.year, date.month + 1, dueDay);

/// The earliest unpaid date stays overdue until a payment is actually recorded.
DateTime? nextDueDate(InstallmentPlan plan, [DateTime? now]) {
  final date = plan.nextDueDate;
  if (plan.isFinished || date == null) return null;
  return clampedPaymentDate(date.year, date.month, plan.dueDay);
}

/// A plan's current payment can be swiped (paid / not paid) only once its
/// month has arrived: due this month or overdue. Later months stay locked.
bool isPaymentOpen(InstallmentPlan plan, DateTime now) {
  final date = plan.nextDueDate;
  if (!plan.active || plan.isFinished || date == null) return false;
  return !DateTime(
    date.year,
    date.month,
  ).isAfter(DateTime(now.year, now.month));
}

/// Total of the remaining payments across active plans.
double totalRemainingInstallments(
  List<InstallmentPlan> plans, {
  String currency = 'SAR',
}) => moneyFromUnits(
  plans
      .where((p) => p.active && !p.isFinished && p.currency == currency)
      .fold<int>(0, (s, p) => s + moneyUnits(p.remainingBalance, currency)),
  currency,
);

/// Parses user-typed amounts, accepting Arabic-Indic digits and a comma decimal.
double? parseAmountInput(String raw, {String currency = 'SAR'}) {
  var s = raw.trim();
  if (s.isEmpty) return null;
  const arabic = '٠١٢٣٤٥٦٧٨٩';
  for (var i = 0; i < arabic.length; i++) {
    s = s.replaceAll(arabic[i], '$i');
  }
  final hasArabicGrouping = s.contains('٬');
  s = s.replaceAll('٫', '.').replaceAll('٬', ',');
  if (!hasArabicGrouping &&
      RegExp('^\\d+,\\d{1,${currencyDecimals(currency)}}\$').hasMatch(s)) {
    s = s.replaceAll(',', '.');
  } else {
    if (!RegExp(r'^(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d*)?$|^\.\d+$')
        .hasMatch(s)) {
      return null;
    }
    s = s.replaceAll(',', '');
  }
  if (s.contains('.') &&
      s.split('.').last.length > currencyDecimals(currency)) {
    return null;
  }
  final v = double.tryParse(s);
  if (v == null || !isValidMoney(v, currency)) return null;
  return v;
}

bool isValidExpenseAmount(double amount, {String currency = 'SAR'}) =>
    isValidMoney(amount, currency);
