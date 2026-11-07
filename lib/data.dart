import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'logic.dart';
import 'models.dart';
import 'money.dart';

/// Loads and mutates the signed-in user's data. Row-level security in the
/// database restricts every query to the current user.
class AppData extends ChangeNotifier {
  AppData(this._db, {DateTime Function()? now})
    : _userId = _db.auth.currentUser?.id,
      _now = now ?? DateTime.now {
    _authSubscription = _db.auth.onAuthStateChange.listen(
      (state) {
        if (state.session?.user.id != _userId) _invalidate();
      },
      onError: (Object error, StackTrace stackTrace) {
        // GoTrue already logs refresh errors. A retryable failure retains the
        // session; only an identity-change event should invalidate its data.
      },
    );
  }

  final SupabaseClient _db;
  final String? _userId;
  final DateTime Function() _now;
  late final StreamSubscription<AuthState> _authSubscription;
  bool _disposed = false;
  bool _invalidated = false;
  int _refreshVersion = 0;
  final Set<String> _pendingPlans = {};
  bool _addingPlan = false;
  BudgetSummary? _budgetSnapshot;
  DateTime? budgetAsOf;
  bool budgetStale = true;
  bool planBusy(String id) => _pendingPlans.contains(id);
  bool get budgetReady => _budgetSnapshot != null;

  Profile? profile;
  List<Expense> expenses = [];
  List<InstallmentPlan> plans = [];
  bool loading = false;
  bool rotatingIngestToken = false;
  String? error;

  String get currency => profile?.currency ?? 'SAR';
  String get accountEmail =>
      _isCurrentUser ? _db.auth.currentUser?.email ?? '' : '';

  bool get _isCurrentUser =>
      !_disposed &&
      !_invalidated &&
      _userId != null &&
      _db.auth.currentUser?.id == _userId;

  void _invalidate() {
    if (_disposed || _invalidated) return;
    _invalidated = true;
    _refreshVersion++;
    profile = null;
    expenses = [];
    plans = [];
    _budgetSnapshot = null;
    budgetAsOf = null;
    budgetStale = true;
    loading = false;
    error = null;
    notifyListeners();
  }

  String _requireUser() {
    if (!_isCurrentUser) {
      _invalidate();
      throw StateError('Sign in again to access your data.');
    }
    return _userId!;
  }

  Profile _requireProfile() {
    final current = profile;
    if (current == null) {
      throw StateError('Load your profile before adding a payment or plan.');
    }
    return current;
  }

  @override
  void dispose() {
    _disposed = true;
    _refreshVersion++;
    unawaited(_authSubscription.cancel());
    super.dispose();
  }

  BudgetSummary get budget =>
      _budgetSnapshot ??
      BudgetSummary(
        income: 0,
        installmentsDue: 0,
        spent: 0,
        currency: currency,
      );

  void _publishMutation() {
    _refreshVersion++;
    loading = false;
    budgetStale = true;
    notifyListeners();
  }

  Future<void> refresh() async {
    if (!_isCurrentUser) {
      _invalidate();
      return;
    }
    final version = ++_refreshVersion;
    final userId = _userId!;
    final snapshotTime = _now();
    bool isCurrent() => _isCurrentUser && version == _refreshVersion;
    loading = true;
    budgetStale = true;
    error = null;
    notifyListeners();
    try {
      final p = await _db.from('profiles').select().eq('id', userId).single();
      if (!isCurrent()) return;
      final profileResult = Profile.fromJson(p);
      final e = await _db
          .from('expenses')
          .select()
          .eq('user_id', userId)
          .order('spent_at', ascending: false)
          .order('id', ascending: false)
          .limit(500);
      if (!isCurrent()) return;
      final planRows = <Map<String, dynamic>>[];
      int? planCount;
      while (true) {
        final page = await _db
            .from('installment_plans')
            .select()
            .eq('user_id', userId)
            .order('created_at', ascending: false)
            .order('id', ascending: false)
            .range(planRows.length, planRows.length + 499)
            .count(CountOption.exact);
        if (!isCurrent()) return;
        if (planCount != null && planCount != page.count) {
          throw StateError('Plans changed while loading.');
        }
        planCount = page.count;
        planRows.addAll(page.data);
        if (planRows.length == planCount) break;
        if (page.data.isEmpty || planRows.length > planCount) {
          throw StateError('Incomplete plan page.');
        }
      }
      final budgetRows = <Map<String, dynamic>>[];
      int? expenseCount;
      while (true) {
        final page = await _db
            .from('expenses')
            .select()
            .eq('user_id', userId)
            .eq('currency', profileResult.currency)
            .gte('spent_at', monthStart(snapshotTime).toUtc().toIso8601String())
            .lte('spent_at', snapshotTime.toUtc().toIso8601String())
            .order('spent_at', ascending: false)
            .order('id', ascending: false)
            .range(budgetRows.length, budgetRows.length + 499)
            .count(CountOption.exact);
        if (!isCurrent()) return;
        if (expenseCount != null && expenseCount != page.count) {
          throw StateError('Expenses changed while loading.');
        }
        expenseCount = page.count;
        budgetRows.addAll(page.data);
        if (budgetRows.length == expenseCount) break;
        if (page.data.isEmpty || budgetRows.length > expenseCount) {
          throw StateError('Incomplete expense page.');
        }
      }
      final expenseResults = e.map(Expense.fromJson).toList();
      final planResults = planRows.map(InstallmentPlan.fromJson).toList();
      final summary = computeBudget(
        income: profileResult.monthlyIncome,
        plans: planResults,
        expenses: budgetRows.map(Expense.fromJson).toList(),
        now: snapshotTime,
        currency: profileResult.currency,
      );
      profile = profileResult;
      expenses = expenseResults;
      plans = planResults;
      _budgetSnapshot = summary;
      budgetAsOf = snapshotTime;
      budgetStale = false;
    } catch (_) {
      if (isCurrent()) error = 'Could not load your data. Pull to retry.';
    } finally {
      if (isCurrent()) {
        loading = false;
        notifyListeners();
      } else if (!_disposed && _db.auth.currentUser?.id != _userId) {
        _invalidate();
      }
    }
  }

