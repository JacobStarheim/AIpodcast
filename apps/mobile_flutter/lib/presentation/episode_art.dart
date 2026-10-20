import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Local decorative cover art, not a waveform or playback indicator.
class EpisodeArt extends StatelessWidget {
  const EpisodeArt({super.key, required this.seed, this.size = 92});
  final String seed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hash = seed.codeUnits.fold<int>(0, (value, char) => value + char);
    final colors = [
      const [Color(0xFFF1B18A), Color(0xFF88432F)],
      const [Color(0xFFB9CEAF), Color(0xFF34533E)],
      const [Color(0xFFD6C6E8), Color(0xFF655277)],
    ][hash % 3];
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(size * .18),
          child: CustomPaint(painter: _CoverPainter(colors[0], colors[1])),
        ),
      ),
    );
  }
}

class _CoverPainter extends CustomPainter {
  const _CoverPainter(this.background, this.foreground);
  final Color background;
  final Color foreground;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(background, BlendMode.src);
    final center = Offset(size.width * .5, size.height * .48);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-math.pi / 5);
    final line = Paint()
      ..color = foreground.withValues(alpha: .8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * .019;
    for (var index = 0; index < 8; index++) {
      final width = size.width * (.16 + index * .115);
      canvas.drawOval(
          Rect.fromCenter(
              center: Offset.zero, width: width, height: width * .64),
          line);
    }
    canvas.restore();
    canvas.drawCircle(Offset(size.width * .79, size.height * .2),
        size.width * .055, Paint()..color = const Color(0xFFFFF7EC));
    final accent = Paint()..color = foreground.withValues(alpha: .55);
    for (var i = 0; i < 5; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(size.width * (.16 + i * .055), size.height * .82,
              size.width * .025, size.height * .035),
          const Radius.circular(2),
        ),
        accent,
      );
    }
  }

  @override
  bool shouldRepaint(_CoverPainter oldDelegate) =>
      oldDelegate.background != background ||
      oldDelegate.foreground != foreground;
}
