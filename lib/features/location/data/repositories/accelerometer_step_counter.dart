/// Implementación de [StepCounter] sobre el acelerómetro de `sensors_plus`.
/// No necesita permisos: Android pide ACTIVITY_RECOGNITION solo para el
/// contador de pasos del sistema.
library;

import 'dart:async';

import 'package:sensors_plus/sensors_plus.dart';

import '../../domain/entities/step_detector.dart';
import '../../domain/repositories/step_counter.dart';

class AccelerometerStepCounter implements StepCounter {
  final _detector = StepDetector();
  StreamSubscription<AccelerometerEvent>? _sub;

  @override
  int get steps => _detector.steps;

  @override
  void start() {
    _detector.reset();
    _sub?.cancel();
    _sub = accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval)
        .listen(
          (e) => _detector.add(e.x, e.y, e.z, e.timestamp),
          // Sin sensor: los pasos se quedan en 0 y la guía no los menciona.
          onError: (_) {},
          cancelOnError: true,
        );
  }

  @override
  void stop() {
    _sub?.cancel();
    _sub = null;
  }
}
