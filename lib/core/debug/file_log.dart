/// Copia en un archivo del teléfono de las trazas `[Lazarus]` (solo con
/// evidencia de campo, ver `field_evidence.dart`), para las pruebas en la calle sin el PC conectado: en la
/// prueba de CP-LAZA-39 el búfer de logcat se llenó con mensajes del sistema y
/// se perdió la conversación del recorrido.
///
///   adb pull /sdcard/Android/data/com.lazarus.app/files/lazarus.log
///
/// Al llegar a [maxBytes] el archivo pasa a `lazarus.log.1` (se conserva el
/// anterior) y empieza uno nuevo.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

const String fileLogName = 'lazarus.log';

class FileLog {
  FileLog(
    this._file, {
    this.maxBytes = 5 * 1024 * 1024,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final File _file;
  final int maxBytes;
  final DateTime Function() _clock;

  /// Anota la línea si es una traza de la app.
  void write(String? message) {
    if (message == null || !message.contains('[Lazarus]')) return;
    try {
      if (_file.existsSync() && _file.lengthSync() > maxBytes) {
        _file.renameSync('${_file.path}.1');
      }
      _file.writeAsStringSync(
        '${_time(_clock())} $message\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Sin espacio o sin acceso: el registro no debe tumbar la app.
    }
  }

  /// Hace que cada `debugPrint` también quede en el archivo.
  void install() {
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      original(message, wrapWidth: wrapWidth);
      write(message);
    };
  }
}

/// "10-05 15:01:26.181", el mismo formato de hora que `logcat -v time`.
String _time(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:'
      '${two(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';
}
