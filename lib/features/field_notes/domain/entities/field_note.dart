/// Nota de campo dictada por voz (HU-024): "anota que la rampa está
/// bloqueada". Lleva la hora y la posición del momento en que se dictó.
library;

import 'package:flutter/foundation.dart';

import '../../../location/domain/entities/location_fix.dart';

@immutable
class FieldNote {
  const FieldNote({
    required this.at,
    required this.text,
    this.fix,
    this.reliability = GpsReliability.unknown,
  });

  final DateTime at;
  final String text;

  /// Última posición conocida; `null` sin GPS.
  final LocationFix? fix;
  final GpsReliability reliability;
}