  Future<void> addExpense({
    required double amount,
    required String merchant,
    required String category,
  }) async {
    final userId = _requireUser();
    final currency = _requireProfile().currency;
    final place = merchant.trim();
    if (!isValidExpenseAmount(amount, currency: currency) ||
        place.isEmpty ||
        place.runes.length > 200 ||
        !expenseCategories.contains(category)) {
      throw ArgumentError(
        'Enter a place, category and an amount with up to ${currencyDecimals(currency)} decimal places.',
      );
    }
    final row = await _db
        .from('expenses')
        .insert({
          'user_id': userId,
          'amount': amount,
          'currency': currency,
          'merchant': place,
          'category': category,
          'source': 'manual',
          // Use the same clock as the month-to-date budget bounds.
          'spent_at': _now().toUtc().toIso8601String(),
        })
        .select()
        .single();
    _requireUser();
    final expense = Expense.fromJson(row);
    expenses = [expense, ...expenses.where((e) => e.id != expense.id)];
    _publishMutation();
    await refresh();
  }

  Future<void> deleteExpense(String id) async {
    final userId = _requireUser();
    await _db.from('expenses').delete().eq('id', id).eq('user_id', userId);
    _requireUser();
    expenses = expenses.where((e) => e.id != id).toList();
    _publishMutation();
    await refresh();
  }

  Future<String> rotateIngestToken() async {
    _requireUser();
    if (profile == null) {
      throw StateError('Load your profile before regenerating the token.');
    }
    if (rotatingIngestToken) {
      throw StateError('Token regeneration is already in progress.');
    }
    rotatingIngestToken = true;
    notifyListeners();
    try {
      final result = await _db.rpc('rotate_ingest_token');
      _requireUser();
      if (result is! String || !RegExp(r'^[0-9a-f]{48}$').hasMatch(result)) {
        throw StateError(
          'Unexpected token response. Reload your profile to check the token.',
        );
      }
      final current = profile!;
      _refreshVersion++;
      loading = false;
      profile = Profile(
        currency: current.currency,
        monthlyIncome: current.monthlyIncome,
        ingestToken: result,
      );
      notifyListeners();
      return result;
    } finally {
      rotatingIngestToken = false;
      if (_isCurrentUser) notifyListeners();
    }
  }

