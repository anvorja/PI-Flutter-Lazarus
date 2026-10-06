/// Implementación de [LocationRepository] sobre `geolocator` (posición) y
/// `geocoding` (dirección aproximada con el geocodificador del sistema).
library;

import 'dart:async';

import 'package:flutter/widgets.dart' show Locale;
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

import '../../domain/entities/location_fix.dart';
import '../../domain/repositories/location_repository.dart';

class LocationRepositoryImpl implements LocationRepository {
  @override
  Future<LocationPermissionStatus> requestPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationPermissionStatus.serviceDisabled;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return switch (permission) {
      LocationPermission.always ||
      LocationPermission.whileInUse => LocationPermissionStatus.granted,
      LocationPermission.deniedForever => LocationPermissionStatus.blocked,
      _ => LocationPermissionStatus.denied,
    };
  }

  @override
  Stream<LocationFix> positions() {
    // Sin filtro de distancia: con la persona quieta también llegan posiciones
    // cada 2 s, y así "sin posiciones" significa "sin señal".
    final settings = AndroidSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: 0,
      intervalDuration: const Duration(seconds: 2),
    );
    return Geolocator.getPositionStream(locationSettings: settings).map(
      (p) => LocationFix(
        latitude: p.latitude,
        longitude: p.longitude,
        accuracyM: p.accuracy,
        at: p.timestamp,
      ),
    );
  }

  @override
  Future<String?> addressOf(LocationFix fix) async {
    try {
      final places = await Geocoding()
          .placemarkFromCoordinates(
            fix.latitude,
            fix.longitude,
            locale: const Locale('es', 'CO'),
          )
          .timeout(const Duration(seconds: 4));
      if (places.isEmpty) return null;
      return formatAddress(places.first);
    } catch (_) {
      return null; // sin red o sin resultado: se responde con coordenadas
    }
  }
}

/// Dirección corta para decirla en voz alta: calle con número, barrio y
/// ciudad, sin repetir partes. En Colombia el geocodificador pone la dirección
/// completa en `street` ("Cra. 76 # 14C-101, Comuna 17, Cali, …"), así que se
/// arma con los campos separados y `street` solo se usa si faltan.
String? formatAddress(Placemark p) {
  String? clean(String? s) {
    final t = s?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  final road = clean(p.thoroughfare);
  // El número a veces ya trae el "#" ("# 14C-101").
  final number = clean(p.subThoroughfare?.replaceFirst(RegExp(r'^\s*#'), ''));
  final street = road != null
      ? (number != null ? '$road # $number' : road)
      : clean(_streetOnly(p.street?.split(',').first));
  final parts = <String>[];
  for (final part in [street, clean(p.subLocality), clean(p.locality)]) {
    if (part != null && !parts.contains(part)) parts.add(part);
  }
  return parts.isEmpty ? null : parts.join(', ');
}

/// En el sótano de un centro comercial `street` llegó como
/// "18:00Cra. 100 # #5-169": con texto pegado delante de la vía y el "#"
/// repetido. Se corta desde el tipo de vía y se deja un solo "#".
String? _streetOnly(String? s) {
  if (s == null) return null;
  final road = RegExp(
    r'(Carrera|Cra\.?|Kr\.?|Calle|Cl\.?|Avenida|Av\.?|Diagonal|Dg\.?|'
    r'Transversal|Tv\.?|Autopista)\s',
  ).firstMatch(s);
  final from = road == null ? s : s.substring(road.start);
  return from
      .replaceAll(RegExp(r'#\s*#'), '#')
      .replaceAll(RegExp(r'#(?=\S)'), '# ');
}
