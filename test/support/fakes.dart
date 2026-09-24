/// Dobles de prueba de los contratos de `domain` (sin red, audio ni cámara).
library;

import 'package:app/features/live/domain/entities/live_close.dart';
import 'package:app/features/live/domain/entities/live_message.dart';
import 'package:app/features/live/domain/entities/media_permission.dart';
import 'package:app/features/live/domain/repositories/live_session_repository.dart';
import 'package:app/features/live/domain/repositories/media_repository.dart';

class FakeLiveSessionRepository implements LiveSessionRepository {
  int connectCalls = 0;
  bool? lastCamera;
  final List<String> sentImages = [];
  int kickoffs = 0;
  int micResumed = 0;
  final List<String> sentAudio = [];
  void Function(LiveResponse message)? _onResponse;
  void Function(LiveCloseCause cause)? _onClose;
  void Function(Object error)? _onError;
  bool _connected = false;

  @override
  bool get connected => _connected;

  @override
  void connect({
    required String language,
    String? voice,
    String? assistantName,
    String? userName,
    String? verbosity,
    bool? describing,
    bool camera = true,
    required void Function(LiveResponse message) onResponse,
    required void Function(LiveCloseCause cause) onClose,
    required void Function(Object error) onError,
  }) {
    connectCalls++;
    lastCamera = camera;
    _connected = true;
    _onResponse = onResponse;
    _onClose = onClose;
    _onError = onError;
  }

  /// Simula que Gemini confirmó la sesión.
  void emitSetupComplete() => _onResponse?.call(
    const LiveResponse(type: LiveResponseType.setupComplete),
  );

  /// Simula cualquier respuesta de Gemini (p. ej. un toolCall).
  void emitResponse(LiveResponse response) => _onResponse?.call(response);

  /// Simula que el backend no está disponible o se cayó la conexión.
  void emitError([Object error = 'backend no disponible']) {
    _connected = false;
    _onError?.call(error);
  }

  /// Simula que el backend cerró la sesión con una causa.
  void emitClose(LiveCloseCause cause) {
    _connected = false;
    _onClose?.call(cause);
  }

  @override
  void disconnect() => _connected = false;

  @override
  void sendAudio(String base64Pcm) => sentAudio.add(base64Pcm);

  @override
  void sendImage(String base64Jpeg, [String mimeType = 'image/jpeg']) =>
      sentImages.add(base64Jpeg);

  @override
  void sendKickoff() => kickoffs++;

  @override
  void sendVoiceSample() {}

  @override
  void sendMicResumed() => micResumed++;

  final List<({String id, String name, String result})> toolResponses = [];

  @override
  void sendToolResponse(
    List<({String id, String name, String result})> calls,
  ) => toolResponses.addAll(calls);
}

class FakeMediaRepository implements MediaRepository {
  FakeMediaRepository({
    this.permission = MediaPermission.granted,
    this.cameraGranted = true,
    this.headset = false,
  });

  MediaPermission permission;
  bool cameraGranted;
  bool headset;
  void Function(String base64Pcm)? onMicChunk;
  void Function()? onDrained;
  void Function(String base64Jpeg)? onFrame;
  int settingsOpened = 0;
  int interruptions = 0;
  bool micStarted = false;
  bool cameraStarted = false;

  @override
  Future<MediaAccess> requestPermissions() async =>
      (microphone: permission, camera: cameraGranted);

  @override
  Future<void> openPermissionSettings() async => settingsOpened++;

  @override
  Future<bool> isHeadsetConnected() async => headset;

  @override
  Future<void> startMic(void Function(String base64Pcm) onChunk) async {
    micStarted = true;
    onMicChunk = onChunk;
  }

  @override
  Future<void> stopMic() async => micStarted = false;

  @override
  Future<void> startCamera(
    void Function(String base64Jpeg) onFrame, {
    int fps = 1,
  }) async {
    cameraStarted = true;
    this.onFrame = onFrame;
  }

  @override
  Future<void> stopCamera() async => cameraStarted = false;

  @override
  Future<void> initPlayer(void Function() onDrained) async =>
      this.onDrained = onDrained;

  @override
  Future<void> playAudio(String base64Pcm) async {}

  @override
  Future<void> interruptPlayback() async => interruptions++;

  @override
  Future<void> destroyPlayer() async {}
}
