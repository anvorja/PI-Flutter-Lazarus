/// HU-022 (y HU-018 para esta ruta): guía por un perfil de ruta curado. Las
/// coordenadas son ficticias (cerca de 0,0): las reales viven en el backend.
library;

import 'dart:convert';

import 'package:app/features/access/presentation/providers/access_providers.dart';
import 'package:app/features/field_notes/presentation/providers/field_notes_providers.dart';
import 'package:app/features/live/domain/entities/live_message.dart';
import 'package:app/features/live/presentation/controllers/live_controller.dart';
import 'package:app/features/live/presentation/providers/live_providers.dart';
import 'package:app/features/location/domain/entities/heading.dart';
import 'package:app/features/location/domain/entities/location_fix.dart';
import 'package:app/features/location/presentation/providers/location_providers.dart';
import 'package:app/features/routes/domain/route_guide.dart';
import 'package:app/features/routes/domain/route_profile.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fakes.dart';

/// Unos 100 m hacia el norte.
const double _step = 0.0009;

Map<String, Object?> _profileJson({
  String slug = 'estacion-prueba-ida',
  String destination = 'Entrada',
  double startLat = 0,
  bool validated = false,
}) => {
  'slug': slug,
  'name': 'Estación de prueba → $destination',
  'origin': 'Estación de prueba',
  'destination': destination,
  'direction': 'outbound',
  'family': 'A',
  'validated_in_field': validated,
  'points': [
    {
      'name': 'Torniquetes',
      'lat': startLat,
      'lon': 0,
      'instruction': 'Sal por la rampa con barandas',
    },
    {'name': 'Árbol grande', 'lat': startLat + _step, 'lon': 0},
    {
      'name': 'Cebra',
      'lat': startLat + 2 * _step,
      'lon': 0,
      'risk': 'high',
      'crossing': 'zebra',
      'instruction': 'Cruza por la cebra hacia la portería',
    },
    {'name': destination, 'lat': startLat + 3 * _step, 'lon': 0},
  ],
};

LocationFix _at(
  double lat, {
  double lon = 0,
  double accuracy = 5,
  DateTime? at,
}) => LocationFix(
  latitude: lat,
  longitude: lon,
  accuracyM: accuracy,
  at: at ?? DateTime(2026, 10, 24, 9),
);

