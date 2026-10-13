/// Estado de la ubicación (HU-013): posición continua, confiabilidad y la
/// respuesta que recibe el asistente cuando pide la ubicación (`get_location`).
/// También el rumbo de la persona (HU-016): brújula filtrada, o el rumbo de
/// marcha del GPS cuando camina, y la respuesta a `get_heading`.
///
/// Cada posición queda en el log (`[Lazarus] gps: …`) y cada minuto un resumen
/// con el porcentaje de posiciones con precisión de 10 m o mejor: es la
/// evidencia del recorrido real.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/heading.dart';
import '../../domain/entities/location_fix.dart';
import '../../domain/entities/reliability_tracker.dart';
import '../../domain/entities/spoken_address.dart';
import '../../domain/repositories/compass_repository.dart';
import '../../domain/repositories/location_repository.dart';
import '../../domain/repositories/track_recorder.dart';
import '../providers/location_providers.dart';
import '../../../../core/debug/live_debug.dart';

void _log(String message) => liveLog(message);

@immutable
class LocationState {
  const LocationState({
    this.permission,
    this.fix,
    this.reliability = GpsReliability.unknown,
    this.lastReliableFix,
    this.heading,
  });

  /// `null` mientras no se ha pedido el permiso.
  final LocationPermissionStatus? permission;
  final LocationFix? fix;
  final GpsReliability reliability;

  /// Última posición tomada con el GPS confiable: si deja de serlo, es la
  /// "última posición conocida" que lleva la alerta SOS (HU-012).
  final LocationFix? lastReliableFix;

  /// Hacia dónde mira o camina la persona (HU-016); `null` sin lecturas.
  final Heading? heading;

  LocationState copyWith({
    LocationPermissionStatus? permission,
    LocationFix? fix,
    GpsReliability? reliability,
    LocationFix? lastReliableFix,
    Heading? heading,
  }) => LocationState(
    permission: permission ?? this.permission,
    fix: fix ?? this.fix,
    reliability: reliability ?? this.reliability,
    lastReliableFix: lastReliableFix ?? this.lastReliableFix,
    heading: heading ?? this.heading,
  );
}

class LocationController extends Notifier<LocationState> {
  late final LocationRepository _repo;
  late final TrackRecorder _track;
  late final CompassRepository _compass;
  StreamSubscription<CompassReading>? _compassSub;
  final HeadingFilter _compassFilter = HeadingFilter();
  CompassReading? _lastCompass;
  final ReliabilityTracker _tracker = ReliabilityTracker();
  StreamSubscription<LocationFix>? _sub;
  Timer? _ticker;
  bool _starting = false;

  // Resumen del último minuto (evidencia del criterio 1).
  int _fixes = 0;
  int _preciseFixes = 0;
  int _ticks = 0;

  @override
  LocationState build() {
    _repo = ref.read(locationRepositoryProvider);
    _track = ref.read(trackRecorderProvider);
    _compass = ref.read(compassRepositoryProvider);
    ref.onDispose(stop);
    return const LocationState();
  }

  bool get running => _sub != null;

  /// Pide el permiso y empieza a recibir posiciones. Sin permiso la app sigue
  /// funcionando; el asistente dirá que no conoce la ubicación.
  Future<void> start() async {
    if (running || _starting) return;
    _starting = true;
    try {
      final LocationPermissionStatus permission;
      try {
        permission = await _repo.requestPermission();
      } catch (e) {
        _log('[Lazarus] gps: no disponible ($e)');
        return;
      }
      if (!ref.mounted) return;
      state = state.copyWith(permission: permission);
      if (permission != LocationPermissionStatus.granted) {
        _log('[Lazarus] gps: sin permiso (${permission.name})');
        return;
      }
      _tracker.reset();
      // Estado y máquina empiezan juntos; si no, el primer "tick" confundiría el
      // estado de la sesión anterior con una pérdida de señal.
      state = LocationState(permission: permission);
      try {
        await _track.begin();
      } catch (e) {
        _log('[Lazarus] gps: sin registro del recorrido ($e)');
      }
      if (!ref.mounted) return;
      _sub = _repo.positions().listen(
        _onFix,
        onError: (Object e) => _log('[Lazarus] gps: error $e'),
      );
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
      _startCompass();
      _screenAwake(true);
      _log('[Lazarus] gps: iniciado');
    } finally {
      _starting = false;
    }
  }

