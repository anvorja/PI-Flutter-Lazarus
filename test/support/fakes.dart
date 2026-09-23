/// Dobles de prueba de los contratos de `domain` (sin red, audio ni cámara).
library;

import 'package:app/features/live/domain/entities/live_message.dart';
import 'package:app/features/live/domain/repositories/live_session_repository.dart';
import 'package:app/features/live/domain/repositories/media_repository.dart';

class FakeLiveSessionRepository implements LiveSessionRepository {
  int connectCalls = 0;
  int kickoffs = 0;
  int micResumed = 0;
  final List<String> sentAudio = [];
  void Function(LiveResponse message)? _onResponse;
  void Function()? _onClose;
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
    required void Function(LiveResponse message) onResponse,
    required void Function() onClose,
    required void Function(Object error) onError,
  }) {
    connectCalls++;
    _connected = true;
    _onResponse = onResponse;
    _onClose = onClose;
    _onError = onError;
  }

  /// Simula que Gemini confirmó la sesión.
  void emitSetupComplete() => _onResponse?.call(
    const LiveResponse(type: LiveResponseType.setupComplete),
  );

  /// Simula que el backend no está disponible o se cayó la conexión.
  void emitError([Object error = 'backend no disponible']) {
    _connected = false;
    _onError?.call(error);
  }

  void emitClose() {
    _connected = false;
    _onClose?.call();
  }

  @override
  void disconnect() => _connected = false;

  @override
  void sendAudio(String base64Pcm) => sentAudio.add(base64Pcm);

  @override
  void sendImage(String base64Jpeg, [String mimeType = 'image/jpeg']) {}

  @override
  void sendKickoff() => kickoffs++;

  @override
  void sendVoiceSample() {}

  @override
  void sendMicResumed() => micResumed++;

  @override
  void sendToolResponse(List<({String id, String name})> calls) {}
}

class FakeMediaRepository implements MediaRepository {
  FakeMediaRepository({this.permissionsGranted = true});

  final bool permissionsGranted;
  bool micStarted = false;
  bool cameraStarted = false;

  @override
  Future<bool> requestPermissions() async => permissionsGranted;

  @override
  Future<bool> isHeadsetConnected() async => false;

  @override
  Future<void> startMic(void Function(String base64Pcm) onChunk) async =>
      micStarted = true;

  @override
  Future<void> stopMic() async => micStarted = false;

  @override
  Future<void> startCamera(
    void Function(String base64Jpeg) onFrame, {
    int fps = 1,
  }) async => cameraStarted = true;

  @override
  Future<void> stopCamera() async => cameraStarted = false;

  @override
  Future<void> initPlayer(void Function() onDrained) async {}

  @override
  Future<void> playAudio(String base64Pcm) async {}

  @override
  void interruptPlayback() {}

  @override
  Future<void> destroyPlayer() async {}
}
