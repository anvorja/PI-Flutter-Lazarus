/// Consulta la ruta de salida de audio (canal nativo `lazarus/audio`).
///
/// Sirve para decidir el modo de captura:
/// - con audífonos → full-duplex (el mic queda siempre abierto, se puede
///   interrumpir al asistente hablando, sin eco porque no suena por altavoz);
/// - sin audífonos (altavoz) → medio-dúplex (se silencia el envío del mic
///   mientras el asistente suena, para que el mic no capte al propio altavoz).
library;

import 'package:flutter/services.dart';

const _channel = MethodChannel('lazarus/audio');

/// `true` si hay audífonos/auriculares de salida (cable, Bluetooth o USB).
/// En plataformas sin implementación nativa devuelve `false` (asume altavoz).
Future<bool> isHeadsetConnected() async {
  try {
    final result = await _channel.invokeMethod<bool>('isHeadsetConnected');
    return result ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}
