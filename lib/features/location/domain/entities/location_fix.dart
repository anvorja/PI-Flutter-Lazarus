/// Una posición del GPS con su precisión (radio en metros) y la hora en que se
/// tomó.
library;

import 'package:flutter/foundation.dart';

@immutable
class LocationFix {
  const LocationFix({
    required this.latitude,
    required this.longitude,
    required this.accuracyM,
    required this.at,
  });

  final double latitude;
  final double longitude;

  /// Radio de incertidumbre reportado por el sistema (68 %), en metros.
  final double accuracyM;
  final DateTime at;
}

/// Si se puede creer en la posición.
enum GpsReliability {
  /// Aún no hay datos suficientes para decidir.
  unknown,
  reliable,
  unreliable,
}

/// Resultado de pedir el permiso de ubicación.
enum LocationPermissionStatus { granted, denied, blocked, serviceDisabled }
