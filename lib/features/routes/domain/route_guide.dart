/// Avance por un perfil de ruta curado (HU-018 y HU-022): con cada posición del
/// GPS decide si la persona se acerca o llegó al siguiente punto. Sin GPS
/// confiable no hay eventos (HU-018, regla 4).
library;

import 'package:flutter/foundation.dart';

import '../../location/domain/entities/location_fix.dart';
import 'route_profile.dart';

/// Cada cuánto se revisa la ruta activa: el GPS da una posición cada ~2 s.
const Duration routeCheckInterval = Duration(seconds: 2);

/// Cuánto espera una ruta pedida sin GPS confiable antes de desistir.
const Duration routeGpsWait = Duration(minutes: 5);

/// `passed`: la persona ya va hacia el punto que sigue sin haber entrado al
/// radio de este; la guía avanza sin anunciarlo.
enum RouteEventKind { approaching, arrived, passed, finished }

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
  /// [startAt]: el punto desde el que se guía; al retomar una ruta a mitad de
  /// camino es el más cercano a la persona ([nearestPointIndex]).
  RouteGuide(this.profile, {int startAt = 0})
    : _next = startAt.clamp(0, profile.points.length);

  final RouteProfile profile;

  /// Cuántos puntos adelante se busca la llegada: un punto que se pasó sin
  /// señal no detiene la guía.
  static const int lookAhead = 3;

  /// Tope del radio de llegada cuando el GPS es menos preciso que el radio
  /// del perfil. El 27-oct, con una precisión de 8–9 m, un radio de 4 m dejó
  /// la guía esperando un punto que la persona pasó a 24 m.
  static const double maxArriveM = 10;

  int _next;
  int? _approached;

  /// Índice del siguiente punto por alcanzar.
  int get nextIndex => _next;

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
      if (d <= arriveRadius(p, fix)) {
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
    if (_next + 1 < points.length) {
      // Pasó de largo: está más cerca del punto que sigue que el propio punto
      // pendiente (con [maxArriveM] de margen, para no adelantarse a una
      // llegada), sin haberse alejado de este.
      final n = points[_next + 1];
      final toNext = distanceMeters(
        fix.latitude,
        fix.longitude,
        n.latitude,
        n.longitude,
      );
      final span = distanceMeters(
        p.latitude,
        p.longitude,
        n.latitude,
        n.longitude,
      );
      if (toNext < span - maxArriveM && d <= 2 * p.approachM) {
        final passed = _next;
        _next++;
        return RouteEvent(RouteEventKind.passed, passed, profile);
      }
    }
    if (d <= p.approachM && _approached != _next) {
      _approached = _next;
      return RouteEvent(RouteEventKind.approaching, _next, profile);
    }
    return null;
  }

  /// Radio de llegada a [p]: el del perfil o la precisión del GPS, si es
  /// mayor, hasta [maxArriveM].
  static double arriveRadius(RoutePoint p, LocationFix fix) {
    final gps = fix.accuracyM.clamp(0, maxArriveM).toDouble();
    return p.arriveM > gps ? p.arriveM : gps;
  }
}

/// Índice del punto del perfil más cercano a [fix].
int nearestPointIndex(RouteProfile profile, LocationFix fix) {
  var best = 0;
  var bestD = double.infinity;
  for (var i = 0; i < profile.points.length; i++) {
    final p = profile.points[i];
    final d = distanceMeters(
      fix.latitude,
      fix.longitude,
      p.latitude,
      p.longitude,
    );
    if (d < bestD) {
      best = i;
      bestD = d;
    }
  }
  return best;
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
    case RouteEventKind.passed:
      return "passed point $number of $total: '${p.name}' without reaching it.";
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

/// El perfil que pasa cerca de la posición (a [maxStartM] o menos de alguno
/// de sus puntos, para poder retomarlo a mitad de camino), prefiriendo el que
/// va al destino que dijo la persona.
RouteProfile? pickRoute(
  List<RouteProfile> profiles,
  LocationFix fix,
  String destination, {
  double maxStartM = 250,
}) {
  double startDistance(RouteProfile r) {
    final p = r.points[nearestPointIndex(r, fix)];
    return distanceMeters(fix.latitude, fix.longitude, p.latitude, p.longitude);
  }

  final near = [
    for (final r in profiles)
      if (startDistance(r) <= maxStartM) r,
  ]..sort((a, b) => startDistance(a).compareTo(startDistance(b)));
  if (near.isEmpty) return null;
  final words = _words(destination);
  if (words.isNotEmpty) {
    for (final r in near) {
      // Solo el destino: el nombre de la vuelta también nombra el origen.
      final target = _words(r.destination);
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
  t = t.replaceAll('universidad del valle', 'univalle');
  return {
    for (final w in t.split(RegExp(r'[^a-z0-9]+')))
      if (w.length >= 4) w,
  };
}
