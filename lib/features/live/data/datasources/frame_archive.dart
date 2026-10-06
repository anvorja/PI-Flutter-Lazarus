/// Fotos recientes de la cámara guardadas como evidencia de las pruebas (solo
/// en builds de depuración): las de los últimos [FrameArchive.maxFrames]
/// segundos, con la hora en el nombre, para comparar lo que vio el asistente con
/// lo que dijo. Las más viejas se borran solas.
///
///   adb exec-out run-as com.lazarus.app tar c files/frames > frames.tar
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import '../../../../core/debug/live_debug.dart';

const String framesFolder = 'frames';

class FrameArchive {
  FrameArchive(
    this._directory, {
    this.maxFrames = 600, // 10 min a 1 foto por segundo (unos 70 MB)
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Future<Directory> Function() _directory;
  final int maxFrames;
  final DateTime Function() _clock;

  final List<File> _kept = [];
  Directory? _folder;

  /// Guarda la foto y borra la más vieja si se pasa del máximo.
  Future<void> keep(Uint8List jpeg) async {
    try {
      final folder = _folder ?? await _open();
      final file = File('${folder.path}/frame_${_stamp(_clock())}.jpg');
      await file.writeAsBytes(jpeg, flush: false);
      _kept.add(file);
      while (_kept.length > maxFrames) {
        await _delete(_kept.removeAt(0));
      }
    } catch (e) {
      // Sin espacio o sin acceso: la evidencia no debe tumbar la cámara.
      liveLog('[Lazarus] fotos de evidencia: $e');
    }
  }

  /// Abre la carpeta y retoma las fotos de sesiones anteriores, por orden,
  /// para que el máximo valga también entre sesiones.
  Future<Directory> _open() async {
    final base = await _directory();
    final folder = Directory('${base.path}/$framesFolder');
    await folder.create(recursive: true);
    final previous =
        folder
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.jpg'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    _kept.addAll(previous);
    _folder = folder;
    return folder;
  }

  Future<void> _delete(File file) async {
    try {
      await file.delete();
    } catch (_) {
      // Ya no estaba: nada que hacer.
    }
  }
}

/// "20261005_150126_123": ordena por nombre igual que por hora.
String _stamp(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}${two(t.month)}${two(t.day)}_'
      '${two(t.hour)}${two(t.minute)}${two(t.second)}_'
      '${t.millisecond.toString().padLeft(3, '0')}';
}

/// Borra las fotos que dejó la cámara en la caché (`CAP*.jpg`) en versiones
/// anteriores, que no las borraban: en la prueba de CP-LAZA-39 eran 1164 fotos
/// y 194 MB. Devuelve cuántas borró.
Future<int> deleteLeftoverCaptures(Directory cache) async {
  var deleted = 0;
  try {
    for (final entity in cache.listSync()) {
      final name = entity.uri.pathSegments.last;
      if (entity is File && name.startsWith('CAP') && name.endsWith('.jpg')) {
        try {
          await entity.delete();
          deleted++;
        } catch (_) {}
      }
    }
  } catch (_) {}
  return deleted;
}
