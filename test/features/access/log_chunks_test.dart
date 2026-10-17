/// HU-045: la app sube solo lo nuevo de cada archivo de evidencia.
library;

import 'dart:io';

import 'package:app/features/access/data/repositories/log_chunks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('lazarus_logs_');
    addTearDown(() => dir.deleteSync(recursive: true));
  });

  File file(String name) => File('${dir.path}/$name');

  test('sube lo nuevo desde la última subida', () async {
    file('notas_campo.csv').writeAsStringSync('hora,nota\n11:02,cebra\n');
    final first = await pendingChunks(dir, {});
    expect(first.single.name, 'notas_campo.csv');
    expect(
      String.fromCharCodes(first.single.bytes),
      'hora,nota\n11:02,cebra\n',
    );

    file(
      'notas_campo.csv',
    ).writeAsStringSync('11:05,rampa\n', mode: FileMode.append);
    final second = await pendingChunks(dir, {
      'notas_campo.csv': first.single.endOffset,
    });
    expect(String.fromCharCodes(second.single.bytes), '11:05,rampa\n');
  });

  test('sin cambios no sube nada, y solo archivos conocidos', () async {
    file('gps_track.csv').writeAsStringSync('x\n');
    file('otro.txt').writeAsStringSync('privado');
    final offsets = {'gps_track.csv': 2};
    expect(await pendingChunks(dir, offsets), isEmpty);
  });

  test(
    'si el archivo se rotó (más corto que lo subido), empieza de nuevo',
    () async {
      file('lazarus.log').writeAsStringSync('nuevo\n');
      final chunks = await pendingChunks(dir, {'lazarus.log': 5000000});
      expect(String.fromCharCodes(chunks.single.bytes), 'nuevo\n');
    },
  );

  test('un archivo enorme se sube por partes', () async {
    file('lazarus.log').writeAsBytesSync(List.filled(maxChunkBytes + 10, 65));
    final chunks = await pendingChunks(dir, {});
    expect(chunks.single.bytes, hasLength(maxChunkBytes));
    expect(chunks.single.endOffset, maxChunkBytes);
  });
}
