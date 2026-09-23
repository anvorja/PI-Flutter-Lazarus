import 'package:app/features/live/domain/entities/live_message.dart';
import 'package:app/features/live/domain/entities/media_permission.dart';
import 'package:app/features/live/presentation/controllers/live_controller.dart';
import 'package:app/features/live/presentation/providers/live_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/fakes.dart';

void main() {
  late FakeLiveSessionRepository session;
  late FakeMediaRepository media;
  late List<String> announcements;
  late ProviderContainer container;

  Future<ProviderContainer> build({
    MediaPermission permission = MediaPermission.granted,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    session = FakeLiveSessionRepository();
    media = FakeMediaRepository(permission: permission);
    announcements = [];
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        liveSessionRepositoryProvider.overrideWithValue(session),
        mediaRepositoryProvider.overrideWithValue(media),
        announcerProvider.overrideWithValue((m, _) => announcements.add(m)),
        retryDelayProvider.overrideWithValue((_) => Duration.zero),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  LiveUiState state() => container.read(liveControllerProvider);
  LiveController controller() =>
      container.read(liveControllerProvider.notifier);

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('estado inicial: inactivo', () async {
    container = await build();
    expect(state().status, LiveStatus.idle);
    expect(state().statusLabel, 'Toca para empezar');
  });

  test(
    'tocar la pantalla abre la sesión y el saludo llega tras setupComplete',
    () async {
      container = await build();

      controller().onTap();
      await settle();
      expect(state().status, LiveStatus.connecting);
      expect(session.connectCalls, 1);

      session.emitSetupComplete();
      await settle();
      expect(state().status, LiveStatus.connected);
      expect(session.kickoffs, 1);
      expect(media.micStarted, isTrue);
      expect(media.cameraStarted, isTrue);
    },
  );

  test(
    'sin backend: avisa, reintenta 3 veces y luego queda en error',
    () async {
      container = await build();

      controller().onTap();
      await settle();
      for (var i = 0; i < maxConnectionRetries; i++) {
        session.emitError();
        await settle();
        expect(state().status, LiveStatus.connecting);
      }
      expect(session.connectCalls, 1 + maxConnectionRetries);

      session.emitError();
      await settle();
      expect(state().status, LiveStatus.error);
      // "Reintentando" una sola vez por serie: cada aviso cortaría el anterior.
      expect(announcements, [
        noticeText(LiveNotice.retrying, 'es'),
        noticeText(LiveNotice.connectionFailed, 'es'),
      ]);
    },
  );

  test('si un reintento conecta, la sesión continúa normalmente', () async {
    container = await build();

    controller().onTap();
    await settle();
    session.emitError();
    await settle();
    session.emitSetupComplete();
    await settle();

    expect(state().status, LiveStatus.connected);
    expect(announcements, [noticeText(LiveNotice.retrying, 'es')]);
  });

  test(
    'tras agotar los reintentos, tocar la pantalla vuelve a intentarlo',
    () async {
      container = await build();
      controller().onTap();
      await settle();
      for (var i = 0; i <= maxConnectionRetries; i++) {
        session.emitError();
        await settle();
      }
      expect(state().status, LiveStatus.error);

      controller().onTap();
      await settle();
      expect(state().status, LiveStatus.connecting);
      expect(session.connectCalls, 2 + maxConnectionRetries);
    },
  );

  test(
    'sin permisos de micrófono y cámara no se abre la sesión y lo explica',
    () async {
      container = await build(permission: MediaPermission.denied);
      controller().onTap();
      await settle();
      expect(state().status, LiveStatus.error);
      expect(session.connectCalls, 0);
      expect(announcements, [noticeText(LiveNotice.permissionDenied, 'es')]);

      // Al tocar de nuevo se vuelven a pedir; si los concede, arranca la sesión.
      media.permission = MediaPermission.granted;
      controller().onTap();
      await settle();
      expect(session.connectCalls, 1);
    },
  );

  test(
    'permisos bloqueados: lo explica y el siguiente toque abre los ajustes',
    () async {
      container = await build(permission: MediaPermission.blocked);
      controller().onTap();
      await settle();
      expect(announcements, [noticeText(LiveNotice.permissionBlocked, 'es')]);

      controller().onTap();
      await settle();
      expect(media.settingsOpened, 1);
      expect(session.connectCalls, 0);

      // De vuelta de los ajustes con los permisos activados.
      media.permission = MediaPermission.granted;
      controller().onTap();
      await settle();
      expect(session.connectCalls, 1);
    },
  );

  test('el idioma arranca en español y se cambia solo por voz', () async {
    container = await build();
    expect(state().language, 'es');

    controller().onTap();
    await settle();
    session.emitSetupComplete();
    await settle();
    session.emitResponse(
      const LiveResponse(
        type: LiveResponseType.toolCall,
        data: LiveToolCall(
          functionCalls: [
            LiveFunctionCall(
              id: '1',
              name: 'set_language',
              args: {'language': 'en'},
            ),
          ],
        ),
      ),
    );
    await settle();
    expect(state().language, 'en');

    // Al reabrir la app se conserva el idioma elegido por voz.
    final prefs = await SharedPreferences.getInstance();
    final reopened = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        liveSessionRepositoryProvider.overrideWithValue(
          FakeLiveSessionRepository(),
        ),
        mediaRepositoryProvider.overrideWithValue(FakeMediaRepository()),
      ],
    );
    addTearDown(reopened.dispose);
    expect(reopened.read(liveControllerProvider).language, 'en');
  });

  test('interrupción del asistente: vacía la cola de reproducción', () async {
    container = await build();
    controller().onTap();
    await settle();
    session.emitSetupComplete();
    await settle();

    session.emitResponse(
      const LiveResponse(type: LiveResponseType.audio, data: 'AAAA'),
    );
    session.emitResponse(
      const LiveResponse(type: LiveResponseType.interrupted),
    );
    await settle();

    expect(media.interruptions, 1);
  });

  test('Detener cierra la sesión y libera micrófono y cámara', () async {
    container = await build();
    controller().onTap();
    await settle();
    session.emitSetupComplete();
    await settle();

    controller().disconnect();
    await settle();
    expect(state().status, LiveStatus.idle);
    expect(session.connected, isFalse);
    expect(media.micStarted, isFalse);
    expect(media.cameraStarted, isFalse);
  });
}
