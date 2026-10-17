/// Reporte de disturbios del día (HU-019, regla 6): se guarda el día de Bogotá
/// en que se reportó, así vale aunque se cierre la app y vence solo a la
/// medianoche.
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/unicentro_schedule.dart';

class DisturbanceStore {
  DisturbanceStore(this._prefs);

  static const String key = 'route_a_disturbance_day';

  final SharedPreferences _prefs;

  /// [wall] es la hora de pared de Bogotá.
  bool isActive(DateTime wall) => _prefs.getString(key) == bogotaDay(wall);

  Future<void> set({required bool active, required DateTime wall}) =>
      active ? _prefs.setString(key, bogotaDay(wall)) : _prefs.remove(key);
}
