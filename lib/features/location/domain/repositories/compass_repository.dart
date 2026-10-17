/// Contrato de acceso a la brújula del teléfono (HU-016). No sabe nada del
/// plugin: eso vive en `data`.
library;

import '../entities/heading.dart';

abstract class CompassRepository {
  /// Lecturas continuas de la brújula. Vacío si el teléfono no tiene sensor.
  Stream<CompassReading> readings();
}
