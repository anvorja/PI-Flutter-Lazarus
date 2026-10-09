/// HU-012: alerta SOS por voz dentro de la sesión (confirmación, envío solo a
/// los 5 s, cancelación, sin contacto) y llamadas.
library;

import 'package:app/features/emergency/domain/entities/emergency_contact.dart';
import 'package:app/features/emergency/domain/repositories/emergency_repository.dart';
import 'package:app/features/emergency/presentation/providers/emergency_providers.dart';
import 'package:app/features/live/domain/entities/live_message.dart';
import 'package:app/features/live/presentation/controllers/live_controller.dart';
import 'package:app/features/live/presentation/providers/live_providers.dart';
import 'package:app/features/location/domain/entities/location_fix.dart';
import 'package:app/features/location/presentation/providers/location_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/fakes.dart';

void main() {
  final t0 = DateTime(2026, 9, 30, 9);
  const window = Duration(milliseconds: 20); // cuenta de la confirmación
  const fallback = Duration(milliseconds: 60); // si la pregunta no suena
  const laura = EmergencyContact(name: 'Laura', phone: '+573151234567');

  late FakeLiveSessionRepository session;
  late FakeMediaRepository media;
  late FakeLocationRepository gps;
  late FakeEmergencyRepository emergency;
  late List<String> announcements;
  late ProviderContainer container;

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> wait(Duration d) => Future<void>.delayed(d);

  LiveController live() => container.read(liveControllerProvider.notifier);

  Future<String> tool(
    String name, [
    Map<String, dynamic> args = const {},
  ]) async {
    final id = 'c${session.toolResponses.length}';
    session.emitResponse(
      LiveResponse(
        type: LiveResponseType.toolCall,
        data: LiveToolCall(
          functionCalls: [LiveFunctionCall(id: id, name: name, args: args)],
        ),
      ),
    );
    await settle();
    return session.toolResponses.lastWhere((r) => r.id == id).result;
  }

  /// El asistente habla (la pregunta de confirmación) y termina su turno.
  Future<void> assistantSpeaks() async {
    session.emitResponse(
      const LiveResponse(type: LiveResponseType.audio, data: 'AAAA'),
    );
    session.emitResponse(
      const LiveResponse(type: LiveResponseType.turnComplete),
    );
    media.onDrained?.call();
    await settle();
  }

  /// El asistente empieza a hablar (en altavoz, el micrófono se cierra).
  Future<void> assistantStarts() async {
    session.emitResponse(
      const LiveResponse(type: LiveResponseType.audio, data: 'AAAA'),
    );
    await settle();
  }

  /// Termina su turno y el audio deja de sonar (el micrófono se reabre).
  Future<void> assistantEnds() async {
    session.emitResponse(
      const LiveResponse(type: LiveResponseType.turnComplete),
    );
    media.onDrained?.call();
    await settle();
  }

  Future<void> reliableGps() async {
    for (var s = 0; s <= 6; s += 2) {
      gps.fixes.add(
        LocationFix(
          latitude: 3.38927,
          longitude: -76.53019,
          accuracyM: 5,
          at: t0.add(Duration(seconds: s)),
        ),
      );
      await settle();
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    session = FakeLiveSessionRepository();
    media = FakeMediaRepository();
    gps = FakeLocationRepository(
      address: 'Carrera 76 # 14C-101, Comuna 17, Cali',
    );
    emergency = FakeEmergencyRepository();
    announcements = [];
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        liveSessionRepositoryProvider.overrideWithValue(session),
        mediaRepositoryProvider.overrideWithValue(media),
        backgroundSessionRepositoryProvider.overrideWithValue(
          FakeBackgroundSession(),
        ),
        locationRepositoryProvider.overrideWithValue(gps),
        trackRecorderProvider.overrideWithValue(FakeTrackRecorder()),
        locationClockProvider.overrideWithValue(() => t0),
        emergencyRepositoryProvider.overrideWithValue(emergency),
        sosConfirmationWindowProvider.overrideWithValue(window),
        sosQuestionFallbackProvider.overrideWithValue(fallback),
        sosMaxWaitProvider.overrideWithValue(window * 4),
        sosAnswerWindowProvider.overrideWithValue(window * 2),
        announcerProvider.overrideWithValue((m, _) => announcements.add(m)),
        retryDelayProvider.overrideWithValue((_) => Duration.zero),
      ],
    );
    addTearDown(container.dispose);
    live().onTap();
    await settle();
    session.emitSetupComplete();
    await settle();
  });

  group('contacto de emergencia por voz', () {
    test('se guarda normalizado, se lee por grupos y pide permisos', () async {
      final r = await tool('set_emergency_contact', {
        'name': 'Laura',
        'phone': '315 123 4567',
      });
      expect(r, startsWith('ok'));
      expect(r, contains('315 123 4567'));
      expect(emergency.contact?.phone, '+573151234567');
      expect(emergency.permissionRequests, 1);
    });

    test('sin permiso de SMS lo guarda y avisa que no podrá enviar', () async {
      emergency.smsPermission = false;
      final r = await tool('set_emergency_contact', {
        'name': 'Laura',
        'phone': '3151234567',
      });
      expect(r, startsWith('ok'));
      expect(r, contains('SMS permission was not granted'));
    });

    test('un número inválido no se guarda y se lee por grupos lo que se '
        'oyó', () async {
      // En la prueba el reconocimiento añadía un dígito al inicio.
      final r = await tool('set_emergency_contact', {
        'name': 'Laura',
        'phone': '13151234567',
      });
      expect(r, startsWith('error'));
      expect(r, contains('11 digits: 131 512 345 67'));
      expect(r, contains('groups of three, three and four'));
      expect(emergency.contact, isNull);
    });
  });

  group('alerta SOS', () {
    test('criterio 3: sin contacto ofrece el 123 y no envía nada', () async {
      final r = await tool('trigger_sos');
      expect(r, startsWith('no_contact'));
      expect(r, contains('123'));
      await wait(fallback + window * 2);
      expect(emergency.sms, isEmpty);
    });

    test('criterio 1: pregunta, la persona confirma y se envía con la '
        'ubicación', () async {
      emergency.contact = laura;
      await reliableGps();

      final pending = await tool('trigger_sos');
      expect(pending, startsWith('pending'));
      expect(pending, contains('¿Envío la alerta a Laura?'));
      expect(emergency.sms, isEmpty);

      final sent = await tool('trigger_sos'); // "sí" o "SOS" otra vez
      expect(sent, startsWith('sent'));
      expect(sent, contains('current location'));
      expect(emergency.sms.single.phone, '+573151234567');
      expect(
        emergency.sms.single.text,
        contains(
          'Estoy en Carrera 76 # 14C-101, Comuna 17, Cali. Coordenadas '
          '3.38927,-76.53019 (precision 5 m, 09:00)',
        ),
      );
      await wait(fallback + window * 2);
      expect(emergency.sms, hasLength(1)); // la cuenta no la envía otra vez
    });

    test('criterio 2: sin respuesta, se envía sola cuando termina la '
        'pregunta y el asistente lo dice', () async {
      emergency.contact = laura;
      await tool('trigger_sos');
      await assistantSpeaks(); // "¿Envío la alerta a Laura?"
      expect(emergency.sms, isEmpty);

      await wait(window * 3);
      expect(emergency.sms, hasLength(1));
      expect(session.sosResults.single, startsWith('sent'));
      expect(session.sosResults.single, contains('without a location'));
    });

    test('si la pregunta no llega a sonar, la cuenta arranca igual', () async {
      emergency.contact = laura;
      await tool('trigger_sos');
      await wait(fallback ~/ 2);
      expect(emergency.sms, isEmpty);
      await wait(fallback + window * 2);
      expect(emergency.sms, hasLength(1));
    });

    test(
      'si la persona está hablando, la cuenta espera su respuesta',
      () async {
        emergency.contact = laura;
        await tool('trigger_sos');
        await assistantSpeaks();
        await wait(window ~/ 2);
        session.emitResponse(
          const LiveResponse(
            type: LiveResponseType.inputTranscription,
            data: LiveTranscription(text: ' sí', finished: false),
          ),
        );
        await wait(window ~/ 2 + const Duration(milliseconds: 5));
        expect(emergency.sms, isEmpty); // sin reinicio ya se habría enviado

        final r = await tool('trigger_sos'); // llega el "sí"
        expect(r, startsWith('sent'));
        await wait(window * 3);
        expect(emergency.sms, hasLength(1));
        expect(session.sosResults, isEmpty);
      },
    );

    test('la cuenta no se alarga sin fin por ruido', () async {
      emergency.contact = laura;
      await tool('trigger_sos');
      await assistantSpeaks();
      for (var i = 0; i < 8; i++) {
        await wait(window ~/ 2);
        session.emitResponse(
          const LiveResponse(
            type: LiveResponseType.inputTranscription,
            data: LiveTranscription(text: ' <noise>', finished: false),
          ),
        );
      }
      await wait(window * 2);
      expect(emergency.sms, hasLength(1)); // se envió dentro del tope
    });

    test('si la red no confirma a tiempo, no dice que no se envió', () async {
      emergency.contact = laura;
      emergency.smsResult = SmsResult.timeout;
      await tool('trigger_sos');
      final r = await tool('trigger_sos');
      expect(r, startsWith('unconfirmed'));
      expect(r, contains('cannot confirm'));
    });

    test('la cuenta se pausa mientras habla el asistente (la persona no '
        'puede contestar)', () async {
      emergency.contact = laura;
      await tool('trigger_sos');
      await assistantSpeaks(); // la pregunta: empieza la cuenta
      await assistantStarts(); // vuelve a hablar (p. ej. otro anuncio)
      await wait(window * 3);
      expect(emergency.sms, isEmpty); // en la prueba, aquí ya se enviaba

      await assistantEnds(); // se reabre el micrófono: cuenta completa
      await wait(window ~/ 2);
      expect(emergency.sms, isEmpty);
      await wait(window * 2);
      expect(emergency.sms, hasLength(1));
    });

    test(
      'recién enviada, otra alerta solo sale si la persona la confirma',
      () async {
        emergency.contact = laura;
        await tool('trigger_sos');
        await tool('trigger_sos'); // "sí"
        expect(emergency.sms, hasLength(1));

        final again = await tool('trigger_sos'); // "Ah! So." mientras salía
        expect(again, startsWith('pending'));
        expect(again, contains('¿Envío otra?'));
        await assistantSpeaks();
        await wait(fallback + window * 3);
        expect(emergency.sms, hasLength(1)); // en silencio no se envía otra

        expect(await tool('trigger_sos'), startsWith('sent')); // "sí, otra"
        expect(emergency.sms, hasLength(2));
      },
    );

    test('"no" cancela: no se envía nada', () async {
      emergency.contact = laura;
      await tool('trigger_sos');
      await assistantSpeaks();
      expect(await tool('cancel_sos'), startsWith('cancelled'));
      await wait(fallback + window * 2);
      expect(emergency.sms, isEmpty);
    });

    test('si el SMS falla, el asistente lo sabe y ofrece llamar', () async {
      emergency.contact = laura;
      emergency.smsResult = SmsResult.failed;
      await tool('trigger_sos');
      final r = await tool('trigger_sos');
      expect(r, startsWith('failed'));
      expect(r, contains('call_phone'));
    });

    test('si la sesión se cayó, el aviso lo da la voz del teléfono', () async {
      emergency.contact = laura;
      await tool('trigger_sos');
      await assistantSpeaks();
      live().disconnect(); // Detener no cancela la alerta pendiente
      announcements.clear();

      await wait(window * 3);
      expect(emergency.sms, hasLength(1));
      expect(session.sosResults, isEmpty);
      expect(announcements.single, noticeText(LiveNotice.sosSent, 'es'));
    });
  });

  group('llamadas', () {
    test('al contacto: cuando el asistente avisa, se pausa y llama', () async {
      emergency.contact = laura;
      final r = await tool('call_phone', {'to': 'contact'});
      expect(r, startsWith('ok'));
      expect(emergency.calls, isEmpty); // primero dice "Llamando a Laura"

      await assistantSpeaks();
      await settle();
      expect(emergency.calls, ['+573151234567']);
      expect(session.connected, isFalse);
      expect(container.read(liveControllerProvider).status, LiveStatus.idle);
    });

    test('al 123: abre el marcador con el número', () async {
      await tool('call_phone', {'to': 'emergency'});
      await wait(fallback * 2);
      expect(emergency.dials, ['123']);
      expect(emergency.calls, isEmpty);
    });

    test('al contacto sin configurarlo: no llama y ofrece el 123', () async {
      final r = await tool('call_phone', {'to': 'contact'});
      expect(r, startsWith('no_contact'));
      await wait(fallback * 2);
      expect(emergency.calls, isEmpty);
    });
  });
}