  void stop() {
    if (_sub == null) return;
    _logSummary();
    _sub?.cancel();
    _sub = null;
    _ticker?.cancel();
    _ticker = null;
    _compassSub?.cancel();
    _compassSub = null;
    _compassFilter.reset();
    _lastCompass = null;
    _track.end();
    _screenAwake(false);
    _log('[Lazarus] gps: detenido');
  }

  void _screenAwake(bool on) {
    try {
      ref
          .read(screenAwakeProvider)(on)
          .catchError((Object e) => _log('[Lazarus] pantalla encendida: $e'));
    } catch (e) {
      _log('[Lazarus] pantalla encendida: $e');
    }
  }

  void _onFix(LocationFix fix) {
    final before = state.reliability;
    final after = _tracker.add(fix);
    _fixes++;
    if (fix.accuracyM <= _tracker.goodAccuracyM) _preciseFixes++;
    _log(
      '[Lazarus] gps: ±${fix.accuracyM.toStringAsFixed(1)} m (${after.name})',
    );
    if (after != before) _logChange(after, fix.accuracyM);
    state = state.copyWith(
      fix: fix,
      reliability: after,
      lastReliableFix: after == GpsReliability.reliable ? fix : null,
    );
    _updateHeading();
    _track.record(fix, after, state.heading);
  }

  void _startCompass() {
    try {
      _compassSub = _compass.readings().listen(
        _onCompass,
        onError: (Object e) => _log('[Lazarus] brújula: error $e'),
      );
    } catch (e) {
      _log('[Lazarus] brújula: no disponible ($e)');
    }
  }

  void _onCompass(CompassReading reading) {
    final before = _lastCompass;
    if (before == null) {
      _log('[Lazarus] brújula: iniciada');
    }
    if (before == null || before.needsCalibration != reading.needsCalibration) {
      _log(
        reading.needsCalibration
            ? '[Lazarus] brújula: necesita calibración'
            : '[Lazarus] brújula: calibrada (±${reading.accuracyDeg!.toStringAsFixed(0)}°)',
      );
    }
    _lastCompass = reading;
    _compassFilter.add(reading.headingDeg);
    _updateHeading();
  }

  /// Caminando (> 0,5 m/s con rumbo de marcha y GPS reciente) manda el GPS;
  /// si no, la brújula filtrada (regla de negocio 1).
  void _updateHeading() {
    final fix = state.fix;
    final now = ref.read(locationClockProvider)();
    final course = fix?.courseDeg;
    final walking =
        fix != null &&
        course != null &&
        (fix.speedMps ?? 0) > walkingSpeedMps &&
        now.difference(fix.at) <= const Duration(seconds: 5);
    final Heading? heading;
    if (walking) {
      heading = Heading(degrees: course, source: HeadingSource.gps);
    } else {
      final value = _compassFilter.value;
      heading = value == null
          ? null
          : Heading(
              degrees: value,
              source: HeadingSource.compass,
              needsCalibration: _lastCompass?.needsCalibration ?? true,
            );
    }
    if (heading != null) state = state.copyWith(heading: heading);
  }

  /// Hora de reloj hacia un punto (geocercas y ruta, HU-018 y HU-022), o
  /// `null` si no se sabe la posición o el rumbo.
  int? clockHourTowards(double latitude, double longitude) {
    final fix = state.fix;
    final heading = state.heading;
    if (fix == null || heading == null) return null;
    final bearing = bearingBetween(
      fix.latitude,
      fix.longitude,
      latitude,
      longitude,
    );
    return clockHour(bearing, heading.degrees);
  }

  void _onTick() {
    final before = state.reliability;
    final after = _tracker.tick(ref.read(locationClockProvider)());
    if (after != before) {
      _log('[Lazarus] gps: sin señal');
      _logChange(after, null);
      state = state.copyWith(reliability: after);
    }
    if (++_ticks % 60 == 0) _logSummary();
  }

