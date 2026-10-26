/// Operador y tipo de red del teléfono (canal nativo `lazarus/session`).
///
/// Va en el frame `start` para que el panel compare la latencia entre SIM
/// (p. ej. Movistar y Claro) y entre datos móviles y Wi-Fi. No incluye el
/// nombre de la red Wi-Fi ni datos de la persona.
library;

import 'package:flutter/services.dart';

const _channel = MethodChannel('lazarus/session');
const _transports = {'wifi', 'cellular', 'other', 'none'};

/// `{operator?, transport?}` o `null` si el teléfono no lo informa.
Future<Map<String, String>?> readNetworkInfo() async {
  try {
    final info = await _channel
        .invokeMapMethod<String, Object?>('networkInfo')
        .timeout(const Duration(seconds: 1));
    if (info == null) return null;
    final operator = '${info['operator'] ?? ''}'.trim();
    final transport = '${info['transport'] ?? ''}';
    return {
      if (operator.isNotEmpty)
        'operator': operator.length > 40 ? operator.substring(0, 40) : operator,
      if (_transports.contains(transport)) 'transport': transport,
    };
  } on Object {
    return null; // sin canal nativo (pruebas, web) o sin respuesta
  }
}
