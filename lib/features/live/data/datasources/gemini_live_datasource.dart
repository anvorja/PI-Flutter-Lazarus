/// Cliente de la Gemini Live API a través del proxy WebSocket del backend.
///
/// Conecta al
/// backend (`/ws/live`), NO a Gemini directo: la API key vive server-side y el
/// dispositivo nunca la ve (ADR-0003). El primer frame es
/// `{type:"start", language, ...}`; el backend arma el `setup` con el system
/// prompt server-side. El resto (audio/imagen/texto) viaja como `realtime_input`
/// / `client_content`.
library;

import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import '../../domain/entities/live_message.dart';

/// Sentinela que dispara el saludo de arranque (lo interpreta el system prompt).
const String kickoffTrigger = '[INICIO]';

/// Sentinela tras un cambio de voz: el asistente da una muestra corta, sin
/// repetir la presentación completa (lo interpreta el system prompt).
const String voiceSampleTrigger = '[VOZ]';

/// Sentinela tras reactivar el micrófono (al salir de silencio total): el
/// asistente da una confirmación muy corta (lo interpreta el system prompt).
const String micOnTrigger = '[MIC_ON]';

/// Opciones de conexión del cliente Live.
class GeminiLiveClientOptions {
  const GeminiLiveClientOptions({
    required this.url,
    required this.language,
    this.voice,
    this.assistantName,
    this.userName,
    this.verbosity,
    this.describing,
    this.onResponse,
    this.onOpen,
    this.onClose,
    this.onError,
  });

  /// URL del proxy del backend, ej. `ws://localhost:8000/ws/live`.
  final String url;
  final String language;
  final String? voice;

  /// Nombre con el que se identifica el asistente (persona elegida por el usuario).
  final String? assistantName;

  /// Nombre de la persona usuaria (para que la salude por su nombre).
  final String? userName;

  /// Nivel de detalle de las descripciones (`concise` | `detailed`).
  final String? verbosity;

  /// Si Gemini describe el entorno por su cuenta (false = solo preguntas/alertas).
  final bool? describing;

  final void Function(LiveResponse message)? onResponse;
  final void Function()? onOpen;

  /// Cierre no pedido por la app, con el código de cierre del backend.
  final void Function(int? closeCode)? onClose;
  final void Function(Object error)? onError;
}

class GeminiLiveClient {
  GeminiLiveClient(this._opts);

  final GeminiLiveClientOptions _opts;
  WebSocketChannel? _channel;
  bool connected = false;
  bool _closedByApp = false;

  /// Ya se informó el fin de la conexión (error o cierre). Un fallo al conectar
  /// llega por el stream y por `ready`; se informa una sola vez.
  bool _ended = false;

  void _reportError(Object error) {
    connected = false;
    if (_ended) return;
    _ended = true;
    _opts.onError?.call(error);
  }

  void connect() {
    final channel = WebSocketChannel.connect(Uri.parse(_opts.url));
    _channel = channel;

    channel.stream.listen(
      (event) {
        // Primer mensaje recibido implica que el socket está abierto.
        if (!connected) {
          connected = true;
          _sendStart();
          _opts.onOpen?.call();
        }
        _onMessage(event);
      },
      onError: _reportError,
      onDone: () {
        connected = false;
        // Si la app cerró la sesión (Detener, cambio de voz…) no es un corte.
        if (_closedByApp || _ended) return;
        _ended = true;
        _opts.onClose?.call(channel.closeCode);
      },
      cancelOnError: true,
    );

    // En WebSocketChannel no hay callback onOpen explícito; el ready se confirma
    // al poder enviar. Enviamos el frame `start` apenas el sink esté listo.
    channel.ready
        .then((_) {
          if (!connected) {
            connected = true;
            _sendStart();
            _opts.onOpen?.call();
          }
        })
        .catchError((Object error) {
          _reportError(error);
        });
  }

  void disconnect() {
    _closedByApp = true;
    _channel?.sink.close(ws_status.normalClosure);
    _channel = null;
    connected = false;
  }

  void _sendStart() {
    _send({
      'type': 'start',
      'language': _opts.language,
      if (_opts.voice != null) 'voice': _opts.voice,
      if (_opts.assistantName != null) 'assistantName': _opts.assistantName,
      if (_opts.userName != null && _opts.userName!.isNotEmpty)
        'userName': _opts.userName,
      if (_opts.verbosity != null) 'verbosity': _opts.verbosity,
      if (_opts.describing == false) 'describing': false,
    });
  }

  void _onMessage(dynamic event) {
    try {
      final text = event is List<int> ? utf8.decode(event) : event as String;
      final raw = jsonDecode(text) as Map<String, dynamic>;
      _opts.onResponse?.call(parseLiveMessage(raw));
    } catch (_) {
      // Mensaje no parseable: se ignora.
    }
  }

  void _send(Object message) {
    final channel = _channel;
    if (channel != null) {
      channel.sink.add(jsonEncode(message));
    }
  }

  /// Chunk de audio del micrófono (PCM 16-bit 16 kHz, base64).
  void sendAudio(String base64Pcm) =>
      _sendRealtimeInput(base64Pcm, 'audio/pcm');

  /// Frame de cámara (JPEG base64).
  void sendImage(String base64Jpeg, [String mimeType = 'image/jpeg']) =>
      _sendRealtimeInput(base64Jpeg, mimeType);

  /// Pregunta del usuario por texto (cierra turno).
  void sendText(String text) {
    _send({
      'client_content': {
        'turns': [
          {
            'role': 'user',
            'parts': [
              {'text': text},
            ],
          },
        ],
        'turn_complete': true,
      },
    });
  }

  /// Dispara el saludo inicial una vez establecida la sesión (setupComplete).
  void sendKickoff() => sendText(kickoffTrigger);

  /// Tras un cambio de voz: pide una muestra breve de la nueva voz.
  void sendVoiceSample() => sendText(voiceSampleTrigger);

  /// Tras reactivar el micrófono (salir de silencio total): pide confirmación.
  void sendMicResumed() => sendText(micOnTrigger);

  /// Responde a las funciones que pidió Gemini (toolCall).
  void sendToolResponse(List<({String id, String name})> calls) {
    _send({
      'tool_response': {
        'function_responses': [
          for (final c in calls)
            {
              'id': c.id,
              'name': c.name,
              'response': {'result': 'ok'},
            },
        ],
      },
    });
  }

  void _sendRealtimeInput(String data, String mimeType) {
    _send({
      'realtime_input': {
        'media_chunks': [
          {'mime_type': mimeType, 'data': data},
        ],
      },
    });
  }
}
