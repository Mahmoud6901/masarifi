import 'money.dart';

class Expense {
  Expense({
    required this.id,
    required this.amount,
    required this.merchant,
    required this.category,
    required this.source,
    required this.spentAt,
    this.currency = 'SAR',
    this.refundedAmount = 0,
    this.cardId,
  });

  final String id;
  final double amount;
  final String merchant;
  final String category;
  final String source;
  final DateTime spentAt;
  final String currency;

  /// Money the bank returned for this purchase (bank SMS refunds).
  final double refundedAmount;
  final String? cardId;

  bool get isRefunded => refundedAmount > 0;
  bool get isFullyRefunded => refundedAmount > 0 && refundedAmount >= amount;

  /// What the purchase really cost after refunds, in exact minor units.
  double get netAmount => moneyFromUnits(
    moneyUnits(amount, currency) - moneyUnits(refundedAmount, currency),
    currency,
  );

  factory Expense.fromJson(Map<String, dynamic> j) => Expense(
    id: j['id'] as String,
    amount: (j['amount'] as num).toDouble(),
    merchant: j['merchant'] as String,
    category: j['category'] as String,
    source: j['source'] as String,
    spentAt: DateTime.parse(j['spent_at'] as String).toLocal(),
    currency: j['currency'] as String,
    refundedAmount: (j['refunded_amount'] as num?)?.toDouble() ?? 0,
    cardId: j['card_id'] as String?,
  );
}

/// A payment card, created automatically from Wallet taps and bank SMS.
class PaymentCard {
  PaymentCard({
    required this.id,
    this.walletName,
    this.bank,
    this.last4,
    this.nickname,
  });

  final String id;
  final String? walletName;
  final String? bank;
  final String? last4;
  final String? nickname;

  /// Nickname first, then Wallet's name, then "Bank ··1234".
  String get displayName {
    if (nickname case final n? when n.trim().isNotEmpty) return n;
    final digits = last4 == null ? '' : '··$last4';
    if (walletName case final w? when w.trim().isNotEmpty) {
      return digits.isEmpty ? w : '$w $digits';
    }
    return [
      bank,
      digits,
    ].whereType<String>().where((s) => s.isNotEmpty).join(' ');
  }

  factory PaymentCard.fromJson(Map<String, dynamic> j) => PaymentCard(
    id: j['id'] as String,
    walletName: j['wallet_name'] as String?,
    bank: j['bank'] as String?,
    last4: j['last4'] as String?,
    nickname: j['nickname'] as String?,
  );
}

class InstallmentPlan {
  InstallmentPlan({
    required this.id,
    required this.name,
    required this.provider,
    required this.kind,
    required this.monthlyAmount,
    required this.totalCount,
    required this.paidCount,
    required this.dueDay,
    required this.active,
    this.currency = 'SAR',
    this.nextDueDate,
    this.storedTotalAmount,
  });

  final String id;
  final String name;
  final String provider;
  final String kind;
  final double monthlyAmount;
  final int totalCount;
  final int paidCount;
  final int dueDay;
  final bool active;
  final String currency;
  final DateTime? nextDueDate;
  final double? storedTotalAmount;

  int get remainingCount => (totalCount - paidCount).clamp(0, totalCount);
  double get totalAmount =>
      storedTotalAmount ??
      moneyFromUnits(
        moneyUnits(monthlyAmount, currency) * totalCount,
        currency,
      );
  double get remainingBalance => moneyFromUnits(
    moneyUnits(monthlyAmount, currency) * remainingCount,
    currency,
  );
  bool get isFinished => remainingCount <= 0;

  factory InstallmentPlan.fromJson(Map<String, dynamic> j) => InstallmentPlan(
    id: j['id'] as String,
    name: j['name'] as String,
    provider: (j['provider'] as String?) ?? '',
    kind: j['kind'] as String,
    monthlyAmount: (j['monthly_amount'] as num).toDouble(),
    totalCount: j['total_count'] as int,
    paidCount: j['paid_count'] as int,
    dueDay: j['due_day'] as int,
    active: j['active'] as bool,
    currency: j['currency'] as String,
    storedTotalAmount: (j['total_amount'] as num).toDouble(),
    nextDueDate: j['next_due_date'] == null
        ? null
        : DateTime.parse(j['next_due_date'] as String),
  );
}

class Profile {
  Profile({
    required this.currency,
    required this.monthlyIncome,
    required this.ingestToken,
  });

  final String currency;
  final double monthlyIncome;
  final String ingestToken;

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
    currency: j['currency'] as String,
    monthlyIncome: (j['monthly_income'] as num).toDouble(),
    ingestToken: j['ingest_token'] as String,
  );
}

const expenseCategories = [
  'food',
  'groceries',
  'transport',
  'health',
  'bills',
  'shopping',
  'entertainment',
  'other',
];

const installmentKinds = ['loan', 'bnpl', 'card', 'other'];
