// HU-002: qué hace la app según la causa por la que terminó la sesión.

import 'dart:async';

import 'package:app/features/access/presentation/providers/access_providers.dart';
import 'package:app/features/live/domain/entities/live_close.dart';
import 'package:app/features/live/domain/entities/live_message.dart';
import 'package:app/features/live/presentation/controllers/live_controller.dart';
import 'package:app/features/live/presentation/providers/live_providers.dart';
import 'package:app/features/location/presentation/providers/location_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/fakes.dart';

void main() {
  late FakeLiveSessionRepository session;
  late List<String> announcements;
  late ProviderContainer container;
  late FakeDeviceAccess deviceAccess;
  late DateTime now;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    session = FakeLiveSessionRepository();
    announcements = [];
    deviceAccess = FakeDeviceAccess();
    now = DateTime(2026, 10, 24, 10);
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        liveSessionRepositoryProvider.overrideWithValue(session),
        networkStatusRepositoryProvider.overrideWithValue(FakeNetworkStatus()),
        mediaRepositoryProvider.overrideWithValue(FakeMediaRepository()),
        backgroundSessionRepositoryProvider.overrideWithValue(
          FakeBackgroundSession(),
        ),
        compassRepositoryProvider.overrideWithValue(FakeCompassRepository()),
        locationRepositoryProvider.overrideWithValue(FakeLocationRepository()),
        trackRecorderProvider.overrideWithValue(FakeTrackRecorder()),
        announcerProvider.overrideWithValue((m, _) => announcements.add(m)),
        announcerStopProvider.overrideWithValue(() {}),
        retryDelayProvider.overrideWithValue((_) => Duration.zero),
        deviceAccessRepositoryProvider.overrideWithValue(deviceAccess),
        liveClockProvider.overrideWithValue(() => now),
      ],
    );
    addTearDown(container.dispose);
  });

  LiveUiState state() => container.read(liveControllerProvider);
  LiveController controller() =>
      container.read(liveControllerProvider.notifier);
  Future<void> settle() => Future<void>.delayed(Duration.zero);
  String notice(LiveNotice n) => noticeText(n, 'es');

  /// Sesión abierta y confirmada por Gemini (ya saludó una vez).
  Future<void> openSession() async {
    controller().onTap();
    await settle();
    session.emitSetupComplete();
    await settle();
    expect(session.kickoffs, 1);
  }

  test(
    'Gemini cierra la sesión: queda en pausa, avisa y al tocar retoma sin presentarse de nuevo',
    () async {
      await openSession();

      session.emitClose(LiveCloseCause.upstreamEnded);
      await settle();
      expect(state().status, LiveStatus.idle);
      expect(announcements, [notice(LiveNotice.sessionPaused)]);
      expect(session.connectCalls, 1, reason: 'no reconecta sin interacción');

      controller().onTap();
      await settle();
      session.emitSetupComplete();
      await settle();
      expect(state().status, LiveStatus.connected);
      expect(session.kickoffs, 1, reason: 'no repite la presentación');
      expect(session.micResumed, 1, reason: 'confirma con una frase corta');
    },
  );

  test('error de red: reconecta sola y confirma con una frase corta', () async {
    await openSession();

    session.emitClose(LiveCloseCause.upstreamError);
    await settle(); // pregunta la causa al backend: no hay ninguna conocida
    await settle();
    expect(announcements, [notice(LiveNotice.retrying)]);
    expect(session.connectCalls, 2);

    session.emitSetupComplete();
    await settle();
    expect(state().status, LiveStatus.connected);
    expect(session.kickoffs, 1);
    expect(session.micResumed, 1);
  });

  test('cuota agotada: avisa y no reintenta', () async {
    await openSession();

    session.emitClose(LiveCloseCause.quotaExceeded);
    await settle();
    expect(state().status, LiveStatus.error);
    expect(announcements, [notice(LiveNotice.quotaExceeded)]);
    expect(session.connectCalls, 1);
  });

  test('sin saldo: lo dice y no reintenta (no es un fallo de red)', () async {
    await openSession();

    session.emitClose(LiveCloseCause.billingExhausted);
    await settle();
    expect(state().status, LiveStatus.error);
    expect(announcements, [notice(LiveNotice.billingExhausted)]);
    expect(announcements.single, contains('sin saldo'));
    expect(session.connectCalls, 1);
  });

  test('sin saldo pero el cierre llega sin código (Fase 0, Render): la app '
      'pregunta la causa al backend, lo dice y no reintenta', () async {
    await openSession();
    session.failureCause = LiveCloseCause.billingExhausted;
    session.emitClose(LiveCloseCause.unknown);
    await settle();
    await settle();
    expect(announcements, [notice(LiveNotice.billingExhausted)]);
    expect(state().status, LiveStatus.error);
    expect(session.connectCalls, 1);
  });

  test('servicio en pausa: lo dice y no reintenta (no gasta saldo)', () async {
    await openSession();
    session.emitClose(LiveCloseCause.servicePaused);
    await settle();
    expect(state().status, LiveStatus.error);
    expect(announcements, [notice(LiveNotice.servicePaused)]);
    expect(announcements.single, contains('en pausa'));
    expect(session.connectCalls, 1);
  });

  test(
    'en pausa pero el cierre llega sin código: lo sabe por el backend',
    () async {
      await openSession();
      session.failureCause = LiveCloseCause.servicePaused;
      session.emitClose(LiveCloseCause.unknown);
      await settle();
      await settle();
      expect(announcements, [notice(LiveNotice.servicePaused)]);
      expect(session.connectCalls, 1);
    },
  );

  group('control de acceso del piloto (HU-044 y HU-045)', () {
    test('la sesión lleva el token del teléfono', () async {
      await openSession();
      expect(session.lastDeviceToken, 'token-de-prueba');
    });

    for (final (cause, expected, text) in [
      (LiveCloseCause.devicePending, LiveNotice.devicePending, 'aprobación'),
      (
        LiveCloseCause.deviceDisabled,
        LiveNotice.deviceDisabled,
        'no tiene acceso',
      ),
      (
        LiveCloseCause.dailyLimit,
        LiveNotice.dailyLimit,
        'tiempo de uso de hoy',
      ),
      (
        LiveCloseCause.closedByAdmin,
        LiveNotice.closedByAdmin,
        'cerró la sesión',
      ),
    ]) {
      test('${cause.name}: lo dice y no reintenta', () async {
        await openSession();
        session.emitClose(cause);
        await settle();
        expect(announcements, [notice(expected)]);
        expect(announcements.single, contains(text));
        expect(session.connectCalls, 1);
      });
    }

    test('cerrada desde el panel pero sin código (Render): pregunta la causa '
        'con su token, lo dice, no reintenta y sube los logs', () async {
      await openSession();
      session.failureCause = LiveCloseCause.closedByAdmin;
      session.emitClose(LiveCloseCause.unknown);
      await settle();
      await settle();
      expect(session.lastStatusToken, 'token-de-prueba');
      expect(announcements, [notice(LiveNotice.closedByAdmin)]);
      expect(state().status, LiveStatus.idle);
      expect(session.connectCalls, 1);
      expect(deviceAccess.uploads, 1);
    });

    test('al tocar Detener sube los logs de campo', () async {
      await openSession();
      controller().disconnect();
      await settle();
      expect(deviceAccess.uploads, 1);
    });

    test('con la red lenta, las subidas van de a una y no repiten lo mismo '
        '(jornada del 24-oct)', () async {
      deviceAccess.slowNetwork = Completer<void>();
      await openSession();
      controller().disconnect();
      await settle();
      controller().onTap();
      await settle();
      session.emitSetupComplete();
      await settle();
      controller().disconnect();
      await settle();
      expect(deviceAccess.uploads, 1); // la segunda espera a la primera
      deviceAccess.slowNetwork!.complete();
      await settle();
      await settle();
      expect(deviceAccess.uploads, 2);
      expect(deviceAccess.maxUploadsInFlight, 1);
    });

    test('si el panel pidió los logs, los sube al empezar la sesión', () async {
      deviceAccess.requested = true;
      await openSession();
      await settle();
      expect(deviceAccess.uploads, 1);
    });

    test('los códigos 4007 a 4010 del backend', () {
      expect(liveCloseCauseFromCode(4007), LiveCloseCause.devicePending);
      expect(liveCloseCauseFromCode(4008), LiveCloseCause.deviceDisabled);
      expect(liveCloseCauseFromCode(4009), LiveCloseCause.dailyLimit);
      expect(liveCloseCauseFromCode(4010), LiveCloseCause.closedByAdmin);
    });
  });

  test('servidor sin configurar: avisa y no reintenta', () async {
    controller().onTap();
    await settle();

    session.emitClose(LiveCloseCause.serverMisconfigured);
    await settle();
    expect(state().status, LiveStatus.error);
    expect(announcements, [notice(LiveNotice.serverMisconfigured)]);
    expect(session.connectCalls, 1);
  });

  test('en silencio total no reconecta por su cuenta (privacidad)', () async {
    await openSession();
    session.emitResponse(
      const LiveResponse(
        type: LiveResponseType.toolCall,
        data: LiveToolCall(
          functionCalls: [
            LiveFunctionCall(
              id: '1',
              name: 'set_microphone',
              args: {'active': false},
            ),
          ],
        ),
      ),
    );
    await settle();
    expect(state().micMuted, isTrue);

    session.emitClose(LiveCloseCause.upstreamEnded);
    await settle();
    expect(session.connectCalls, 1);
    expect(announcements, isEmpty);
  });

  test(
    'Detener no provoca reconexión; solo el aviso corto de cierre',
    () async {
      await openSession();

      controller().disconnect();
      await settle();
      expect(state().status, LiveStatus.idle);
      expect(session.connectCalls, 1);
      expect(announcements, [notice(LiveNotice.stopped)]);
    },
  );

  test('los avisos existen en los 5 idiomas de la app', () {
    for (final lang in ['es', 'en', 'fr', 'pt', 'it']) {
      for (final n in LiveNotice.values) {
        expect(noticeText(n, lang), isNotEmpty, reason: '$lang/$n');
      }
    }
    expect(
      noticeText(LiveNotice.retrying, 'de'),
      noticeText(LiveNotice.retrying, 'es'),
    );
  });

  group('Detener con confirmación (jornada del 24-oct)', () {
    test('el segundo toque dentro de 4 s detiene', () async {
      await openSession();
      controller().requestStop();
      expect(announcements, [notice(LiveNotice.stopConfirm)]);
      expect(state().isLive, isTrue);
      now = now.add(const Duration(seconds: 3));
      controller().requestStop();
      expect(state().isLive, isFalse);
      expect(announcements.last, notice(LiveNotice.stopped));
    });

    test('pasados 4 s, el toque vuelve a preguntar', () async {
      await openSession();
      controller().requestStop();
      now = now.add(const Duration(seconds: 5));
      controller().requestStop();
      expect(state().isLive, isTrue);
      expect(announcements, [
        notice(LiveNotice.stopConfirm),
        notice(LiveNotice.stopConfirm),
      ]);
    });
  });
}
