/// HU-015: la sesión registra eventos y la latencia voz a voz, sin el texto de
/// la persona ni del asistente.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:app/core/telemetry/session_telemetry.dart';
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
  late FakeMediaRepository media;
  late List<Map<String, Object?>> events;
  late ProviderContainer container;

  LiveController controller() =>
      container.read(liveControllerProvider.notifier);
  Future<void> settle() => Future<void>.delayed(Duration.zero);
  void emit(LiveResponseType type, [Object? data]) =>
      session.emitResponse(LiveResponse(type: type, data: data));

  String pcm({required bool loud}) {
    final bytes = Uint8List(320);
    if (loud) {
      for (var i = 0; i < 160; i++) {
        bytes[2 * i] = 0x00;
        bytes[2 * i + 1] = 0x40; // 0x4000 ≈ 0,5 del máximo
      }
    }
    return base64Encode(bytes);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    session = FakeLiveSessionRepository();
    media = FakeMediaRepository();
    events = [];
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
        sessionTelemetryProvider.overrideWithValue(
          SessionTelemetry(events.add),
        ),
        observePeriodProvider.overrideWithValue(const Duration(hours: 1)),
      ],
    );
    addTearDown(container.dispose);
    controller().onTap();
    await settle();
    session.emitSetupComplete();
    await settle();
  });

  test(
    'mide la latencia desde la voz de la persona hasta la respuesta',
    () async {
      for (var i = 0; i < 3; i++) {
        media.onMicChunk!(pcm(loud: true)); // voz sostenida, no un golpe suelto
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
      media.onMicChunk!(
        pcm(loud: false),
      ); // silencio: no mueve el fin de la voz
      emit(LiveResponseType.audio, 'AAAA');
      await settle();

      final latency = events.singleWhere((e) => e['event'] == 'latency');
      expect(latency['kind'], 'voice_to_voice');
      expect(latency['ms'] as int, greaterThanOrEqualTo(100));
    },
  );

  test('un ruido suelto no cuenta como voz', () async {
    media.onMicChunk!(pcm(loud: true));
    media.onMicChunk!(pcm(loud: false));
    emit(LiveResponseType.audio, 'AAAA');
    await settle();
    expect(events.where((e) => e['event'] == 'latency'), isEmpty);
  });

  test(
    'si el micrófono no detectó la voz, mide desde la transcripción',
    () async {
      emit(
        LiveResponseType.inputTranscription,
        LiveTranscription(text: '¿dónde está el vaso?', finished: true),
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      emit(LiveResponseType.audio, 'AAAA');
      await settle();
      final latency = events.singleWhere((e) => e['event'] == 'latency');
      expect(latency['ms'] as int, greaterThanOrEqualTo(70));
    },
  );

  test('sin voz de la persona no hay latencia que medir', () async {
    media.onMicChunk!(pcm(loud: false));
    emit(LiveResponseType.audio, 'AAAA');
    await settle();
    expect(events.where((e) => e['event'] == 'latency'), isEmpty);
  });

  test(
    'registra la sesión y sus eventos, y la cierra con el resumen',
    () async {
      emit(
        LiveResponseType.toolCall,
        LiveToolCall(
          functionCalls: [
            LiveFunctionCall(
              id: '1',
              name: 'set_verbosity',
              args: {'level': 'concise'},
            ),
          ],
        ),
      );
      emit(LiveResponseType.turnComplete);
      await settle();
      controller().disconnect();

      final types = events.map((e) => e['event']).toList();
      expect(
        types,
        containsAllInOrder([
          'session_start',
          'tool_call',
          'turn_complete',
          'session_end',
        ]),
      );
      expect(events.firstWhere((e) => e['event'] == 'tool_call')['names'], [
        'set_verbosity',
      ]);
      expect(events.last['reason'], 'stopped');
    },
  );

  test('no guarda lo que dijo la persona ni el asistente', () async {
    emit(
      LiveResponseType.inputTranscription,
      LiveTranscription(text: 'mi clave es 1234', finished: true),
    );
    emit(
      LiveResponseType.outputTranscription,
      LiveTranscription(text: 'Entendido', finished: true),
    );
    emit(LiveResponseType.turnComplete);
    await settle();
    controller().disconnect();

    final all = jsonEncode(events);
    expect(all, isNot(contains('1234')));
    expect(all, isNot(contains('Entendido')));
  });
}
