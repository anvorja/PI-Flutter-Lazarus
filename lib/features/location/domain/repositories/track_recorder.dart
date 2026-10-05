/// Registro del recorrido: cada posición con su precisión y estado de
/// confiabilidad. Es la evidencia de las pruebas en campo (HU-013, DoD) y no
/// depende de que el teléfono siga conectado al PC.
library;

import '../entities/location_fix.dart';

abstract class TrackRecorder {
  /// Empieza un tramo nuevo (una sesión de GPS).
  Future<void> begin();

  /// Anota una posición.
  void record(LocationFix fix, GpsReliability reliability);

  /// Cierra el tramo y asegura que todo quede escrito.
  Future<void> end();
}

/// Grabador que no hace nada (producción).
class NoTrackRecorder implements TrackRecorder {
  const NoTrackRecorder();

  @override
  Future<void> begin() async {}

  @override
  void record(LocationFix fix, GpsReliability reliability) {}

  @override
  Future<void> end() async {}
}
