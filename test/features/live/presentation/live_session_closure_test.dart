// HU-002: qué hace la app según la causa por la que terminó la sesión.

import 'package:app/features/live/domain/entities/live_close.dart';
import 'package:app/features/live/domain/entities/live_message.dart';
import 'package:app/features/live/presentation/controllers/live_controller.dart';
import 'package:app/features/live/presentation/providers/live_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/fakes.dart';

void main() {
  late FakeLiveSessionRepository session;
  late List<String> announcements;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    session = FakeLiveSessionRepository();
    announcements = [];
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        liveSessionRepositoryProvider.overrideWithValue(session),
        mediaRepositoryProvider.overrideWithValue(FakeMediaRepository()),
        announcerProvider.overrideWithValue((m, _) => announcements.add(m)),
        retryDelayProvider.overrideWithValue((_) => Duration.zero),
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

  test('Detener no provoca reconexión ni avisos', () async {
    await openSession();

    controller().disconnect();
    await settle();
    expect(state().status, LiveStatus.idle);
    expect(session.connectCalls, 1);
    expect(announcements, isEmpty);
  });

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
}
