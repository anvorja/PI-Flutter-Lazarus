/// Evidencia de las pruebas de campo: el registro de la conversación
/// (`lazarus.log`), el recorrido (`gps_track.csv`) y las fotos recientes.
///
/// Se guarda en depuración y en las versiones del piloto, que el CD compila con
/// `--dart-define=FIELD_EVIDENCE=true` (TASK-013). Una versión sin ese valor no
/// guarda nada de esto: lleva lo que oyó y dijo el asistente y dónde estuvo la
/// persona.
///
/// Va a la carpeta externa propia de la app, que ninguna otra app puede leer y
/// que se baja sin `run-as` (una versión release no es depurable):
///
///   adb pull /sdcard/Android/data/com.lazarus.app/files/lazarus.log
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

const bool kFieldEvidence =
    kDebugMode || bool.fromEnvironment('FIELD_EVIDENCE');

/// Carpeta de la evidencia: la externa propia de la app; si el teléfono no la
/// tiene, la interna.
Future<Directory> evidenceDirectory({
  Future<Directory?> Function() external = getExternalStorageDirectory,
  Future<Directory> Function() internal = getApplicationSupportDirectory,
}) async {
  try {
    final dir = await external();
    if (dir != null) return dir;
  } catch (_) {
    // Sin almacenamiento externo (o en una plataforma que no lo tiene).
  }
  return internal();
}
