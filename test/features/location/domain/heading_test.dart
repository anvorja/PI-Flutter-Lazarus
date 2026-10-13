/// HU-016: rumbo filtrado y conversión a horas de reloj relativas al cuerpo.
library;

import 'package:app/features/location/domain/entities/heading.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('hora de reloj (regla de negocio 2)', () {
    test('mirando al norte: norte a las 12, este a las 3, sur a las 6, '
        'oeste a las 9', () {
      expect(clockHour(0, 0), 12);
      expect(clockHour(90, 0), 3);
      expect(clockHour(180, 0), 6);
      expect(clockHour(270, 0), 9);
    });

    test('es relativa a hacia dónde mira la persona', () {
      // Mirando al este, el sur queda a su derecha (criterio 1).
      expect(clockHour(180, 90), 3);
      expect(clockHour(0, 90), 9);
      // Cruzando el norte: mirando a 350°, un punto a 80° está a las 3.
      expect(clockHour(80, 350), 3);
    });

    test('sectores de 30° centrados en cada hora', () {
      expect(clockHour(14, 0), 12);
      expect(clockHour(16, 0), 1);
      expect(clockHour(346, 0), 12);
      expect(clockHour(344, 0), 11);
    });
  });

  group('filtro circular (regla de negocio 1)', () {
    test('promedia sin saltar al cruzar el norte', () {
      final filter = HeadingFilter(size: 4)
        ..add(358)
        ..add(2)
        ..add(359)
        ..add(1);
      final value = filter.value!;
      expect(value < 1 || value > 359, isTrue);
    });

    test('suaviza un salto aislado', () {
      final filter = HeadingFilter(size: 8);
      for (var i = 0; i < 7; i++) {
        filter.add(90);
      }
      filter.add(150); // lectura suelta cerca de una estructura metálica
      expect(filter.value!, closeTo(97.5, 1.5));
    });

    test('solo cuenta las últimas lecturas', () {
      final filter = HeadingFilter(size: 3);
      for (final d in [10.0, 10.0, 10.0, 200.0, 200.0, 200.0]) {
        filter.add(d);
      }
      expect(filter.value!, closeTo(200, 0.001));
    });

    test('sin lecturas no hay rumbo', () {
      expect(HeadingFilter().value, isNull);
    });
  });

  test('calibración: precisión baja o desconocida la pide (criterio 2)', () {
    expect(
      const CompassReading(headingDeg: 0, accuracyDeg: 15).needsCalibration,
      isFalse,
    );
    expect(
      const CompassReading(headingDeg: 0, accuracyDeg: 30).needsCalibration,
      isFalse,
    );
    expect(
      const CompassReading(headingDeg: 0, accuracyDeg: 45).needsCalibration,
      isTrue,
    );
    expect(const CompassReading(headingDeg: 0).needsCalibration, isTrue);
  });

  test('rumbo entre dos puntos', () {
    expect(bearingBetween(0, 0, 1, 0), closeTo(0, 0.01));
    expect(bearingBetween(0, 0, 0, 1), closeTo(90, 0.01));
    expect(bearingBetween(0, 0, -1, 0), closeTo(180, 0.01));
    expect(bearingBetween(0, 0, 0, -1), closeTo(270, 0.01));
  });

  test('punto cardinal en 8 sectores', () {
    expect(cardinalDirection(0), 'north');
    expect(cardinalDirection(350), 'north');
    expect(cardinalDirection(46), 'northeast');
    expect(cardinalDirection(180), 'south');
    expect(cardinalDirection(271), 'west');
  });
}
