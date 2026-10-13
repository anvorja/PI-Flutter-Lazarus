/// Implementación de [CompassRepository] sobre `flutter_compass`, que usa el
/// sensor de rotación de Android (brújula y acelerómetro ya combinados).
///
/// Con el teléfono vertical en el pecho, el plugin da el rumbo hacia donde
/// apunta la parte de atrás del teléfono (la cámara), que es hacia donde mira
/// la persona.
library;

import 'package:flutter_compass/flutter_compass.dart';

import '../../domain/entities/heading.dart';
import '../../domain/repositories/compass_repository.dart';

class CompassRepositoryImpl implements CompassRepository {
  @override
  Stream<CompassReading> readings() {
    final events = FlutterCompass.events;
    if (events == null) return const Stream.empty();
    return events
        .where((e) => e.heading != null)
        .map(
          (e) => CompassReading(
            headingDeg: normalizeDegrees(e.heading!),
            accuracyDeg: e.accuracy,
          ),
        );
  }
}
