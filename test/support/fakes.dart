/// Dobles de prueba de los contratos de `domain` (sin red, audio ni cámara).
library;

import 'dart:async';

import 'package:app/features/access/domain/repositories/device_access_repository.dart';
import 'package:app/features/emergency/domain/entities/emergency_contact.dart';
import 'package:app/features/emergency/domain/repositories/emergency_repository.dart';
import 'package:app/features/live/domain/entities/live_close.dart';
import 'package:app/features/live/domain/entities/live_message.dart';
import 'package:app/features/live/domain/entities/media_permission.dart';
import 'package:app/features/live/domain/repositories/background_session_repository.dart';
import 'package:app/features/live/domain/repositories/live_session_repository.dart';
import 'package:app/features/live/domain/repositories/media_repository.dart';
import 'package:app/features/live/domain/repositories/network_status_repository.dart';
import 'package:app/features/field_notes/domain/entities/field_note.dart';
import 'package:app/features/field_notes/domain/repositories/note_recorder.dart';
import 'package:app/features/location/domain/entities/heading.dart';
import 'package:app/features/location/domain/entities/location_fix.dart';
import 'package:app/features/location/domain/repositories/compass_repository.dart';
import 'package:app/features/location/domain/repositories/location_repository.dart';
import 'package:app/features/location/domain/repositories/track_recorder.dart';

class FakeLiveSessionRepository implements LiveSessionRepository {
  /// Lo que responde el backend en `/api/v1/live/status`.
  LiveCloseCause? failureCause;

  @override
  Future<LiveCloseCause?> lastFailureCause({String? deviceToken}) async {
    lastStatusToken = deviceToken;
    return failureCause;
  }

  /// Token con el que la app preguntó la causa del cierre.
  String? lastStatusToken;

  int connectCalls = 0;
  bool? lastCamera;
  bool? lastScreenLocked;
  bool? lastScreenReader;
  String? lastDeviceToken;
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
    bool screenLocked = false,
    bool screenReader = false,
    String? deviceToken,
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
    lastScreenLocked = screenLocked;
    lastScreenReader = screenReader;
    lastDeviceToken = deviceToken;
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

  final List<String> routeNotices = [];

  @override
  void sendRouteNotice(String notice) => routeNotices.add(notice);

  final List<String> routeGuides = [];

  @override
  void sendRouteGuide(String message) => routeGuides.add(message);

  /// Primeros mensajes de sesión sin cámara (`false`) y con cámara de vuelta
  /// (`true`), en orden.
  final List<bool> cameraNotices = [];

  @override
  void sendCameraPaused() => cameraNotices.add(false);

  @override
  void sendCameraResumed() => cameraNotices.add(true);

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

  /// Voz de TalkBack simulada (HU-023).
  final StreamController<bool> screenReaderSpeaking =
      StreamController<bool>.broadcast();

  @override
  Stream<bool> screenReaderSpeech() => screenReaderSpeaking.stream;

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

/// Bitácora en memoria (HU-024).
class FakeNoteRecorder implements NoteRecorder {
  FakeNoteRecorder({this.enabled = true});

  bool enabled;
  final List<FieldNote> notes = [];

  @override
  Future<bool> add(FieldNote note) async {
    if (enabled) notes.add(note);
    return enabled;
  }
}

/// Brújula falsa: las pruebas empujan lecturas.
class FakeCompassRepository implements CompassRepository {
  final StreamController<CompassReading> events =
      StreamController<CompassReading>.broadcast();

  @override
  Stream<CompassReading> readings() => events.stream;
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

  final List<Heading?> headings = [];

  @override
  void record(LocationFix fix, GpsReliability reliability, [Heading? heading]) {
    if (open) {
      rows.add((accuracyM: fix.accuracyM, reliability: reliability));
      headings.add(heading);
    }
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

/// Servicio en primer plano falso (HU-017): registra arranques y paradas, y
/// permite simular el "Detener" de la notificación.
class FakeBackgroundSession implements BackgroundSessionRepository {
  FakeBackgroundSession({
    this.exempt = true,
    this.manufacturer = 'xiaomi',
    this.startAllowed = true,
  });

  bool exempt;
  String manufacturer;
  bool startAllowed;
  bool running = false;
  int starts = 0;
  int stops = 0;
  int exemptionRequests = 0;

  /// Lo que la persona responde en el diálogo de batería.
  bool grantExemption = true;
  void Function()? _onStop;

  @override
  Future<bool> start() async {
    starts++;
    running = startAllowed;
    return startAllowed;
  }

  @override
  Future<void> stop() async {
    stops++;
    running = false;
  }

  @override
  void onStopRequested(void Function() callback) => _onStop = callback;

  /// Simula que la persona pulsó "Detener" en la notificación.
  void pressStopInNotification() => _onStop?.call();

  @override
  Future<BatteryStatus> batteryStatus() async =>
      (exempt: exempt, manufacturer: manufacturer);

  @override
  Future<bool> requestBatteryExemption() async {
    exemptionRequests++;
    exempt = grantExemption;
    return exempt;
  }
}

/// Red de datos simulada (HU-042): [setOnline] emite el cambio como el sistema.
class FakeNetworkStatus implements NetworkStatusRepository {
  FakeNetworkStatus({this.online = true});

  bool online;
  final StreamController<bool> _changes = StreamController<bool>.broadcast();

  void setOnline(bool value) {
    online = value;
    _changes.add(value);
  }

  @override
  Future<bool> isOnline() async => online;

  @override
  Stream<bool> onlineChanges() => _changes.stream;
}

/// Acceso del teléfono al piloto (HU-044 y HU-045), sin red.
class FakeDeviceAccess implements DeviceAccessRepository {
  FakeDeviceAccess({
    this.deviceToken = 'token-de-prueba',
    this.requested = false,
  });

  String? deviceToken;
  bool requested;
  int uploads = 0;

  @override
  String? get savedToken => deviceToken;

  @override
  Future<String?> token() async => deviceToken;

  @override
  Future<bool> uploadRequested() async => requested;

  /// Si no es `null`, cada subida espera a que se complete (red lenta).
  Completer<void>? slowNetwork;
  int uploadsInFlight = 0;
  int maxUploadsInFlight = 0;

  @override
  Future<int> uploadLogs() async {
    uploads++;
    uploadsInFlight++;
    if (uploadsInFlight > maxUploadsInFlight) {
      maxUploadsInFlight = uploadsInFlight;
    }
    await slowNetwork?.future;
    uploadsInFlight--;
    return 1;
  }

  /// Perfiles de ruta en JSON (HU-022).
  String? routes;

  @override
  Future<String?> routeProfiles() async => routes;
}
