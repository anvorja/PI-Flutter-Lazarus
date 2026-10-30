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
import '../../../../core/debug/live_debug.dart';
import '../datasources/gemini_live_datasource.dart';
import '../datasources/live_token_datasource.dart';
import '../datasources/network_info_datasource.dart';

typedef LiveTokenRequester =
    Future<LiveTokenResult?> Function(
      Map<String, Object?> start,
      String? deviceToken,
    );
typedef LiveSessionEndReporter =
    Future<void> Function(int sessionId, int? closeCode, String? deviceToken);

/// Tras una conexión directa fallida, la app usa el proxy un rato antes de
/// volver a intentarla: así no se suma la espera del intento en cada sesión.
const Duration directRetryAfter = Duration(minutes: 10);

class LiveSessionRepositoryImpl implements LiveSessionRepository {
  LiveSessionRepositoryImpl({
    LiveTokenRequester? requestToken,
    LiveSessionEndReporter? reportEnd,
    GeminiLiveClient Function(GeminiLiveClientOptions options)? clientFactory,
    DateTime Function()? clock,
  }) : _requestToken = requestToken ?? requestLiveToken,
       _reportEnd = reportEnd ?? reportLiveSessionEnd,
       _newClient = clientFactory ?? GeminiLiveClient.new,
       _clock = clock ?? DateTime.now;

  final LiveTokenRequester _requestToken;
  final LiveSessionEndReporter _reportEnd;
  final GeminiLiveClient Function(GeminiLiveClientOptions options) _newClient;
  final DateTime Function() _clock;

  GeminiLiveClient? _client;

  /// Cada `connect` y `disconnect` cambia el intento: un token que llega
  /// después de Detener no abre ninguna sesión.
  int _attempt = 0;
  bool _opening = false;
  DateTime? _directBlockedUntil;

  /// Sesión directa en curso, para informar su fin al backend.
  int? _directSessionId;
  String? _directDeviceToken;

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
    if (_client != null || _opening) return; // ya hay una sesión en curso
    final attempt = ++_attempt;
    _opening = true;

    GeminiLiveClient open({LiveTokenGranted? direct}) {
      late final GeminiLiveClient client;
      void forget() {
        // Solo olvida el cliente si sigue siendo el actual (no uno más nuevo).
        if (identical(_client, client)) _client = null;
      }

      // Una conexión directa que falla antes de abrir cae al proxy (HU-031,
      // regla 4) sin que la persona note más que la espera.
      bool fellBack() {
        if (direct == null || client.receivedAny || attempt != _attempt) {
          return false;
        }
        liveLog('[Lazarus] conexión directa fallida: se usa el proxy');
        _directBlockedUntil = _clock().add(directRetryAfter);
        _endDirect(4002);
        forget();
        _client = open();
        _client!.connect();
        return true;
      }

      client = _newClient(
        GeminiLiveClientOptions(
          url: direct?.socketUrl ?? liveWsUrl,
          directModel: direct?.model,
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
            if (fellBack()) return;
            forget();
            if (direct != null) _endDirect(code);
            onClose(liveCloseCauseFromCode(code));
          },
          onError: (error) {
            if (fellBack()) return;
            forget();
            if (direct != null) _endDirect(4002);
            onError(error);
          },
        ),
      );
      return client;
    }

    Future<void> run() async {
      LiveTokenResult? token;
      final blocked = _directBlockedUntil;
      final askToken = blocked == null || _clock().isAfter(blocked);
      if (!askToken) {
        liveLog('[Lazarus] conexión por el proxy (directa en espera)');
      }
      if (askToken) {
        Map<String, String>? network;
        try {
          network = await readNetworkInfo();
        } on Object {
          network = null;
        }
        token = await _requestToken({
          'language': language,
          'voice': ?voice,
          'assistantName': ?assistantName,
          if (userName != null && userName.isNotEmpty) 'userName': userName,
          'verbosity': ?verbosity,
          'describing': describing ?? true,
          'camera': camera,
          'screenLocked': screenLocked,
          'screenReader': screenReader,
          if (network != null && network.isNotEmpty) 'network': network,
        }, deviceToken);
      }
      if (attempt != _attempt) return; // Detener mientras llegaba el token
      _opening = false;
      switch (token) {
        case LiveTokenRefused(:final code):
          liveLog('[Lazarus] token rechazado por el backend ($code)');
          onClose(liveCloseCauseFromCode(code));
          return;
        case LiveTokenGranted():
          liveLog('[Lazarus] sesión directa con Gemini (token efímero)');
          _directSessionId = token.sessionId;
          _directDeviceToken = deviceToken;
          _client = open(direct: token);
        case null:
          // Sin conexión directa en el backend (o sin respuesta): el proxy, y no
          // se vuelve a preguntar en un rato para no sumar la espera. La espera
          // cuenta desde la última pregunta, no desde cada sesión.
          if (askToken) {
            liveLog(
              '[Lazarus] conexión directa no disponible: se usa el proxy',
            );
            _directBlockedUntil = _clock().add(directRetryAfter);
          }
          _client = open();
      }
      _client!.connect();
    }

    run();
  }

  /// Informa una sola vez el fin de la sesión directa (HU-031).
  void _endDirect(int? code) {
    final id = _directSessionId;
    _directSessionId = null;
    if (id == null) return;
    _reportEnd(id, code, _directDeviceToken);
  }

  @override
  void disconnect() {
    _attempt++;
    _opening = false;
    _client?.disconnect();
    _client = null;
    _endDirect(null);
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
