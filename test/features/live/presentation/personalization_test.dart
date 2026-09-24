/// HU-009: comandos de voz de personalización. El asistente pide una función
/// (toolCall), la app la ejecuta, la guarda entre sesiones y responde el
/// resultado.
library;

import 'package:app/features/live/domain/entities/live_message.dart';
import 'package:app/features/live/presentation/controllers/live_controller.dart';
import 'package:app/features/live/presentation/providers/live_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/fakes.dart';

void main() {
  late SharedPreferences prefs;
  late FakeLiveSessionRepository session;
  late List<String> announcements;
  late ProviderContainer container;

  /// Abre la app: mismas preferencias guardadas, sesión y medios nuevos.
  ProviderContainer open() {
    session = FakeLiveSessionRepository();
    announcements = [];
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        liveSessionRepositoryProvider.overrideWithValue(session),
        mediaRepositoryProvider.overrideWithValue(FakeMediaRepository()),
        announcerProvider.overrideWithValue((m, _) => announcements.add(m)),
        retryDelayProvider.overrideWithValue((_) => Duration.zero),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  LiveController controller() =>
      container.read(liveControllerProvider.notifier);

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  /// Toca la pantalla y espera a que la sesión quede lista.
  Future<void> startSession() async {
    controller().onTap();
    await settle();
    session.emitSetupComplete();
    await settle();
  }

  /// El asistente pide ejecutar una función.
  Future<void> toolCall(String name, Map<String, dynamic> args) async {
    session.emitResponse(
      LiveResponse(
        type: LiveResponseType.toolCall,
        data: LiveToolCall(
          functionCalls: [LiveFunctionCall(id: 'c1', name: name, args: args)],
        ),
      ),
    );
    await settle();
  }

  /// Espera la reconexión que sigue a un cambio de voz o idioma.
  Future<void> waitReconnect() =>
      Future<void>.delayed(const Duration(milliseconds: 700));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    container = open();
  });

  test(
    'por defecto: asistente "Aria", voz Charon (la del backend) y español',
    () async {
      await startSession();
      expect(session.lastAssistantName, 'Aria');
      expect(session.lastVoice, isNull); // el backend usa Charon
      expect(session.lastLanguage, 'es');
      expect(session.lastUserName, '');
    },
  );

  test(
    '"quiero que te llames Sol": responde ok y lo recuerda al reabrir',
    () async {
      await startSession();
      await toolCall('set_assistant_name', {'name': 'Sol'});
      expect(session.toolResponses.single.result, 'ok');

      controller().disconnect();
      container = open();
      await startSession();
      expect(session.lastAssistantName, 'Sol');
    },
  );

  test(
    '"me llamo Andrés": al abrir la app al día siguiente lo conoce',
    () async {
      await startSession();
      await toolCall('set_user_name', {'name': 'Andrés'});
      expect(session.toolResponses.single.result, 'ok');

      controller().disconnect();
      container = open();
      await startSession();
      expect(session.lastUserName, 'Andrés');
      expect(session.kickoffs, 1); // saludo completo, que lo nombra (prompt)
    },
  );

  test(
    '"cambia tu voz a Aoede": reconecta con la voz y da una muestra corta',
    () async {
      await startSession();
      await toolCall('set_voice', {'voice': 'Aoede'});
      expect(session.toolResponses.single.result, restartResult);

      await waitReconnect();
      expect(session.connectCalls, 2);
      expect(session.lastVoice, 'Aoede');
      session.emitSetupComplete();
      await settle();
      expect(session.voiceSamples, 1);
      expect(session.kickoffs, 1); // no repite la presentación

      controller().disconnect();
      container = open();
      await startSession();
      expect(session.lastVoice, 'Aoede');
    },
  );

  test('voz con otras mayúsculas: se guarda con el nombre exacto', () async {
    await startSession();
    await toolCall('set_voice', {'voice': 'kore'});
    await waitReconnect();
    expect(session.lastVoice, 'Kore');
  });

  test(
    'voz que no existe: no cambia nada ni reconecta, y se lo explica',
    () async {
      await startSession();
      await toolCall('set_voice', {'voice': 'Alexa'});
      expect(session.toolResponses.single.result, unsupportedVoiceResult);

      await waitReconnect();
      expect(session.connectCalls, 1);
      expect(prefs.getString('lazarus_voice'), isNull);
    },
  );

  test(
    '"switch to English": reconecta en inglés, confirma corto y lo recuerda',
    () async {
      await startSession();
      await toolCall('set_language', {'language': 'en'});
      expect(session.toolResponses.single.result, restartResult);

      await waitReconnect();
      expect(session.lastLanguage, 'en');
      session.emitSetupComplete();
      await settle();
      expect(session.languageChanges, 1);
      expect(session.kickoffs, 1); // no repite la presentación

      controller().disconnect();
      container = open();
      expect(container.read(liveControllerProvider).language, 'en');
      await startSession();
      expect(session.lastLanguage, 'en');
    },
  );

  test(
    '"sé más breve" / "con más detalle": el nivel de detalle persiste',
    () async {
      await startSession();
      await toolCall('set_verbosity', {'level': 'detailed'});
      expect(session.toolResponses.single.result, 'ok');

      controller().disconnect();
      container = open();
      await startSession();
      expect(session.lastVerbosity, 'detailed');

      await toolCall('set_verbosity', {'level': 'extremo'}); // se ignora
      controller().disconnect();
      container = open();
      await startSession();
      expect(session.lastVerbosity, 'detailed');
    },
  );

  test('"deja de describir": la pausa de descripciones persiste', () async {
    await startSession();
    await toolCall('set_descriptions', {'enabled': false});

    controller().disconnect();
    container = open();
    await startSession();
    expect(session.lastDescribing, isFalse);
  });

  test(
    '"silencia los avisos": calla los informativos, no los de error',
    () async {
      await startSession();
      await toolCall('set_system_cues', {'enabled': false});
      controller().disconnect();
      expect(
        announcements,
        isNot(contains(noticeText(LiveNotice.stopped, 'es'))),
      );

      // Persiste: al reabrir sigue en silencio, pero un error que exige tocar la
      // pantalla para recuperarse se anuncia siempre.
      container = open();
      controller().onTap();
      await settle();
      for (var i = 0; i <= maxConnectionRetries; i++) {
        session.emitError();
        await settle();
      }
      expect(announcements, [noticeText(LiveNotice.connectionFailed, 'es')]);

      // "Activa los avisos" los devuelve.
      await startSession();
      await toolCall('set_system_cues', {'enabled': true});
      controller().disconnect();
      expect(announcements.last, noticeText(LiveNotice.stopped, 'es'));
    },
  );

  test('varias funciones a la vez: responde cada una por su id', () async {
    await startSession();
    session.emitResponse(
      const LiveResponse(
        type: LiveResponseType.toolCall,
        data: LiveToolCall(
          functionCalls: [
            LiveFunctionCall(
              id: 'a',
              name: 'set_assistant_name',
              args: {'name': 'Sol'},
            ),
            LiveFunctionCall(
              id: 'b',
              name: 'set_user_name',
              args: {'name': 'Andrés'},
            ),
          ],
        ),
      ),
    );
    await settle();
    expect(session.toolResponses.map((r) => (r.id, r.result)), [
      ('a', 'ok'),
      ('b', 'ok'),
    ]);
  });
}
