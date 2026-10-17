/// Orientación de la persona (HU-016): hacia dónde mira o camina, filtrada, y
/// la conversión de un rumbo a horas de reloj relativas a su cuerpo
/// (12 = al frente, 3 = derecha, 6 = atrás, 9 = izquierda).
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Desde esta velocidad se usa el rumbo de marcha del GPS en lugar de la
/// brújula: caminando, hacia donde avanza es más estable que hacia donde apunta
/// el teléfono (regla de negocio 1).
const double walkingSpeedMps = 0.5;

/// Con una precisión peor que esta (en grados), o desconocida, la brújula se
/// considera descalibrada. En Android el sistema solo reporta tres niveles:
/// alta (15°), media (30°) y baja (45°).
const double calibrationNeededDeg = 45;

/// Una lectura de la brújula: rumbo en grados (0 = norte, 90 = este) y su
/// error estimado en grados (`null` si el sistema dice que no es confiable).
@immutable
class CompassReading {
  const CompassReading({required this.headingDeg, this.accuracyDeg});

  final double headingDeg;
  final double? accuracyDeg;

  bool get needsCalibration {
    final accuracy = accuracyDeg;
    return accuracy == null || accuracy >= calibrationNeededDeg;
  }
}

/// De dónde sale el rumbo que se usa.
enum HeadingSource { compass, gps }

/// Rumbo de la persona ya filtrado.
@immutable
class Heading {
  const Heading({
    required this.degrees,
    required this.source,
    this.needsCalibration = false,
  });

  final double degrees;
  final HeadingSource source;

  /// Solo aplica a la brújula: el rumbo de marcha del GPS no se calibra.
  final bool needsCalibration;
}

/// Media móvil circular de los últimos [size] rumbos. Promedia senos y
/// cosenos para que 359° y 1° den 0° y no 180° (regla de negocio 1).
class HeadingFilter {
  HeadingFilter({this.size = 8});

  final int size;
  final List<double> _samples = [];

  void add(double degrees) {
    _samples.add(degrees);
    if (_samples.length > size) _samples.removeAt(0);
  }

  void reset() => _samples.clear();

  double? get value {
    if (_samples.isEmpty) return null;
    var sin = 0.0;
    var cos = 0.0;
    for (final d in _samples) {
      final r = d * math.pi / 180;
      sin += math.sin(r);
      cos += math.cos(r);
    }
    if (sin.abs() < 1e-9 && cos.abs() < 1e-9) return _samples.last;
    return normalizeDegrees(math.atan2(sin, cos) * 180 / math.pi);
  }
}

/// Lleva un ángulo a [0, 360).
double normalizeDegrees(double degrees) {
  final d = degrees % 360;
  return d < 0 ? d + 360 : d;
}

/// Hora de reloj (1 a 12) de un rumbo absoluto [targetDeg] para alguien que
/// mira hacia [headingDeg]. Sectores de 30° centrados en cada hora: 12 cubre
/// de -15° a +15° respecto al frente (regla de negocio 2).
int clockHour(double targetDeg, double headingDeg) {
  final relative = normalizeDegrees(targetDeg - headingDeg);
  final hour = (relative / 30).round() % 12;
  return hour == 0 ? 12 : hour;
}

/// Rumbo inicial (0 = norte) de un punto a otro, en grados. Lo usarán las
/// geocercas y el perfil de la ruta para decir "la entrada está a tus 2".
double bearingBetween(double lat1, double lon1, double lat2, double lon2) {
  double rad(double d) => d * math.pi / 180;
  final dLon = rad(lon2 - lon1);
  final y = math.sin(dLon) * math.cos(rad(lat2));
  final x =
      math.cos(rad(lat1)) * math.sin(rad(lat2)) -
      math.sin(rad(lat1)) * math.cos(rad(lat2)) * math.cos(dLon);
  return normalizeDegrees(math.atan2(y, x) * 180 / math.pi);
}

/// Punto cardinal (8 sectores de 45°), en inglés para la respuesta de la
/// función: el asistente lo dice en el idioma de la persona.
String cardinalDirection(double degrees) {
  const names = [
    'north',
    'northeast',
    'east',
    'southeast',
    'south',
    'southwest',
    'west',
    'northwest',
  ];
  return names[(normalizeDegrees(degrees) / 45).round() % 8];
}
