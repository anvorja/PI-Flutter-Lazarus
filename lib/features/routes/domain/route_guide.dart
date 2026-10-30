/// Avance por un perfil de ruta curado (HU-018 y HU-022): con cada posición del
/// GPS decide si la persona se acerca o llegó al siguiente punto. Sin GPS
/// confiable no hay eventos (HU-018, regla 4).
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../location/domain/entities/location_fix.dart';
import 'route_profile.dart';

/// Cada cuánto se revisa la ruta activa: el GPS da una posición cada ~2 s.
const Duration routeCheckInterval = Duration(seconds: 2);

/// Cuánto espera una ruta pedida sin GPS confiable antes de desistir.
const Duration routeGpsWait = Duration(minutes: 5);

/// Sin GPS confiable con la ruta activa, a los 3 minutos se sugiere pedir ayuda
/// a una persona cercana o el SOS (HU-021, regla 5).
const Duration routeGpsHelpAfter = Duration(minutes: 3);

/// Pulsos de la vibración direccional para una hora de reloj (HU-021, regla
/// 3): uno, recto (11 a 1); dos, a la derecha (2 a 4); tres, a la izquierda (8
/// a 10). Hacia atrás o sin brújula, ninguno: la voz lo explica.
int directionPulses(int? clock) => switch (clock) {
  11 || 12 || 1 => 1,
  2 || 3 || 4 => 2,
  8 || 9 || 10 => 3,
  _ => 0,
};

/// Hasta cuándo se repite un aviso de ruta que se cortó al cambiar de sesión
/// (LAZA-127). Una sesión nueva tarda de 2 a 12 s en abrir; pasado este
/// tiempo, la persona ya siguió caminando y el aviso no corresponde.
const Duration routeNoticeRepeatWindow = Duration(seconds: 45);

