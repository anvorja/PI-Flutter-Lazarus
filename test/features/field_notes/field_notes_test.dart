/// HU-024: "anota que…" deja una nota con la hora y la posición (criterio 3).
library;

import 'dart:io';

import 'package:app/features/field_notes/data/repositories/csv_note_recorder.dart';
import 'package:app/features/field_notes/domain/entities/field_note.dart';
import 'package:app/features/field_notes/presentation/providers/field_notes_providers.dart';
import 'package:app/features/live/domain/entities/live_message.dart';
import 'package:app/features/live/presentation/controllers/live_controller.dart';
import 'package:app/features/live/presentation/providers/live_providers.dart';
import 'package:app/features/location/domain/entities/heading.dart';
import 'package:app/features/location/domain/entities/location_fix.dart';
import 'package:app/features/location/presentation/providers/location_providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fakes.dart';

void main() {
  final t0 = DateTime(2026, 10, 13, 15, 2);

  group('comando "anota que…"', () {
    late FakeLiveSessionRepository session;
    late FakeLocationRepository gps;
    late FakeNoteRecorder notes;
    late List<String> logs;
    late ProviderContainer container;

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    Future<String> addNote(Map<String, dynamic> args) async {
      session.emitResponse(
        LiveResponse(
          type: LiveResponseType.toolCall,
          data: LiveToolCall(
            functionCalls: [
              LiveFunctionCall(id: 'n1', name: 'add_note', args: args),
            ],
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return session.toolResponses.last.result;
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      session = FakeLiveSessionRepository();
      gps = FakeLocationRepository();
      notes = FakeNoteRecorder();
      logs = [];
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
      addTearDown(() => debugPrint = original);
      container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          liveSessionRepositoryProvider.overrideWithValue(session),
          networkStatusRepositoryProvider.overrideWithValue(
            FakeNetworkStatus(),
          ),
          mediaRepositoryProvider.overrideWithValue(FakeMediaRepository()),
          backgroundSessionRepositoryProvider.overrideWithValue(
            FakeBackgroundSession(),
          ),
          compassRepositoryProvider.overrideWithValue(FakeCompassRepository()),
          locationRepositoryProvider.overrideWithValue(gps),
          trackRecorderProvider.overrideWithValue(FakeTrackRecorder()),
          screenAwakeProvider.overrideWithValue((_) async {}),
          noteRecorderProvider.overrideWithValue(notes),
          liveClockProvider.overrideWithValue(() => t0),
          announcerProvider.overrideWithValue((_, _) {}),
          announcerStopProvider.overrideWithValue(() {}),
          retryDelayProvider.overrideWithValue((_) => Duration.zero),
        ],
      );
      addTearDown(container.dispose);
      container.read(liveControllerProvider.notifier).onTap();
      await settle();
      session.emitSetupComplete();
      await settle();
    });

    test('guarda la nota con la hora y la posición (criterio 3)', () async {
      // Coordenadas ficticias: las pruebas no usan lugares reales.
      gps.fixes.add(
        LocationFix(latitude: 0, longitude: 0, accuracyM: 6, at: t0),
      );
      await settle();
      final result = await addNote({'text': 'la rampa está bloqueada'});
      expect(result, startsWith('ok: note saved at 15:02 with the position'));
      final note = notes.notes.single;
      expect(note.text, 'la rampa está bloqueada');
      expect(note.at, t0);
      expect(note.fix!.accuracyM, 6);
      expect(
        logs,
        contains(
          '[Lazarus] nota: "la rampa está bloqueada" (15:02, ±6 m, unknown)',
        ),
      );
    });

    test('sin GPS todavía, la guarda sin posición', () async {
      final result = await addNote({'text': 'hay un hueco en el andén'});
      expect(result, contains('without position'));
      expect(notes.notes.single.fix, isNull);
    });

    test('una nota que solo dice "posición" se guarda y pide qué hay ahí '
        '(jornada del 24-oct)', () async {
      final result = await addNote({'text': 'Guarda posición.'});
      expect(result, contains('ask in one short sentence what is at'));
      expect(notes.notes.single.text, 'Guarda posición.');
    });

    test('notas que solo marcan el lugar', () {
      for (final text in [
        'posición',
        'Coordenadas',
        'Posición actual',
        'Guarde posición',
        'position',
      ]) {
        expect(isPlaceMarkerNote(text), isTrue, reason: text);
      }
      for (final text in [
        'inicio de cruce peatonal',
        'girar a la derecha',
        'posición del semáforo dañado',
        '',
      ]) {
        expect(isPlaceMarkerNote(text), isFalse, reason: text);
      }
    });

    test('una nota vacía no se guarda: pregunta qué anotar', () async {
      final result = await addNote({'text': '  '});
      expect(result, startsWith('error'));
      expect(notes.notes, isEmpty);
    });

    test('en una versión sin evidencia de campo lo dice', () async {
      notes.enabled = false;
      final result = await addNote({'text': 'algo'});
      expect(result, startsWith('unavailable'));
    });

    void hear(String text) => session.emitResponse(
      LiveResponse(
        type: LiveResponseType.inputTranscription,
        data: LiveTranscription(text: text, finished: false),
      ),
    );

    Future<void> assistantSaysAndEnds(String text) async {
      session.emitResponse(
        LiveResponse(
          type: LiveResponseType.outputTranscription,
          data: LiveTranscription(text: text, finished: true),
        ),
      );
      session.emitResponse(
        const LiveResponse(type: LiveResponseType.turnComplete),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    test(
      'si dice "Anotado." sin llamar a add_note, la app guarda la nota',
      () async {
        hear(' Ano');
        hear('ta que');
        hear(' estoy en los torniquetes.');
        await assistantSaysAndEnds('Anotado.');
        expect(notes.notes.single.text, 'estoy en los torniquetes');
        expect(
          logs,
          contains(
            '[Lazarus] nota guardada por la app (el asistente dijo "Anotado" sin llamar a add_note)',
          ),
        );
      },
    );

    test('si sí llama a add_note, no la duplica', () async {
      hear(' Anota que hay un escalón.');
      await addNote({'text': 'hay un escalón'});
      await assistantSaysAndEnds('Anotado.');
      expect(notes.notes, hasLength(1));
    });

    test('si pregunta qué anotar, la respuesta de la persona es la nota '
        'aunque no llame a add_note', () async {
      hear(' Anota.');
      await assistantSaysAndEnds('¿Qué quieres que anote?');
      expect(notes.notes, isEmpty);
      hear(' Que hay un poste.');
      await assistantSaysAndEnds('Semáforo en rojo.');
      expect(notes.notes.single.text, 'Que hay un poste.');
    });

    test('sin pedir anotar no se guarda nada', () async {
      hear(' ¿Dónde estoy?');
      await assistantSaysAndEnds('Estás en la estación.');
      expect(notes.notes, isEmpty);
    });

    for (final (heard, said, text) in [
      // Jornada del 27-oct: notas que se perdieron.
      (
        ' A nota que para pasar el cruce peatonal son 15 pasos.',
        'Anotado.',
        'para pasar el cruce peatonal son 15 pasos',
      ),
      (' Anota que son 22 pasos.', 'Anoto que son 22 pasos.', 'son 22 pasos'),
      (
        ' Anota que hay dos bancos Davivienda.',
        'Anotado: hay dos bancos Davivienda.',
        'hay dos bancos Davivienda',
      ),
      (
        ' Nota que aquí debo seguir por un pasillo largo.',
        'Entendido.',
        'aquí debo seguir por un pasillo largo',
      ),
    ]) {
      test('la persona pidió anotar y el asistente respondió "$said" sin '
          'llamar a add_note: la app la guarda', () async {
        hear(heard);
        await assistantSaysAndEnds(said);
        expect(notes.notes.single.text, text);
      });
    }

    test(
      'si el asistente guarda después la misma nota, no se repite',
      () async {
        hear(' Anota que son 22 pasos hasta la portería.');
        await assistantSaysAndEnds('Anoto que son 22 pasos.');
        expect(
          await addNote({'text': 'son 22 pasos hasta la portería'}),
          startsWith('ok: the note was already saved'),
        );
        expect(notes.notes, hasLength(1));
        await addNote({'text': 'hay un escalón'});
        expect(notes.notes, hasLength(2));
      },
    );

    test('una nota ya guardada no se repite en el turno siguiente', () async {
      hear(' Anota que llegamos a la portería.');
      await assistantSaysAndEnds('Anotado.');
      hear(' ¿Dónde estoy?');
      await assistantSaysAndEnds('Anotado.');
      expect(notes.notes, hasLength(1));
    });

    test('al Detener, el log dice cuántas notas hubo', () async {
      await addNote({'text': 'uno'});
      await addNote({'text': 'dos'});
      container.read(liveControllerProvider.notifier).disconnect();
      expect(logs, contains('[Lazarus] bitácora: 2 notas en esta sesión'));
    });
  });

  group('nota "Anotado." sin llamar a add_note (Fase 0)', () {
    test('frases de la caminata: lo que sigue a "anota que", o lo anterior '
        'si "anota" va al final', () {
      expect(
        noteRequestText(' Anota que estoy en la estación.'),
        'estoy en la estación',
      );
      expect(
        noteRequestText(' Estoy en la estación y voy para Univalle, anota.'),
        'Estoy en la estación y voy para Univalle',
      );
      expect(
        noteRequestText('apunta que el semáforo peatonal está dañado'),
        'el semáforo peatonal está dañado',
      );
      expect(noteRequestText(' A nota que hay escaleras.'), 'hay escaleras');
      expect(
        noteRequestText('136 pasos por el pasillo, anótalo.'),
        '136 pasos por el pasillo',
      );
      expect(noteRequestText('Es una nota musical.'), isNull);
      expect(
        sameNote('son 22 pasos', 'Son 22 pasos hasta la portería'),
        isTrue,
      );
      expect(sameNote('hay un escalón', 'son 22 pasos'), isFalse);
      expect(asksWhatToNote('¿Qué deseas anotar?'), isTrue);
      expect(asksWhatToNote('Anotado.'), isFalse);
      expect(noteRequestText(' Anota.'), isNull);
      expect(noteRequestText('¿Dónde estoy?'), isNull);
      expect(saysNoted('Anotado. El semáforo peatonal está en verde.'), isTrue);
      expect(saysNoted('Noted.'), isTrue);
      expect(saysNoted('Semáforo en rojo.'), isFalse);
    });
  });

  group('archivo de notas', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('lazarus_notas_');
      addTearDown(() => dir.deleteSync(recursive: true));
    });

    test('encabezado una vez y una línea por nota, escrita al momento', () async {
      final recorder = CsvNoteRecorder(() async => dir);
      await recorder.add(
        FieldNote(
          at: t0,
          text: 'semáforo sin sonido, frente al paradero',
          fix: LocationFix(latitude: 0, longitude: 0, accuracyM: 5, at: t0),
          reliability: GpsReliability.reliable,
        ),
      );
      await recorder.add(FieldNote(at: t0, text: 'dijo "cuidado"'));
      final lines = File('${dir.path}/$fieldNotesFileName').readAsLinesSync();
      expect(lines.first, fieldNotesHeader);
      expect(lines, hasLength(3));
      expect(
        lines[1],
        endsWith(
          ',"semáforo sin sonido, frente al paradero",0.000000,0.000000,5.0,reliable,,',
        ),
      );
      expect(lines[2], endsWith(',"dijo ""cuidado""",,,,,,'));
    });

    test(
      'guarda el rumbo de la brújula o del GPS (pedido en la Fase 0)',
      () async {
        final recorder = CsvNoteRecorder(() async => dir);
        File file() => File('${dir.path}/$fieldNotesFileName');
        await recorder.add(
          FieldNote(
            at: DateTime(2026, 10, 17, 11, 55),
            text: 'portería de Unicentro',
            heading: const Heading(
              degrees: 312.4,
              source: HeadingSource.compass,
            ),
          ),
        );
        final lines = file().readAsLinesSync();
        expect(lines.first, endsWith(',rumbo_grados,rumbo_fuente'));
        expect(lines[1], endsWith(',312,compass'));
      },
    );

    test('un archivo con el encabezado anterior se guarda aparte', () async {
      final recorder = CsvNoteRecorder(() async => dir);
      File file() => File('${dir.path}/$fieldNotesFileName');
      file().writeAsStringSync(
        'hora,nota,latitud,longitud,precision_m,estado_gps\nx,y,,,,\n',
      );
      await recorder.add(FieldNote(at: DateTime(2026, 10, 17), text: 'cebra'));
      expect(file().readAsLinesSync().first, fieldNotesHeader);
      expect(
        File('${dir.path}/$fieldNotesPreviousFileName').readAsLinesSync(),
        hasLength(2),
      );
    });
  });
}
