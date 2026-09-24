import 'package:app/features/live/domain/entities/live_message.dart';
import 'package:app/features/live/presentation/providers/live_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/fakes.dart';

/// HU-007: en altavoz (medio-dúplex) el micrófono no se envía mientras el
/// asistente suena; con audífonos (full-duplex) queda siempre abierto.
void main() {
  late FakeLiveSessionRepository session;
  late FakeMediaRepository media;

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  Future<void> startSession({bool headset = false}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    session = FakeLiveSessionRepository();
    media = FakeMediaRepository(headset: headset);
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        liveSessionRepositoryProvider.overrideWithValue(session),
        mediaRepositoryProvider.overrideWithValue(media),
        announcerProvider.overrideWithValue((_, _) {}),
        drainFallbackMarginProvider.overrideWithValue(
          const Duration(milliseconds: 50),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(liveControllerProvider.notifier).onTap();
    await settle();
    session.emitSetupComplete();
    await settle();
  }

  void assistantSpeaks() => session.emitResponse(
    const LiveResponse(type: LiveResponseType.audio, data: 'AAAA'),
  );
  void turnComplete() => session.emitResponse(
    const LiveResponse(type: LiveResponseType.turnComplete),
  );
  bool micSends() {
    final before = session.sentAudio.length;
    media.onMicChunk!('mic');
    return session.sentAudio.length > before;
  }

  test(
    'altavoz: el micrófono no se envía mientras el asistente suena',
    () async {
      await startSession();
      expect(micSends(), isTrue);

      assistantSpeaks();
      await settle();
      expect(micSends(), isFalse);
    },
  );

  test('altavoz: se reabre con fin del audio y luego turnComplete', () async {
    await startSession();
    assistantSpeaks();
    await settle();

    media.onDrained!();
    expect(micSends(), isFalse); // el turno sigue: puede llegar más audio
    turnComplete();
    await settle();
    expect(micSends(), isTrue);
  });

  test(
    'altavoz: respuesta corta, turnComplete antes del fin del audio',
    () async {
      await startSession();
      assistantSpeaks();
      await settle();

      turnComplete();
      await settle();
      expect(micSends(), isFalse); // el audio aún suena
      media.onDrained!();
      expect(micSends(), isTrue); // no queda sorda
    },
  );

  test(
    'altavoz: si nunca llega el fin del audio, se reabre por tiempo',
    () async {
      await startSession();
      assistantSpeaks();
      await settle();
      turnComplete();
      await settle();
      expect(micSends(), isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(micSends(), isTrue);
    },
  );

  test(
    'audífonos: el micrófono queda abierto aunque el asistente suene',
    () async {
      await startSession(headset: true);
      assistantSpeaks();
      await settle();
      expect(micSends(), isTrue);
    },
  );
}
