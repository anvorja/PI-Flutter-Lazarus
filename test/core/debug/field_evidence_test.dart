/// TASK-013: la evidencia de campo va a la carpeta externa propia de la app,
/// que se baja con `adb pull` aunque la versión release no sea depurable.
library;

import 'dart:io';

import 'package:app/core/debug/field_evidence.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final externa = Directory('/sdcard/Android/data/com.lazarus.app/files');
  final interna = Directory('/data/user/0/com.lazarus.app/files');

  test('usa la carpeta externa propia de la app', () async {
    final dir = await evidenceDirectory(
      external: () async => externa,
      internal: () async => interna,
    );
    expect(dir.path, externa.path);
  });

  test('sin almacenamiento externo, usa la interna', () async {
    final dir = await evidenceDirectory(
      external: () async => null,
      internal: () async => interna,
    );
    expect(dir.path, interna.path);
  });

  test('si pedir la externa falla, usa la interna', () async {
    final dir = await evidenceDirectory(
      external: () async => throw UnsupportedError('sin almacenamiento'),
      internal: () async => interna,
    );
    expect(dir.path, interna.path);
  });

  test('en las pruebas (depuración) la evidencia está activa', () {
    expect(kFieldEvidence, isTrue);
  });
}
