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
    'hora,nota,latitud,longitud,precision_m,estado_gps,rumbo_grados,rumbo_fuente';

/// Notas con el encabezado anterior (sin rumbo): se conservan aparte para no
/// mezclar columnas.
const String fieldNotesPreviousFileName = 'notas_campo_anterior.csv';

/// Ruta y punto de cada nota dictada con una ruta activa (HU-050). Va en un
/// archivo aparte: cambiar el encabezado de `notas_campo.csv` rompería la
/// subida al panel, que manda solo lo nuevo de cada archivo. El panel une las
/// dos por la hora y el texto.
const String routeNotesFileName = 'notas_ruta.csv';
const String routeNotesHeader = 'hora,ruta,punto,nombre_punto,nota';

class CsvNoteRecorder implements NoteRecorder {
  CsvNoteRecorder(this._directory);

  /// Carpeta donde vive el archivo (en la app: `evidenceDirectory`).
  final Future<Directory> Function() _directory;

  @override
  Future<bool> add(FieldNote note) async {
    try {
      final dir = await _directory();
      final file = File('${dir.path}/$fieldNotesFileName');
      if (file.existsSync()) {
        final lines = file.readAsLinesSync();
        if (lines.isNotEmpty && lines.first != fieldNotesHeader) {
          file.renameSync('${dir.path}/$fieldNotesPreviousFileName');
        }
      }
      final fix = note.fix;
      final heading = note.heading;
      final line = [
        note.at.toIso8601String(),
        csvField(note.text),
        fix?.latitude.toStringAsFixed(6) ?? '',
        fix?.longitude.toStringAsFixed(6) ?? '',
        fix?.accuracyM.toStringAsFixed(1) ?? '',
        fix == null ? '' : note.reliability.name,
        heading?.degrees.toStringAsFixed(0) ?? '',
        heading?.source.name ?? '',
      ].join(',');
      final header = file.existsSync() ? '' : '$fieldNotesHeader\n';
      file.writeAsStringSync(
        '$header$line\n',
        mode: FileMode.append,
        flush: true,
      );
      final route = note.route;
      if (route != null) {
        final routeFile = File('${dir.path}/$routeNotesFileName');
        final routeLine = [
          note.at.toIso8601String(),
          csvField(route),
          note.nextPoint?.toString() ?? '',
          csvField(note.nextPointName ?? ''),
          csvField(note.text),
        ].join(',');
        routeFile.writeAsStringSync(
          '${routeFile.existsSync() ? '' : '$routeNotesHeader\n'}$routeLine\n',
          mode: FileMode.append,
          flush: true,
        );
      }
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