/// `passed`: la persona ya va hacia el punto que sigue sin haber entrado al
/// radio de este; la guía avanza sin anunciarlo. `rejoined`: llegó a un punto
/// más adelante que los que se buscan, por otro camino, y la guía sigue desde
/// ahí. `offRoute`: se alejó de todos los puntos que faltan; el índice es el
/// más cercano de ellos.
enum RouteEventKind {
  approaching,
  arrived,
  passed,
  finished,
  rejoined,
  offRoute,
}

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

  /// A partir de esta distancia de todos los puntos que faltan, la persona va
  /// fuera de la ruta. El 27-oct, dentro de Unicentro, tomó otro pasillo y la
  /// guía esperó un punto 19 minutos sin decir nada.
  static const double offRouteM = 30;

  /// Posiciones seguidas que confirman un reenganche o una salida de la ruta:
  /// una sola puede ser un salto del GPS.
  static const int rejoinFixes = 2;
  static const int offRouteFixes = 3;

  int _next;
  int? _approached;

  /// Último punto alcanzado o dado por pasado; `null` al empezar o al retomar.
  int? _last;

  int? _rejoinAt;
  int _rejoinSeen = 0;
  int _offSeen = 0;
  bool _offSaid = false;

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
      if (d <= arriveRadius(p, fix) && (i == _next || _advanced(fix))) {
        _last = i;
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
    final aside = _offRoute(fix, last, d > arriveRadius(p, fix));
    if (aside != null) return aside;
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
      if (toNext < span - maxArriveM &&
          d <= 2 * p.approachM &&
          _advanced(fix)) {
        final passed = _next;
        _last = passed;
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

  /// Reenganche y salida de la ruta. [from]: el primer punto que no buscó la
  /// llegada normal; [awayFromNext]: la persona no está en el radio del
  /// pendiente.
  RouteEvent? _offRoute(LocationFix fix, int from, bool awayFromNext) {
    final points = profile.points;
    // Reenganche: está en el radio de un punto más adelante, dos veces seguidas.
    int? at;
    if (awayFromNext) {
      for (var i = from; i < points.length; i++) {
        final p = points[i];
        final d = distanceMeters(
          fix.latitude,
          fix.longitude,
          p.latitude,
          p.longitude,
        );
        if (d <= arriveRadius(p, fix)) {
          at = i;
          break;
        }
      }
    }
    if (at == null) {
      _rejoinAt = null;
      _rejoinSeen = 0;
    } else {
      _rejoinSeen = at == _rejoinAt ? _rejoinSeen + 1 : 1;
      _rejoinAt = at;
      if (_rejoinSeen >= rejoinFixes) {
        _rejoinAt = null;
        _rejoinSeen = 0;
        _offSeen = 0;
        _offSaid = false;
        _last = at;
        _next = at + 1;
        _approached = null;
        return RouteEvent(
          at == points.length - 1
              ? RouteEventKind.finished
              : RouteEventKind.rejoined,
          at,
          profile,
        );
      }
    }
    // Fuera de la ruta: lejos de todos los tramos que faltan (desde el que
    // lleva al pendiente), tres veces seguidas. Se mide al tramo y no a los
    // puntos: a mitad de un tramo de 100 m se está a 50 m de ambos extremos.
    var nearest = _next;
    var nearestD = double.infinity;
    for (var i = _next; i < points.length; i++) {
      final p = points[i];
      final d = distanceMeters(
        fix.latitude,
        fix.longitude,
        p.latitude,
        p.longitude,
      );
      if (d < nearestD) {
        nearest = i;
        nearestD = d;
      }
    }
    var routeD = nearestD;
    for (var i = _next > 0 ? _next - 1 : 0; i + 1 < points.length; i++) {
      final d = segmentDistanceMeters(fix, points[i], points[i + 1]);
      if (d < routeD) routeD = d;
    }
    if (routeD <= offRouteM) {
      _offSeen = 0;
      // De vuelta cerca: si se vuelve a salir, se avisa otra vez.
      if (routeD <= offRouteM / 2) _offSaid = false;
      return null;
    }
    _offSeen++;
    if (_offSeen < offRouteFixes || _offSaid) return null;
    _offSaid = true;
    return RouteEvent(RouteEventKind.offRoute, nearest, profile);
  }

  /// Si la persona ya se alejó del último punto lo que mide el tramo hasta el
  /// pendiente (con [maxArriveM] de margen). Sin esto no se salta un punto: en
  /// un tramo en U el punto de después queda cerca del anterior, y el 27-oct
  /// la guía dio por pasado el 7 de la vuelta (y su "gira a la izquierda")
  /// cuando la persona seguía en el 6.
  bool _advanced(LocationFix fix) {
    final last = _last;
    if (last == null) return true;
    final a = profile.points[last];
    final b = profile.points[_next];
    final moved = distanceMeters(
      fix.latitude,
      fix.longitude,
      a.latitude,
      a.longitude,
    );
    final span = distanceMeters(
      a.latitude,
      a.longitude,
      b.latitude,
      b.longitude,
    );
    return moved >= span - maxArriveM;
  }

  /// Radio de llegada a [p]: el del perfil o la precisión del GPS, si es
  /// mayor, hasta [maxArriveM].
  static double arriveRadius(RoutePoint p, LocationFix fix) {
    final gps = fix.accuracyM.clamp(0, maxArriveM).toDouble();
    return p.arriveM > gps ? p.arriveM : gps;
  }
}

/// Distancia de [fix] al tramo recto entre [a] y [b], en metros (plano local:
/// los tramos miden decenas de metros).
double segmentDistanceMeters(LocationFix fix, RoutePoint a, RoutePoint b) {
  const metersPerDegree = 111320.0;
  final cosLat = math.cos(a.latitude * math.pi / 180);
  double x(double lon) => (lon - a.longitude) * metersPerDegree * cosLat;
  double y(double lat) => (lat - a.latitude) * metersPerDegree;
  final bx = x(b.longitude);
  final by = y(b.latitude);
  final px = x(fix.longitude);
  final py = y(fix.latitude);
  final length2 = bx * bx + by * by;
  final t = length2 == 0
      ? 0.0
      : ((px * bx + py * by) / length2).clamp(0.0, 1.0).toDouble();
  final dx = px - t * bx;
  final dy = py - t * by;
  return math.sqrt(dx * dx + dy * dy);
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
    case RouteEventKind.arrived || RouteEventKind.rejoined:
      final instruction = p.instruction.isEmpty
          ? ''
          : " Instruction: '${p.instruction}'.";
      final next = event.next!;
      final reached = event.kind == RouteEventKind.rejoined
          ? 'back on the route at point'
          : 'reached point';
      // Un cruce cerca del punto no tiene aviso de aproximación propio (el
      // 27-oct, la Calle Quinta queda a 5 pasos del paradero): va aquí.
      final nextDetails = next.crossing != null || next.risk == RouteRisk.high
          ? details(next)
          : '';
      return "$reached $number of $total: '${p.name}'.$instruction"
          '${details(p)}'
          " Next: '${next.name}', ${where(next)}.$nextDetails";
    case RouteEventKind.offRoute:
      return 'off route: the person is away from the route. Nearest point '
          "ahead: point $number of $total, '${p.name}', ${where(p)}. Tell "
          'them once, in one short sentence, with that distance and hour; do '
          'not invent turns or streets. The route stays active: the app will '
          "send '[RUTA]' when they are back on it.";
  }
}

