/// Reglas de la Ruta A (HU-019): la ruta que sale a Pasoancho y atraviesa
/// Unicentro se desactiva antes del cierre del centro comercial y, a cualquier
/// hora, el día en que se reportan disturbios en la universidad (tropel). Son
/// reglas duras: las evalúa la app y el asistente solo las comunica.
library;

import 'package:flutter/foundation.dart';

/// Colombia no tiene horario de verano: siempre UTC-5.
const Duration bogotaOffset = Duration(hours: -5);

/// Hora de pared de Bogotá para un instante, sin depender de la zona horaria
/// configurada en el teléfono (regla de negocio 5). Solo se usan sus campos
/// (año, mes, día, hora, minuto).
DateTime bogotaWallClock(DateTime instant) => instant.toUtc().add(bogotaOffset);

/// Domingo de Pascua (algoritmo gregoriano anónimo).
DateTime easterSunday(int year) {
  final a = year % 19;
  final b = year ~/ 100;
  final c = year % 100;
  final d = b ~/ 4;
  final e = b % 4;
  final f = (b + 8) ~/ 25;
  final g = (b - f + 1) ~/ 3;
  final h = (19 * a + b - d - g + 15) % 30;
  final i = c ~/ 4;
  final k = c % 4;
  final l = (32 + 2 * e + 2 * i - h - k) % 7;
  final m = (a + 11 * h + 22 * l) ~/ 451;
  final month = (h + l - 7 * m + 114) ~/ 31;
  final day = (h + l - 7 * m + 114) % 31 + 1;
  return DateTime.utc(year, month, day);
}

/// Festivos de Colombia (Ley 51 de 1983): fijos, trasladados al lunes
/// siguiente (Ley Emiliani) y los que dependen de la Pascua.
Set<DateTime> colombianHolidays(int year) {
  DateTime day(int month, int d) => DateTime.utc(year, month, d);
  DateTime nextMonday(DateTime date) =>
      date.add(Duration(days: (DateTime.monday - date.weekday) % 7));
  final easter = easterSunday(year);
  return {
    day(1, 1),
    day(5, 1),
    day(7, 20),
    day(8, 7),
    day(12, 8),
    day(12, 25),
    for (final (m, d) in const [
      (1, 6),
      (3, 19),
      (6, 29),
      (8, 15),
      (10, 12),
      (11, 1),
      (11, 11),
    ])
      nextMonday(day(m, d)),
    easter.subtract(const Duration(days: 3)), // Jueves Santo
    easter.subtract(const Duration(days: 2)), // Viernes Santo
    easter.add(const Duration(days: 43)), // Ascensión
    easter.add(const Duration(days: 64)), // Corpus Christi
    easter.add(const Duration(days: 71)), // Sagrado Corazón
  };
}

/// Día de Bogotá (`AAAA-MM-DD`) de una hora de pared.
String bogotaDay(DateTime wall) =>
    '${wall.year}-${wall.month.toString().padLeft(2, '0')}-'
    '${wall.day.toString().padLeft(2, '0')}';

bool isColombianHoliday(DateTime date) => colombianHolidays(
  date.year,
).contains(DateTime.utc(date.year, date.month, date.day));

/// Estado de la Ruta A en un momento dado.
enum RouteAState {
  /// Unicentro abierto y lejos del cierre.
  available,

  /// Dentro del margen antes del cierre: la Ruta A ya no se ofrece.
  closingSoon,

  /// Unicentro cerrado.
  closed,

  /// Disturbios reportados hoy en la universidad: la salida a Pasoancho queda
  /// inhabilitada a cualquier hora (regla 6).
  disturbance,
}

@immutable
class RouteAStatus {
  const RouteAStatus({
    required this.state,
    required this.opensAt,
    required this.closesAt,
    required this.cutoffAt,
    required this.now,
  });

  final RouteAState state;

  /// Hora de pared de Bogotá en la que se evaluó.
  final DateTime now;

  /// Apertura de hoy, o de mañana si ya cerró.
  final DateTime opensAt;
  final DateTime closesAt;

