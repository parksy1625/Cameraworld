import 'package:cameraworld_mobile/capture/capture_guide.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('marks distinct slices by heading', () {
    final g = CaptureGuide(slices: 8);
    expect(g.covered, 0);
    g.markHeading(0);
    g.markHeading(10); // same slice
    expect(g.covered, 1);
    g.markHeading(90);
    g.markHeading(180);
    g.markHeading(270);
    expect(g.covered, 4);
    expect(g.progress, closeTo(0.5, 1e-6));
  });

  test('reset clears state', () {
    final g = CaptureGuide();
    g.markHeading(45);
    g.reset();
    expect(g.covered, 0);
  });

  test('ignores NaN heading', () {
    final g = CaptureGuide();
    g.markHeading(double.nan);
    expect(g.covered, 0);
  });
}
