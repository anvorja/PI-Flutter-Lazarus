/// HU-011: modo reunión (escucha y calla salvo que lo llamen por su nombre) y
/// silencio total (no se envía micrófono ni cámara; se reactiva tocando).
library;

import 'package:app/features/live/domain/entities/live_close.dart';
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
  late List<String> announced; // lo que dijo la voz del teléfono
  late List<String> screenReader; // lo que leyó TalkBack (HU-023)
  late ProviderContainer container;

  LiveUiState state() => container.read(liveControllerProvider);
  LiveController controller() =>
      container.read(liveControllerProvider.notifier);
  Future<void> settle() => Future<void>.delayed(Duration.zero);

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

  Future<void> heard(String text) async {
    emit(
      LiveResponseType.inputTranscription,
      LiveTranscription(text: text, finished: false),
    );
    await settle();
  }

  Future<void> assistantSays(String pcm) async {
    emit(LiveResponseType.audio, pcm);
    await settle();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    session = FakeLiveSessionRepository();
    media = FakeMediaRepository();
    logs = [];
    announced = [];
    screenReader = [];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
    addTearDown(() => debugPrint = original);
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        liveSessionRepositoryProvider.overrideWithValue(session),
        networkStatusRepositoryProvider.overrideWithValue(FakeNetworkStatus()),
        mediaRepositoryProvider.overrideWithValue(media),
        backgroundSessionRepositoryProvider.overrideWithValue(
          FakeBackgroundSession(),
        ),
        compassRepositoryProvider.overrideWithValue(FakeCompassRepository()),
        locationRepositoryProvider.overrideWithValue(FakeLocationRepository()),
        trackRecorderProvider.overrideWithValue(FakeTrackRecorder()),
        announcerProvider.overrideWithValue((m, _) => announced.add(m)),
        announcerStopProvider.overrideWithValue(() {}),
        screenReaderAnnouncerProvider.overrideWithValue(screenReader.add),
        retryDelayProvider.overrideWithValue((_) => Duration.zero),
      ],
    );
    addTearDown(container.dispose);

    controller().onTap();
    await settle();
    session.emitSetupComplete();
    await settle();
  });

  group('modo reunión', () {
    late List<String> playedOnEnter;

    setUp(() async {
      await heard('Estoy en una reunión, escucha pero no hables.');
      await toolCall('set_meeting_mode', {'enabled': true});
      await assistantSays('entendido');
      emit(LiveResponseType.turnComplete);
      await settle();
      playedOnEnter = List.of(media.played);
      media.played.clear();
    });

    test('al entrar lo confirma la voz del teléfono, no el asistente '
        '(LAZA-113)', () {
      expect(state().meetingMode, isTrue);
      expect(playedOnEnter, isEmpty);
      expect(announced, [noticeText(LiveNotice.meetingOn, 'es')]);
    });

    test('lo que no suena tampoco se muestra en pantalla (LAZA-113)', () async {
      await heard('¿Qué hora es?');
      emit(
        LiveResponseType.outputTranscription,
        LiveTranscription(text: 'Son las cinco.', finished: false),
      );
      await assistantSays('la-hora');
      emit(LiveResponseType.turnComplete);
      await settle();
      expect(media.played, isEmpty);
      expect(state().assistantTranscript, isEmpty);

      // Si lo llaman por su nombre, la respuesta suena y se muestra.
      await heard('Aria, ¿qué hora es?');
      emit(
        LiveResponseType.outputTranscription,
        LiveTranscription(text: 'Son las cinco.', finished: false),
      );
      await assistantSays('la-hora');
      expect(media.played, ['la-hora']);
      expect(state().assistantTranscript, 'Son las cinco.');
    });

    test('"Aria, ya puedes hablar" sin la función: la app sale del modo '
        '(LAZA-113)', () async {
      await heard('Aria, ya puedes hablar.');
      await assistantSays('entendido');
      emit(LiveResponseType.turnComplete);
      await settle();
      expect(media.played, ['entendido']);
      expect(state().meetingMode, isFalse);
      expect(
        logs,
        contains(
          '[Lazarus] modo reunión desactivado por la app (el asistente no llamó a set_meeting_mode)',
        ),
      );
    });

    test('"ya puedes hablar" sin su nombre no sale del modo', () async {
      await heard('Ya puedes hablar, Juan.');
      await assistantSays('respuesta-no-pedida');
      emit(LiveResponseType.turnComplete);
      await settle();
      expect(state().meetingMode, isTrue);
      expect(media.played, isEmpty);
    });

    test('si nadie lo llama por su nombre, no produce audio', () async {
      await heard('Bueno, pasemos al siguiente punto del acta.');
      await assistantSays('respuesta-no-pedida');
      emit(LiveResponseType.turnComplete);
      await settle();

      expect(media.played, isEmpty);
      expect(
        logs,
        contains(
          '[Lazarus] modo reunión: respuesta descartada (no lo llamaron por su nombre)',
        ),
      );
    });

    test('si lo llaman por su nombre, responde', () async {
      await heard('Aria, ¿qué se dijo?');
      await assistantSays('resumen');
      expect(media.played, ['resumen']);
    });

    test(
      'si el nombre llega en la transcripción después del audio, lo suelta',
      () async {
        await assistantSays('resumen-1');
        await assistantSays('resumen-2');
        expect(media.played, isEmpty);

        await heard('ÁRIA, ¿qué se dijo?'); // mayúsculas y tilde
        expect(media.played, ['resumen-1', 'resumen-2']);
      },
    );

    test(
      'una palabra que contiene el nombre no cuenta como llamarlo',
      () async {
        await heard('La ariadna del proyecto llega tarde.');
        await assistantSays('respuesta-no-pedida');
        expect(media.played, isEmpty);
      },
    );

    test('"ya puedes hablar": la confirmación suena aunque llegue antes de la '
        'función', () async {
      await heard('Ya puedes hablar.');
      await assistantSays('entendido-1'); // Gemini habla antes de la función
      expect(media.played, isEmpty);

      await toolCall('set_meeting_mode', {'enabled': false});
      expect(state().meetingMode, isFalse);
      expect(media.played, ['entendido-1']);
    });

    test('Detener termina el modo reunión', () async {
      controller().disconnect();
      expect(state().meetingMode, isFalse);
    });
  });

  test('al entrar, el "Entendido" no suena aunque lo llamen por su nombre: '
      'lo dice el teléfono', () async {
    await heard('Aria, estoy en una reunión.');
    await toolCall('set_meeting_mode', {'enabled': true});
    await assistantSays('entendido');
    emit(LiveResponseType.turnComplete);
    await settle();
    expect(media.played, isEmpty);
    expect(announced, [noticeText(LiveNotice.meetingOn, 'es')]);

    // Pasada la confirmación, lo llaman y responde.
    await heard('Aria, ¿qué se dijo?');
    await assistantSays('resumen');
    expect(media.played, ['resumen']);
  });

  test('reconoce cómo salir del modo reunión en los idiomas de la app', () {
    expect(asksLeaveMeeting('Aria, ya puedes hablar.'), isTrue);
    expect(asksLeaveMeeting('Aria, salimos de la reunión'), isTrue);
    expect(asksLeaveMeeting('Aria, you can talk now'), isTrue);
    expect(asksLeaveMeeting('Aria, tu peux parler'), isTrue);
    expect(asksLeaveMeeting('Aria, já pode falar'), isTrue);
    expect(asksLeaveMeeting('Aria, puoi parlare'), isTrue);
    expect(asksLeaveMeeting('Aria, ¿qué se dijo?'), isFalse);
  });

  group('reconocer el nombre en la transcripción', () {
    test('tolera una letra de diferencia en nombres de 4 letras o más', () {
      expect(mentionsName('¿Qué se dijo, Área?', 'Aria'), isTrue); // CP-LAZA-37
      expect(mentionsName('Arya, ¿qué se dijo?', 'Aria'), isTrue);
      expect(mentionsName('ARIA qué se dijo', 'Aria'), isTrue);
    });

    test('no confunde palabras más distintas ni partes de otra palabra', () {
      expect(mentionsName('Ariadna llega tarde', 'Aria'), isFalse);
      expect(mentionsName('pasemos al siguiente punto', 'Aria'), isFalse);
    });

    test('los nombres cortos deben coincidir exacto', () {
      expect(mentionsName('Sol, ¿qué se dijo?', 'Sol'), isTrue);
      expect(mentionsName('pásame la sal', 'Sol'), isFalse);
    });
  });

  group('pausar o reanudar descripciones aunque no llame a la función', () {
    // CP-LAZA-107: "deja escribir" y "vuelve a escribir" → "Entendido" sin
    // set_descriptions.
    test('la app guarda la pausa al terminar el turno', () async {
      await heard('Deja escribir.');
      emit(LiveResponseType.turnComplete);
      await settle();
      expect(
        container.read(liveSettingsRepositoryProvider).getDescribing(),
        isFalse,
      );
      expect(
        logs,
        contains(
          '[Lazarus] descripciones en pausa por la app (el asistente no llamó a set_descriptions)',
        ),
      );
    });

    test('y la reanudación', () async {
      await heard('Deja de describir.');
      await toolCall('set_descriptions', {'enabled': false});
      emit(LiveResponseType.turnComplete);
      await settle();
      await heard('Vuelve a escribir.');
      emit(LiveResponseType.turnComplete);
      await settle();
      expect(
        container.read(liveSettingsRepositoryProvider).getDescribing(),
        isTrue,
      );
    });

    test('si llamó a la función, la app no hace nada más', () async {
      await heard('Deja de describir.');
      await toolCall('set_descriptions', {'enabled': false});
      emit(LiveResponseType.turnComplete);
      await settle();
      expect(logs.where((l) => l.contains('por la app')), isEmpty);
    });
  });

  group('silencio total aunque el asistente no llame a la función', () {
    test('la app lo aplica al terminar el turno (CP-LAZA-37, paso H)', () async {
      await heard('Silencio total.');
      await assistantSays('toca-la-pantalla');
      emit(LiveResponseType.turnComplete);
      await settle();

      expect(state().micMuted, isTrue);
      expect(
        logs,
        contains(
          '[Lazarus] silencio total aplicado por la app (el asistente no llamó a set_microphone)',
        ),
      );
      final sent = session.sentAudio.length;
      media.onMicChunk?.call('pcm');
      expect(session.sentAudio.length, sent);
    });

    test(
      'si el asistente sí llama a la función, la app no repite nada',
      () async {
        await heard('Silencio total.');
        await toolCall('set_microphone', {'active': false});
        emit(LiveResponseType.turnComplete);
        await settle();
        expect(state().micMuted, isTrue);
        expect(logs.where((l) => l.contains('aplicado por la app')), isEmpty);
      },
    );

    test('reconoce la frase en los idiomas de la app', () {
      expect(asksTotalSilence('Silencio total.'), isTrue);
      expect(asksTotalSilence('Total silence, please'), isTrue);
      expect(asksTotalSilence('Silence total !'), isTrue);
      expect(asksTotalSilence('Silêncio total'), isTrue);
      expect(asksTotalSilence('Silenzio totale'), isTrue);
      expect(asksTotalSilence('Hay silencio en la sala'), isFalse);
    });
  });

  group('TalkBack (HU-023, criterio 2)', () {
    test('al entrar en silencio total anuncia el estado y cómo reactivarlo, '
        'después de la confirmación del asistente', () async {
      screenReader.clear();
      await heard('Silencio total.');
      await toolCall('set_microphone', {'active': false});
      expect(screenReader, isEmpty); // no tapa al asistente
      await assistantSays('entendido');
      emit(LiveResponseType.turnComplete);
      await settle();
      expect(screenReader, isEmpty); // aún suena la confirmación
      media.onDrained!();
      await settle();
      expect(screenReader, [noticeText(LiveNotice.muted, 'es')]);
      expect(screenReader.single, contains('toca dos veces'));
      // Sin TalkBack no suena por la voz del teléfono: es silencio total.
      expect(announced, isEmpty);
    });

    test('también si el asistente ya hablaba cuando llegó la función: el '
        'aviso suena al terminar esa respuesta, sin esperar otra', () async {
      screenReader.clear();
      await heard('Silencio total.');
      await assistantSays('toca-dos-veces');
      await toolCall('set_microphone', {'active': false});
      emit(LiveResponseType.turnComplete);
      await settle();
      expect(screenReader, isEmpty);
      media.onDrained!();
      await settle();
      expect(screenReader, [noticeText(LiveNotice.muted, 'es')]);
    });

    test('también si lo aplica la app', () async {
      screenReader.clear();
      await heard('Silencio total.');
      await assistantSays('toca-la-pantalla');
      emit(LiveResponseType.turnComplete);
      await settle();
      expect(screenReader, [noticeText(LiveNotice.muted, 'es')]);
    });

    test('el aviso está en los 5 idiomas', () {
      for (final lang in ['es', 'en', 'fr', 'pt', 'it']) {
        expect(noticeText(LiveNotice.muted, lang), isNot(isEmpty));
        expect(noticeText(LiveNotice.connecting, lang), isNot(isEmpty));
      }
      expect(
        noticeText(LiveNotice.muted, 'en'),
        isNot(noticeText(LiveNotice.muted, 'es')),
      );
    });
  });

  group('silencio total', () {
    setUp(() async {
      await toolCall('set_microphone', {'active': false});
    });

    test('no envía audio ni imágenes', () async {
      final audioBefore = session.sentAudio.length;
      final imagesBefore = session.sentImages.length;
      media.onMicChunk?.call('pcm');
      media.onFrame?.call('jpeg');
      expect(session.sentAudio.length, audioBefore);
      expect(session.sentImages.length, imagesBefore);
      expect(state().statusLabel, contains('Toca la pantalla'));
    });

    test(
      'tocar con la sesión viva reactiva sin reconectar y pide confirmación',
      () async {
        controller().onTap();
        await settle();
        expect(state().micMuted, isFalse);
        expect(session.connectCalls, 1);
        expect(session.micResumed, 1);
        media.onMicChunk?.call('pcm');
        expect(session.sentAudio, contains('pcm'));
      },
    );

    test('si la sesión se cerró durante el silencio, tocar reconecta con una '
        'confirmación corta, sin presentarse', () async {
      session.emitClose(LiveCloseCause.upstreamEnded);
      await settle();
      expect(session.connectCalls, 1); // no reconecta por su cuenta

      controller().onTap();
      await settle();
      expect(session.connectCalls, 2);
      session.emitSetupComplete();
      await settle();
      expect(session.micResumed, 1);
      expect(session.kickoffs, 1); // solo la presentación de la primera sesión
      expect(state().micMuted, isFalse);
    });

    test(
      'Detener termina el silencio total: la siguiente sesión se presenta',
      () async {
        controller().disconnect();
        expect(state().micMuted, isFalse);
        expect(state().statusLabel, 'Toca para empezar');

        controller().onTap();
        await settle();
        session.emitSetupComplete();
        await settle();
        expect(session.kickoffs, 2);
        expect(session.micResumed, 0);
      },
    );
  });

  group('silencio total en modo reunión (LAZA-113)', () {
    setUp(() async {
      await heard('Estoy en una reunión, escucha pero no hables.');
      await toolCall('set_meeting_mode', {'enabled': true});
      await assistantSays('entendido');
      emit(LiveResponseType.turnComplete);
      await settle();
      media.played.clear();
    });

    test('la confirmación del silencio total suena sin llamarlo por su '
        'nombre', () async {
      await heard('Silencio total.');
      await assistantSays('toca-para-reactivar'); // antes de la función
      expect(media.played, isEmpty);
      await toolCall('set_microphone', {'active': false});
      expect(state().micMuted, isTrue);
      expect(media.played, ['toca-para-reactivar']);
    });

    test('al reactivar con un toque, "te escucho de nuevo" suena', () async {
      await toolCall('set_microphone', {'active': false});
      await assistantSays('toca-para-reactivar');
      emit(LiveResponseType.turnComplete);
      await settle();
      media.played.clear();

      controller().onTap();
      await settle();
      expect(state().meetingMode, isTrue);
      await assistantSays('te-escucho');
      expect(media.played, ['te-escucho']);
      emit(LiveResponseType.turnComplete);
      await settle();

      // Pasada la confirmación, vuelve a callar si no lo llaman.
      await heard('Sigamos con el acta.');
      await assistantSays('respuesta-no-pedida');
      expect(media.played, ['te-escucho']);
    });

    test('si la sesión se cerró durante el silencio, la sesión nueva sale '
        'del modo reunión y su confirmación suena', () async {
      await toolCall('set_microphone', {'active': false});
      emit(LiveResponseType.turnComplete);
      await settle();
      session.emitClose(LiveCloseCause.upstreamEnded);
      await settle();
      media.played.clear();

      controller().onTap();
      await settle();
      session.emitSetupComplete();
      await settle();
      expect(state().meetingMode, isFalse);
      await assistantSays('te-escucho');
      expect(media.played, ['te-escucho']);
    });
  });
}
