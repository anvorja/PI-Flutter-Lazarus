/// HU-024: "anota que…" deja una nota con la hora y la posición (criterio 3).
library;

import 'dart:io';

import 'package:app/features/field_notes/data/repositories/csv_note_recorder.dart';
import 'package:app/features/field_notes/domain/entities/field_note.dart';
import 'package:app/features/field_notes/presentation/providers/field_notes_providers.dart';
import 'package:app/features/live/domain/entities/live_message.dart';
import 'package:app/features/live/presentation/providers/live_providers.dart';
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

    test('al Detener, el log dice cuántas notas hubo', () async {
      await addNote({'text': 'uno'});
      await addNote({'text': 'dos'});
      container.read(liveControllerProvider.notifier).disconnect();
      expect(logs, contains('[Lazarus] bitácora: 2 notas en esta sesión'));
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
          ',"semáforo sin sonido, frente al paradero",0.000000,0.000000,5.0,reliable',
        ),
      );
      expect(lines[2], endsWith(',"dijo ""cuidado""",,,,'));
    });
  });
}
