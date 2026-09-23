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

  Future<ProviderContainer> build({bool permissions = true}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    session = FakeLiveSessionRepository();
    media = FakeMediaRepository(permissionsGranted: permissions);
    announcements = [];
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        liveSessionRepositoryProvider.overrideWithValue(session),
        mediaRepositoryProvider.overrideWithValue(media),
        announcerProvider.overrideWithValue(announcements.add),
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
      expect(announcements, [
        ...List.filled(
          maxConnectionRetries,
          noticeText(LiveNotice.retrying, 'es'),
        ),
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

  test('sin permisos de micrófono y cámara no se abre la sesión', () async {
    container = await build(permissions: false);
    controller().onTap();
    await settle();
    expect(state().status, LiveStatus.error);
    expect(session.connectCalls, 0);
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