  Future<void> addPlan({
    required String name,
    required String provider,
    required String kind,
    required double monthlyAmount,
    required int totalCount,
    required int paidCount,
    required int dueDay,
    DateTime? nextPaymentMonth,
  }) async {
    final userId = _requireUser();
    final currency = _requireProfile().currency;
    final unitAmount = isValidMoney(monthlyAmount, currency)
        ? moneyUnits(monthlyAmount, currency)
        : -1;
    if (name.trim().isEmpty ||
        name.trim().runes.length > 200 ||
        provider.trim().runes.length > 200 ||
        !installmentKinds.contains(kind) ||
        unitAmount < 0 ||
        totalCount < 1 ||
        totalCount > 2147483647 ||
        paidCount < 0 ||
        paidCount > totalCount ||
        dueDay < 1 ||
        dueDay > 31 ||
        (unitAmount > 0 &&
            totalCount > maxMoneyUnits(currency) ~/ unitAmount) ||
        (paidCount < totalCount && nextPaymentMonth == null)) {
      throw ArgumentError(
        'Check plan fields, currency precision, counts and the next payment month.',
      );
    }
    final date = paidCount < totalCount
        ? clampedPaymentDate(
            nextPaymentMonth!.year,
            nextPaymentMonth.month,
            dueDay,
          )
        : null;
    if (_addingPlan) {
      throw StateError('A plan is already being created.');
    }
    _addingPlan = true;
    try {
      final row = await _db
          .from('installment_plans')
          .insert({
            'user_id': userId,
            'name': name.trim(),
            'provider': provider.trim(),
            'kind': kind,
            'monthly_amount': monthlyAmount,
            'total_amount': moneyFromUnits(unitAmount * totalCount, currency),
            'total_count': totalCount,
            'paid_count': paidCount,
            'due_day': dueDay,
            'currency': currency,
            'next_due_date': date == null ? null : _dateText(date),
            'active': paidCount < totalCount,
          })
          .select()
          .single();
      _requireUser();
      final result = InstallmentPlan.fromJson(row);
      plans = [result, ...plans.where((p) => p.id != result.id)];
      _publishMutation();
      await refresh();
    } finally {
      _addingPlan = false;
    }
  }

