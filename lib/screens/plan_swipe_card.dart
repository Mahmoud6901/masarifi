import 'package:flutter/material.dart';

import '../theme.dart';

/// A card you throw right (paid) or left (not paid), like a dating-app card.
///
/// Directions are physical: right always means paid, also in Arabic (RTL).
/// [builder] gets a `decide` callback so buttons inside the card throw it the
/// same way a swipe does. [peek] sits behind it, like the next card in a pile.
class PlanSwipeCard extends StatefulWidget {
  const PlanSwipeCard({
    required this.builder,
    required this.onDecide,
    this.enabled = true,
    this.peek,
    super.key,
  });

  final Widget Function(BuildContext context, void Function(bool paid) decide)
  builder;

  /// Saves the decision and returns true when it was saved. On false the card
  /// springs back to where it was.
  final Future<bool> Function(bool paid) onDecide;

  final bool enabled;
  final Widget? peek;

  @override
  State<PlanSwipeCard> createState() => _PlanSwipeCardState();
}

class _PlanSwipeCardState extends State<PlanSwipeCard>
    with TickerProviderStateMixin {
  /// Share of the card's width a drag must pass to count as a decision.
  static const _threshold = 0.35;
  static const _flingVelocity = 900.0;

  late final AnimationController _dx = AnimationController.unbounded(
    vsync: this,
  );
  late final AnimationController _appear = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: 1,
  );
  double _width = 1;
  bool _settling = false;

  bool get _active => widget.enabled && !_settling;

  Duration _time(int ms) => MediaQuery.of(context).disableAnimations
      ? Duration.zero
      : Duration(milliseconds: ms);

  @override
  void dispose() {
    _dx.dispose();
    _appear.dispose();
    super.dispose();
  }

  void _springBack() =>
      _dx.animateTo(0, duration: _time(320), curve: Curves.easeOutBack);

  void _onUpdate(DragUpdateDetails d) {
    if (_active) _dx.value += d.delta.dx;
  }

  void _onEnd(DragEndDetails d) {
    if (!_active) return;
    final x = _dx.value;
    final v = d.velocity.pixelsPerSecond.dx;
    final far = x.abs() > _width * _threshold;
    final flung = x != 0 && v.abs() > _flingVelocity && v.sign == x.sign;
    if (far || flung) {
      _decide(x > 0);
    } else {
      _springBack();
    }
  }

  Future<void> _decide(bool paid) async {
    if (!_active) return;
    setState(() => _settling = true);
    await _dx.animateTo(
      (paid ? 1 : -1) * _width * 1.4,
      duration: _time(200),
      curve: Curves.easeIn,
    );
    var saved = false;
    try {
      saved = await widget.onDecide(paid);
    } catch (_) {
      saved = false;
    }
    if (!mounted) return;
    if (saved) {
      // The same card now holds the next month: bring it back in place.
      _dx.value = 0;
      _appear.duration = _time(220);
      _appear.forward(from: 0);
    } else {
      await _dx.animateTo(0, duration: _time(320), curve: Curves.easeOutBack);
    }
    if (mounted) setState(() => _settling = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.mc;
    final card = widget.builder(context, _decide);
    return LayoutBuilder(
      builder: (context, constraints) {
        _width = constraints.maxWidth <= 0 ? 1 : constraints.maxWidth;
        return Padding(
          padding: EdgeInsets.only(bottom: widget.peek == null ? 0 : 10),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (widget.peek case final peek?)
                Positioned(
                  left: 12,
                  right: 12,
                  top: 10,
                  bottom: -10,
                  child: ExcludeSemantics(child: peek),
                ),
              GestureDetector(
                onHorizontalDragUpdate: widget.enabled ? _onUpdate : null,
                onHorizontalDragEnd: widget.enabled ? _onEnd : null,
                onHorizontalDragCancel: widget.enabled
                    ? () {
                        if (!_settling) _springBack();
                      }
                    : null,
                child: AnimatedBuilder(
                  animation: Listenable.merge([_dx, _appear]),
                  child: card,
                  builder: (context, child) {
                    final x = _dx.value;
                    final shown = (x.abs() / (_width * _threshold)).clamp(
                      0.0,
                      1.0,
                    );
                    final a = Curves.easeOut.transform(_appear.value);
                    return Opacity(
                      opacity: a,
                      child: Transform.translate(
                        offset: Offset(x, (1 - a) * 12),
                        child: Transform.rotate(
                          angle: x / _width * 0.12,
                          child: Stack(
                            children: [
                              child!,
                              if (x > 0)
                                Positioned(
                                  top: 18,
                                  left: 18,
                                  child: _Stamp('PAID', c.growth, -0.18, shown),
                                ),
                              if (x < 0)
                                Positioned(
                                  top: 18,
                                  right: 18,
                                  child: _Stamp(
                                    'NOT PAID',
                                    c.warm,
                                    0.18,
                                    shown,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The label that fades in while dragging, so the direction reads at a glance.
class _Stamp extends StatelessWidget {
  const _Stamp(this.text, this.color, this.angle, this.opacity);

  final String text;
  final Color color;
  final double angle;
  final double opacity;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Opacity(
      opacity: opacity,
      child: Transform.rotate(
        angle: angle,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: context.mc.card,
            border: Border.all(color: color, width: 2),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            text,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        ),
      ),
    ),
  );
}
