/// Acceso del teléfono al piloto (HU-044 y HU-045).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../live/presentation/providers/live_providers.dart';
import '../../data/repositories/device_access_repository_impl.dart';
import '../../domain/repositories/device_access_repository.dart';

final deviceAccessRepositoryProvider = Provider<DeviceAccessRepository>(
  (ref) => DeviceAccessRepositoryImpl(ref.watch(sharedPreferencesProvider)),
);
