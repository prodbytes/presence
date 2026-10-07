import 'package:flutter/material.dart';

/// A small filled circle in [color]: a status light, or a subject's dot on
/// a map, outlined in white ([outlined]) and faded by [opacity].
class Dot extends StatelessWidget {
  const Dot({
    super.key,
    required this.color,
    this.size = 10,
    this.opacity = 1,
    this.outlined = false,
  });

  final Color color;
  final double size;
  final double opacity;

  /// A white ring around it, to stand out on a map.
  final bool outlined;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: opacity,
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: outlined ? Border.all(color: Colors.white, width: 2) : null,
      ),
    ),
  );
}
