import 'dart:math';

import 'package:flutter/material.dart';

/// An easter egg, after Google's: searching for "do a barrel roll" spins
/// the whole screen once around its center. Wraps the app (in
/// [MaterialApp.builder], so routes, dialogs and snack bars spin too);
/// [roll] starts a turn from anywhere below it.
class BarrelRoll extends StatefulWidget {
  const BarrelRoll({super.key, required this.child});

  final Widget child;

  /// How long one turn takes.
  static const duration = Duration(seconds: 2);

  /// Spins the screen above [context] once; nothing outside a
  /// [BarrelRoll], or while one is already turning.
  static void roll(BuildContext context) => context
      .getInheritedWidgetOfExactType<_BarrelRollScope>()
      ?.state
      ._roll(context);

  /// Whether [text] asks for a barrel roll: "do a barrel roll" (or
  /// "barrell"), ignoring case and extra spaces.
  static bool asks(String text) => RegExp(
    r'^do\s+a\s+barrell?\s+roll$',
    caseSensitive: false,
  ).hasMatch(text.trim());

  @override
  State<BarrelRoll> createState() => _BarrelRollState();
}

class _BarrelRollState extends State<BarrelRoll>
    with SingleTickerProviderStateMixin {
  late final _turn = AnimationController(
    vsync: this,
    duration: BarrelRoll.duration,
  );
  late final _angle = CurvedAnimation(
    parent: _turn,
    curve: Curves.easeInOut,
  ).drive(Tween(begin: 0.0, end: 2 * pi));

  void _roll(BuildContext context) {
    // Not for those who asked for less motion.
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return;
    if (_turn.isAnimating) return;
    _turn.forward(from: 0).then((_) {
      if (mounted) _turn.reset();
    });
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _BarrelRollScope(
      state: this,
      child: AnimatedBuilder(
        animation: _angle,
        // Always a Transform (at rest, 0), so the app's state isn't lost
        // when a turn starts.
        builder: (context, child) => Transform.rotate(
          key: const Key('barrel-roll'),
          angle: _angle.value,
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}

class _BarrelRollScope extends InheritedWidget {
  const _BarrelRollScope({required this.state, required super.child});

  final _BarrelRollState state;

  @override
  bool updateShouldNotify(_BarrelRollScope oldWidget) => false;
}
