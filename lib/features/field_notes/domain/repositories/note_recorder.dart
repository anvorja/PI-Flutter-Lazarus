/// Dónde quedan las notas de campo (HU-024).
library;

import '../entities/field_note.dart';

abstract class NoteRecorder {
  /// Guarda la nota. Devuelve `false` si esta versión no guarda notas.
  Future<bool> add(FieldNote note);
}

/// Versión sin evidencia de campo: no guarda notas (llevan la posición).
class NoNoteRecorder implements NoteRecorder {
  const NoNoteRecorder();

  @override
  Future<bool> add(FieldNote note) async => false;
}
