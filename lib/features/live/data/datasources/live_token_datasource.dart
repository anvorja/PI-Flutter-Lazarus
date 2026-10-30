/// Token efímero de Gemini Live (HU-031): el backend aplica las reglas del
/// piloto y entrega un token de un solo uso con el prompt fijado; la app abre
/// la sesión directo con Gemini y el audio y la cámara no pasan por el backend.
library;

import 'dart:convert';
import 'dart:io';

import '../../../../core/config/app_config.dart';

sealed class LiveTokenResult {
  const LiveTokenResult();
}

/// Token emitido: URL de Gemini, modelo y el registro de la sesión.
class LiveTokenGranted extends LiveTokenResult {
  const LiveTokenGranted({
    required this.token,
    required this.url,
    required this.model,
    this.sessionId,
  });

  final String token;
  final String url;
  final String model;
  final int? sessionId;

  /// URL del WebSocket con el token (nunca la API key).
  String get socketUrl =>
      '$url?access_token=${Uri.encodeQueryComponent(token)}';
}

/// El backend rechazó la sesión con el mismo código de cierre del proxy
/// (servicio en pausa, teléfono pendiente o deshabilitado, minutos agotados).
class LiveTokenRefused extends LiveTokenResult {
  const LiveTokenRefused(this.code);
  final int code;
}

const _timeout = Duration(seconds: 5);

/// Pide el token. `null` = usar el proxy: el backend no tiene activa la
/// conexión directa (404), no pudo emitirlo (502) o no respondió.
Future<LiveTokenResult?> requestLiveToken(
  Map<String, Object?> start,
  String? deviceToken,
) async {
  final http = HttpClient()..connectionTimeout = _timeout;
  try {
    final request = await http.postUrl(
      Uri.parse('$backendUrl/api/v1/live/token'),
    );
    request.headers.contentType = ContentType.json;
    if (deviceToken != null) request.headers.set('X-Device-Token', deviceToken);
    request.write(jsonEncode(start));
    final response = await request.close().timeout(_timeout);
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode == 403) {
      final code = (jsonDecode(body) as Map<String, dynamic>)['code'];
      return code is int ? LiveTokenRefused(code) : null;
    }
    if (response.statusCode != 200) return null;
    final json = jsonDecode(body) as Map<String, dynamic>;
    return LiveTokenGranted(
      token: json['token'] as String,
      url: json['url'] as String,
      model: json['model'] as String,
      sessionId: json['session_id'] as int?,
    );
  } on Object {
    return null;
  } finally {
    http.close(force: true);
  }
}

/// Informa el fin de una sesión directa, para contar sus minutos.
Future<void> reportLiveSessionEnd(
  int sessionId,
  int? closeCode,
  String? deviceToken,
) async {
  final http = HttpClient()..connectionTimeout = _timeout;
  try {
    final request = await http.postUrl(
      Uri.parse('$backendUrl/api/v1/live/sessions/$sessionId/end'),
    );
    request.headers.contentType = ContentType.json;
    if (deviceToken != null) request.headers.set('X-Device-Token', deviceToken);
    request.write(jsonEncode({'closeCode': closeCode}));
    await (await request.close().timeout(_timeout)).drain<void>();
  } on Object {
    // Si no llega, el backend la cierra al pedir el siguiente token.
  } finally {
    http.close(force: true);
  }
}
