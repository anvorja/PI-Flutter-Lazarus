/// Nota de campo dictada por voz (HU-024): "anota que la rampa está
/// bloqueada". Lleva la hora y la posición del momento en que se dictó.
library;

import 'package:flutter/foundation.dart';

import '../../../location/domain/entities/heading.dart';
import '../../../location/domain/entities/location_fix.dart';

@immutable
class FieldNote {
  const FieldNote({
    required this.at,
    required this.text,
    this.fix,
    this.reliability = GpsReliability.unknown,
    this.heading,
    this.route,
    this.nextPoint,
    this.nextPointName,
  });

  final DateTime at;
  final String text;

  /// Última posición conocida; `null` sin GPS.
  final LocationFix? fix;
  final GpsReliability reliability;

  /// Hacia dónde miraba o caminaba (brújula o GPS); `null` sin lecturas. Lo
  /// pidieron los participantes de la Fase 0 para cada punto.
  final Heading? heading;

  /// Ruta activa al dictarla (`slug` del perfil) y el punto al que iba, contado
  /// desde 1 (HU-050): el editor del panel la muestra junto a ese punto como
  /// corrección sugerida. `null` sin ruta activa.
  final String? route;
  final int? nextPoint;
  final String? nextPointName;
}
