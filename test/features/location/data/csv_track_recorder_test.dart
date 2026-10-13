/// HU-013 (DoD): el recorrido queda en un CSV en el teléfono.
library;

import 'dart:io';

import 'package:app/features/location/data/repositories/csv_track_recorder.dart';
import 'package:app/features/location/domain/entities/heading.dart';
import 'package:app/features/location/domain/entities/location_fix.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late CsvTrackRecorder recorder;

  File csv() => File('${dir.path}/$gpsTrackFileName');

  LocationFix fix(double accuracyM, int second) => LocationFix(
    latitude: 3.451294,
    longitude: -76.512191,
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
      expect(lines[2], endsWith(',3.451294,-76.512191,3.9,reliable,,,,'));
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

  test('anota la velocidad y el rumbo de la persona (HU-016)', () async {
    await recorder.begin();
    recorder.record(
      LocationFix(
        latitude: 0,
        longitude: 0,
        accuracyM: 4,
        at: DateTime(2026, 10, 13, 15),
        speedMps: 1.2,
        courseDeg: 92,
      ),
      GpsReliability.reliable,
      const Heading(degrees: 92, source: HeadingSource.gps),
    );
    recorder.record(
      fix(4, 2),
      GpsReliability.reliable,
      const Heading(
        degrees: 181.4,
        source: HeadingSource.compass,
        needsCalibration: true,
      ),
    );
    final lines = csv().readAsLinesSync();
    expect(lines[1], endsWith(',reliable,1.20,92,gps,no'));
    expect(lines[2], endsWith(',reliable,,181,compass,si'));
  });

  test('un archivo con el encabezado anterior se guarda aparte', () async {
    File(
      '${dir.path}/$gpsTrackFileName',
    ).writeAsStringSync('tramo,hora,latitud,longitud,precision_m,estado\nx\n');
    await recorder.begin();
    expect(csv().readAsLinesSync(), [gpsTrackHeader]);
    expect(
      File('${dir.path}/$gpsTrackPreviousFileName').readAsLinesSync(),
      hasLength(2),
    );
  });
}
