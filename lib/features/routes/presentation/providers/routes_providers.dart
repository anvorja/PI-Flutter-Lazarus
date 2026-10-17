/// Inyección de dependencias de las rutas (HU-019).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../live/presentation/providers/live_providers.dart';
import '../../data/disturbance_store.dart';
import '../../domain/unicentro_schedule.dart';

/// Horario de Unicentro con el margen por defecto (45 min antes del cierre).
final unicentroScheduleProvider = Provider<UnicentroSchedule>(
  (ref) => UnicentroSchedule(),
);

/// Disturbios reportados hoy (tropel): inhabilitan la Ruta A todo el día.
final disturbanceStoreProvider = Provider<DisturbanceStore>(
  (ref) => DisturbanceStore(ref.watch(sharedPreferencesProvider)),
);
