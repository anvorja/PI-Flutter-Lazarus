/// Contrato de acceso a la ubicación del teléfono. No sabe nada de
/// `geolocator` ni `geocoding`: eso vive en `data`.
library;

import '../entities/location_fix.dart';

abstract class LocationRepository {
  /// Pide el permiso de ubicación precisa (y comprueba que el GPS esté activo).
  Future<LocationPermissionStatus> requestPermission();

  /// Posiciones continuas con precisión alta: cada ≤ 2 s o cada 3 m.
  Stream<LocationFix> positions();

  /// Dirección aproximada de una posición (calle y barrio), o `null` si no se
  /// pudo obtener (sin red, sin resultado).
  Future<String?> addressOf(LocationFix fix);
}
