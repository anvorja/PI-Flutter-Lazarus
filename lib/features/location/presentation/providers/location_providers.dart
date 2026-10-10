/// Inyección de dependencias del feature "location". Los widgets y otros
/// controllers solo leen estos providers; en pruebas se sustituyen por fakes.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../data/repositories/csv_track_recorder.dart';
import '../../data/repositories/location_repository_impl.dart';
import '../../domain/repositories/location_repository.dart';
import '../../domain/repositories/track_recorder.dart';
import '../controllers/location_controller.dart';
import '../../../../core/debug/field_evidence.dart';

final locationRepositoryProvider = Provider<LocationRepository>(
  (ref) => LocationRepositoryImpl(),
);

/// Registro del recorrido en CSV: solo con evidencia de campo (depuración y
/// versiones del piloto); en otra versión no se guarda la ubicación.
final trackRecorderProvider = Provider<TrackRecorder>(
  (ref) => kFieldEvidence
      ? CsvTrackRecorder(evidenceDirectory)
      : const NoTrackRecorder(),
);

/// Mantiene la pantalla encendida mientras el GPS sigue a la persona: con la
/// pantalla apagada Android pausa la app y deja de llegar la posición (en la
/// prueba de CP-LAZA-39, 2 min sin posiciones al entrar a la casa). El
/// seguimiento en segundo plano llega con HU-017.
final screenAwakeProvider = Provider<Future<void> Function(bool on)>(
  (ref) =>
      (on) => WakelockPlus.toggle(enable: on),
);

/// Reloj de la máquina de confiabilidad (en pruebas se fija la hora).
final locationClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

final locationControllerProvider =
    NotifierProvider<LocationController, LocationState>(LocationController.new);
