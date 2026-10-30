import 'package:app/features/location/domain/entities/step_detector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 10, 30, 9);

  /// Marcha simulada: un pico de 12,5 m/s² cada [every], y reposo entre picos.
  void walk(StepDetector d, int count, Duration every) {
    for (var i = 0; i < count; i++) {
      final at = t0.add(every * i);
      d.add(0, 0, 9.8, at);
      d.add(0, 0, 12.5, at.add(const Duration(milliseconds: 100)));
      d.add(0, 0, 9.8, at.add(const Duration(milliseconds: 200)));
    }
  }

  test('cuenta un paso por pico de la marcha', () {
    final d = StepDetector();
    walk(d, 20, const Duration(milliseconds: 550));
    expect(d.steps, 20);
  });

  test('en reposo no cuenta pasos', () {
    final d = StepDetector();
    for (var i = 0; i < 100; i++) {
      d.add(0.1, 0.2, 9.8, t0.add(Duration(milliseconds: 20 * i)));
    }
    expect(d.steps, 0);
  });

  test('una sacudida rápida no cuenta varios pasos', () {
    final d = StepDetector();
    walk(d, 5, const Duration(milliseconds: 120));
    expect(d.steps, lessThanOrEqualTo(2));
  });

  test('reset vuelve a cero', () {
    final d = StepDetector();
    walk(d, 3, const Duration(milliseconds: 600));
    d.reset();
    expect(d.steps, 0);
  });
}
