/// [NoteRecorder] que escribe las notas de campo en un CSV en la carpeta de la
/// evidencia (ver `field_evidence.dart`):
///
///   adb pull /sdcard/Android/data/com.lazarus.app/files/notas_campo.csv
///
/// Cada nota se escribe y se vuelca al disco en el momento: si la app se cierra
/// de golpe en la calle, la nota queda.
library;

import 'dart:io';

import '../../domain/entities/field_note.dart';
import '../../domain/repositories/note_recorder.dart';

const String fieldNotesFileName = 'notas_campo.csv';
const String fieldNotesHeader =
    'hora,nota,latitud,longitud,precision_m,estado_gps';

class CsvNoteRecorder implements NoteRecorder {
  CsvNoteRecorder(this._directory);

  /// Carpeta donde vive el archivo (en la app: `evidenceDirectory`).
  final Future<Directory> Function() _directory;

  @override
  Future<bool> add(FieldNote note) async {
    try {
      final dir = await _directory();
      final file = File('${dir.path}/$fieldNotesFileName');
      final fix = note.fix;
      final line = [
        note.at.toIso8601String(),
        csvField(note.text),
        fix?.latitude.toStringAsFixed(6) ?? '',
        fix?.longitude.toStringAsFixed(6) ?? '',
        fix?.accuracyM.toStringAsFixed(1) ?? '',
        fix == null ? '' : note.reliability.name,
      ].join(',');
      final header = file.existsSync() ? '' : '$fieldNotesHeader\n';
      file.writeAsStringSync(
        '$header$line\n',
        mode: FileMode.append,
        flush: true,
      );
      return true;
    } catch (_) {
      return false; // sin espacio o sin acceso: la nota no debe tumbar la app
    }
  }
}

/// Campo de CSV: entre comillas si lleva comas, comillas o saltos de línea.
String csvField(String text) {
  final clean = text.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
  if (!clean.contains(',') && !clean.contains('"')) return clean;
  return '"${clean.replaceAll('"', '""')}"';
}
