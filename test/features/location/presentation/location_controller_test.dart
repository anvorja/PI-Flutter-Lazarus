/// HU-013: posición continua, log de precisión y respuesta a `get_location`.
library;

import 'package:app/features/live/domain/entities/live_message.dart';
import 'package:app/features/live/presentation/providers/live_providers.dart';
import 'package:app/features/location/domain/entities/location_fix.dart';
import 'package:app/features/location/presentation/controllers/location_controller.dart';
import 'package:app/features/location/presentation/providers/location_providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/fakes.dart';

void main() {
  final t0 = DateTime(2026, 9, 30, 8);
  late FakeLocationRepository gps;
  late FakeTrackRecorder track;
  late FakeLiveSessionRepository session;
  late List<String> logs;
  late ProviderContainer container;
  late List<bool> screenAwake;

  LocationController location() =>
      container.read(locationControllerProvider.notifier);
  LocationState state() => container.read(locationControllerProvider);
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  Future<void> emit(double accuracyM, int second) async {
    gps.fixes.add(
      LocationFix(
        latitude: 3.37531,
        longitude: -76.53252,
        accuracyM: accuracyM,
        at: t0.add(Duration(seconds: second)),
      ),
    );
    await settle();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    gps = FakeLocationRepository(address: 'Calle 13, Meléndez, Cali');
    track = FakeTrackRecorder();
    session = FakeLiveSessionRepository();
    logs = [];
    screenAwake = [];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
    addTearDown(() => debugPrint = original);
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        liveSessionRepositoryProvider.overrideWithValue(session),
        mediaRepositoryProvider.overrideWithValue(FakeMediaRepository()),
        locationRepositoryProvider.overrideWithValue(gps),
        trackRecorderProvider.overrideWithValue(track),
        locationClockProvider.overrideWithValue(() => t0),
        screenAwakeProvider.overrideWithValue(
          (on) async => screenAwake.add(on),
        ),
        announcerProvider.overrideWithValue((_, _) {}),
        retryDelayProvider.overrideWithValue((_) => Duration.zero),
      ],
    );
    addTearDown(container.dispose);
  });

  test('sin permiso no arranca y el asistente lo sabe', () async {
    gps.permission = LocationPermissionStatus.denied;
    await location().start();
    expect(location().running, isFalse);
    expect(await location().describeForAssistant(), startsWith('unavailable'));
  });

  test(
    'si activan la ubicación después, al preguntar la app reintenta',
    () async {
      gps.permission = LocationPermissionStatus.serviceDisabled;
      await location().start();
      expect(location().running, isFalse);

      gps.permission = LocationPermissionStatus.granted; // la persona la activó
      final text = await location().describeForAssistant();
      expect(location().running, isTrue);
      expect(gps.permissionRequests, 2);
      expect(
        text,
        startsWith('unavailable: no GPS position'),
      ); // aún sin posición
    },
  );

  test('sin posiciones todavía: el asistente dice que no la conoce', () async {
    await location().start();
    expect(
      await location().describeForAssistant(),
      startsWith('unavailable: no GPS position'),
    );
  });

  test('confiable: responde con la dirección y la precisión', () async {
    await location().start();
    for (var s = 0; s <= 6; s += 2) {
      await emit(4, s);
    }
    expect(state().reliability, GpsReliability.reliable);
    final text = await location().describeForAssistant();
    expect(text, startsWith('ok:'));
    expect(text, contains('Calle 13, Meléndez, Cali'));
    expect(text, contains('±4 m'));
  });

  test('no confiable: lo dice en lugar de dar una posición', () async {
    await location().start();
    for (var s = 0; s <= 12; s += 2) {
      await emit(35, s);
    }
    expect(state().reliability, GpsReliability.unreliable);
    final text = await location().describeForAssistant();
    expect(text, startsWith('unreliable'));
    expect(text, isNot(contains('Calle 13')));
  });

  test('registra cada posición y el porcentaje con precisión ≤ 10 m', () async {
    await location().start();
    await emit(4, 0);
    await emit(8, 2);
    await emit(12, 4);
    await emit(30, 6);
    location().stop();

    expect(logs, contains('[Lazarus] gps: ±4.0 m (unknown)'));
    expect(
      logs,
      contains(
        '[Lazarus] gps resumen: 4 posiciones, 50 % con precisión ≤ 10 m',
      ),
    );
  });

  test('al reiniciar el GPS el estado vuelve a "sin datos"', () async {
    await location().start();
    for (var s = 0; s <= 6; s += 2) {
      await emit(4, s);
    }
    expect(state().reliability, GpsReliability.reliable);
    location().stop();

    await location().start();
    expect(state().reliability, GpsReliability.unknown);
    expect(state().fix, isNull);
  });

  test(
    'la pantalla queda encendida mientras el GPS sigue a la persona',
    () async {
      await location().start();
      expect(screenAwake, [true]);
      location().stop();
      expect(screenAwake, [true, false]);
    },
  );

  test('sin permiso no mantiene la pantalla encendida', () async {
    gps.permission = LocationPermissionStatus.denied;
    await location().start();
    expect(screenAwake, isEmpty);
  });

  test('graba cada posición con su estado en el recorrido', () async {
    await location().start();
    expect(track.open, isTrue);
    for (var s = 0; s <= 6; s += 2) {
      await emit(4, s);
    }
    await emit(35, 8);
    location().stop();

    expect(track.open, isFalse);
    expect(track.rows.map((r) => r.accuracyM), [4, 4, 4, 4, 35]);
    expect(track.rows.first.reliability, GpsReliability.unknown);
    expect(track.rows[3].reliability, GpsReliability.reliable);
    await emit(4, 10); // tras detener ya no se graba
    expect(track.rows, hasLength(5));
  });

  group('con la sesión', () {
    Future<void> startSession() async {
      container.read(liveControllerProvider.notifier).onTap();
      await settle();
      session.emitSetupComplete();
      await settle();
    }

    test('el GPS arranca al iniciar y se detiene con Detener', () async {
      await startSession();
      expect(location().running, isTrue);
      container.read(liveControllerProvider.notifier).disconnect();
      expect(location().running, isFalse);
    });

    test('"¿dónde estoy?": get_location responde con la ubicación', () async {
      await startSession();
      for (var s = 0; s <= 6; s += 2) {
        await emit(5, s);
      }
      session.emitResponse(
        const LiveResponse(
          type: LiveResponseType.toolCall,
          data: LiveToolCall(
            functionCalls: [
              LiveFunctionCall(id: 'g1', name: 'get_location', args: {}),
            ],
          ),
        ),
      );
      await settle();
      await settle();

      final r = session.toolResponses.single;
      expect(r.id, 'g1');
      expect(r.result, contains('Calle 13, Meléndez, Cali'));
    });
  });
}
