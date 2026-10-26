/// Implementación concreta de [LiveSessionRepository] sobre [GeminiLiveClient].
///
/// Crea un cliente WebSocket nuevo por cada sesión y lo descarta al
/// desconectar. Gracias al contrato abstracto, el controller nunca instancia
/// `GeminiLiveClient` directamente ni conoce el protocolo de frames.
library;

import 'dart:convert';
import 'dart:io';

import '../../../../core/config/app_config.dart';
import '../../domain/entities/live_message.dart';
import '../../domain/entities/live_close.dart';
import '../../domain/repositories/live_session_repository.dart';
import '../datasources/gemini_live_datasource.dart';
import '../datasources/network_info_datasource.dart';

class LiveSessionRepositoryImpl implements LiveSessionRepository {
  GeminiLiveClient? _client;

  @override
  Future<LiveCloseCause?> lastFailureCause({String? deviceToken}) async {
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final request = await http.getUrl(
        Uri.parse('$backendUrl/api/v1/live/status'),
      );
      if (deviceToken != null) {
        request.headers.set('X-Device-Token', deviceToken);
      }
      final response = await request.close().timeout(
        const Duration(seconds: 4),
      );
      if (response.statusCode != 200) return null;
      final body = await response.transform(utf8.decoder).join();
      return switch ((jsonDecode(body) as Map<String, dynamic>)['cause']) {
        'billing' => LiveCloseCause.billingExhausted,
        'quota' => LiveCloseCause.quotaExceeded,
        'paused' => LiveCloseCause.servicePaused,
        'closed_by_admin' => LiveCloseCause.closedByAdmin,
        'device_pending' => LiveCloseCause.devicePending,
        'device_disabled' => LiveCloseCause.deviceDisabled,
        'daily_limit' => LiveCloseCause.dailyLimit,
        _ => null,
      };
    } on Object {
      return null; // sin respuesta: se reintenta como siempre
    } finally {
      http.close(force: true);
    }
  }

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
    bool camera = true,
    bool screenLocked = false,
    bool screenReader = false,
    String? deviceToken,
    required void Function(LiveResponse message) onResponse,
    required void Function(LiveCloseCause cause) onClose,
    required void Function(Object error) onError,
  }) {
    if (_client != null) return; // ya hay una sesión en curso
    late final GeminiLiveClient client;
    client = GeminiLiveClient(
      GeminiLiveClientOptions(
        url: liveWsUrl,
        language: language,
        voice: voice,
        assistantName: assistantName,
        userName: userName,
        verbosity: verbosity,
        describing: describing,
        camera: camera,
        screenLocked: screenLocked,
        screenReader: screenReader,
        deviceToken: deviceToken,
        networkInfo: readNetworkInfo,
        onResponse: onResponse,
        onClose: (code) {
          // Solo olvida el cliente si sigue siendo el actual (no uno más nuevo).
          if (identical(_client, client)) _client = null;
          onClose(liveCloseCauseFromCode(code));
        },
        onError: (error) {
          if (identical(_client, client)) _client = null;
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
  void sendLanguageChanged() => _client?.sendLanguageChanged();

  @override
  void sendMicResumed() => _client?.sendMicResumed();

  @override
  void sendSosResult(String result) => _client?.sendSosResult(result);

  @override
  void sendRouteNotice(String notice) => _client?.sendRouteNotice(notice);

  @override
  void sendRouteGuide(String message) => _client?.sendRouteGuide(message);

  @override
  void sendCameraPaused() => _client?.sendCameraPaused();

  @override
  void sendCameraResumed() => _client?.sendCameraResumed();

  @override
  void sendObserve({bool risksOnly = false}) =>
      _client?.sendObserve(risksOnly: risksOnly);

  @override
  void sendToolResponse(
    List<({String id, String name, String result})> calls,
  ) => _client?.sendToolResponse(calls);
}
