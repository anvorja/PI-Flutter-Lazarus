/// HU-022 (y HU-018 para esta ruta): guía por un perfil de ruta curado. Las
/// coordenadas son ficticias (cerca de 0,0): las reales viven en el backend.
library;

import 'dart:convert';

import 'package:app/features/access/presentation/providers/access_providers.dart';
import 'package:app/features/live/domain/entities/live_message.dart';
import 'package:app/features/live/presentation/controllers/live_controller.dart';
import 'package:app/features/live/presentation/providers/live_providers.dart';
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
          mediaRepositoryProvider.overrideWithValue(FakeMediaRepository()),
          backgroundSessionRepositoryProvider.overrideWithValue(
            FakeBackgroundSession(),
          ),
          compassRepositoryProvider.overrideWithValue(FakeCompassRepository()),
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

    test('validado en campo no lleva la advertencia', () async {
      access.routes = jsonEncode([_profileJson(validated: true)]);
      await connect();
      await reliableAt(0);
      expect(await callTool('start_route'), isNot(contains('not validated')));
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
  });
}