void main() {
  final profile = RouteProfile.fromJson(_profileJson());
  const ok = GpsReliability.reliable;

  group('avance por el perfil', () {
    test('en el primer punto da su indicación y el siguiente', () {
      final guide = RouteGuide(profile);
      final event = guide.update(_at(0), ok)!;
      expect(event.kind, RouteEventKind.arrived);
      final message = describeRouteEvent(event, _at(0), (_) => 2);
      expect(message, startsWith("reached point 1 of 4: 'Torniquetes'."));
      expect(message, contains("Instruction: 'Sal por la rampa con barandas'"));
      expect(message, contains("Next: 'Árbol grande', about 135 steps at 2"));
    });

    test('avisa una vez al acercarse y luego al llegar', () {
      final guide = RouteGuide(profile)..update(_at(0), ok);
      expect(guide.update(_at(_step * 0.2), ok), isNull);
      final near = guide.update(_at(_step * 0.5), ok)!;
      expect(near.kind, RouteEventKind.approaching);
      expect(near.point.name, 'Árbol grande');
      expect(guide.update(_at(_step * 0.6), ok), isNull); // no se repite
      final arrived = guide.update(_at(_step), ok)!;
      expect(arrived.kind, RouteEventKind.arrived);
      expect(arrived.index, 1);
    });

    test('sin GPS confiable no hay avisos (HU-018, regla 4)', () {
      final guide = RouteGuide(profile);
      expect(guide.update(_at(0), GpsReliability.unreliable), isNull);
      expect(guide.update(_at(0), GpsReliability.unknown), isNull);
      expect(guide.update(_at(0), ok)!.kind, RouteEventKind.arrived);
    });

    test('un punto que se pasó sin señal no detiene la guía', () {
      final guide = RouteGuide(profile)..update(_at(0), ok);
      final event = guide.update(_at(2 * _step), ok)!;
      expect(event.index, 2);
      final message = describeRouteEvent(event, _at(2 * _step), (_) => null);
      expect(message, contains('crossing: zebra crossing. risk: high.'));
      expect(message, contains("Next: 'Entrada', about 135 steps."));
    });

    test('al último punto la ruta termina', () {
      final guide = RouteGuide(profile)
        ..update(_at(0), ok)
        ..update(_at(_step), ok)
        ..update(_at(2 * _step), ok);
      final end = guide.update(_at(3 * _step), ok)!;
      expect(end.kind, RouteEventKind.finished);
      expect(guide.finished, isTrue);
      expect(
        describeRouteEvent(end, _at(3 * _step), (_) => 12),
        contains('finished'),
      );
      expect(guide.update(_at(3 * _step), ok), isNull);
    });

    test('con un GPS impreciso, el radio de llegada crece hasta 10 m', () {
      final tight = RouteProfile.fromJson({
        ..._profileJson(),
        'points': [
          {'name': 'A', 'lat': 0, 'lon': 0, 'arrive_m': 4, 'approach_m': 12},
          {'name': 'B', 'lat': _step, 'lon': 0},
        ],
      });
      const off = -0.00007; // ~7,8 m antes de A
      expect(
        RouteGuide(tight).update(_at(off, accuracy: 3), ok)!.kind,
        RouteEventKind.approaching,
      );
      expect(
        RouteGuide(tight).update(_at(off, accuracy: 9), ok)!.kind,
        RouteEventKind.arrived,
      );
      const far = -0.0001; // ~11 m antes de A: más que el tope
      expect(
        RouteGuide(tight).update(_at(far, accuracy: 30), ok)!.kind,
        RouteEventKind.approaching,
      );
    });

    test('si va hacia el siguiente sin entrar al radio, lo da por pasado', () {
      final guide = RouteGuide(profile)..update(_at(0), ok);
      // Lejos del radio del árbol (15 m), pero más cerca de la cebra que él.
      final passed = guide.update(_at(_step * 1.3), ok)!;
      expect(passed.kind, RouteEventKind.passed);
      expect(passed.point.name, 'Árbol grande');
      expect(
        describeRouteEvent(passed, _at(_step * 1.3), (_) => null),
        "passed point 2 of 4: 'Árbol grande' without reaching it.",
      );
      expect(guide.nextPoint!.name, 'Cebra');
      expect(guide.update(_at(2 * _step), ok)!.kind, RouteEventKind.arrived);
    });

    test('en un tramo en U no salta el punto de la vuelta', () {
      // B está 33 m al norte de A; C, a unos 15 m de A, ya de regreso.
      final u = RouteProfile.fromJson({
        ..._profileJson(),
        'points': [
          {'name': 'A', 'lat': 0, 'lon': 0},
          {'name': 'B', 'lat': 0.0003, 'lon': 0, 'instruction': 'Gira'},
          {'name': 'C', 'lat': 0.0001, 'lon': 0.0001},
        ],
      });
      final guide = RouteGuide(u)..update(_at(0), ok);
      // A 5 m de A: más cerca de C que B, y dentro del radio de C.
      expect(guide.update(_at(0.00005), ok), isNull);
      expect(guide.nextPoint!.name, 'B');
      final b = guide.update(_at(0.0003), ok)!;
      expect(b.kind, RouteEventKind.arrived);
      expect(b.point.name, 'B');
    });

    test('al llegar, si el siguiente es un cruce, lo dice', () {
      final guide = RouteGuide(profile, startAt: 1);
      final event = guide.update(_at(_step), ok)!;
      expect(
        describeRouteEvent(event, _at(_step), (_) => null),
        endsWith(
          "Next: 'Cebra', about 135 steps. crossing: zebra crossing. "
          'risk: high.',
        ),
      );
    });

    test('se retoma en el punto más cercano', () {
      expect(nearestPointIndex(profile, _at(_step * 2.1)), 2);
      final guide = RouteGuide(profile, startAt: 2);
      expect(guide.nextPoint!.name, 'Cebra');
      expect(guide.update(_at(2 * _step), ok)!.index, 2);
    });

    test('si el siguiente punto ya está cerca, no se anuncia dos veces', () {
      final close = RouteProfile.fromJson({
        ..._profileJson(),
        'points': [
          {'name': 'A', 'lat': 0, 'lon': 0},
          {'name': 'B', 'lat': 0.0003, 'lon': 0}, // ~33 m
          {'name': 'C', 'lat': 0.0006, 'lon': 0},
        ],
      });
      final guide = RouteGuide(close)..update(_at(0), ok);
      expect(guide.update(_at(0.0001), ok), isNull);
      expect(guide.update(_at(0.0003), ok)!.kind, RouteEventKind.arrived);
    });
  });

  group('fuera de la ruta y reenganche (27-oct, Unicentro)', () {
    // Seis puntos cada ~100 m hacia el norte.
    final long = RouteProfile.fromJson({
      ..._profileJson(),
      'points': [
        for (var i = 0; i < 6; i++)
          {'name': 'P${i + 1}', 'lat': i * _step, 'lon': 0, 'arrive_m': 8},
      ],
    });

    test('a mitad de un tramo largo no está fuera de la ruta', () {
      final guide = RouteGuide(long)..update(_at(0), ok);
      for (final f in [0.3, 0.4, 0.5, 0.6]) {
        final e = guide.update(_at(_step * f), ok);
        expect(e?.kind, isNot(RouteEventKind.offRoute));
      }
    });

    test('lejos de los tramos que faltan lo dice una sola vez, con el punto '
        'más cercano', () {
      final guide = RouteGuide(long)..update(_at(0), ok);
      final aside = _at(_step * 2, lon: 0.0006); // ~65 m al este del P3
      expect(guide.update(aside, ok), isNull);
      expect(guide.update(aside, ok), isNull);
      final off = guide.update(aside, ok)!;
      expect(off.kind, RouteEventKind.offRoute);
      expect(off.point.name, 'P3');
      final message = describeRouteEvent(off, aside, (_) => 3);
      expect(message, startsWith('off route:'));
      expect(message, contains("point 3 of 6, 'P3'"));
      expect(message, contains("at 3 o'clock"));
      for (var i = 0; i < 5; i++) {
        expect(guide.update(aside, ok), isNull); // no se repite
      }
    });

    test(
      'al llegar a un punto más adelante por otro camino, sigue desde ahí',
      () {
        final guide = RouteGuide(long)..update(_at(0), ok);
        final p5 = _at(_step * 4);
        expect(guide.update(p5, ok), isNull); // una sola posición no basta
        final back = guide.update(p5, ok)!;
        expect(back.kind, RouteEventKind.rejoined);
        expect(back.index, 4);
        expect(guide.nextPoint!.name, 'P6');
        expect(
          describeRouteEvent(back, p5, (_) => null),
          startsWith("back on the route at point 5 of 6: 'P5'."),
        );
      },
    );

    test('un salto aislado del GPS no reengancha', () {
      final guide = RouteGuide(long)..update(_at(0), ok);
      expect(guide.update(_at(_step * 4), ok), isNull);
      guide.update(_at(_step * 0.3), ok);
      expect(guide.update(_at(_step * 4), ok), isNull);
      expect(guide.nextPoint!.name, 'P2');
    });

    test('el reenganche al último punto termina la ruta', () {
      final guide = RouteGuide(long)..update(_at(0), ok);
      guide.update(_at(_step * 5), ok);
      expect(guide.update(_at(_step * 5), ok)!.kind, RouteEventKind.finished);
      expect(guide.finished, isTrue);
    });
  });

  group('elegir el perfil', () {
    final other = RouteProfile.fromJson(
      _profileJson(
        slug: 'estacion-prueba-biblioteca',
        destination: 'Biblioteca',
      ),
    );
    final far = RouteProfile.fromJson(
      _profileJson(slug: 'otra-estacion', startLat: 0.01), // ~1,1 km
    );

    test('el que empieza cerca, y el del destino que dijo', () {
      final routes = [far, other, profile];
      expect(pickRoute(routes, _at(0), '')!.slug, 'estacion-prueba-biblioteca');
      expect(
        pickRoute(routes, _at(0), 'a la entrada')!.slug,
        'estacion-prueba-ida',
      );
      expect(
        pickRoute(routes, _at(0), 'a la biblioteca')!.slug,
        'estacion-prueba-biblioteca',
      );
      expect(pickRoute([far], _at(0), ''), isNull);
    });

    test(
      'a mitad de camino sirve cualquier punto, y cuenta solo el destino',
      () {
        final back = RouteProfile.fromJson({
          ..._profileJson(slug: 'vuelta', destination: 'Estación de prueba'),
          'name': 'Univalle → Estación de prueba',
          'origin': 'Univalle',
        });
        final ida = RouteProfile.fromJson(
          _profileJson(slug: 'ida', destination: 'Univalle'),
        );
        // ~330 m del primer punto, junto al último.
        final mid = _at(_step * 3);
        expect(
          pickRoute([back, ida], mid, 'la Universidad del Valle')!.slug,
          'ida',
        );
        expect(pickRoute([ida, back], mid, 'la estación')!.slug, 'vuelta');
      },
    );

    test('un destino intermedio elige el perfil que lo tiene por delante, no '
        'el que ya terminó (27-oct: "llévame a Unicentro")', () {
      final ida = RouteProfile.fromJson({
        ..._profileJson(slug: 'ida', destination: 'Univalle'),
        'points': [
          {'name': 'Torniquetes', 'lat': 0.0001, 'lon': 0},
          {'name': 'Entrada de Unicentro', 'lat': _step, 'lon': 0},
          {'name': 'Univalle', 'lat': 2 * _step, 'lon': 0},
        ],
      });
      final vuelta = RouteProfile.fromJson({
        ..._profileJson(slug: 'vuelta', destination: 'Estación de prueba'),
        'points': [
          {'name': 'Univalle', 'lat': 2 * _step, 'lon': 0},
          {'name': 'Salida de Unicentro', 'lat': _step, 'lon': 0},
          {'name': 'Torniquetes', 'lat': 0, 'lon': 0},
        ],
      });
      // En la estación: el último punto de la vuelta es el más cercano.
      expect(pickRoute([vuelta, ida], _at(0), 'Unicentro')!.slug, 'ida');
      // Sin destino, la que no terminó.
      expect(pickRoute([vuelta, ida], _at(0), '')!.slug, 'ida');
    });

    test('un destino que no es el de ningún perfil no elige ninguno '
        '(28-oct: "Utrega", LAZA-128)', () {
      final routes = [other, profile];
      expect(pickRoute(routes, _at(0), 'Utrega'), isNull);
      expect(pickRoute(routes, _at(0), 'el cine'), isNull);
      expect(isUnknownDestination(routes, _at(0), 'Utrega'), isTrue);
      expect(
        destinationsNear([profile, other, far], _at(0)),
        unorderedEquals(['Entrada', 'Biblioteca']),
      );
      // Lejos de toda ruta no es un destino desconocido: no hay ruta.
      expect(isUnknownDestination([far], _at(0), 'Utrega'), isFalse);
      // Un destino conocido o ninguno no es desconocido.
      expect(isUnknownDestination(routes, _at(0), 'la biblioteca'), isFalse);
      expect(isUnknownDestination(routes, _at(0), ''), isFalse);
    });

    test('"la universidad" es Univalle, pero "Universidades" no', () {
      final ida = RouteProfile.fromJson(
        _profileJson(slug: 'ida', destination: 'Univalle'),
      );
      final otra = RouteProfile.fromJson(
        _profileJson(slug: 'otra', destination: 'Universidades'),
      );
      expect(pickRoute([otra, ida], _at(0), 'a la universidad')!.slug, 'ida');
      expect(pickRoute([ida, otra], _at(0), 'a Universidades')!.slug, 'otra');
    });

    test('"guíame por mi ruta" no es un destino', () {
      final routes = [other, profile];
      expect(
        pickRoute(routes, _at(0), 'guíame por mi ruta')!.slug,
        'estacion-prueba-biblioteca',
      );
      expect(isUnknownDestination(routes, _at(0), 'mi ruta'), isFalse);
    });

    test('un perfil mal formado se descarta', () {
      final body = jsonEncode([
        _profileJson(),
        {'slug': 'roto'},
      ]);
      expect(
        RouteProfile.listFromJson(body).single.slug,
        'estacion-prueba-ida',
      );
      expect(RouteProfile.listFromJson('{}'), isEmpty);
    });

    test('pasos aproximados', () {
      expect(stepsFor(1), 5);
      expect(stepsFor(100), 135);
    });
  });

  group('en la sesión', () {
    late FakeLiveSessionRepository session;
    late FakeLocationRepository gps;
    late FakeDeviceAccess access;
    late FakeMediaRepository media;
    late FakeNoteRecorder notes;
    late FakeStepCounter steps;
    late FakeCompassRepository compass;
    late List<int> pulses;
    late List<String> logs;
    late ProviderContainer container;
    final t0 = DateTime(2026, 10, 24, 9);
    late DateTime now;

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 10));

    Future<String> callTool(
      String name, [
      Map<String, dynamic> args = const {},
    ]) async {
      session.emitResponse(
        LiveResponse(
          type: LiveResponseType.toolCall,
          data: LiveToolCall(
            functionCalls: [LiveFunctionCall(id: name, name: name, args: args)],
          ),
        ),
      );
      await settle();
      return session.toolResponses.last.result;
    }

    /// Posiciones buenas durante 6 s: el GPS pasa a confiable (HU-013).
    Future<void> reliableAt(double lat) async {
      for (final s in [0, 3, 6]) {
        gps.fixes.add(_at(lat, at: t0.add(Duration(seconds: s))));
      }
      await settle();
    }

    LiveController live() => container.read(liveControllerProvider.notifier);

    setUp(() async {
      now = t0;
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      session = FakeLiveSessionRepository();
      gps = FakeLocationRepository();
      access = FakeDeviceAccess()..routes = jsonEncode([_profileJson()]);
      media = FakeMediaRepository();
      notes = FakeNoteRecorder();
      steps = FakeStepCounter();
      compass = FakeCompassRepository();
      pulses = [];
      logs = [];
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
      addTearDown(() => debugPrint = original);
      container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          liveSessionRepositoryProvider.overrideWithValue(session),
          networkStatusRepositoryProvider.overrideWithValue(
            FakeNetworkStatus(),
          ),
          mediaRepositoryProvider.overrideWithValue(media),
          noteRecorderProvider.overrideWithValue(notes),
          cameraLockDelayProvider.overrideWithValue(Duration.zero),
          cameraUnlockDelayProvider.overrideWithValue(Duration.zero),
          backgroundSessionRepositoryProvider.overrideWithValue(
            FakeBackgroundSession(),
          ),
          compassRepositoryProvider.overrideWithValue(compass),
          stepCounterProvider.overrideWithValue(steps),
          hapticPulsesProvider.overrideWithValue((n) async => pulses.add(n)),
          locationRepositoryProvider.overrideWithValue(gps),
          trackRecorderProvider.overrideWithValue(FakeTrackRecorder()),
          deviceAccessRepositoryProvider.overrideWithValue(access),
          screenAwakeProvider.overrideWithValue((_) async {}),
          liveClockProvider.overrideWithValue(() => now),
          announcerProvider.overrideWithValue((_, _) {}),
          announcerStopProvider.overrideWithValue(() {}),
          retryDelayProvider.overrideWithValue((_) => Duration.zero),
        ],
      );
      addTearDown(container.dispose);
    });

    /// Abre la sesión: al conectar se descargan los perfiles.
    Future<void> connect() async {
      live().onTap();
      await settle();
      session.emitSetupComplete();
      await settle();
    }

    test(
      'start_route elige el perfil, advierte que no está validado y guía',
      () async {
        await connect();
        expect(logs, contains('[Lazarus] ruta: 1 perfiles disponibles'));
        await reliableAt(0);
        final result = await callTool('start_route', {
          'destination': 'la entrada',
        });
        expect(
          result,
          startsWith("ok: guiding along 'Estación de prueba → Entrada'"),
        );
        expect(result, contains('not validated'));

        live().checkRoute();
        await settle();
        expect(
          session.routeGuides.single,
          startsWith("reached point 1 of 4: 'Torniquetes'"),
        );
        live().checkRoute(); // misma posición: nada nuevo
        expect(session.routeGuides, hasLength(1));

        gps.fixes.add(_at(_step, at: t0.add(const Duration(seconds: 9))));
        await settle();
        live().checkRoute();
        await settle();
        expect(
          session.routeGuides.last,
          startsWith("reached point 2 of 4: 'Árbol grande'"),
        );
      },
    );

    test(
      'start_route con la misma ruta activa no la reinicia (27-oct)',
      () async {
        await connect();
        await reliableAt(0);
        await callTool('start_route', {'destination': 'la entrada'});
        live().checkRoute();
        await settle();
        gps.fixes.add(_at(_step, at: t0.add(const Duration(seconds: 9))));
        await settle();
        live().checkRoute();
        await settle();
        final guides = session.routeGuides.length;
        final again = await callTool('start_route', {'destination': 'Entrada'});
        expect(again, startsWith('already_active:'));
        expect(again, contains("Next: point 3 of 4, 'Cebra'"));
        expect(again, isNot(contains('not validated')));
        live().checkRoute();
        await settle();
        expect(session.routeGuides, hasLength(guides)); // no repite el punto 2
        expect(
          logs,
          contains(
            '[Lazarus] ruta: ya activa "estacion-prueba-ida", no se reinicia (siguiente: punto 3)',
          ),
        );
      },
    );

    test('validado en campo no lleva la advertencia', () async {
      access.routes = jsonEncode([_profileJson(validated: true)]);
      await connect();
      await reliableAt(0);
      expect(await callTool('start_route'), isNot(contains('not validated')));
    });

    test('un destino desconocido no arranca ninguna ruta y pregunta '
        '(LAZA-128)', () async {
      await connect();
      await reliableAt(0);
      final result = await callTool('start_route', {'destination': 'Utrega'});
      expect(result, startsWith('unknown_destination:'));
      expect(result, contains("go to: 'Entrada'"));
      live().checkRoute();
      await settle();
      expect(session.routeGuides, isEmpty);
      expect(
        logs,
        contains(
          '[Lazarus] ruta: destino "Utrega" sin perfil; no se inicia '
          '(destinos cerca: Entrada)',
        ),
      );
    });

    test('un destino desconocido en espera del GPS tampoco arranca', () async {
      await connect();
      expect(
        await callTool('start_route', {'destination': 'Utrega'}),
        startsWith('waiting_gps'),
      );
      await reliableAt(0);
      live().checkRoute();
      await settle();
      expect(
        session.routeGuides.single,
        startsWith('not started. unknown_destination:'),
      );
      live().checkRoute();
      await settle();
      expect(session.routeGuides, hasLength(1));
    });

    test('lejos de toda ruta no arranca', () async {
      await connect();
      await reliableAt(0.05); // ~5,5 km
      expect(await callTool('start_route'), startsWith('none'));
    });

    test('sin GPS confiable espera y arranca sola cuando lo es', () async {
      await connect();
      expect(await callTool('start_route'), startsWith('waiting_gps'));
      live().checkRoute();
      await settle();
      expect(session.routeGuides, isEmpty);
      await reliableAt(2 * _step);
      live().checkRoute();
      await settle();
      expect(
        session.routeGuides.single,
        startsWith('started now that the GPS is reliable.'),
      );
      expect(session.routeGuides.single, contains('Resuming at point 3 of 4'));
      live().checkRoute();
      await settle();
      expect(
        session.routeGuides.last,
        startsWith("reached point 3 of 4: 'Cebra'"),
      );
    });

    test('si el GPS no se recupera en 5 minutos, desiste y lo dice', () async {
      await connect();
      await callTool('start_route');
      now = t0.add(routeGpsWait);
      live().checkRoute();
      await settle();
      expect(session.routeGuides.single, startsWith('not started'));
      live().checkRoute();
      await settle();
      expect(session.routeGuides, hasLength(1));
      expect(await callTool('stop_route'), 'ok: there was no active route.');
    });

    test('stop_route cancela una ruta en espera del GPS', () async {
      await connect();
      await callTool('start_route');
      expect(
        await callTool('stop_route'),
        startsWith('ok: route guidance stopped'),
      );
      await reliableAt(0);
      live().checkRoute();
      await settle();
      expect(session.routeGuides, isEmpty);
    });

    test('stop_route deja de guiar', () async {
      await connect();
      await reliableAt(0);
      await callTool('start_route');
      expect(
        await callTool('stop_route'),
        startsWith('ok: route guidance stopped'),
      );
      live().checkRoute();
      await settle();
      expect(session.routeGuides, isEmpty);
      expect(await callTool('stop_route'), 'ok: there was no active route.');
    });

    test('un corte de conexión no borra la ruta (27-oct)', () async {
      await connect();
      await reliableAt(0);
      await callTool('start_route');
      live().checkRoute(); // torniquetes
      await settle();
      // El corte llega un minuto después: el aviso ya no se repite (LAZA-127).
      now = t0.add(const Duration(minutes: 1));
      session.emitError();
      await settle();
      session.emitSetupComplete();
      await settle();
      expect(
        session.routeGuides.last,
        startsWith(
          "still guiding: the app is still guiding along 'Estación de prueba "
          "→ Entrada'. Next: point 2 of 4, 'Árbol grande'.",
        ),
      );
      gps.fixes.add(_at(_step, at: t0.add(const Duration(seconds: 9))));
      await settle();
      live().checkRoute();
      await settle();
      expect(session.routeGuides.last, startsWith('reached point 2 of 4'));
    });

    /// Recorre la ruta hasta el último punto: la guía avisa la llegada.
    Future<void> walkToTheEnd() async {
      for (var i = 0; i < 4; i++) {
        gps.fixes.add(_at(i * _step, at: t0.add(Duration(seconds: 9 + 3 * i))));
        await settle();
        live().checkRoute();
        await settle();
      }
    }

    test('un aviso cortado al cambiar de sesión se repite en la nueva '
        '(28-oct, LAZA-127)', () async {
      await connect();
      await reliableAt(0);
      await callTool('start_route');
      live().checkRoute(); // torniquetes: el aviso no alcanza a sonar
      await settle();
      now = t0.add(const Duration(seconds: 3));
      session.emitError();
      await settle();
      session.emitSetupComplete();
      await settle();
      expect(
        session.routeGuides.last,
        startsWith('repeat: the session changed while you were saying this'),
      );
      expect(session.routeGuides.last, contains("reached point 1 of 4"));
      expect(
        session.routeGuides.where((m) => m.startsWith('still guiding')),
        isEmpty,
      );
      expect(
        logs,
        contains(
          '[Lazarus] ruta: se repite el aviso cortado al cambiar de sesión',
        ),
      );
    });

    test('bloquear la pantalla espera a que suene el aviso de ruta '
        '(LAZA-127)', () async {
      await connect();
      await reliableAt(0);
      await callTool('start_route');
      live().checkRoute(); // torniquetes
      await settle();
      final calls = session.connectCalls;
      live().onVisibilityChanged(false);
      await settle();
      expect(session.connectCalls, calls, reason: 'el aviso aún no suena');
      expect(
        logs,
        contains(
          '[Lazarus] cambio de sesión en espera: suena un aviso de ruta',
        ),
      );
      // El asistente dice el aviso completo; recién ahí cambia la sesión.
      session.emitResponse(
        const LiveResponse(type: LiveResponseType.audio, data: 'AAAA'),
      );
      session.emitResponse(
        const LiveResponse(type: LiveResponseType.turnComplete),
      );
      await settle();
      media.onDrained!();
      await settle();
      expect(session.connectCalls, calls + 1);
      session.emitSetupComplete();
      await settle();
      expect(session.routeGuides.last, startsWith('still guiding'));
    });

    test('un aviso cortado hace rato no se repite', () async {
      await connect();
      await reliableAt(0);
      await callTool('start_route');
      live().checkRoute();
      await settle();
      now = t0.add(const Duration(seconds: 50));
      session.emitError();
      await settle();
      session.emitSetupComplete();
      await settle();
      expect(session.routeGuides.last, startsWith('still guiding'));
      expect(
        logs,
        contains(
          '[Lazarus] ruta: aviso cortado al cambiar de sesión, descartado '
          '(pasaron 50 s)',
        ),
      );
    });

    test('la llegada cortada se repite si no empezó otra ruta', () async {
      await connect();
      await reliableAt(0);
      await callTool('start_route');
      await walkToTheEnd();
      expect(session.routeGuides.last, startsWith('finished'));
      session.emitError();
      await settle();
      session.emitSetupComplete();
      await settle();
      expect(session.routeGuides.last, startsWith('repeat:'));
      expect(session.routeGuides.last, contains('finished'));
    });

    test('la llegada cortada no se repite si ya empezó otra ruta', () async {
      await connect();
      await reliableAt(0);
      await callTool('start_route');
      await walkToTheEnd();
      final guides = session.routeGuides.length;
      await callTool('start_route', {'destination': 'la entrada'});
      session.emitError();
      await settle();
      session.emitSetupComplete();
      await settle();
      expect(
        session.routeGuides.skip(guides).where((m) => m.startsWith('repeat')),
        isEmpty,
      );
    });

    test('una nota dictada con la ruta activa lleva la ruta y el punto al que '
        'iba (HU-050)', () async {
      await connect();
      await reliableAt(0);
      await callTool('add_note', {'text': 'antes de la ruta'});
      await callTool('start_route');
      live().checkRoute(); // torniquetes: el siguiente es el punto 2
      await settle();
      await callTool('add_note', {'text': 'aquí la rampa está a la izquierda'});
      expect(notes.notes.first.route, isNull);
      final noted = notes.notes.last;
      expect(noted.route, 'estacion-prueba-ida');
      expect(noted.nextPoint, 2);
      expect(noted.nextPointName, 'Árbol grande');
      await callTool('stop_route');
      await callTool('add_note', {'text': 'después de la ruta'});
      expect(notes.notes.last.route, isNull);
    });

    test('Detener sí termina la ruta', () async {
      await connect();
      await reliableAt(0);
      await callTool('start_route');
      live().disconnect();
      await settle();
      await connect();
      expect(session.routeGuides, isEmpty);
      live().checkRoute();
      await settle();
      expect(session.routeGuides, isEmpty);
    });

    test('en modo reunión solo pasan los cruces y los riesgos altos', () async {
      await connect();
      await reliableAt(0);
      await callTool('start_route');
      await callTool('set_meeting_mode', {'enabled': true});
      live().checkRoute(); // torniquetes: no se dice
      await settle();
      expect(session.routeGuides, isEmpty);
      gps.fixes.add(_at(2 * _step, at: t0.add(const Duration(seconds: 9))));
      await settle();
      live().checkRoute(); // la cebra sí
      await settle();
      expect(session.routeGuides.single, contains('crossing: zebra crossing'));
    });

    test('de noche, el aviso de un cruce pide decir que con poca luz no ve '
        'los colores; de día no (HU-020)', () async {
      await connect();
      await reliableAt(0);
      await callTool('start_route');
      live().checkRoute(); // torniquetes, de día
      await settle();
      expect(session.routeGuides.last, isNot(contains('It is night')));
      now = DateTime(2026, 10, 24, 19, 30);
      gps.fixes.add(_at(_step, at: t0.add(const Duration(seconds: 9))));
      await settle();
      live().checkRoute(); // árbol grande: el siguiente es la cebra
      await settle();
      expect(session.routeGuides.last, contains('crossing: zebra crossing'));
      expect(session.routeGuides.last, contains('It is night'));
    });

    test('al llegar a un cruce vibra hacia la otra acera (HU-020)', () async {
      await connect();
      await reliableAt(0);
      compass.events.add(const CompassReading(headingDeg: 0, accuracyDeg: 5));
      await settle();
      await callTool('start_route');
      live().checkRoute(); // torniquetes: no es cruce
      await settle();
      expect(pulses, isEmpty);
      gps.fixes.add(_at(_step, at: t0.add(const Duration(seconds: 9))));
      await settle();
      live().checkRoute(); // árbol grande, antes de la cebra
      await settle();
      expect(pulses, [1]); // la cebra queda al frente
    });

    test('sin GPS confiable lo dice una vez y luego que volvió (HU-021, fase '
        '1)', () async {
      await connect();
      await reliableAt(0);
      await callTool('start_route');
      live().checkRoute(); // torniquetes
      await settle();
      for (final s in [9, 15, 21]) {
        gps.fixes.add(
          _at(_step, accuracy: 40, at: t0.add(Duration(seconds: s))),
        );
      }
      await settle();
      live().checkRoute();
      await settle();
      expect(session.routeGuides.last, startsWith('gps lost:'));
      expect(session.routeGuides.last, contains('Never say which point'));
      expect(session.routeGuides.last, contains('camera'));
      live().checkRoute(); // sigue sin GPS: no se repite
      await settle();
      expect(session.routeGuides, hasLength(2));
      expect(logs, contains('[Lazarus] ruta: GPS no confiable (±40 m)'));

      for (final s in [24, 27, 30]) {
        gps.fixes.add(_at(_step, at: t0.add(Duration(seconds: s))));
      }
      await settle();
      live().checkRoute();
      await settle();
      expect(
        session.routeGuides.last,
        startsWith('gps back: the GPS is reliable again'),
      );
      expect(
        session.routeGuides.last,
        contains("Next: point 2 of 4, 'Árbol grande'"),
      );
      live().checkRoute();
      await settle();
      expect(
        session.routeGuides.last,
        startsWith("reached point 2 of 4: 'Árbol grande'"),
      );
    });

    test('una sesión nueva sin GPS confiable recuerda que no afirme el punto '
        '(HU-021)', () async {
      await connect();
      await reliableAt(0);
      await callTool('start_route');
      for (final s in [9, 15, 21]) {
        gps.fixes.add(_at(0, accuracy: 40, at: t0.add(Duration(seconds: s))));
      }
      await settle();
      live().checkRoute();
      await settle();
      expect(session.routeGuides.last, startsWith('gps lost:'));
      now = t0.add(const Duration(minutes: 1));
      session.emitError();
      await settle();
      session.emitSetupComplete();
      await settle();
      expect(session.routeGuides.last, startsWith('still guiding:'));
      expect(session.routeGuides.last, contains('gps lost:'));
    });

    /// Con la ruta activa en el primer punto, el GPS pasa a no confiable.
    Future<void> loseGps() async {
      await connect();
      await reliableAt(0);
      await callTool('start_route');
      live().checkRoute(); // torniquetes
      await settle();
      for (final s in [9, 15, 21]) {
        gps.fixes.add(_at(0, accuracy: 40, at: t0.add(Duration(seconds: s))));
      }
      await settle();
      live().checkRoute();
      await settle();
      expect(session.routeGuides.last, startsWith('gps lost:'));
    }

    test('sin GPS cuenta los pasos y a los 3 minutos sugiere ayuda o el SOS, '
        'una vez (HU-021)', () async {
      await loseGps();
      expect(steps.running, isTrue);
      now = t0.add(const Duration(minutes: 2));
      live().checkRoute();
      await settle();
      expect(session.routeGuides.last, startsWith('gps lost:'));

      now = t0.add(routeGpsHelpAfter + const Duration(seconds: 30));
      live().checkRoute();
      await settle();
      expect(session.routeGuides.last, startsWith('gps still lost:'));
      expect(session.routeGuides.last, contains('trigger_sos only if'));
      final count = session.routeGuides.length;
      now = t0.add(const Duration(minutes: 6));
      live().checkRoute();
      await settle();
      expect(session.routeGuides, hasLength(count));

      for (final s in [400, 403, 406]) {
        gps.fixes.add(_at(0, at: t0.add(Duration(seconds: s))));
      }
      await settle();
      live().checkRoute();
      await settle();
      expect(session.routeGuides.last, startsWith('gps back:'));
      expect(steps.running, isFalse);
    });

    test('get_route_progress sin GPS da una estimación con los pasos y vibra '
        'hacia el punto (HU-021)', () async {
      await loseGps();
      compass.events.add(const CompassReading(headingDeg: 0, accuracyDeg: 5));
      await settle();
      steps.steps = 42;
      final progress = await callTool('get_route_progress');
      expect(progress, startsWith('estimate: the GPS is still lost.'));
      expect(progress, contains('about 42 steps'));
      expect(progress, contains("'Árbol grande'"));
      expect(progress, contains('never as a sure position'));
      expect(pulses, isNotEmpty);
      expect(pulses.last, 1); // el punto queda al frente (norte)
    });

    test(
      'get_route_progress con GPS da el siguiente punto; sin ruta lo dice',
      () async {
        await connect();
        expect(await callTool('get_route_progress'), startsWith('none:'));
        await reliableAt(0);
        await callTool('start_route');
        live().checkRoute();
        await settle();
        expect(
          await callTool('get_route_progress'),
          startsWith("ok: next point 2 of 4, 'Árbol grande'"),
        );
      },
    );
  });

  test('pulsos de la vibración direccional (HU-021, regla 3)', () {
    expect([12, 1, 11].map(directionPulses), [1, 1, 1]);
    expect([2, 3, 4].map(directionPulses), [2, 2, 2]);
    expect([8, 9, 10].map(directionPulses), [3, 3, 3]);
    expect([5, 6, 7, null].map(directionPulses), [0, 0, 0, 0]);
  });

  test('franja nocturna de 18:00 a 6:00 (HU-020)', () {
    expect(isNight(DateTime(2026, 10, 30, 17, 59)), isFalse);
    expect(isNight(DateTime(2026, 10, 30, 18)), isTrue);
    expect(isNight(DateTime(2026, 10, 30, 5, 59)), isTrue);
    expect(isNight(DateTime(2026, 10, 30, 6)), isFalse);
  });
}
