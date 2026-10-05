/// Fotos de evidencia: solo las más recientes, y sin basura en la caché.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:app/features/live/data/datasources/frame_archive.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory base;
  var now = DateTime(2026, 10, 5, 15, 1, 26);

  setUp(() {
    base = Directory.systemTemp.createTempSync('lazarus_frames_');
    now = DateTime(2026, 10, 5, 15, 1, 26);
  });
  tearDown(() => base.deleteSync(recursive: true));

  FrameArchive archive({int max = 3}) => FrameArchive(
    () async => base,
    maxFrames: max,
    clock: () => now = now.add(const Duration(seconds: 1)),
  );

  List<String> kept() => (Directory(
    '${base.path}/$framesFolder',
  ).listSync().map((f) => f.uri.pathSegments.last)).toList()..sort();

  test('guarda solo las últimas fotos, con la hora en el nombre', () async {
    final a = archive();
    for (var i = 0; i < 5; i++) {
      await a.keep(Uint8List.fromList([i]));
    }
    expect(kept(), [
      'frame_20261005_150129_000.jpg',
      'frame_20261005_150130_000.jpg',
      'frame_20261005_150131_000.jpg',
    ]);
  });

  test('el máximo vale también entre sesiones', () async {
    final first = archive();
    await first.keep(Uint8List.fromList([1]));
    await first.keep(Uint8List.fromList([2]));

    final second = archive(); // sesión nueva
    await second.keep(Uint8List.fromList([3]));
    await second.keep(Uint8List.fromList([4]));

    expect(kept(), hasLength(3));
    expect(kept().first, 'frame_20261005_150128_000.jpg');
  });

  test('borra de la caché solo las fotos viejas de la cámara', () async {
    for (final name in ['CAP1.jpg', 'CAP2.jpg', 'otra.jpg', 'CAP3.png']) {
      File('${base.path}/$name').writeAsBytesSync([0]);
    }
    expect(await deleteLeftoverCaptures(base), 2);
    expect(base.listSync().map((f) => f.uri.pathSegments.last).toSet(), {
      'otra.jpg',
      'CAP3.png',
    });
  });
}
