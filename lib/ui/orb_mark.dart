import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The same curved parallels identify Orb in the launcher and the conversation.
class OrbMark extends StatelessWidget {
  const OrbMark({super.key, this.size = 64});
  final double size;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CustomPaint(size: Size.square(size), painter: const _Globe()),
  );
}

class _Globe extends CustomPainter {
  const _Globe();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 64);
    final disc = Path()..addOval(const Rect.fromLTWH(0, 0, 64, 64));
    canvas.drawPath(disc, Paint()..color = const Color(0xfff7f7f7));
    canvas.clipPath(disc);
    canvas.translate(32, 32);
    canvas.rotate(-26 * math.pi / 180);
    final stroke = Paint()
      ..color = Colors.black
      ..strokeWidth = 2.8
      ..style = PaintingStyle.stroke;
    for (final y in [-25.0, -15.0, -5.0, 5.0, 15.0]) {
      final curve = Path()
        ..moveTo(-44.5, y)
        ..quadraticBezierTo(0, y + 21, 44.5, y);
      canvas.drawPath(curve, stroke);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_Globe oldDelegate) => false;
}

enum Glyph {
  history,
  compose,
  arrow,
  stop,
  add,
  mic,
  search,
  more,
  clock,
  settings,
  chevron,
}

class OrbGlyph extends StatelessWidget {
  const OrbGlyph(
    this.glyph, {
    super.key,
    this.color = const Color(0xfff7f7f7),
    this.size = 24,
  });
  final Glyph glyph;
  final Color color;
  final double size;
  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _GlyphPainter(glyph, color),
  );
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.glyph, this.color);
  final Glyph glyph;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24);
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.65
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    switch (glyph) {
      case Glyph.history:
        path.moveTo(3, 8);
        path.lineTo(21, 8);
        path.moveTo(3, 15.5);
        path.lineTo(15, 15.5);
      case Glyph.compose:
        path.moveTo(13.5, 5);
        path.lineTo(6, 5);
        path.quadraticBezierTo(4, 5, 4, 7);
        path.lineTo(4, 18);
        path.quadraticBezierTo(4, 20, 6, 20);
        path.lineTo(17, 20);
        path.quadraticBezierTo(19, 20, 19, 18);
        path.lineTo(19, 12);
        path.moveTo(11, 14);
        path.lineTo(12, 10);
        path.lineTo(19.5, 2.5);
        path.lineTo(22.5, 5.5);
        path.lineTo(15, 13);
        path.close();
      case Glyph.arrow:
        path.moveTo(12, 18);
        path.lineTo(12, 6);
        path.moveTo(7, 11);
        path.lineTo(12, 6);
        path.lineTo(17, 11);
      case Glyph.add:
        path.moveTo(12, 5);
        path.lineTo(12, 19);
        path.moveTo(5, 12);
        path.lineTo(19, 12);
      case Glyph.mic:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(9, 4, 6, 10),
            const Radius.circular(3),
          ),
          pen,
        );
        path.moveTo(6.5, 10);
        path.lineTo(6.5, 11);
        path.arcToPoint(
          const Offset(17.5, 11),
          radius: const Radius.circular(5.5),
          clockwise: false,
        );
        path.lineTo(17.5, 10);
        path.moveTo(12, 17);
        path.lineTo(12, 20);
        path.moveTo(9, 20);
        path.lineTo(15, 20);
      case Glyph.search:
        canvas.drawCircle(const Offset(10.5, 10.5), 7.5, pen);
        path.moveTo(17, 17);
        path.lineTo(21.5, 21.5);
      case Glyph.more:
        for (final x in [4.0, 11.0, 18.0]) {
          path.moveTo(x, 12);
          path.lineTo(x + .5, 12);
        }
      case Glyph.clock:
        canvas.drawCircle(const Offset(12, 12), 9, pen);
        path.moveTo(12, 7);
        path.lineTo(12, 12);
        path.lineTo(15.5, 14);
      case Glyph.settings:
        path.moveTo(3, 7);
        path.lineTo(8, 7);
        path.moveTo(13, 7);
        path.lineTo(21, 7);
        path.moveTo(3, 17);
        path.lineTo(12, 17);
        path.moveTo(17, 17);
        path.lineTo(21, 17);
        canvas.drawCircle(const Offset(10.5, 7), 2.5, pen);
        canvas.drawCircle(const Offset(14.5, 17), 2.5, pen);
      case Glyph.chevron:
        path.moveTo(8, 10);
        path.lineTo(12, 14);
        path.lineTo(16, 10);
      case Glyph.stop:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(6, 6, 12, 12),
            const Radius.circular(2),
          ),
          Paint()..color = color,
        );
    }
    canvas.drawPath(path, pen);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlyphPainter oldDelegate) =>
      oldDelegate.glyph != glyph || oldDelegate.color != color;
}
