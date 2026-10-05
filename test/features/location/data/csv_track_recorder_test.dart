/// HU-013 (DoD): el recorrido queda en un CSV en el teléfono.
library;

import 'dart:io';

import 'package:app/features/location/data/repositories/csv_track_recorder.dart';
import 'package:app/features/location/domain/entities/location_fix.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late CsvTrackRecorder recorder;

  File csv() => File('${dir.path}/$gpsTrackFileName');

  LocationFix fix(double accuracyM, int second) => LocationFix(
    latitude: 3.389294,
    longitude: -76.530191,
    accuracyM: accuracyM,
    at: DateTime(2026, 9, 30, 10, 0, second),
  );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('lazarus_track_');
    addTearDown(() => dir.deleteSync(recursive: true));
    recorder = CsvTrackRecorder(() async => dir);
  });

  test(
    'cabecera una vez y una línea por posición, escrita al momento',
    () async {
      await recorder.begin();
      recorder.record(fix(4.2, 0), GpsReliability.unknown);
      recorder.record(fix(3.9, 2), GpsReliability.reliable);

      // Sin cerrar: ya está en disco (si la app se cierra de golpe, queda).
      final lines = csv().readAsLinesSync();
      expect(lines.first, gpsTrackHeader);
      expect(lines, hasLength(3));
      expect(lines[2], endsWith(',3.389294,-76.530191,3.9,reliable'));
    },
  );

  test(
    'varios tramos en el mismo archivo, cada uno con su identificador',
    () async {
      await recorder.begin();
      recorder.record(fix(4, 0), GpsReliability.unknown);
      await recorder.end();
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await recorder.begin();
      recorder.record(fix(5, 2), GpsReliability.unknown);
      await recorder.end();

      final lines = csv().readAsLinesSync();
      expect(lines.where((l) => l == gpsTrackHeader), hasLength(1));
      final segments = lines.skip(1).map((l) => l.split(',').first).toSet();
      expect(segments, hasLength(2));
    },
  );

  test('tras end() no se escribe nada', () async {
    await recorder.begin();
    await recorder.end();
    recorder.record(fix(4, 0), GpsReliability.unknown);
    expect(csv().readAsLinesSync(), [gpsTrackHeader]);
  });
}
