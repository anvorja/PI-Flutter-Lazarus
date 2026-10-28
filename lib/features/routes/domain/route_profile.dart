/// Perfil de ruta curado (HU-022): una estación, un sentido y sus puntos en el
/// orden en que se pasan, verificados en campo (Fase 0). Lo arma el equipo y lo
/// carga en el backend; la app lo descarga con su token (las coordenadas no
/// van en el código).
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

enum RouteRisk { low, medium, high }

/// Tipo de cruce de vía de un punto (HU-020).
enum RouteCrossing { trafficLight, zebra, uncontrolled }

@immutable
class RoutePoint {
  const RoutePoint({
    required this.name,
    required this.latitude,
    required this.longitude,
    this.instruction = '',
    this.risk = RouteRisk.low,
    this.crossing,
    this.approachM = 60,
    this.arriveM = 15,
  });

  factory RoutePoint.fromJson(Map<String, dynamic> json) => RoutePoint(
    name: json['name'] as String,
    latitude: (json['lat'] as num).toDouble(),
    longitude: (json['lon'] as num).toDouble(),
    instruction: (json['instruction'] as String?) ?? '',
    risk: switch (json['risk']) {
      'high' => RouteRisk.high,
      'medium' => RouteRisk.medium,
      _ => RouteRisk.low,
    },
    crossing: switch (json['crossing']) {
      'traffic_light' => RouteCrossing.trafficLight,
      'zebra' => RouteCrossing.zebra,
      'uncontrolled' => RouteCrossing.uncontrolled,
      _ => null,
    },
    approachM: (json['approach_m'] as num?)?.toDouble() ?? 60,
    arriveM: (json['arrive_m'] as num?)?.toDouble() ?? 15,
  );

  final String name;
  final double latitude;
  final double longitude;

  /// Qué hacer al llegar, con las palabras del perfil.
  final String instruction;
  final RouteRisk risk;
  final RouteCrossing? crossing;

  /// Geocercas (HU-018, regla 1): aproximación y llegada, en metros.
  final double approachM;
  final double arriveM;
}

@immutable
class RouteProfile {
  const RouteProfile({
    required this.slug,
    required this.name,
    required this.origin,
    required this.destination,
    required this.points,
    this.validatedInField = false,
  });

  factory RouteProfile.fromJson(Map<String, dynamic> json) => RouteProfile(
    slug: json['slug'] as String,
    name: json['name'] as String,
    origin: json['origin'] as String,
    destination: json['destination'] as String,
    validatedInField: json['validated_in_field'] == true,
    points: [
      for (final p in json['points'] as List)
        RoutePoint.fromJson(p as Map<String, dynamic>),
    ],
  );

  final String slug;
  final String name;
  final String origin;
  final String destination;

  /// Sin validar en campo, solo se usa acompañado (HU-022, regla 3).
  final bool validatedInField;
  final List<RoutePoint> points;

  /// Los perfiles que responde el backend; uno mal formado se descarta.
  static List<RouteProfile> listFromJson(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! List) return const [];
    final profiles = <RouteProfile>[];
    for (final item in decoded) {
      try {
        final profile = RouteProfile.fromJson(item as Map<String, dynamic>);
        if (profile.points.length >= 2) profiles.add(profile);
      } on Object {
        // Un perfil roto no tumba los demás.
      }
    }
    return profiles;
  }
}

/// Distancia en metros entre dos posiciones (haversine).
double distanceMeters(double lat1, double lon1, double lat2, double lon2) {
  const earthRadiusM = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLon = rad(lon2 - lon1);
  final a =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) *
          math.cos(rad(lat2)) *
          math.pow(math.sin(dLon / 2), 2);
  return 2 * earthRadiusM * math.asin(math.sqrt(a));
}

/// Pasos aproximados de una distancia (paso de ~0,75 m), redondeados a 5.
int stepsFor(double meters) {
  final steps = meters / 0.75;
  return steps < 5 ? 5 : (steps / 5).round() * 5;
}
