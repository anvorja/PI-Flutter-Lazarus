/// Implementación concreta de [LiveSessionRepository] sobre [GeminiLiveClient].
///
/// Crea un cliente WebSocket nuevo por cada sesión y lo descarta al
/// desconectar. Gracias al contrato abstracto, el controller nunca instancia
/// `GeminiLiveClient` directamente ni conoce el protocolo de frames.
library;

import '../../../../core/config/app_config.dart';
import '../../domain/entities/live_message.dart';
import '../../domain/repositories/live_session_repository.dart';
import '../datasources/gemini_live_datasource.dart';

class LiveSessionRepositoryImpl implements LiveSessionRepository {
  GeminiLiveClient? _client;

  @override
  bool get connected => _client?.connected ?? false;

  @override
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
  }) {
    if (_client != null) return; // ya hay una sesión en curso
    final client = GeminiLiveClient(
      GeminiLiveClientOptions(
        url: liveWsUrl,
        language: language,
        voice: voice,
        assistantName: assistantName,
        userName: userName,
        verbosity: verbosity,
        describing: describing,
        onResponse: onResponse,
        onClose: () {
          _client = null;
          onClose();
        },
        onError: (error) {
          _client = null;
          onError(error);
        },
      ),
    );
    _client = client;
    client.connect();
  }

  @override
  void disconnect() {
    _client?.disconnect();
    _client = null;
  }

  @override
  void sendAudio(String base64Pcm) => _client?.sendAudio(base64Pcm);

  @override
  void sendImage(String base64Jpeg, [String mimeType = 'image/jpeg']) =>
      _client?.sendImage(base64Jpeg, mimeType);

  @override
  void sendKickoff() => _client?.sendKickoff();

  @override
  void sendVoiceSample() => _client?.sendVoiceSample();

  @override
  void sendMicResumed() => _client?.sendMicResumed();

  @override
  void sendToolResponse(List<({String id, String name})> calls) =>
      _client?.sendToolResponse(calls);
}
