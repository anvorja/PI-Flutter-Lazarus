/// Dobles de prueba de los contratos de `domain` (sin red, audio ni cámara).
library;

import 'dart:async';

import 'package:app/features/emergency/domain/entities/emergency_contact.dart';
import 'package:app/features/emergency/domain/repositories/emergency_repository.dart';
import 'package:app/features/live/domain/entities/live_close.dart';
import 'package:app/features/live/domain/entities/live_message.dart';
import 'package:app/features/live/domain/entities/media_permission.dart';
import 'package:app/features/live/domain/repositories/live_session_repository.dart';
import 'package:app/features/live/domain/repositories/media_repository.dart';
import 'package:app/features/location/domain/entities/location_fix.dart';
import 'package:app/features/location/domain/repositories/location_repository.dart';
import 'package:app/features/location/domain/repositories/track_recorder.dart';

class FakeLiveSessionRepository implements LiveSessionRepository {
  int connectCalls = 0;
  bool? lastCamera;
  final List<String> sentImages = [];
  int kickoffs = 0;
  int micResumed = 0;
  int voiceSamples = 0;
  int languageChanges = 0;
  String? lastVoice;
  String? lastLanguage;
  String? lastAssistantName;
  String? lastUserName;
  String? lastVerbosity;
  bool? lastDescribing;
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
    lastVoice = voice;
    lastLanguage = language;
    lastAssistantName = assistantName;
    lastUserName = userName;
    lastVerbosity = verbosity;
    lastDescribing = describing;
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
  void sendVoiceSample() => voiceSamples++;

  @override
  void sendLanguageChanged() => languageChanges++;

  @override
  void sendMicResumed() => micResumed++;

  final List<String> sosResults = [];

  @override
  void sendSosResult(String result) => sosResults.add(result);

  int observes = 0;
  final List<bool> observeRisksOnly = [];

  @override
  void sendObserve({bool risksOnly = false}) {
    observes++;
    observeRisksOnly.add(risksOnly);
  }

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

  final List<String> played = [];

  @override
  Future<void> playAudio(String base64Pcm) async => played.add(base64Pcm);

  @override
  Future<void> interruptPlayback() async => interruptions++;

  @override
  Future<void> destroyPlayer() async {}
}

/// GPS falso: el test decide el permiso, emite posiciones y fija la dirección.
class FakeLocationRepository implements LocationRepository {
  FakeLocationRepository({
    this.permission = LocationPermissionStatus.granted,
    this.address,
  });

  LocationPermissionStatus permission;
  String? address;
  final StreamController<LocationFix> fixes =
      StreamController<LocationFix>.broadcast();
  int permissionRequests = 0;

  @override
  Future<LocationPermissionStatus> requestPermission() async {
    permissionRequests++;
    return permission;
  }

  @override
  Stream<LocationFix> positions() => fixes.stream;

  @override
  Future<String?> addressOf(LocationFix fix) async => address;
}

/// Grabador de recorrido en memoria.
class FakeTrackRecorder implements TrackRecorder {
  int segments = 0;
  bool open = false;
  final List<({double accuracyM, GpsReliability reliability})> rows = [];

  @override
  Future<void> begin() async {
    segments++;
    open = true;
  }

  @override
  void record(LocationFix fix, GpsReliability reliability) {
    if (open) rows.add((accuracyM: fix.accuracyM, reliability: reliability));
  }

  @override
  Future<void> end() async => open = false;
}

/// Alerta SOS falsa: guarda el contacto en memoria y registra SMS y llamadas.
class FakeEmergencyRepository implements EmergencyRepository {
  FakeEmergencyRepository({this.contact});

  EmergencyContact? contact;
  bool smsPermission = true;
  SmsResult smsResult = SmsResult.sent;
  int permissionRequests = 0;
  final List<({String phone, String text})> sms = [];
  final List<String> calls = [];
  final List<String> dials = [];

  @override
  EmergencyContact? getContact() => contact;

  @override
  Future<void> setContact(EmergencyContact contact) async =>
      this.contact = contact;

  @override
  Future<bool> requestPermissions() async {
    permissionRequests++;
    return smsPermission;
  }

  @override
  Future<SmsResult> sendSms(String phone, String text) async {
    sms.add((phone: phone, text: text));
    return smsResult;
  }

  @override
  Future<bool> call(String phone) async {
    calls.add(phone);
    return true;
  }

  @override
  Future<bool> dial(String number) async {
    dials.add(number);
    return true;
  }
}
