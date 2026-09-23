import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:app/features/live/data/datasources/gemini_live_datasource.dart';

void main() {
  test('backend caído: el error de conexión se informa una sola vez', () async {
    // Servidor que corta la conexión antes de responder (como un backend detenido
    // detrás de un túnel): "Connection closed before full header was received".
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) => socket.destroy());
    addTearDown(server.close);

    final errors = <Object>[];
    final closes = <int?>[];
    GeminiLiveClient(
      GeminiLiveClientOptions(
        url: 'ws://127.0.0.1:${server.port}/ws/live',
        language: 'es',
        onError: errors.add,
        onClose: closes.add,
      ),
    ).connect();

    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(errors, hasLength(1));
    expect(closes, isEmpty);
  });
}
