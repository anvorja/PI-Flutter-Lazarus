/// Registro de las trazas en un archivo del teléfono (pruebas en la calle).
library;

import 'dart:io';

import 'package:app/core/debug/file_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('lazarus_log_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('anota solo las trazas de la app, con la hora', () {
    final file = File('${dir.path}/$fileLogName');
    final log = FileLog(
      file,
      clock: () => DateTime(2026, 10, 5, 15, 1, 26, 181),
    );
    log.write('[Lazarus] gps: iniciado');
    log.write('otra cosa del sistema');
    log.write(null);
    expect(
      file.readAsStringSync(),
      '10-05 15:01:26.181 [Lazarus] gps: iniciado\n',
    );
  });

  test('al llenarse, conserva el anterior y empieza otro', () {
    final file = File('${dir.path}/$fileLogName');
    final log = FileLog(file, maxBytes: 40);
    log.write('[Lazarus] primera línea bastante larga');
    log.write('[Lazarus] segunda');
    expect(File('${file.path}.1').readAsStringSync(), contains('primera'));
    expect(file.readAsStringSync(), contains('segunda'));
    expect(file.readAsStringSync(), isNot(contains('primera')));
  });
}
