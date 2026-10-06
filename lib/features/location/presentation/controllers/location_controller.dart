/// Estado de la ubicación (HU-013): posición continua, confiabilidad y la
/// respuesta que recibe el asistente cuando pide la ubicación (`get_location`).
///
/// Cada posición queda en el log (`[Lazarus] gps: …`) y cada minuto un resumen
/// con el porcentaje de posiciones con precisión de 10 m o mejor: es la
/// evidencia del recorrido real.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/location_fix.dart';
import '../../domain/entities/reliability_tracker.dart';
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
  });

  /// `null` mientras no se ha pedido el permiso.
  final LocationPermissionStatus? permission;
  final LocationFix? fix;
  final GpsReliability reliability;

  /// Última posición tomada con el GPS confiable: si deja de serlo, es la
  /// "última posición conocida" que lleva la alerta SOS (HU-012).
  final LocationFix? lastReliableFix;

  LocationState copyWith({
    LocationPermissionStatus? permission,
    LocationFix? fix,
    GpsReliability? reliability,
    LocationFix? lastReliableFix,
  }) => LocationState(
    permission: permission ?? this.permission,
    fix: fix ?? this.fix,
    reliability: reliability ?? this.reliability,
    lastReliableFix: lastReliableFix ?? this.lastReliableFix,
  );
}

class LocationController extends Notifier<LocationState> {
  late final LocationRepository _repo;
  late final TrackRecorder _track;
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
    _track.record(fix, after);
    state = state.copyWith(
      fix: fix,
      reliability: after,
      lastReliableFix: after == GpsReliability.reliable ? fix : null,
    );
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
  Future<String> describeForAssistant() async {
    // La persona pudo activar la ubicación o dar el permiso después de iniciar
    // la sesión: se reintenta antes de responder que no está disponible.
    if (!running) await start();
    final permission = state.permission;
    if (permission != null && permission != LocationPermissionStatus.granted) {
      return 'unavailable: the app has no location permission or the GPS is '
          'off. Tell the person you do not know their location and describe '
          'what you see instead.';
    }
    final fix = state.fix;
    if (fix == null) {
      return 'unavailable: no GPS position yet. Tell the person you do not know '
          'their location yet and describe what you see instead.';
    }
    final accuracy = fix.accuracyM.toStringAsFixed(0);
    if (state.reliability == GpsReliability.unreliable) {
      return 'unreliable: the GPS is not reliable here (accuracy ±$accuracy m). '
          'Tell the person, in one sentence, that you cannot be sure of their '
          'position right now, and describe what you see instead.';
    }
    final address = await _repo.addressOf(fix);
    final where = address ?? 'no street address available';
    return 'ok: approximate address: $where; accuracy ±$accuracy m; '
        'coordinates ${fix.latitude.toStringAsFixed(5)}, '
        '${fix.longitude.toStringAsFixed(5)}. Tell the person where they are in '
        'one or two short sentences (street and area, not coordinates), '
        'together with what you see.';
  }
}

const _reliabilityEs = {
  GpsReliability.unknown: 'sin datos',
  GpsReliability.reliable: 'confiable',
  GpsReliability.unreliable: 'no confiable',
};
