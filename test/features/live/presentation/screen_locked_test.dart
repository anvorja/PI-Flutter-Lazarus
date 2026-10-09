/// HU-017: la sesión sigue con la pantalla bloqueada. Un servicio en primer
/// plano la mantiene mientras dura; "Detener" en la notificación equivale al
/// botón; la primera vez se pide quitar la optimización de batería; y como
/// Android no deja usar la cámara sin la app visible, al bloquear se abre una
/// sesión nueva sin ninguna imagen (el asistente no puede describir la última
/// foto como si fuera la escena actual) y al desbloquear, una con cámara.
library;

import 'package:app/features/live/domain/entities/live_message.dart';
import 'package:app/features/live/presentation/controllers/live_controller.dart';
import 'package:app/features/live/presentation/providers/live_providers.dart';
import 'package:app/features/location/presentation/providers/location_providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/fakes.dart';

void main() {
  late FakeLiveSessionRepository session;
  late FakeMediaRepository media;
  late FakeBackgroundSession background;
  late List<String> spoken;
  late List<String> logs;
  late ProviderContainer container;

  LiveController controller() =>
      container.read(liveControllerProvider.notifier);
  LiveUiState state() => container.read(liveControllerProvider);
  Future<void> settle() => Future<void>.delayed(Duration.zero);
  Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

  Future<void> build({
    Map<String, Object> prefs = const {},
    bool cameraGranted = true,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    final p = await SharedPreferences.getInstance();
    session = FakeLiveSessionRepository();
    media = FakeMediaRepository(cameraGranted: cameraGranted);
    spoken = [];
    logs = [];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
    addTearDown(() => debugPrint = original);
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(p),
        liveSessionRepositoryProvider.overrideWithValue(session),
        mediaRepositoryProvider.overrideWithValue(media),
        backgroundSessionRepositoryProvider.overrideWithValue(background),
        locationRepositoryProvider.overrideWithValue(FakeLocationRepository()),
        trackRecorderProvider.overrideWithValue(FakeTrackRecorder()),
        announcerProvider.overrideWithValue((m, _) => spoken.add(m)),
        retryDelayProvider.overrideWithValue((_) => Duration.zero),
        observePeriodProvider.overrideWithValue(
          const Duration(milliseconds: 300),
        ),
        observeAfterReplyProvider.overrideWithValue(
          const Duration(milliseconds: 100),
        ),
        observeReplyWaitProvider.overrideWithValue(
          const Duration(milliseconds: 200),
        ),
        observeTimeoutProvider.overrideWithValue(
          const Duration(milliseconds: 400),
        ),
        cameraUnlockDelayProvider.overrideWithValue(
          const Duration(milliseconds: 300),
        ),
      ],
    );
    addTearDown(container.dispose);
  }

  /// Abre una sesión y deja al asistente callado tras el saludo.
  Future<void> startSession() async {
    controller().onTap();
    await settle();
    session.emitSetupComplete();
    await settle();
    session.emitResponse(
      const LiveResponse(type: LiveResponseType.audio, data: 'AAAA'),
    );
    session.emitResponse(
      const LiveResponse(type: LiveResponseType.turnComplete),
    );
    await settle();
    media.onDrained!();
    await settle();
  }

  setUp(() => background = FakeBackgroundSession());

  test('la sesión arranca el servicio y Detener lo detiene', () async {
    await build();
    await startSession();
    expect(background.starts, 1);
    expect(background.running, isTrue);

    controller().disconnect();
    await settle();
    expect(background.running, isFalse);
  });

  test('"Detener" en la notificación cierra la sesión como el botón', () async {
    await build();
    await startSession();

    background.pressStopInNotification();
    await settle();

    expect(state().status, LiveStatus.idle);
    expect(session.connected, isFalse);
    expect(media.micStarted, isFalse);
    expect(media.cameraStarted, isFalse);
    expect(background.running, isFalse);
    expect(spoken.last, 'Asistente detenido.');
  });

  test('si Android no deja arrancar el servicio, la sesión sigue', () async {
    background = FakeBackgroundSession(startAllowed: false);
    await build();
    await startSession();
    expect(state().status, LiveStatus.connected);
    expect(logs, contains('[Lazarus] segundo plano: Android no lo permitió'));
  });

  group('optimización de batería', () {
    test('en un Xiaomi, la primera vez explica el ajuste y no abre la sesión; '
        'el siguiente toque empieza sin volver a pedirlo', () async {
      background = FakeBackgroundSession(exempt: false);
      await build();

      controller().onTap();
      await settle();
      expect(background.exemptionRequests, 1);
      expect(spoken.single, contains('Xiaomi'));
      expect(spoken.single, contains('Sin restricciones'));
      expect(session.connectCalls, 0);
      expect(state().status, LiveStatus.idle);

      background.exempt = false; // aunque no la haya quitado, no se insiste
      controller().onTap();
      await settle();
      expect(background.exemptionRequests, 1);
      expect(session.connectCalls, 1);
    });

    test('en otra marca, sin el ajuste de Xiaomi', () async {
      background = FakeBackgroundSession(
        exempt: false,
        manufacturer: 'samsung',
      );
      await build();
      controller().onTap();
      await settle();
      expect(spoken.single, contains('sin restricciones de batería'));
      expect(spoken.single, isNot(contains('Xiaomi')));
    });

    test('si ya está excluida, no pregunta', () async {
      await build();
      controller().onTap();
      await settle();
      expect(background.exemptionRequests, 0);
      expect(spoken, isEmpty);
      expect(session.connectCalls, 1);
    });
  });

  group('pantalla bloqueada', () {
    /// Bloquea la pantalla y confirma la sesión nueva que se abre.
    Future<void> lock() async {
      controller().onVisibilityChanged(false);
      await settle();
      session.emitSetupComplete();
      await settle();
    }

    LiveFunctionCall call(String name, Map<String, Object?> args) =>
        LiveFunctionCall(id: name, name: name, args: args);

    void emitTool(LiveFunctionCall c) {
      session.emitResponse(
        LiveResponse(
          type: LiveResponseType.toolCall,
          data: LiveToolCall(functionCalls: [c]),
        ),
      );
      session.emitResponse(
        const LiveResponse(type: LiveResponseType.turnComplete),
      );
    }

    test('al bloquear abre una sesión nueva sin imágenes, que avisa que sigue '
        'sin ver; al desbloquear vuelve a una con cámara', () async {
      await build();
      await startSession();
      expect(session.connectCalls, 1);
      expect(session.lastScreenLocked, isFalse);

      controller().onVisibilityChanged(false);
      await settle();
      expect(media.cameraStarted, isFalse);
      expect(session.connectCalls, 2, reason: 'la sesión vieja tenía la foto');
      expect(session.lastScreenLocked, isTrue);
      expect(session.lastCamera, isTrue);

      session.emitSetupComplete();
      await settle();
      expect(session.cameraNotices, [false]);
      expect(session.kickoffs, 1, reason: 'sin repetir la presentación');
      expect(media.micStarted, isTrue, reason: 'el audio sigue');
      expect(media.cameraStarted, isFalse);
      expect(state().status, LiveStatus.connected);

      final before = session.observes;
      await wait(1000);
      expect(session.observes, before, reason: 'no hay imagen que observar');

      controller().onVisibilityChanged(true);
      await settle();
      expect(session.connectCalls, 2, reason: 'espera por si fue sin querer');
      expect(media.cameraStarted, isFalse);

      await wait(400);
      expect(session.connectCalls, 3);
      expect(session.lastScreenLocked, isFalse);
      session.emitSetupComplete();
      await settle();
      expect(session.cameraNotices, [false, true]);
      expect(media.cameraStarted, isTrue);
    });

    test('un desbloqueo breve no cambia de sesión', () async {
      await build();
      await startSession();
      await lock();

      controller().onVisibilityChanged(true);
      await wait(100);
      controller().onVisibilityChanged(false);
      await wait(500);
      expect(session.connectCalls, 2);
      expect(session.lastScreenLocked, isTrue);
      expect(media.cameraStarted, isFalse);
    });

    test('si se desbloquea antes del cambio, sigue la misma sesión con la '
        'cámara', () async {
      await build();
      await startSession();
      controller().onVisibilityChanged(false);
      controller().onVisibilityChanged(true);
      await settle();
      await wait(100);
      expect(session.connectCalls, 1);
      expect(media.cameraStarted, isTrue);
    });

    test('si se corta la red con la pantalla bloqueada, la sesión que se '
        'reconecta también va sin imágenes', () async {
      await build();
      await startSession();
      await lock();

      session.emitError(); // corte de los datos móviles
      await settle();
      expect(session.lastScreenLocked, isTrue);
      session.emitSetupComplete();
      await settle();
      expect(media.micStarted, isTrue);
      expect(media.cameraStarted, isFalse);

      controller().onVisibilityChanged(true);
      await wait(400);
      expect(session.lastScreenLocked, isFalse);
      session.emitSetupComplete();
      await settle();
      expect(media.cameraStarted, isTrue);
    });

    test('si se bloquea mientras se conecta, cambia apenas la sesión está '
        'lista', () async {
      await build();
      controller().onTap();
      await settle();
      controller().onVisibilityChanged(false);
      session.emitSetupComplete();
      await settle();
      await wait(50);
      expect(session.connectCalls, 2);
      expect(session.lastScreenLocked, isTrue);
      expect(session.sentImages, isEmpty);
    });

    test('en silencio total no cambia de sesión (no debe hablar); al '
        'reactivar el micrófono, la sesión nueva va sin imágenes', () async {
      await build();
      await startSession();
      emitTool(call('set_microphone', {'active': false}));
      await settle();

      controller().onVisibilityChanged(false);
      await wait(50);
      expect(media.cameraStarted, isFalse);
      expect(session.connectCalls, 1);
      expect(session.cameraNotices, isEmpty);

      controller().onTap(); // reactiva el micrófono
      await settle();
      expect(session.connectCalls, 2);
      expect(session.lastScreenLocked, isTrue);
      session.emitSetupComplete();
      await settle();
      expect(session.cameraNotices, [false]);
    });

    test('en modo reunión no cambia de sesión; al salir, sí', () async {
      await build();
      await startSession();
      emitTool(call('set_meeting_mode', {'enabled': true}));
      await settle();

      controller().onVisibilityChanged(false);
      await wait(50);
      expect(session.connectCalls, 1);
      expect(state().meetingMode, isTrue);

      emitTool(call('set_meeting_mode', {'enabled': false}));
      await settle();
      session.emitResponse(
        const LiveResponse(type: LiveResponseType.audio, data: 'AAAA'),
      );
      session.emitResponse(
        const LiveResponse(type: LiveResponseType.turnComplete),
      );
      await settle();
      media.onDrained!();
      await wait(50);
      expect(session.connectCalls, 2);
      expect(session.lastScreenLocked, isTrue);
    });

    test('en la sesión sin imágenes, get_location no le pide describir lo que '
        've', () async {
      await build();
      await startSession();
      await lock();
      emitTool(call('get_location', {}));
      await wait(50);
      final r = session.toolResponses.last;
      expect(r.name, 'get_location');
      expect(r.result, isNot(contains('what you see')));
      expect(r.result, contains('do not describe'));
    });

    test('sin permiso de cámara no hay nada que cambiar', () async {
      await build(cameraGranted: false);
      await startSession();
      controller().onVisibilityChanged(false);
      await wait(50);
      controller().onVisibilityChanged(true);
      await wait(400);
      expect(session.connectCalls, 1);
      expect(session.lastScreenLocked, isFalse);
      expect(session.cameraNotices, isEmpty);
    });

    test('sin sesión, bloquear la pantalla no hace nada', () async {
      await build();
      controller().onVisibilityChanged(false);
      controller().onVisibilityChanged(true);
      await wait(400);
      expect(media.cameraStarted, isFalse);
      expect(session.connectCalls, 0);
      expect(session.cameraNotices, isEmpty);
    });

    test('Detener cancela el cambio pendiente', () async {
      await build();
      await startSession();
      await lock();
      controller().onVisibilityChanged(true);
      controller().disconnect();
      await wait(400);
      expect(session.connectCalls, 2);
      expect(session.connected, isFalse);
    });
  });
}
