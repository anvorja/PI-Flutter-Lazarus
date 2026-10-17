/// Lo nuevo de cada archivo de evidencia desde la última subida (HU-045).
///
/// La app guarda hasta qué byte subió cada archivo. Si un archivo es más corto
/// que eso, se rotó (`lazarus.log` pasa a `lazarus.log.1` al llegar a 5 MB) y
/// se sube completo otra vez desde el principio.
library;

import 'dart:io';

/// Archivos que se suben (el backend rechaza cualquier otro).
const List<String> uploadableFiles = [
  'lazarus.log.1',
  'lazarus.log',
  'telemetry.jsonl.1',
  'telemetry.jsonl',
  'gps_track_anterior.csv',
  'gps_track.csv',
  'notas_campo_anterior.csv',
  'notas_campo.csv',
];

/// Máximo por fragmento (el backend acepta hasta 5 MB por archivo).
const int maxChunkBytes = 4 * 1024 * 1024;

class LogChunk {
  const LogChunk(this.name, this.bytes, this.endOffset);

  final String name;
  final List<int> bytes;

  /// Hasta dónde queda subido el archivo si este fragmento llega.
  final int endOffset;
}

Future<List<LogChunk>> pendingChunks(
  Directory dir,
  Map<String, int> offsets,
) async {
  final out = <LogChunk>[];
  for (final name in uploadableFiles) {
    final file = File('${dir.path}/$name');
    if (!file.existsSync()) continue;
    final length = await file.length();
    var from = offsets[name] ?? 0;
    if (length < from) from = 0; // rotado: empieza de nuevo
    if (length == from) continue;
    final end = (length - from) > maxChunkBytes ? from + maxChunkBytes : length;
    final raf = await file.open();
    try {
      await raf.setPosition(from);
      out.add(LogChunk(name, await raf.read(end - from), end));
    } finally {
      await raf.close();
    }
  }
  return out;
}
