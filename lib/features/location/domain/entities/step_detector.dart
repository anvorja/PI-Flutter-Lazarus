/// Detector de pasos sobre el acelerómetro (HU-021, regla 2): sin GPS, la guía
/// usa los pasos que la persona camina desde que se perdió la señal.
///
/// Cuenta un paso en cada pico de la magnitud de la aceleración que supera
/// [threshold] (m/s², sin la gravedad) y llega al menos [minInterval] después
/// del anterior: un paso de marcha dura 0,4–0,7 s. Es una estimación: el
/// teléfono en la mano o en el bolsillo cuenta distinto, y la guía lo dice así.
///
/// Es puro: recibe muestras con su hora; no sabe nada del plugin.
library;

import 'dart:math' as math;

class StepDetector {
  StepDetector({
    this.threshold = 1.6,
    this.minInterval = const Duration(milliseconds: 300),
  });

  final double threshold;
  final Duration minInterval;

  static const double _gravity = 9.81;

  int _steps = 0;
  bool _above = false;
  DateTime? _lastStep;

  int get steps => _steps;

  /// Procesa una muestra del acelerómetro (con la gravedad incluida).
  void add(double x, double y, double z, DateTime at) {
    final magnitude = math.sqrt(x * x + y * y + z * z) - _gravity;
    if (magnitude > threshold) {
      if (_above) return;
      _above = true;
      final last = _lastStep;
      if (last != null && at.difference(last) < minInterval) return;
      _lastStep = at;
      _steps++;
    } else if (magnitude < threshold / 2) {
      // Histéresis: el pico termina cuando la aceleración baja de la mitad.
      _above = false;
    }
  }

  void reset() {
    _steps = 0;
    _above = false;
    _lastStep = null;
  }
}