  void _logChange(GpsReliability to, double? accuracyM) {
    final detail = accuracyM == null
        ? ''
        : ' (±${accuracyM.toStringAsFixed(1)} m)';
    _log('[Lazarus] gps: estado → ${_reliabilityEs[to]}$detail');
  }

  void _logSummary() {
    if (_fixes == 0) return;
    final pct = (_preciseFixes * 100 / _fixes).toStringAsFixed(0);
    _log(
      '[Lazarus] gps resumen: $_fixes posiciones, $pct % con precisión ≤ 10 m',
    );
    _fixes = 0;
    _preciseFixes = 0;
  }

  /// Respuesta a `get_location`: lo que el asistente puede decir de la posición.
  /// Con [canSee] en `false` (pantalla bloqueada o sin cámara) no se le pide
  /// sumar lo que ve: en la caminata de CP-LAZA-45, "together with what you
  /// see" lo llevó a describir una calle que no veía (HU-017).
  Future<String> describeForAssistant({bool canSee = true}) async {
    // La persona pudo activar la ubicación o dar el permiso después de iniciar
    // la sesión: se reintenta antes de responder que no está disponible.
    if (!running) await start();
    final instead = canSee
        ? ' and describe what you see instead.'
        : '. The camera is paused: do not describe anything around them.';
    final permission = state.permission;
    if (permission != null && permission != LocationPermissionStatus.granted) {
      return 'unavailable: the app has no location permission or the GPS is '
          'off. Tell the person you do not know their location$instead';
    }
    final fix = state.fix;
    if (fix == null) {
      return 'unavailable: no GPS position yet. Tell the person you do not know '
          'their location yet$instead';
    }
    final accuracy = fix.accuracyM.toStringAsFixed(0);
    if (state.reliability == GpsReliability.unreliable) {
      return 'unreliable: the GPS is not reliable here (accuracy ±$accuracy m). '
          'Tell the person, in one sentence, that you cannot be sure of their '
          'position right now$instead';
    }
    final address = await _repo.addressOf(fix);
    final where = address == null
        ? 'no street address available'
        // Leída tal cual: con "# 12B-80" repetía "doce be" (CP-LAZA-45).
        : '$address (say it exactly as: "${spokenAddress(address)}")';
    final seen = canSee
        ? ', together with what you see.'
        : '. The camera is paused: say only the street and area and do not '
              'describe anything around them.';
    return 'ok: approximate address: $where; accuracy ±$accuracy m; '
        'coordinates ${fix.latitude.toStringAsFixed(5)}, '
        '${fix.longitude.toStringAsFixed(5)}. Tell the person where they are in '
        'one or two short sentences (street and area, not coordinates)$seen';
  }

  /// Respuesta a `get_heading` (HU-016): hacia dónde mira la persona, o que
  /// pida calibrar la brújula antes de dar direcciones (criterio 2).
  Future<String> describeHeadingForAssistant() async {
    if (!running) await start();
    final heading = state.heading;
    if (heading == null) {
      return 'unavailable: there is no compass reading. Tell the person, in one '
          'sentence, that you cannot know which way they are facing right now.';
    }
    if (heading.needsCalibration) {
      return 'needs_calibration: the compass is not accurate. Before giving any '
          'direction, ask the person to move the phone in a figure eight a few '
          'times and then ask you again. Do not say a direction now.';
    }
    final direction = cardinalDirection(heading.degrees);
    final degrees = heading.degrees.toStringAsFixed(0);
    // Caminando el rumbo es hacia donde avanza ("Vas hacia…"); quieta, hacia
    // donde mira el teléfono ("Miras al…").
    if (heading.source == HeadingSource.gps) {
      return 'ok: the person is walking towards $direction ($degrees degrees, '
          'from the GPS). Answer in 3 or 4 words that they are heading '
          '$direction, without degrees.';
    }
    return 'ok: the person is standing and facing $direction ($degrees degrees, '
        'from the compass). Answer in 3 or 4 words that they face $direction, '
        'without degrees.';
  }
}

const _reliabilityEs = {
  GpsReliability.unknown: 'sin datos',
  GpsReliability.reliable: 'confiable',
  GpsReliability.unreliable: 'no confiable',
};
