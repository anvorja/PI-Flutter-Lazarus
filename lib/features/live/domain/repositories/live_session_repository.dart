/// Contrato de la sesión Live con el asistente (Gemini vía proxy del backend).
///
/// No expone nada sobre WebSockets, JSON ni el protocolo de frames: eso vive en
/// el data source concreto (`GeminiLiveClient`). El controller solo conoce esta
/// API, lo que permite sustituir el transporte (o usar un fake en tests) sin
/// tocar la lógica de orquestación ni la UI.
library;

import '../entities/live_message.dart';

abstract class LiveSessionRepository {
  /// `true` mientras hay una sesión abierta con el backend.
  bool get connected;

  /// Abre la sesión. Si ya hay una en curso, no hace nada (evita duplicados).
  void connect({
    required String language,
    String? voice,
    String? assistantName,
    String? userName,
    String? verbosity,
    bool? describing,
    required void Function(LiveResponse message) onResponse,
    required void Function() onClose,
    required void Function(Object error) onError,
  });

  void disconnect();

  /// Chunk de audio del micrófono (PCM 16-bit 16 kHz, base64).
  void sendAudio(String base64Pcm);

  /// Frame de cámara (JPEG base64).
  void sendImage(String base64Jpeg, [String mimeType]);

  /// Dispara el saludo inicial una vez establecida la sesión.
  void sendKickoff();

  /// Tras un cambio de voz: pide una muestra breve de la nueva voz.
  void sendVoiceSample();

  /// Tras reactivar el micrófono (salir de silencio total): pide confirmación.
  void sendMicResumed();

  /// Responde a las funciones que pidió el asistente (toolCall).
  void sendToolResponse(List<({String id, String name})> calls);
}
