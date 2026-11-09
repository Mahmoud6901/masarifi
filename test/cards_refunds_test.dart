import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:masarifi/screens/expense_tile.dart';
import 'package:masarifi/theme.dart';
import 'package:masarifi/logic.dart';
import 'package:masarifi/models.dart';
import 'package:masarifi/screens/settings_screen.dart';

Expense _expense(double amount, {double refunded = 0, DateTime? at}) => Expense(
  id: 'e$amount$refunded',
  amount: amount,
  merchant: 'Shop',
  category: 'other',
  source: 'sms',
  spentAt: at ?? DateTime(2026, 11, 5),
  refundedAmount: refunded,
);

void main() {
  test('refunds lower month-to-date spending', () {
    final b = computeBudget(
      income: 1000,
      plans: const [],
      expenses: [_expense(100, refunded: 10), _expense(45.5, refunded: 45.5)],
      now: DateTime(2026, 11, 8),
    );
    expect(b.spent, 90);
    expect(b.safeToSpend, 910);
  });

  test('net amount and refund flags', () {
    final partial = _expense(100, refunded: 10.25);
    expect(partial.isRefunded, isTrue);
    expect(partial.isFullyRefunded, isFalse);
    expect(partial.netAmount, 89.75);
    final full = _expense(45.5, refunded: 45.5);
    expect(full.isFullyRefunded, isTrue);
    expect(full.netAmount, 0);
    expect(_expense(5).isRefunded, isFalse);
  });

  test('expense rows read refunds and cards, old rows default to none', () {
    final row = {
      'id': 'x',
      'amount': 50,
      'merchant': 'Jarir',
      'category': 'shopping',
      'source': 'sms',
      'spent_at': '2026-11-08T09:00:00Z',
      'currency': 'SAR',
      'refunded_amount': 20,
      'card_id': 'c1',
    };
    final e = Expense.fromJson(row);
    expect(e.refundedAmount, 20);
    expect(e.cardId, 'c1');
    final old = Expense.fromJson(
      {...row}
        ..remove('refunded_amount')
        ..remove('card_id'),
    );
    expect(old.refundedAmount, 0);
    expect(old.cardId, isNull);
  });

  test('card names prefer nickname, then Wallet name, then bank digits', () {
    expect(
      PaymentCard(
        id: '1',
        walletName: 'Cashback Signature',
        last4: '1226',
        nickname: 'Daily',
      ).displayName,
      'Daily',
    );
    expect(
      PaymentCard(
        id: '1',
        walletName: 'Cashback Signature',
        last4: '1226',
      ).displayName,
      'Cashback Signature ··1226',
    );
    expect(
      PaymentCard(id: '1', walletName: 'SAB Cash Back').displayName,
      'SAB Cash Back',
    );
    expect(
      PaymentCard(id: '1', bank: 'Al Rajhi', last4: '0298').displayName,
      'Al Rajhi ··0298',
    );
    expect(PaymentCard(id: '1', last4: '0298').displayName, '··0298');
    expect(
      PaymentCard.fromJson({
        'id': '9',
        'wallet_name': null,
        'bank': 'SAB',
        'last4': '4421',
        'nickname': null,
      }).displayName,
      'SAB ··4421',
    );
  });

  test('Siri prompt carries the URL, header and both body fields', () {
    final p = siriPrompt('https://x.supabase.co/functions/v1/ingest', 'a' * 48);
    for (final part in [
      'https://x.supabase.co/functions/v1/ingest',
      'method POST',
      'x-ingest-token = ${'a' * 48}',
      'text = Shortcut Input',
      'ISO 8601',
    ]) {
      expect(p, contains(part));
    }
    expect(p, isNot(contains('amount =')));
  });

  test('snackbar actions like Undo are white on the dark theme', () {
    expect(
      masarifiTheme(Brightness.dark).snackBarTheme.actionTextColor,
      const Color(0xFFFFFFFF),
    );
    // Light mode keeps a dark Undo on its white bar.
    expect(
      masarifiTheme(Brightness.light).snackBarTheme.actionTextColor,
      const Color(0xFF0B0B0B),
    );
  });

  testWidgets('a payment card shows a delete button only when asked', (
    tester,
  ) async {
    var deletes = 0;
    Future<void> show({VoidCallback? onDelete}) => tester.pumpWidget(
      MaterialApp(
        theme: masarifiTheme(Brightness.dark),
        home: Scaffold(
          body: ExpenseTile(_expense(10, refunded: 2), onDelete: onDelete),
        ),
      ),
    );
    await show(onDelete: () => deletes++);
    await tester.tap(find.byTooltip('Delete payment'));
    expect(deletes, 1);
    await show();
    expect(find.byTooltip('Delete payment'), findsNothing);
  });
}
