/// Avance por un perfil de ruta curado (HU-018 y HU-022): con cada posición del
/// GPS decide si la persona se acerca o llegó al siguiente punto. Sin GPS
/// confiable no hay eventos (HU-018, regla 4).
library;

import 'package:flutter/foundation.dart';

import '../../location/domain/entities/location_fix.dart';
import 'route_profile.dart';

/// Cada cuánto se revisa la ruta activa: el GPS da una posición cada ~2 s.
const Duration routeCheckInterval = Duration(seconds: 2);

enum RouteEventKind { approaching, arrived, finished }

@immutable
class RouteEvent {
  const RouteEvent(this.kind, this.index, this.profile);

  final RouteEventKind kind;

  /// Índice del punto del evento en el perfil.
  final int index;
  final RouteProfile profile;

  RoutePoint get point => profile.points[index];

  RoutePoint? get next =>
      index + 1 < profile.points.length ? profile.points[index + 1] : null;
}

class RouteGuide {
  RouteGuide(this.profile);

  final RouteProfile profile;

  /// Cuántos puntos adelante se busca la llegada: un punto que se pasó sin
  /// señal no detiene la guía.
  static const int lookAhead = 3;

  int _next = 0;
  int? _approached;

  bool get finished => _next >= profile.points.length;

  /// Siguiente punto por alcanzar, o `null` al terminar.
  RoutePoint? get nextPoint => finished ? null : profile.points[_next];

  RouteEvent? update(LocationFix fix, GpsReliability reliability) {
    if (finished || reliability != GpsReliability.reliable) return null;
    final points = profile.points;
    final last = (_next + lookAhead).clamp(0, points.length);
    for (var i = _next; i < last; i++) {
      final p = points[i];
      final d = distanceMeters(
        fix.latitude,
        fix.longitude,
        p.latitude,
        p.longitude,
      );
      if (d <= p.arriveM) {
        _next = i + 1;
        // El aviso de llegada ya nombra el siguiente punto: si está cerca, no
        // se anuncia otra vez al acercarse.
        if (_next < points.length) {
          final n = points[_next];
          final dNext = distanceMeters(
            fix.latitude,
            fix.longitude,
            n.latitude,
            n.longitude,
          );
          if (dNext <= n.approachM) _approached = _next;
        }
        return RouteEvent(
          i == points.length - 1
              ? RouteEventKind.finished
              : RouteEventKind.arrived,
          i,
          profile,
        );
      }
    }
    final p = points[_next];
    final d = distanceMeters(
      fix.latitude,
      fix.longitude,
      p.latitude,
      p.longitude,
    );
    if (d <= p.approachM && _approached != _next) {
      _approached = _next;
      return RouteEvent(RouteEventKind.approaching, _next, profile);
    }
    return null;
  }
}

/// Mensaje `[RUTA]` para el asistente, en inglés como las demás respuestas de
/// la app: lo dice en el idioma de la persona. [clockTo] da la hora de reloj
/// hacia un punto (`null` sin rumbo).
String describeRouteEvent(
  RouteEvent event,
  LocationFix fix,
  int? Function(RoutePoint point) clockTo,
) {
  final total = event.profile.points.length;
  final number = event.index + 1;
  String where(RoutePoint p) {
    final meters = distanceMeters(
      fix.latitude,
      fix.longitude,
      p.latitude,
      p.longitude,
    );
    final hour = clockTo(p);
    final clock = hour == null ? '' : " at $hour o'clock";
    return 'about ${stepsFor(meters)} steps$clock';
  }

  String details(RoutePoint p) {
    final parts = <String>[];
    final crossing = p.crossing;
    if (crossing != null) parts.add('crossing: ${_crossingName(crossing)}');
    if (p.risk != RouteRisk.low) parts.add('risk: ${p.risk.name}');
    return parts.isEmpty ? '' : ' ${parts.join('. ')}.';
  }

  final p = event.point;
  switch (event.kind) {
    case RouteEventKind.approaching:
      return "approaching point $number of $total: '${p.name}', ${where(p)}."
          '${details(p)}';
    case RouteEventKind.finished:
      return "finished: reached '${p.name}', the end of the route "
          "'${event.profile.name}'.";
    case RouteEventKind.arrived:
      final instruction = p.instruction.isEmpty
          ? ''
          : " Instruction: '${p.instruction}'.";
      final next = event.next!;
      return "reached point $number of $total: '${p.name}'.$instruction"
          '${details(p)}'
          " Next: '${next.name}', ${where(next)}.";
  }
}

String _crossingName(RouteCrossing crossing) => switch (crossing) {
  RouteCrossing.trafficLight => 'traffic light',
  RouteCrossing.zebra => 'zebra crossing',
  RouteCrossing.uncontrolled => 'uncontrolled crossing',
};

/// El perfil que empieza cerca de la posición (a [maxStartM] o menos de su
/// primer punto), prefiriendo el que va al destino que dijo la persona.
RouteProfile? pickRoute(
  List<RouteProfile> profiles,
  LocationFix fix,
  String destination, {
  double maxStartM = 250,
}) {
  double startDistance(RouteProfile r) => distanceMeters(
    fix.latitude,
    fix.longitude,
    r.points.first.latitude,
    r.points.first.longitude,
  );
  final near = [
    for (final r in profiles)
      if (startDistance(r) <= maxStartM) r,
  ]..sort((a, b) => startDistance(a).compareTo(startDistance(b)));
  if (near.isEmpty) return null;
  final words = _words(destination);
  if (words.isNotEmpty) {
    for (final r in near) {
      final target = _words('${r.destination} ${r.name}');
      if (words.any(target.contains)) return r;
    }
  }
  return near.first;
}

Set<String> _words(String text) {
  const from = 'áéíóúüñ';
  const to = 'aeiouun';
  var t = text.toLowerCase();
  for (var i = 0; i < from.length; i++) {
    t = t.replaceAll(from[i], to[i]);
  }
  return {
    for (final w in t.split(RegExp(r'[^a-z0-9]+')))
      if (w.length >= 4) w,
  };
}