String _crossingName(RouteCrossing crossing) => switch (crossing) {
  RouteCrossing.trafficLight => 'traffic light',
  RouteCrossing.zebra => 'zebra crossing',
  RouteCrossing.uncontrolled => 'uncontrolled crossing',
};

/// Los perfiles que pasan cerca de la posición (a [maxStartM] o menos de
/// alguno de sus puntos), del más cercano al más lejano.
List<RouteProfile> routesNear(
  List<RouteProfile> profiles,
  LocationFix fix, {
  double maxStartM = 250,
}) {
  double startDistance(RouteProfile r) {
    final p = r.points[nearestPointIndex(r, fix)];
    return distanceMeters(fix.latitude, fix.longitude, p.latitude, p.longitude);
  }

  return [
    for (final r in profiles)
      if (startDistance(r) <= maxStartM) r,
  ]..sort((a, b) => startDistance(a).compareTo(startDistance(b)));
}

/// El perfil que pasa cerca de la posición (para poder retomarlo a mitad de
/// camino), prefiriendo el que va al destino que dijo la persona. Si el
/// destino no es el de ningún perfil, sirve uno que lo nombre en un punto que
/// falta ("Unicentro" en la ida a Univalle). Sin coincidencias no se elige un
/// perfil que la persona ya terminó: el 27-oct, "llévame a Unicentro" en la
/// estación tomó la vuelta, cuyo último punto era el más cercano, y la ruta
/// terminó al instante.
///
/// Si la persona dijo un destino y ningún perfil cercano lo tiene, devuelve
/// `null` aunque haya perfiles cerca: el 28-oct el asistente entendió
/// "Utrega" y la app inició la ruta más cercana (hallazgo 46, LAZA-128). Ver
/// [isUnknownDestination].
RouteProfile? pickRoute(
  List<RouteProfile> profiles,
  LocationFix fix,
  String destination, {
  double maxStartM = 250,
}) {
  final near = routesNear(profiles, fix, maxStartM: maxStartM);
  if (near.isEmpty) return null;
  final words = _destinationWords(destination);
  if (words.isNotEmpty) {
    for (final r in near) {
      // Solo el destino: el nombre de la vuelta también nombra el origen.
      final target = _words(r.destination);
      if (words.any(target.contains)) return r;
    }
    for (final r in near) {
      final ahead = r.points.skip(nearestPointIndex(r, fix) + 1);
      if (ahead.any((p) => words.any(_words(p.name).contains))) return r;
    }
    return null;
  }
  final unfinished = [
    for (final r in near)
      if (nearestPointIndex(r, fix) < r.points.length - 1) r,
  ];
  return unfinished.isEmpty ? near.first : unfinished.first;
}

/// Hay perfiles cerca, pero ninguno va al destino que dijo la persona: no se
/// inicia ninguna ruta y el asistente le pregunta a cuál va (LAZA-128).
bool isUnknownDestination(
  List<RouteProfile> profiles,
  LocationFix fix,
  String destination, {
  double maxStartM = 250,
}) =>
    _destinationWords(destination).isNotEmpty &&
    routesNear(profiles, fix, maxStartM: maxStartM).isNotEmpty &&
    pickRoute(profiles, fix, destination, maxStartM: maxStartM) == null;

/// Los destinos de los perfiles cercanos, sin repetir, para que el asistente
/// pregunte a cuál va la persona.
List<String> destinationsNear(
  List<RouteProfile> profiles,
  LocationFix fix, {
  double maxStartM = 250,
}) => {
  for (final r in routesNear(profiles, fix, maxStartM: maxStartM))
    r.destination,
}.toList();

/// Palabras que no dicen a dónde va la persona ("guíame por mi ruta").
const _notDestination = {
  'ruta',
  'rutas',
  'camino',
  'destino',
  'guiame',
  'guiar',
  'llevame',
  'llevar',
  'quiero',
  'hasta',
  'hacia',
  'para',
  'favor',
  'aqui',
  'alla',
  'donde',
};

Set<String> _destinationWords(String destination) =>
    _words(destination).difference(_notDestination);

Set<String> _words(String text) {
  const from = 'áéíóúüñ';
  const to = 'aeiouun';
  var t = text.toLowerCase();
  for (var i = 0; i < from.length; i++) {
    t = t.replaceAll(from[i], to[i]);
  }
  t = t.replaceAll('universidad del valle', 'univalle');
  // "La universidad" es Univalle en el piloto; "Universidades" (la estación
  // Universidades–Jardín Plaza) no se toca.
  t = t.replaceAll(RegExp(r'\buniversidad\b'), 'univalle');
  return {
    for (final w in t.split(RegExp(r'[^a-z0-9]+')))
      if (w.length >= 4) w,
  };
}
