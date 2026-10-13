/// Inyección de dependencias de las notas de campo (HU-024).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/debug/field_evidence.dart';
import '../../data/repositories/csv_note_recorder.dart';
import '../../domain/repositories/note_recorder.dart';

/// Notas en CSV solo con evidencia de campo (depuración y versiones del
/// piloto): llevan la posición de la persona.
final noteRecorderProvider = Provider<NoteRecorder>(
  (ref) => kFieldEvidence
      ? CsvNoteRecorder(evidenceDirectory)
      : const NoNoteRecorder(),
);
