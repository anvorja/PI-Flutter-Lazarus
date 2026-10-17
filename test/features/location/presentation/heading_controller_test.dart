/// HU-016: rumbo de la persona (brújula filtrada o rumbo de marcha del GPS),
/// calibración y respuesta a `get_heading`.
library;

import 'package:app/features/live/domain/entities/live_message.dart';
import 'package:app/features/live/presentation/providers/live_providers.dart';
import 'package:app/features/location/domain/entities/heading.dart';
import 'package:app/features/location/domain/entities/location_fix.dart';
import 'package:app/features/location/presentation/controllers/location_controller.dart';
import 'package:app/features/location/presentation/providers/location_providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/fakes.dart';

void main() {
  final t0 = DateTime(2026, 10, 13, 15);
  late FakeLocationRepository gps;
  late FakeCompassRepository compass;
  late FakeTrackRecorder track;
  late FakeLiveSessionRepository session;
  late List<String> logs;
  late ProviderContainer container;

  LocationController location() =>
      container.read(locationControllerProvider.notifier);
  LocationState state() => container.read(locationControllerProvider);
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  Future<void> facing(double degrees, {double? accuracy = 15}) async {
    compass.events.add(
      CompassReading(headingDeg: degrees, accuracyDeg: accuracy),
    );
    await settle();
  }

  // Coordenadas ficticias (golfo de Guinea): las pruebas no usan lugares reales.
  Future<void> fix({double? speed, double? course}) async {
    gps.fixes.add(
      LocationFix(
        latitude: 0,
        longitude: 0,
        accuracyM: 4,
        at: t0,
        speedMps: speed,
        courseDeg: course,
      ),
    );
    await settle();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    gps = FakeLocationRepository();
    compass = FakeCompassRepository();
    track = FakeTrackRecorder();
    session = FakeLiveSessionRepository();
    logs = [];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
    addTearDown(() => debugPrint = original);
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        liveSessionRepositoryProvider.overrideWithValue(session),
        networkStatusRepositoryProvider.overrideWithValue(FakeNetworkStatus()),
        mediaRepositoryProvider.overrideWithValue(FakeMediaRepository()),
        backgroundSessionRepositoryProvider.overrideWithValue(
          FakeBackgroundSession(),
        ),
        compassRepositoryProvider.overrideWithValue(compass),
        locationRepositoryProvider.overrideWithValue(gps),
        trackRecorderProvider.overrideWithValue(track),
        locationClockProvider.overrideWithValue(() => t0),
        screenAwakeProvider.overrideWithValue((_) async {}),
        announcerProvider.overrideWithValue((_, _) {}),
        announcerStopProvider.overrideWithValue(() {}),
        retryDelayProvider.overrideWithValue((_) => Duration.zero),
      ],
    );
    addTearDown(container.dispose);
    await location().start();
  });

  test('con la brújula calibrada dice hacia dónde mira', () async {
    await facing(90);
    final text = await location().describeHeadingForAssistant();
    expect(text, startsWith('ok: the person is standing and facing east'));
    expect(text, contains('from the compass'));
    expect(text, contains('without degrees'));
  });

  test('descalibrada, pide el movimiento en ocho antes de dar direcciones '
      '(criterio 2)', () async {
    await facing(90, accuracy: 45);
    final text = await location().describeHeadingForAssistant();
    expect(text, startsWith('needs_calibration'));
    expect(text, contains('figure eight'));
    expect(text, contains('Do not say a direction now'));

    // Tras calibrar, ya responde.
    await facing(90);
    expect(
      await location().describeHeadingForAssistant(),
      startsWith('ok: the person is standing and facing east'),
    );
    expect(logs, contains('[Lazarus] brújula: necesita calibración'));
    expect(logs, contains('[Lazarus] brújula: calibrada (±15°)'));
  });

  test('sin lecturas de la brújula no inventa un rumbo', () async {
    expect(
      await location().describeHeadingForAssistant(),
      startsWith('unavailable'),
    );
  });

  test('caminando a más de 0,5 m/s manda el rumbo de marcha del GPS '
      '(regla 1)', () async {
    await facing(90); // el teléfono apunta al este
    await fix(speed: 1.2, course: 180); // pero camina hacia el sur
    expect(state().heading!.source, HeadingSource.gps);
    final text = await location().describeHeadingForAssistant();
    expect(text, startsWith('ok: the person is walking towards south'));
    expect(text, contains('heading south'));
  });

  test('quieto o despacio usa la brújula', () async {
    await facing(90);
    await fix(speed: 0.3, course: 180);
    expect(state().heading!.source, HeadingSource.compass);
    expect(state().heading!.degrees, closeTo(90, 0.001));
  });

  test(
    'un punto a la derecha de la persona queda a las 3 (criterio 1)',
    () async {
      await facing(0); // mira al norte
      await fix();
      expect(location().clockHourTowards(0, 0.001), 3); // al este
      expect(location().clockHourTowards(0.001, 0), 12); // al frente
      expect(location().clockHourTowards(0, -0.001), 9); // a la izquierda

      await facing(90); // gira al este: el punto del este queda al frente
      for (var i = 0; i < 8; i++) {
        await facing(90);
      }
      expect(location().clockHourTowards(0, 0.001), 12);
    },
  );

  test('el recorrido guarda el rumbo de cada posición', () async {
    await facing(270);
    await fix();
    expect(track.headings.single!.degrees, closeTo(270, 0.001));
    expect(track.headings.single!.source, HeadingSource.compass);
  });

  test('el asistente pide get_heading y recibe la respuesta', () async {
    container.read(liveControllerProvider.notifier).onTap();
    await settle();
    session.emitSetupComplete();
    await settle();
    await facing(180);
    session.emitResponse(
      LiveResponse(
        type: LiveResponseType.toolCall,
        data: LiveToolCall(
          functionCalls: [
            LiveFunctionCall(id: 'h1', name: 'get_heading', args: {}),
          ],
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(
      session.toolResponses.single.result,
      startsWith('ok: the person is standing and facing south'),
    );
  });
}
