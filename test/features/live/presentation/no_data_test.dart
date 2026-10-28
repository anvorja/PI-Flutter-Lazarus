/// HU-042: sin datos móviles la app lo dice con el teléfono, no gasta
/// reintentos, se reconecta sola al volver los datos y deja pedir ayuda con un
/// gesto (mantener presionada la pantalla), con y sin datos.
library;

import 'package:app/features/emergency/domain/entities/emergency_contact.dart';
import 'package:app/features/emergency/domain/repositories/emergency_repository.dart';
import 'package:app/features/emergency/presentation/providers/emergency_providers.dart';
import 'package:app/features/live/domain/entities/live_message.dart';
import 'package:app/features/live/presentation/controllers/live_controller.dart';
import 'package:app/features/live/presentation/providers/live_providers.dart';
import 'package:app/features/location/presentation/providers/location_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/fakes.dart';

void main() {
  // Contacto de prueba (datos ficticios).
  const contacto = EmergencyContact(name: 'Marta', phone: '+573001112233');
  const window = Duration(milliseconds: 300); // envío solo del SOS por gesto
  const reminder = Duration(milliseconds: 200);
  const resume = Duration(milliseconds: 100);

  late FakeLiveSessionRepository session;
  late FakeNetworkStatus network;
  late FakeEmergencyRepository emergency;
  late List<String> spoken;
  late int stops; // avisos del teléfono cortados
  late ProviderContainer container;

  LiveController live() => container.read(liveControllerProvider.notifier);
  LiveUiState state() => container.read(liveControllerProvider);
  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> wait(Duration d) => Future<void>.delayed(d);
  String text(LiveNotice n, {String name = ''}) =>
      noticeText(n, 'es', name: name);

  Future<void> build({
    EmergencyContact? contact = contacto,
    Map<String, Object> prefs = const {},
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    final p = await SharedPreferences.getInstance();
    session = FakeLiveSessionRepository();
    network = FakeNetworkStatus();
    emergency = FakeEmergencyRepository(contact: contact);
    spoken = [];
    stops = 0;
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(p),
        liveSessionRepositoryProvider.overrideWithValue(session),
        networkStatusRepositoryProvider.overrideWithValue(network),
        mediaRepositoryProvider.overrideWithValue(FakeMediaRepository()),
        backgroundSessionRepositoryProvider.overrideWithValue(
          FakeBackgroundSession(),
        ),
        compassRepositoryProvider.overrideWithValue(FakeCompassRepository()),
        locationRepositoryProvider.overrideWithValue(FakeLocationRepository()),
        trackRecorderProvider.overrideWithValue(FakeTrackRecorder()),
        emergencyRepositoryProvider.overrideWithValue(emergency),
        announcerProvider.overrideWithValue((m, _) => spoken.add(m)),
        announcerStopProvider.overrideWithValue(() => stops++),
        retryDelayProvider.overrideWithValue((_) => Duration.zero),
        offlineReminderProvider.overrideWithValue(reminder),
        sosGestureWindowProvider.overrideWithValue(window),
        sosResumeDelayProvider.overrideWithValue(resume),
      ],
    );
    addTearDown(container.dispose);
    await settle();
  }

  Future<void> startSession() async {
    live().onTap();
    await settle();
    session.emitSetupComplete();
    await settle();
  }

  group('sin datos móviles', () {
    test('criterio 1: con la sesión activa, al apagar los datos lo dice de '
        'inmediato y explica el gesto de SOS', () async {
      await build();
      await startSession();

      network.setOnline(false);
      await settle();

      expect(state().status, LiveStatus.offline);
      expect(session.connected, isFalse);
      expect(spoken.last, text(LiveNotice.noData));
      expect(spoken.last, contains('mantén presionada la pantalla'));
    });

    test('mientras no hay datos no gasta reintentos y lo recuerda', () async {
      await build();
      await startSession();
      network.setOnline(false);
      await settle();
      final calls = session.connectCalls;

      await wait(reminder * 2.5);
      expect(session.connectCalls, calls, reason: 'sin datos no se reintenta');
      expect(spoken, contains(text(LiveNotice.noDataReminder)));
    });

    test('criterio 3: al volver los datos se reconecta sola, sin tocar y sin '
        'repetir el saludo', () async {
      await build();
      await startSession();
      expect(session.kickoffs, 1);
      network.setOnline(false);
      await settle();

      network.setOnline(true);
      await settle();
      expect(state().status, LiveStatus.connecting);
      session.emitSetupComplete();
      await settle();
      expect(state().status, LiveStatus.connected);
      expect(session.kickoffs, 1, reason: 'sin repetir la presentación');
      expect(session.micResumed, 1, reason: 'confirmación corta');

      final said = spoken.length;
      await wait(reminder * 2);
      expect(spoken.length, said, reason: 'con datos ya no lo recuerda');
    });

    test(
      'al reconectar corta el aviso del teléfono antes de abrir el '
      'micrófono, para que el asistente no lo oiga como si fuera la persona',
      () async {
        await build();
        await startSession();
        network.setOnline(false);
        await settle();
        final before = stops;

        network.setOnline(true);
        await settle();
        expect(stops, before, reason: 'mientras conecta, el aviso sigue');
        session.emitSetupComplete();
        await settle();
        expect(stops, before + 1);
      },
    );

    test('criterio 4: con datos y el servidor caído dice el aviso del '
        'servidor, no el de datos', () async {
      await build();
      await startSession();
      session.emitError();
      await settle();
      expect(spoken, contains(text(LiveNotice.retrying)));
      expect(spoken, isNot(contains(text(LiveNotice.noData))));
    });

    test('si la conexión falla sin datos (al empezar), queda esperando y se '
        'conecta sola cuando vuelven', () async {
      await build();
      network.online = false;
      live().onTap();
      await settle();
      network.setOnline(false); // el sistema avisa que no hay red
      session.emitError();
      await settle();
      expect(state().status, LiveStatus.offline);
      expect(spoken, contains(text(LiveNotice.noData)));

      final calls = session.connectCalls;
      network.setOnline(true);
      await settle();
      expect(session.connectCalls, calls + 1);
    });

    test(
      'el aviso de sin datos suena aunque los avisos estén silenciados',
      () async {
        await build(prefs: {'lazarus_system_cues_muted': 'true'});
        await startSession();
        network.setOnline(false);
        await settle();
        expect(spoken, contains(text(LiveNotice.noData)));
      },
    );
  });

  group('SOS con el gesto', () {
    test('criterio 2: sin datos, el gesto pregunta y un segundo gesto envía el '
        'SMS; luego sigue esperando los datos', () async {
      await build();
      await startSession();
      network.setOnline(false);
      await settle();

      await live().onSosGesture();
      await settle();
      expect(state().status, LiveStatus.sos);
      expect(
        spoken.last,
        text(LiveNotice.sosGestureConfirm, name: contacto.name),
      );
      expect(emergency.sms, isEmpty, reason: 'primero pregunta');

      await live().onSosGesture();
      await settle();
      expect(emergency.sms.single.phone, contacto.phone);
      expect(spoken.last, text(LiveNotice.sosSent));
      expect(state().status, LiveStatus.offline);
    });

    test('sin respuesta, se envía sola como en HU-012', () async {
      await build();
      await live().onSosGesture();
      await settle();
      await wait(window * 2);
      expect(emergency.sms, hasLength(1));
      expect(spoken.last, text(LiveNotice.sosSent));
      expect(state().status, LiveStatus.idle);
    });

    test('un toque cancela la alerta pendiente', () async {
      await build();
      await live().onSosGesture();
      await settle();
      live().onTap();
      await settle();
      await wait(window * 2);
      expect(emergency.sms, isEmpty);
      expect(spoken.last, text(LiveNotice.sosCancelled));
      expect(session.connectCalls, 0, reason: 'el toque no abre la sesión');
    });

    test('sin contacto, ofrece el 123 y abre el marcador', () async {
      await build(contact: null);
      await live().onSosGesture();
      await settle();
      expect(spoken.last, text(LiveNotice.sosNoContact));
      expect(emergency.dials, ['123']);
      expect(emergency.sms, isEmpty);
    });

    test('con la sesión activa, la pausa para que el asistente no hable '
        'encima y la retoma con la confirmación corta', () async {
      await build();
      await startSession();
      await live().onSosGesture();
      await settle();
      expect(session.connected, isFalse);

      await live().onSosGesture();
      await settle();
      expect(emergency.sms, hasLength(1));
      final calls = session.connectCalls;
      await wait(resume * 2);
      expect(session.connectCalls, calls + 1);
      session.emitSetupComplete();
      await settle();
      expect(session.micResumed, 1);
      expect(session.kickoffs, 1);
    });

    test('si el SMS no se confirma, lo dice', () async {
      await build();
      emergency.smsResult = SmsResult.timeout;
      await live().onSosGesture();
      await settle();
      await live().onSosGesture();
      await settle();
      expect(spoken.last, text(LiveNotice.sosUnconfirmed));
    });

    test('Detener cancela la alerta pendiente', () async {
      await build();
      await startSession();
      await live().onSosGesture();
      await settle();
      live().disconnect();
      await wait(window * 2);
      expect(emergency.sms, isEmpty);
    });
  });

  group('SOS por voz aunque el asistente no llame a la función', () {
    void emit(LiveResponseType type, [Object? data]) =>
        session.emitResponse(LiveResponse(type: type, data: data));
    Future<void> heard(String text) async {
      emit(
        LiveResponseType.inputTranscription,
        LiveTranscription(text: text, finished: false),
      );
      await settle();
    }

    test(
      'dijo "S o s" y el turno terminó sin la alerta: la app pregunta como '
      'con el gesto y, sin respuesta, la envía (prueba del 21-oct)',
      () async {
        await build();
        await startSession();
        await heard(' S o s');
        emit(LiveResponseType.turnComplete);
        await settle();

        expect(state().status, LiveStatus.sos);
        expect(
          spoken.last,
          text(LiveNotice.sosGestureConfirm, name: contacto.name),
        );
        await wait(window * 2);
        expect(emergency.sms.single.phone, contacto.phone);
      },
    );

    test(
      'si el asistente llamó a la alerta, la app no hace nada más',
      () async {
        await build();
        await startSession();
        await heard('SOS');
        emit(
          LiveResponseType.toolCall,
          LiveToolCall(
            functionCalls: [
              LiveFunctionCall(id: 'sos', name: 'trigger_sos', args: {}),
            ],
          ),
        );
        await settle();
        emit(LiveResponseType.turnComplete);
        await settle();
        expect(state().status, isNot(LiveStatus.sos));
      },
    );

    test('una pregunta sobre el SOS no es un pedido', () async {
      await build();
      await startSession();
      await heard('¿Qué hace el SOS?');
      emit(LiveResponseType.turnComplete);
      await settle();
      expect(state().status, LiveStatus.connected);
      expect(emergency.sms, isEmpty);
    });

    test('reconoce el pedido', () {
      expect(asksSos(' S o s'), isTrue);
      expect(asksSos('SOS.'), isTrue);
      expect(asksSos('Ese o ese'), isTrue);
      expect(asksSos('Aria, SOS, ayuda', name: 'Aria'), isTrue);
      expect(asksSos('¿Qué hace el SOS?'), isFalse);
      expect(asksSos('Lee el letrero de SOS de la pared'), isFalse);
      expect(asksSos('Es o sea lo mismo'), isFalse);
      expect(asksSos('Los osos'), isFalse);
    });
  });
}
