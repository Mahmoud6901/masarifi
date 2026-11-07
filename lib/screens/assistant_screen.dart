import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data.dart';
import '../logic.dart';
import 'profile_required.dart';

/// Chat with the AI agent, plus a "find a place" form that builds a query for it.
class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key});

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<Map<String, String>> _history = [];
  bool _busy = false;
  bool _placeSheetOpen = false;
  String? _requestError;
  List<Map<String, String>>? _retryHistory;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send(String text) async {
    final t = text.trim();
    if (t.isEmpty || _busy) return;
    final data = context.read<AppData>();
    final retrying = _retryHistory != null;
    setState(() {
      if (retrying && _history.isNotEmpty && _history.last['role'] == 'user') {
        _history.removeLast();
      }
      _history.add({'role': 'user', 'content': t});
      _retryHistory = List.of(_history);
      _requestError = null;
      _busy = true;
      _input.clear();
    });
    _jumpToEnd();
    try {
      final reply = await data.askAgent(List.of(_history));
      if (mounted) {
        setState(() {
          _history.add({'role': 'assistant', 'content': reply});
          _retryHistory = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _requestError =
              'The assistant is unavailable. Retry your request.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      _jumpToEnd();
    }
  }

  Future<void> _retry() async {
    final history = _retryHistory;
    if (_busy || history == null || history.isEmpty) return;
    await _send(history.last['content']!);
  }

  void _jumpToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _findPlace() async {
    if (_busy || _placeSheetOpen) return;
    final data = context.read<AppData>();
    setState(() => _placeSheetOpen = true);
    String? query;
    try {
      query = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        builder: (_) => ProfileRequired(
          data: data,
          builder: (_) => _FindPlaceSheet(currency: data.currency),
        ),
      );
    } finally {
      if (mounted) setState(() => _placeSheetOpen = false);
    }
    if (mounted && query != null) await _send(query);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = context.watch<AppData>();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(
            spacing: 8,
            children: [
              ActionChip(
                avatar: const Icon(Icons.place_outlined, size: 18),
                label: const Text('Find a place'),
                onPressed: _busy || _placeSheetOpen ? null : _findPlace,
              ),
              ActionChip(
                label: const Text('Plan my month'),
                onPressed: () => _send(
                  'Plan my spending for the rest of this month based on my installments and expenses.',
                ),
              ),
              ActionChip(
                label: const Text('Can I afford a new installment?'),
                onPressed: _busy || data.profile == null
                    ? null
                    : () => _input.text =
                          'Can I afford a purchase of  ${data.currency} over  months?',
              ),
            ],
          ),
        ),
        if (data.profile == null)
          TextButton(
            onPressed: data.loading ? null : data.refresh,
            child: const Text('Load profile currency'),
          ),
        if (_requestError != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  _requestError!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                TextButton(
                  onPressed: _busy ? null : _retry,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        Expanded(
          child: _history.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Ask about your spending, installments, or find the best place for what you need.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: _history.length + (_busy ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i == _history.length) {
                      return const Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Padding(
                          padding: EdgeInsets.all(8),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      );
                    }
                    final m = _history[i];
                    final mine = m['role'] == 'user';
                    return Align(
                      alignment: mine
                          ? AlignmentDirectional.centerEnd
                          : AlignmentDirectional.centerStart,
                      child: Container(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        padding: const EdgeInsets.all(12),
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width * 0.85,
                        ),
                        decoration: BoxDecoration(
                          color: mine
                              ? theme.colorScheme.primaryContainer
                              : theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: SelectableText(m['content']!),
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: _send,
                  decoration: const InputDecoration(
                    hintText: 'Ask Masarifi...',
                  ),
                ),
              ),
              IconButton(
                onPressed: _busy ? null : () => _send(_input.text),
                icon: const Icon(Icons.send),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FindPlaceSheet extends StatefulWidget {
  const _FindPlaceSheet({required this.currency});
  final String currency;
  @override
  State<_FindPlaceSheet> createState() => _FindPlaceSheetState();
}

class _FindPlaceSheetState extends State<_FindPlaceSheet> {
  final _need = TextEditingController();
  final _area = TextEditingController();
  final _budget = TextEditingController();
  bool _submitting = false;
  String? _error;
  @override
  void dispose() {
    _need.dispose();
    _area.dispose();
    _budget.dispose();
    super.dispose();
  }

  void _submit() {
    if (_submitting) return;
    final need = _need.text.trim(), area = _area.text.trim();
    final rawBudget = _budget.text.trim();
    final amount = rawBudget.isEmpty
        ? null
        : parseAmountInput(rawBudget, currency: widget.currency);
    if (need.isEmpty ||
        area.isEmpty ||
        need.length > 200 ||
        area.length > 200) {
      setState(
        () => _error = 'Enter a need and city/area, up to 200 characters each.',
      );
      return;
    }
    if (rawBudget.isNotEmpty && amount == null) {
      setState(
        () => _error = 'Enter a valid optional budget in ${widget.currency}.',
      );
      return;
    }
    setState(() => _submitting = true);
    final request = jsonEncode({
      'query': need,
      'area': area,
      'budget': ?amount,
      if (amount != null) 'currency': widget.currency,
    });
    Navigator.pop(
      context,
      'Find places using search_places for this request: $request. '
      'Use the exact area. Compare returned options in compact numbered blocks with name, rating and review count, price evidence, opening status when known and distance from the named approximate area centre. '
      'Explain the preferred choice. Price levels are estimates, not exact costs or proof of affordability.',
    );
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: EdgeInsets.fromLTRB(
      16,
      16,
      16,
      16 + MediaQuery.of(context).viewInsets.bottom,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _need,
          enabled: !_submitting,
          maxLength: 200,
          decoration: const InputDecoration(
            labelText: 'What do you need?',
            hintText: 'family dinner, phone repair...',
          ),
        ),
        TextField(
          controller: _area,
          enabled: !_submitting,
          maxLength: 200,
          decoration: const InputDecoration(
            labelText: 'City / area',
            hintText: 'Riyadh, Olaya, Saudi Arabia',
          ),
        ),
        TextField(
          controller: _budget,
          enabled: !_submitting,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Budget (${widget.currency}, optional)',
          ),
        ),
        const Text(
          'Distances use the approximate area centre. Prices may be estimates.',
        ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: const Text('Find and compare'),
        ),
      ],
    ),
  );
}
