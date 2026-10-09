/// HU-040: ciclo de observación. Con todos callados la app envía `[OBSERVA]`
/// cada pocos segundos para que el asistente avise de un riesgo sin que la
/// persona le hable; nunca en modo reunión ni en silencio total.
library;

import 'dart:convert';

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
  late List<String> logs;
  late ProviderContainer container;

  LiveController controller() =>
      container.read(liveControllerProvider.notifier);
  Future<void> settle() => Future<void>.delayed(Duration.zero);
  Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

  void emit(LiveResponseType type, [Object? data]) =>
      session.emitResponse(LiveResponse(type: type, data: data));

  Future<void> toolCall(String name, Map<String, dynamic> args) async {
    emit(
      LiveResponseType.toolCall,
      LiveToolCall(
        functionCalls: [LiveFunctionCall(id: name, name: name, args: args)],
      ),
    );
    await settle();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    session = FakeLiveSessionRepository();
    media = FakeMediaRepository();
    logs = [];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
    addTearDown(() => debugPrint = original);
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        liveSessionRepositoryProvider.overrideWithValue(session),
        mediaRepositoryProvider.overrideWithValue(media),
        backgroundSessionRepositoryProvider.overrideWithValue(
          FakeBackgroundSession(),
        ),
        locationRepositoryProvider.overrideWithValue(FakeLocationRepository()),
        trackRecorderProvider.overrideWithValue(FakeTrackRecorder()),
        announcerProvider.overrideWithValue((_, _) {}),
        retryDelayProvider.overrideWithValue((_) => Duration.zero),
        observePeriodProvider.overrideWithValue(
          const Duration(milliseconds: 600),
        ),
        observeAfterReplyProvider.overrideWithValue(
          const Duration(milliseconds: 200),
        ),
        observeReplyWaitProvider.overrideWithValue(
          const Duration(milliseconds: 2500),
        ),
        observeTimeoutProvider.overrideWithValue(
          const Duration(milliseconds: 1200),
        ),
      ],
    );
    addTearDown(container.dispose);

    controller().onTap();
    await settle();
    session.emitSetupComplete();
    await settle();
    // El saludo: mientras el asistente lo prepara, no se observa.
    expect(session.kickoffs, 1);
    emit(LiveResponseType.audio, 'AAAA');
    emit(LiveResponseType.turnComplete);
    await settle();
    media.onDrained!();
    await settle();
  });

  test('no observa mientras el asistente prepara el saludo', () async {
    controller().disconnect();
    await settle();
    final before = session.observes;
    controller().onTap();
    await settle();
    session.emitSetupComplete();
    await settle();
    await wait(1500); // sin respuesta aún: no se envía nada que la corte
    expect(session.observes, before);
  });

  test('con descripciones en pausa pide solo riesgos', () async {
    await toolCall('set_descriptions', {'enabled': false});
    emit(LiveResponseType.audio, 'AAAA');
    emit(LiveResponseType.turnComplete);
    await settle();
    media.onDrained!();
    await wait(1200);
    expect(session.observeRisksOnly, isNotEmpty);
    expect(session.observeRisksOnly.last, isTrue);
  });

  test(
    'con todos callados envía [OBSERVA] y registra si el asistente calló',
    () async {
      await wait(1100);
      expect(session.observes, 1);
      await wait(1500);
      expect(logs, contains('[Lazarus] observa: calló'));
      expect(session.observes, greaterThanOrEqualTo(2));
    },
  );

  test('registra cuánto tardó el asistente en responder', () async {
    await wait(1100);
    expect(session.observes, 1);
    emit(LiveResponseType.audio, 'AAAA');
    await settle();
    expect(
      logs.where((l) => l.startsWith('[Lazarus] observa: respondió en ')),
      hasLength(1),
    );
  });

  test('no envía mientras el asistente habla', () async {
    emit(LiveResponseType.audio, 'AAAA');
    await settle();
    await wait(1500);
    expect(session.observes, 0);
  });

  test('si la persona habla (aunque el micrófono no la detecte), espera su '
      'respuesta antes de observar', () async {
    await wait(400);
    emit(
      LiveResponseType.inputTranscription,
      LiveTranscription(text: '¿qué hay?', finished: false),
    );
    await settle();
    await wait(1200);
    expect(session.observes, 0, reason: 'esperando la respuesta');
    emit(LiveResponseType.audio, 'AAAA');
    emit(LiveResponseType.turnComplete);
    await settle();
    media.onDrained!();
    await wait(1100);
    expect(session.observes, 1);
  });

  test('no envía en modo reunión', () async {
    await toolCall('set_meeting_mode', {'enabled': true});
    emit(LiveResponseType.turnComplete);
    await settle();
    await wait(1500);
    expect(session.observes, 0);
  });

  test('no envía en silencio total', () async {
    await toolCall('set_microphone', {'active': false});
    emit(LiveResponseType.turnComplete);
    await settle();
    await wait(1500);
    expect(session.observes, 0);
  });

  test(
    'tras la voz de la persona espera su respuesta antes de observar',
    () async {
      // En la prueba, [OBSERVA] cortó la respuesta a "vuelve a describir".
      final loud = Uint8List(320);
      for (var i = 0; i < 160; i++) {
        loud[2 * i + 1] = 0x40;
      }
      for (var i = 0; i < 3; i++) {
        media.onMicChunk!(base64Encode(loud));
      }
      await wait(1800);
      expect(session.observes, 0, reason: 'esperando la respuesta');
      emit(LiveResponseType.audio, 'AAAA'); // llegó la respuesta
      emit(LiveResponseType.turnComplete);
      await settle();
      media.onDrained!();
      await settle();
      await wait(1100);
      expect(session.observes, 1);
    },
  );

  test('Detener apaga el ciclo', () async {
    controller().disconnect();
    await wait(1500);
    expect(session.observes, 0);
  });
}