  String _dateText(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  void _beginPlan(String id) {
    _requireUser();
    if (!_pendingPlans.add(id)) {
      throw StateError('This plan already has a request in progress.');
    }
    notifyListeners();
  }

  void _endPlan(String id) {
    _pendingPlans.remove(id);
    if (_isCurrentUser) notifyListeners();
  }

  void _cachePlan(Map<String, dynamic> row, String id) {
    _requireUser();
    if (row['id'] != id || row['user_id'] != _userId) {
      throw StateError('Unexpected plan response.');
    }
    final result = InstallmentPlan.fromJson(row);
    plans = [result, ...plans.where((p) => p.id != id)];
    _publishMutation();
  }

  Future<bool> markPlanPaid(InstallmentPlan plan) async {
    _requireUser();
    if (plan.isFinished || !plan.active) return false;
    if (plan.nextDueDate == null) {
      throw StateError('Confirm the next unpaid payment date first.');
    }
    _beginPlan(plan.id);
    try {
      final response = await _db.rpc(
        'mark_installment_paid',
        params: {
          'p_plan_id': plan.id,
          'p_expected_paid_count': plan.paidCount,
          'p_expected_next_due_date': _dateText(plan.nextDueDate!),
        },
      );
      _requireUser();
      if (response is! Map<String, dynamic> ||
          response['applied'] is! bool ||
          response['plan'] is! Map<String, dynamic>) {
        throw StateError('Unexpected payment response.');
      }
      _cachePlan(response['plan'] as Map<String, dynamic>, plan.id);
      await refresh();
      return response['applied'] as bool;
    } finally {
      _endPlan(plan.id);
    }
  }

  Future<void> setPlanSchedule(
    InstallmentPlan plan, {
    required int dueDay,
    required DateTime month,
  }) async {
    final userId = _requireUser();
    if (plan.isFinished || !plan.active) {
      throw StateError('This plan is not active.');
    }
    final date = clampedPaymentDate(month.year, month.month, dueDay);
    _beginPlan(plan.id);
    try {
      var query = _db
          .from('installment_plans')
          .update({'due_day': dueDay, 'next_due_date': _dateText(date)})
          .eq('id', plan.id)
          .eq('user_id', userId)
          .eq('paid_count', plan.paidCount)
          .eq('active', true);
      query = plan.nextDueDate == null
          ? query.isFilter('next_due_date', null)
          : query.eq('next_due_date', _dateText(plan.nextDueDate!));
      final row = await query.select().single();
      _cachePlan(row, plan.id);
      await refresh();
    } finally {
      _endPlan(plan.id);
    }
  }

  /// Full edit of an existing plan. Guarded like [setPlanSchedule]: the write
  /// only lands if the plan still has the paid count and date we displayed.
  Future<void> updatePlan(
    InstallmentPlan plan, {
    required String name,
    required String provider,
    required String kind,
    required double monthlyAmount,
    required int totalCount,
    required int paidCount,
    required int dueDay,
    DateTime? nextPaymentMonth,
  }) async {
    final userId = _requireUser();
    final currency = plan.currency;
    final unitAmount = isValidMoney(monthlyAmount, currency)
        ? moneyUnits(monthlyAmount, currency)
        : -1;
    if (name.trim().isEmpty ||
        name.trim().runes.length > 200 ||
        provider.trim().runes.length > 200 ||
        !installmentKinds.contains(kind) ||
        unitAmount < 0 ||
        totalCount < 1 ||
        totalCount > 2147483647 ||
        paidCount < 0 ||
        paidCount > totalCount ||
        dueDay < 1 ||
        dueDay > 31 ||
        (unitAmount > 0 &&
            totalCount > maxMoneyUnits(currency) ~/ unitAmount) ||
        (paidCount < totalCount && nextPaymentMonth == null)) {
      throw ArgumentError(
        'Check plan fields, currency precision, counts and the next payment month.',
      );
    }
    final finished = paidCount >= totalCount;
    final date = finished
        ? null
        : clampedPaymentDate(
            nextPaymentMonth!.year,
            nextPaymentMonth.month,
            dueDay,
          );
    _beginPlan(plan.id);
    try {
      var query = _db
          .from('installment_plans')
          .update({
            'name': name.trim(),
            'provider': provider.trim(),
            'kind': kind,
            'monthly_amount': monthlyAmount,
            'total_amount': moneyFromUnits(unitAmount * totalCount, currency),
            'total_count': totalCount,
            'paid_count': paidCount,
            'due_day': dueDay,
            'next_due_date': date == null ? null : _dateText(date),
            // A finished plan must be inactive; a plan that was finished and
            // now has payments left becomes active again.
            'active': finished ? false : (plan.active || plan.isFinished),
          })
          .eq('id', plan.id)
          .eq('user_id', userId)
          .eq('paid_count', plan.paidCount);
      query = plan.nextDueDate == null
          ? query.isFilter('next_due_date', null)
          : query.eq('next_due_date', _dateText(plan.nextDueDate!));
      final row = await query.select().single();
      _cachePlan(row, plan.id);
      await refresh();
    } finally {
      _endPlan(plan.id);
    }
  }

  Future<void> deletePlan(String id) async {
    final userId = _requireUser();
    _beginPlan(id);
    try {
      await _db
          .from('installment_plans')
          .delete()
          .eq('id', id)
          .eq('user_id', userId);
      _requireUser();
      plans = plans.where((p) => p.id != id).toList();
      _publishMutation();
      await refresh();
    } finally {
      _endPlan(id);
    }
  }

  Future<void> updateProfile({String? currency, double? income}) async {
    final userId = _requireUser();
    final nextCurrency = currency ?? this.currency;
    final nextIncome = income ?? profile?.monthlyIncome ?? 0;
    if (!RegExp(r'^[A-Z]{3}$').hasMatch(nextCurrency) ||
        !isValidMoney(nextIncome, nextCurrency)) {
      throw ArgumentError(
        'Income must fit the selected currency precision without rounding.',
      );
    }
    await _db
        .from('profiles')
        .update({'currency': ?currency, 'monthly_income': ?income})
        .eq('id', userId);
    _requireUser();
    final current = profile;
    if (current != null) {
      profile = Profile(
        currency: nextCurrency,
        monthlyIncome: nextIncome,
        ingestToken: current.ingestToken,
      );
      _publishMutation();
    }
    await refresh();
  }

  /// Asks the AI agent. History is a list of {role, content} maps.
  Future<String> askAgent(List<Map<String, String>> history) async {
    _requireUser();
    final capturedAt = _now();
    final recent = history.length > 20
        ? history.sublist(history.length - 20)
        : history;
    final messages = recent.map((message) {
      final content = message['content'] ?? '';
      var end = content.length > 4000 ? 4000 : content.length;
      if (end < content.length &&
          end > 0 &&
          content.codeUnitAt(end - 1) >= 0xD800 &&
          content.codeUnitAt(end - 1) <= 0xDBFF) {
        end--;
      }
      return {
        'role': message['role'] ?? '',
        'content': content.substring(0, end),
      };
    }).toList();
    final res = await _db.functions.invoke(
      'agent',
      body: {
        'messages': messages,
        'calendar': {
          'asOf': capturedAt.toUtc().toIso8601String(),
          'monthStart': monthStart(capturedAt).toUtc().toIso8601String(),
          'year': capturedAt.year,
          'month': capturedAt.month,
        },
      },
    );
    _requireUser();
    final data = res.data;
    if (data is Map && data['reply'] is String) return data['reply'] as String;
    throw Exception('Unexpected agent response');
  }

  Future<void> signOut() async {
    _requireUser();
    await _db.auth.signOut();
  }
}
