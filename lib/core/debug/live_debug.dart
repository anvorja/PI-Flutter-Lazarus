/// Trazas de diagnóstico `[Lazarus]` (HU-015): solo en builds de depuración.
/// En un build de distribución no se escribe nada en logcat: las trazas llevan
/// lo que oyó y dijo el asistente, y eso no debe salir del modo de pruebas.
library;

import 'package:flutter/foundation.dart';

const bool kLiveDebug = kDebugMode;

void liveLog(String message) {
  if (kLiveDebug) debugPrint(message);
}