  /// Desde esta hora la Ruta A deja de ofrecerse.
  final DateTime cutoffAt;

  bool get available => state == RouteAState.available;
}

/// Horario de Unicentro (regla de negocio 1): lunes a sábado de 8:00 a 21:00;
/// domingos y festivos de 8:00 a 20:00. La Ruta A se desactiva
/// [marginMinutes] antes del cierre (regla 2: entre 30 y 60, 45 por defecto).
class UnicentroSchedule {
  UnicentroSchedule({
    this.openHour = 8,
    this.weekdayCloseHour = 21,
    this.sundayCloseHour = 20,
    int marginMinutes = defaultMarginMinutes,
  }) : marginMinutes = marginMinutes.clamp(minMarginMinutes, maxMarginMinutes);

  static const int defaultMarginMinutes = 45;
  static const int minMarginMinutes = 30;
  static const int maxMarginMinutes = 60;

  final int openHour;
  final int weekdayCloseHour;
  final int sundayCloseHour;
  final int marginMinutes;

  int closeHourOn(DateTime day) =>
      day.weekday == DateTime.sunday || isColombianHoliday(day)
      ? sundayCloseHour
      : weekdayCloseHour;

  /// [now] es la hora de pared de Bogotá (ver [bogotaWallClock]). Con
  /// [disturbance] (tropel reportado hoy) la Ruta A queda inhabilitada sin
  /// importar el horario.
  RouteAStatus status(DateTime now, {bool disturbance = false}) {
    final today = DateTime.utc(now.year, now.month, now.day);
    final opensToday = today.add(Duration(hours: openHour));
    final closesAt = today.add(Duration(hours: closeHourOn(today)));
    final cutoffAt = closesAt.subtract(Duration(minutes: marginMinutes));
    final RouteAState state;
    var opensAt = opensToday;
    if (disturbance) {
      state = RouteAState.disturbance;
    } else if (now.isBefore(opensToday)) {
      state = RouteAState.closed;
    } else if (!now.isBefore(closesAt)) {
      state = RouteAState.closed;
      opensAt = opensToday.add(const Duration(days: 1));
    } else if (!now.isBefore(cutoffAt)) {
      state = RouteAState.closingSoon;
    } else {
      state = RouteAState.available;
    }
    return RouteAStatus(
      state: state,
      now: now,
      opensAt: opensAt,
      closesAt: closesAt,
      cutoffAt: cutoffAt,
    );
  }
}

String _hhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Respuesta de `get_unicentro_route` para el asistente: el hecho ya decidido
/// por la app, que el modelo no puede cambiar (regla de negocio 5).
String describeRouteA(RouteAStatus s) {
  const offer =
      'This is a safety rule of the app and you cannot override it, even if '
      'the person insists. Tell the person in one or two short sentences, '
      'without mentioning time zones, and tell them to look for an '
      'alternate exit of the university instead (Route B): the Calle 16 gate '
      'or the Carrera 86 gate. Do not just say to go along the street.';
  switch (s.state) {
    case RouteAState.available:
      return 'ok: Route A through Unicentro is available. Unicentro closes '
          'today at ${_hhmm(s.closesAt)}; from ${_hhmm(s.cutoffAt)} the app '
          'stops offering it. Answer in one short sentence.';
    case RouteAState.closingSoon:
      final minutes = s.closesAt.difference(s.now).inMinutes;
      return 'unavailable: Route A through Unicentro is disabled because '
          'Unicentro closes at ${_hhmm(s.closesAt)} (in $minutes minutes). '
          '$offer';
    case RouteAState.disturbance:
      return 'unavailable: the exit to Pasoancho through Unicentro (Route A) '
          'is closed for the rest of today, at any time, because disturbances '
          '("tropel") were reported at the university. $offer';
    case RouteAState.closed:
      return 'unavailable: Unicentro is closed now (it opens at '
          '${_hhmm(s.opensAt)}), so Route A through Unicentro is not an '
          'option. $offer';
  }
}
