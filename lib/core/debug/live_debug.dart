/// Trazas de diagnóstico `[Lazarus]` (HU-015): en depuración y en las versiones
/// del piloto con evidencia de campo. En otra versión no se escribe nada en
/// logcat: las trazas llevan lo que oyó y dijo el asistente.
library;

import 'package:flutter/foundation.dart';

import 'field_evidence.dart';

const bool kLiveDebug = kFieldEvidence;

void liveLog(String message) {
  if (kLiveDebug) debugPrint(message);
}
