/// Máquina de estados de la confiabilidad del GPS (HU-013, regla 2).
///
/// - Pasa a **no confiable** si la precisión es peor que [badAccuracyM] de forma
///   continua durante más de [badFor], o si no llega ninguna posición durante
///   [badFor] (sin señal, p. ej. dentro de un edificio).
/// - Pasa a **confiable** tras [goodFor] de forma continua con precisión de
///   [goodAccuracyM] o mejor.
/// - Entre los dos umbrales (10–15 m) mantiene el estado que tenía.
///
/// Es puro: recibe posiciones y "ticks" de reloj; no sabe nada del plugin.
library;

import 'location_fix.dart';

class ReliabilityTracker {
  ReliabilityTracker({
    this.goodAccuracyM = 10,
    this.badAccuracyM = 15,
    this.goodFor = const Duration(seconds: 5),
    this.badFor = const Duration(seconds: 10),
  });

  final double goodAccuracyM;
  final double badAccuracyM;
  final Duration goodFor;
  final Duration badFor;

  GpsReliability _state = GpsReliability.unknown;
  DateTime? _goodSince;
  DateTime? _badSince;
  DateTime? _lastFixAt;

  GpsReliability get state => _state;

  /// Procesa una posición nueva y devuelve el estado resultante.
  GpsReliability add(LocationFix fix) {
    _lastFixAt = fix.at;
    if (fix.accuracyM <= goodAccuracyM) {
      _badSince = null;
      _goodSince ??= fix.at;
      if (fix.at.difference(_goodSince!) >= goodFor) {
        _state = GpsReliability.reliable;
      }
    } else if (fix.accuracyM > badAccuracyM) {
      _goodSince = null;
      _badSince ??= fix.at;
      if (fix.at.difference(_badSince!) > badFor) {
        _state = GpsReliability.unreliable;
      }
    } else {
      // Zona intermedia: no confirma ninguno de los dos estados.
      _goodSince = null;
      _badSince = null;
    }
    return _state;
  }

  /// Revisa el paso del tiempo sin posiciones: sin señal durante [badFor] el
  /// estado pasa a no confiable.
  GpsReliability tick(DateTime now) {
    final last = _lastFixAt;
    if (last != null && now.difference(last) > badFor) {
      _state = GpsReliability.unreliable;
      _goodSince = null;
    }
    return _state;
  }

  void reset() {
    _state = GpsReliability.unknown;
    _goodSince = null;
    _badSince = null;
    _lastFixAt = null;
  }
}
