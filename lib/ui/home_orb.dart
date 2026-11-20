import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'orb_mark.dart';

/// A short press compresses the globe; its latitudes roll and settle on release.
class HomeOrb extends StatefulWidget {
  const HomeOrb({super.key});
  @override
  State<HomeOrb> createState() => _HomeOrbState();
}

class _HomeOrbState extends State<HomeOrb> with SingleTickerProviderStateMixin {
  late final motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  );
  bool pressed = false;
  @override
  void dispose() {
    motion.dispose();
    super.dispose();
  }

  void release() {
    setState(() => pressed = false);
    HapticFeedback.selectionClick();
    if (!MediaQuery.disableAnimationsOf(context)) motion.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '轻触 Orb',
    onTap: release,
    child: GestureDetector(
      excludeFromSemantics: true,
      onTapDown: (_) => setState(() => pressed = true),
      onTapCancel: () => setState(() => pressed = false),
      onTap: release,
      child: AnimatedBuilder(
        animation: motion,
        builder: (context, child) {
          final t = motion.value;
          final spring = math.sin(t * math.pi * 2.5) * (1 - t) * (1 - t);
          return AnimatedScale(
            scale: pressed && !MediaQuery.disableAnimationsOf(context)
                ? .92
                : 1,
            duration: const Duration(milliseconds: 85),
            child: Transform.rotate(
              angle: spring * .22,
              child: Transform.scale(scale: 1 + spring * .085, child: child),
            ),
          );
        },
        child: const OrbMark(size: 128),
      ),
    ),
  );
}
