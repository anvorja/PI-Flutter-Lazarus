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

  group('el archivo va al panel: sin números de teléfono', () {
    test('enmascara el número del contacto de emergencia', () {
      expect(
        maskPhones(
          '[Lazarus] toolCall: set_emergency_contact({name: Ana, phone: 3001234567})',
        ),
        '[Lazarus] toolCall: set_emergency_contact({name: Ana, phone: [número]})',
      );
      expect(
        maskPhones('[Lazarus] asistente dijo: "Guardo a Ana, 300 123 4567."'),
        '[Lazarus] asistente dijo: "Guardo a Ana, [número]."',
      );
      expect(maskPhones('llama al +57 300-123-4567'), 'llama al [número]');
    });

    test('no toca coordenadas, fechas, latencias ni horas', () {
      const otras =
          '[Lazarus] gps: 0.1234567, -0.7654321 el 2026-10-21 a las 21:38:04, '
          'mediana 3764 ms, p90 4934 ms, alerta a los 25928 ms';
      expect(maskPhones(otras), otras);
    });

    test('el archivo queda sin el número', () {
      final file = File('${dir.path}/$fileLogName');
      FileLog(file).write('[Lazarus] phone: 3001234567');
      expect(file.readAsStringSync(), isNot(contains('3001234567')));
      expect(file.readAsStringSync(), contains('phone: [número]'));
    });
  });
}
