/// HU-019: regla horaria dura de la Ruta A por Unicentro, con reloj simulado.
library;

import 'package:app/features/live/domain/entities/live_message.dart';
import 'package:app/features/live/presentation/providers/live_providers.dart';
import 'package:app/features/location/presentation/providers/location_providers.dart';
import 'package:app/features/routes/domain/unicentro_schedule.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fakes.dart';

/// Instante que en Bogotá (UTC-5) marca esa hora de pared, sin importar la
/// zona horaria del equipo que corre las pruebas.
DateTime bogota(int y, int m, int d, int h, [int min = 0]) =>
    DateTime.utc(y, m, d, h + 5, min);

void main() {
  final schedule = UnicentroSchedule();
  RouteAStatus at(int y, int m, int d, int h, [int min = 0]) =>
      schedule.status(bogotaWallClock(bogota(y, m, d, h, min)));

  group('horario (reglas 1, 2 y 4)', () {
    test('sábado 20:20: está por cerrar (criterio 1)', () {
      final s = at(2026, 10, 17, 20, 20);
      expect(s.state, RouteAState.closingSoon);
      expect(s.closesAt.hour, 21);
    });

    test('domingo 20:05: Unicentro cerrado, sin Ruta A (criterio 2)', () {
      final s = at(2026, 10, 18, 20, 5);
      expect(s.state, RouteAState.closed);
      expect(s.opensAt, DateTime.utc(2026, 10, 19, 8));
    });

    test('martes 10:00: Ruta A disponible (criterio 3)', () {
      expect(at(2026, 10, 13, 10).state, RouteAState.available);
    });

    test('bordes de lunes a sábado: 45 min antes de las 21:00', () {
      expect(at(2026, 10, 13, 7, 59).state, RouteAState.closed);
      expect(at(2026, 10, 13, 8).state, RouteAState.available);
      expect(at(2026, 10, 13, 20, 14).state, RouteAState.available);
      expect(at(2026, 10, 13, 20, 15).state, RouteAState.closingSoon);
      expect(at(2026, 10, 13, 20, 59).state, RouteAState.closingSoon);
      expect(at(2026, 10, 13, 21).state, RouteAState.closed);
      expect(at(2026, 10, 13, 23, 30).state, RouteAState.closed);
    });

    test('bordes del domingo: 45 min antes de las 20:00', () {
      expect(at(2026, 10, 18, 19, 14).state, RouteAState.available);
      expect(at(2026, 10, 18, 19, 15).state, RouteAState.closingSoon);
      expect(at(2026, 10, 18, 20).state, RouteAState.closed);
    });

    test('todos los días de la semana a las 20:30', () {
      // Lunes 12 de octubre es festivo (Día de la Raza): horario de domingo.
      final expected = {
        12: RouteAState.closed,
        13: RouteAState.closingSoon,
        14: RouteAState.closingSoon,
        15: RouteAState.closingSoon,
        16: RouteAState.closingSoon,
        17: RouteAState.closingSoon,
        18: RouteAState.closed,
      };
      expected.forEach((day, state) {
        expect(at(2026, 10, day, 20, 30).state, state, reason: 'día $day');
      });
    });

    test('festivo como domingo: lunes 2 de noviembre cierra a las 20:00', () {
      expect(at(2026, 11, 2, 19, 20).state, RouteAState.closingSoon);
      expect(at(2026, 11, 3, 19, 20).state, RouteAState.available);
    });

    test('el margen se configura entre 30 y 60 minutos', () {
      final m30 = UnicentroSchedule(marginMinutes: 30);
      final now = bogotaWallClock(bogota(2026, 10, 13, 20, 20));
      expect(m30.status(now).state, RouteAState.available);
      expect(UnicentroSchedule(marginMinutes: 10).marginMinutes, 30);
      expect(UnicentroSchedule(marginMinutes: 90).marginMinutes, 60);
    });

    test('usa la hora de Colombia aunque el teléfono tenga otra zona', () {
      // 01:20 UTC del domingo = 20:20 del sábado en Bogotá.
      final wall = bogotaWallClock(DateTime.utc(2026, 10, 18, 1, 20));
      expect(wall.weekday, DateTime.saturday);
      expect(wall.hour, 20);
    });
  });

  group('disturbios en la universidad (regla 6)', () {
    test('con tropel reportado, la Ruta A se cierra a cualquier hora', () {
      for (final hour in [8, 10, 14, 19]) {
        final now = bogotaWallClock(bogota(2026, 10, 13, hour));
        expect(
          schedule.status(now, disturbance: true).state,
          RouteAState.disturbance,
          reason: '$hour:00',
        );
      }
    });

    test('la respuesta explica los disturbios y ofrece la ruta alterna', () {
      final now = bogotaWallClock(bogota(2026, 10, 13, 10));
      final text = describeRouteA(schedule.status(now, disturbance: true));
      expect(text, startsWith('unavailable: the exit to Pasoancho'));
      expect(text, contains('tropel'));
      expect(text, contains('Calle 16'));
      expect(text, contains('Carrera 86'));
    });
  });

  group('festivos de Colombia', () {
    test('Pascua', () {
      expect(easterSunday(2026), DateTime.utc(2026, 4, 5));
      expect(easterSunday(2027), DateTime.utc(2027, 3, 28));
    });

    test('2026 completo', () {
      final days = colombianHolidays(2026).toList()..sort();
      expect(days.map((d) => '${d.month}-${d.day}'), [
        '1-1',
        '1-12',
        '3-23',
        '4-2',
        '4-3',
        '5-1',
        '5-18',
        '6-8',
        '6-15',
        '6-29',
        '7-20',
        '8-7',
        '8-17',
        '10-12',
        '11-2',
        '11-16',
        '12-8',
        '12-25',
      ]);
    });
  });

  group('respuesta para el asistente', () {
    test('disponible: dice hasta qué hora', () {
      final text = describeRouteA(at(2026, 10, 13, 10));
      expect(text, startsWith('ok: Route A through Unicentro is available'));
      expect(text, contains('closes today at 21:00; from 20:15'));
    });

    test('por cerrar: minutos que faltan y ruta alterna', () {
      final text = describeRouteA(at(2026, 10, 17, 20, 20));
      expect(text, startsWith('unavailable:'));
      expect(text, contains('closes at 21:00 (in 40 minutes)'));
      expect(text, contains('cannot override it'));
      expect(text, contains('Calle 16'));
      expect(text, contains('Carrera 86'));
    });

    test('cerrado: a qué hora abre', () {
      final text = describeRouteA(at(2026, 10, 18, 20, 5));
      expect(text, contains('Unicentro is closed now (it opens at 08:00)'));
      expect(text, contains('Calle 16'));
      expect(text, contains('Carrera 86'));
    });
  });

  group('en la sesión', () {
    late FakeLiveSessionRepository session;
    late DateTime now;
    late ProviderContainer container;

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    Future<String> askRouteA() async {
      session.emitResponse(
        const LiveResponse(
          type: LiveResponseType.toolCall,
          data: LiveToolCall(
            functionCalls: [
              LiveFunctionCall(id: 'u1', name: 'get_unicentro_route', args: {}),
            ],
          ),
        ),
      );
      await settle();
      return session.toolResponses.last.result;
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      session = FakeLiveSessionRepository();
      now = bogota(2026, 10, 17, 20, 10);
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) {};
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
          locationRepositoryProvider.overrideWithValue(
            FakeLocationRepository(),
          ),
          trackRecorderProvider.overrideWithValue(FakeTrackRecorder()),
          screenAwakeProvider.overrideWithValue((_) async {}),
          liveClockProvider.overrideWithValue(() => now),
          announcerProvider.overrideWithValue((_, _) {}),
          announcerStopProvider.overrideWithValue(() {}),
          retryDelayProvider.overrideWithValue((_) => Duration.zero),
        ],
      );
      addTearDown(container.dispose);
      container.read(liveControllerProvider.notifier).onTap();
      await settle();
      session.emitSetupComplete();
      await settle();
    });

    test('get_unicentro_route responde con la regla de la app', () async {
      expect(await askRouteA(), startsWith('ok: Route A'));
      now = bogota(2026, 10, 17, 20, 20);
      expect(await askRouteA(), contains('in 40 minutes'));
    });

    test('si iba por la Ruta A y se desactiva, avisa una sola vez', () async {
      final live = container.read(liveControllerProvider.notifier);
      await askRouteA(); // 20:10: disponible
      live.checkRouteA();
      expect(session.routeNotices, isEmpty);

      now = bogota(2026, 10, 17, 20, 16);
      live.checkRouteA();
      expect(session.routeNotices.single, contains('in 44 minutes'));
      live.checkRouteA();
      expect(session.routeNotices, hasLength(1));
    });

    test('sin haber consultado la Ruta A no avisa', () async {
      now = bogota(2026, 10, 17, 20, 16);
      container.read(liveControllerProvider.notifier).checkRouteA();
      expect(session.routeNotices, isEmpty);
    });

    Future<String> callTool(String name, Map<String, dynamic> args) async {
      session.emitResponse(
        LiveResponse(
          type: LiveResponseType.toolCall,
          data: LiveToolCall(
            functionCalls: [LiveFunctionCall(id: 'd1', name: name, args: args)],
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return session.toolResponses.last.result;
    }

    test(
      '"hay tropel": Ruta A inhabilitada de día, el resto del día',
      () async {
        now = bogota(2026, 10, 13, 10);
        expect(await askRouteA(), startsWith('ok: Route A'));
        expect(
          await callTool('set_route_disturbance', {'active': true}),
          contains('disabled for the rest of today'),
        );
        expect(await askRouteA(), contains('tropel'));
        // Sigue valiendo horas después, aunque se haya cerrado la sesión.
        now = bogota(2026, 10, 13, 15);
        expect(await askRouteA(), contains('tropel'));
        // Al día siguiente vence solo.
        now = bogota(2026, 10, 14, 10);
        expect(await askRouteA(), startsWith('ok: Route A'));
      },
    );

    void hear(String text) => session.emitResponse(
      LiveResponse(
        type: LiveResponseType.inputTranscription,
        data: LiveTranscription(text: text, finished: true),
      ),
    );

    Future<String> liftDisturbance() =>
        callTool('set_route_disturbance', {'active': false});

    test(
      '"ya pasó el tropel" pide confirmación y lo levanta la segunda vez',
      () async {
        now = bogota(2026, 10, 13, 10);
        await callTool('set_route_disturbance', {'active': true});
        hear('Ya pasó el tropel');
        expect(await liftDisturbance(), startsWith('pending:'));
        expect(await askRouteA(), contains('tropel'));
        now = bogota(2026, 10, 13, 10).add(const Duration(seconds: 8));
        hear('Sí, ya pasó');
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(await liftDisturbance(), startsWith('ok: the disturbance'));
        expect(await askRouteA(), startsWith('ok: Route A'));
      },
    );

    test('el asistente no puede confirmar solo en el mismo turno', () async {
      now = bogota(2026, 10, 13, 10);
      await callTool('set_route_disturbance', {'active': true});
      hear('Ya pasó el tropel');
      expect(await liftDisturbance(), startsWith('pending:'));
      // Sin que la persona vuelva a hablar.
      now = bogota(2026, 10, 13, 10).add(const Duration(seconds: 10));
      expect(await liftDisturbance(), startsWith('pending:'));
      expect(await askRouteA(), contains('tropel'));
    });

    test('la confirmación vence a los 3 minutos', () async {
      now = bogota(2026, 10, 13, 10);
      await callTool('set_route_disturbance', {'active': true});
      expect(await liftDisturbance(), startsWith('pending:'));
      now = bogota(2026, 10, 13, 10, 4);
      hear('Ya pasó el tropel');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(await liftDisturbance(), startsWith('pending:'));
      expect(await askRouteA(), contains('tropel'));
    });

    test(
      'un nuevo reporte de tropel anula la confirmación pendiente',
      () async {
        now = bogota(2026, 10, 13, 10);
        await callTool('set_route_disturbance', {'active': true});
        expect(await liftDisturbance(), startsWith('pending:'));
        await callTool('set_route_disturbance', {'active': true});
        now = bogota(2026, 10, 13, 10).add(const Duration(seconds: 8));
        hear('Ya pasó');
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(await liftDisturbance(), startsWith('pending:'));
      },
    );

    test('si iba por la Ruta A y otro reporta el tropel, avisa', () async {
      now = bogota(2026, 10, 13, 10);
      await askRouteA();
      final prefs = container.read(sharedPreferencesProvider);
      await prefs.setString('route_a_disturbance_day', '2026-10-13');
      container.read(liveControllerProvider.notifier).checkRouteA();
      expect(session.routeNotices.single, contains('tropel'));
    });

    test('si ya estaba desactivada al preguntar, no vuelve a avisar', () {
      now = bogota(2026, 10, 17, 20, 30);
      return askRouteA().then((_) {
        now = bogota(2026, 10, 17, 21, 5);
        container.read(liveControllerProvider.notifier).checkRouteA();
        expect(session.routeNotices, isEmpty);
      });
    });
  });
}
