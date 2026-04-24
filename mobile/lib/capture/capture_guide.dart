import 'package:flutter/material.dart';

/// On-screen overlay guiding the user to walk a full arc around the subject.
/// Tracks how many "slots" of heading have been sampled (8 slices = full 360°).
class CaptureGuide extends ChangeNotifier {
  final int slices;
  final List<bool> _visited;

  CaptureGuide({this.slices = 8}) : _visited = List<bool>.filled(8, false);

  int get covered => _visited.where((v) => v).length;
  double get progress => covered / slices;
  bool sliceVisited(int i) => _visited[i];

  void markHeading(double headingDeg) {
    if (headingDeg.isNaN) return;
    final idx = ((headingDeg % 360) / (360 / slices)).floor() % slices;
    if (!_visited[idx]) {
      _visited[idx] = true;
      notifyListeners();
    }
  }

  void reset() {
    for (var i = 0; i < _visited.length; i++) {
      _visited[i] = false;
    }
    notifyListeners();
  }
}

class CaptureGuideRing extends StatelessWidget {
  const CaptureGuideRing({super.key, required this.guide, this.size = 120});

  final CaptureGuide guide;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(guide),
        child: Center(
          child: Text(
            '${(guide.progress * 100).round()}%',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.guide);
  final CaptureGuide guide;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 6;
    final stroke = 10.0;

    final bg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = Colors.white24;
    final fg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt
      ..color = Colors.tealAccent;

    canvas.drawCircle(center, radius, bg);

    final slice = 2 * 3.14159265 / guide.slices;
    for (var i = 0; i < guide.slices; i++) {
      if (!_visited(i)) continue;
      final start = -3.14159265 / 2 + i * slice + 0.05;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start,
        slice - 0.1,
        false,
        fg,
      );
    }
  }

  bool _visited(int i) => guide.sliceVisited(i);

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) => true;
}
