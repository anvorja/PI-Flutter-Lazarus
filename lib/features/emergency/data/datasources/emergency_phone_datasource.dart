/// SMS y llamadas por el canal nativo `lazarus/emergency` (`MainActivity.kt`).
///
/// El SMS se envía con `SmsManager` (sin abrir la app de mensajes, porque la
/// persona no ve la pantalla) y el canal responde cuando el sistema confirma el
/// envío de todas las partes del mensaje.
library;

import 'package:flutter/services.dart';

const _channel = MethodChannel('lazarus/emergency');

/// `sent`, o `error:<código>` si el sistema o el operador no lo enviaron.
Future<String> sendSms(String phone, String text) async {
  try {
    final result = await _channel.invokeMethod<String>('sendSms', {
      'phone': phone,
      'text': text,
    });
    return result ?? 'error:sin respuesta';
  } on PlatformException catch (e) {
    return 'error:${e.code}';
  } on MissingPluginException {
    return 'error:sin implementación';
  }
}

/// Llamada directa (requiere `CALL_PHONE`; sin él, el lado nativo abre el
/// marcador con el número).
Future<bool> call(String phone) => _invoke('call', phone);

/// Abre el marcador con el número, sin llamar.
Future<bool> dial(String number) => _invoke('dial', number);

Future<bool> _invoke(String method, String phone) async {
  try {
    return await _channel.invokeMethod<bool>(method, {'phone': phone}) ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}
