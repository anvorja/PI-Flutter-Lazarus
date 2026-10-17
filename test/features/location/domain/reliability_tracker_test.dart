/// HU-013, regla 2: confiabilidad del GPS.
library;

import 'package:app/features/location/domain/entities/location_fix.dart';
import 'package:app/features/location/domain/entities/reliability_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 9, 30, 8);
  late ReliabilityTracker tracker;

  LocationFix fix(double accuracyM, int second) => LocationFix(
    latitude: 3.3753,
    longitude: -76.5325,
    accuracyM: accuracyM,
    at: t0.add(Duration(seconds: second)),
  );

  /// Una posición cada 2 s con la misma precisión, de [from] a [to] segundos.
  GpsReliability feed(double accuracyM, int from, int to) {
    var state = tracker.state;
    for (var s = from; s <= to; s += 2) {
      state = tracker.add(fix(accuracyM, s));
    }
    return state;
  }

  setUp(() => tracker = ReliabilityTracker());

  test('sin datos al empezar', () {
    expect(tracker.state, GpsReliability.unknown);
  });

  test('pasa a confiable tras 5 s con precisión ≤ 10 m, no antes', () {
    expect(feed(4, 0, 4), GpsReliability.unknown); // 4 s
    expect(tracker.add(fix(4, 5)), GpsReliability.reliable); // 5 s
  });

  test('pasa a no confiable con precisión > 15 m durante más de 10 s', () {
    feed(4, 0, 6);
    expect(tracker.state, GpsReliability.reliable);

    expect(feed(30, 8, 18), GpsReliability.reliable); // exactamente 10 s
    expect(tracker.add(fix(30, 19)), GpsReliability.unreliable); // > 10 s
  });

  test('una degradación corta (< 10 s) no cambia el estado', () {
    feed(4, 0, 6);
    feed(30, 8, 14); // 6 s malos
    expect(feed(4, 16, 18), GpsReliability.reliable);
    expect(
      feed(30, 20, 28),
      GpsReliability.reliable,
    ); // la cuenta empezó de nuevo
  });

  test('vuelve a confiable tras 5 s con precisión ≤ 10 m', () {
    feed(30, 0, 12);
    expect(tracker.state, GpsReliability.unreliable);
    expect(feed(6, 14, 18), GpsReliability.unreliable); // 4 s
    expect(tracker.add(fix(6, 19)), GpsReliability.reliable); // 5 s
  });

  test('entre 10 y 15 m mantiene el estado y reinicia las cuentas', () {
    feed(4, 0, 6);
    expect(feed(12, 8, 40), GpsReliability.reliable);

    tracker.reset();
    feed(30, 0, 12);
    expect(feed(12, 14, 40), GpsReliability.unreliable);
  });

  test('sin posiciones durante más de 10 s (sin señal) → no confiable', () {
    feed(4, 0, 6);
    expect(
      tracker.tick(t0.add(const Duration(seconds: 16))),
      GpsReliability.reliable,
    );
    expect(
      tracker.tick(t0.add(const Duration(seconds: 17))),
      GpsReliability.unreliable,
    );
  });
}
