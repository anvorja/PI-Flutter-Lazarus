// La capa de presentación (páginas, widgets y controladores) solo depende de
// `domain`; la conexión con `data` vive únicamente en los providers (inyección).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('presentation no importa data (salvo el archivo de providers)', () {
    final files = Directory('lib/features')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.contains('/presentation/'))
        .where((f) => !f.path.contains('/providers/'));

    final violations = <String>[
      for (final f in files)
        for (final line in f.readAsLinesSync())
          if (line.startsWith('import') && line.contains('/data/'))
            '${f.path}: $line',
    ];

    expect(violations, isEmpty);
  });

  test('domain no depende de data ni de presentation', () {
    final files = Directory('lib/features')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.contains('/domain/'));

    for (final f in files) {
      for (final line in f.readAsLinesSync()) {
        if (!line.startsWith('import')) continue;
        expect(line, isNot(contains('/data/')), reason: f.path);
        expect(line, isNot(contains('/presentation/')), reason: f.path);
      }
    }
  });
}
