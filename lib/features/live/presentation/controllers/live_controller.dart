/// Estado + lógica de la sesión Live (equivalente a `auth_controller.dart` en
/// el manual de arquitectura). Orquesta [LiveSessionRepository] y
/// [MediaRepository]: decide cuándo conectar, cuándo silenciar el mic
/// (anti-eco / silencio total) y cómo reaccionar a cada [LiveResponse]. La UI
/// (`LiveHomePage`) solo observa el [LiveUiState] expuesto y dispara acciones;
/// no conoce WebSockets, audio nativo ni cámara.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/live_close.dart';
import '../../domain/entities/live_message.dart';
import '../../domain/entities/media_permission.dart';
import '../../domain/repositories/background_session_repository.dart';
import '../../domain/repositories/live_session_repository.dart';
import '../../domain/repositories/live_settings_repository.dart';
import '../../domain/repositories/media_repository.dart';
import '../../../emergency/domain/repositories/emergency_repository.dart';
import '../../../emergency/presentation/controllers/sos_controller.dart';
import '../../../emergency/presentation/providers/emergency_providers.dart';
import '../../../location/presentation/providers/location_providers.dart';
import '../providers/live_providers.dart';
import '../../../../core/debug/live_debug.dart';
import '../../../../core/telemetry/session_telemetry.dart';

/// Trazas de diagnóstico `[Lazarus]` (mic, turnos, toolCalls, transcripciones):
/// solo en builds de depuración (HU-015).
void _log(String message) => liveLog(message);

/// Respuesta a `set_language` con un idioma que la app no tiene: el asistente la
/// recibe y le explica a la persona, en el idioma actual, cuáles hay.
const String unsupportedLanguageResult =
    'error: unsupported language. The language was not changed. Tell the person, '
    'in the current language, that it is not available yet and that you can speak '
    'Spanish, English, French, Portuguese or Italian.';

/// Respuesta a `set_voice` con una voz que no existe: no se cambia nada.
const String unsupportedVoiceResult =
    'error: unsupported voice. The voice was not changed. Tell the person, in one '
    'sentence, that it is not available and name the available voices: Charon, '
    'Puck, Kore, Fenrir, Aoede, Leda, Orus and Zephyr.';

/// Respuesta a `set_voice` o `set_language` aplicados: la sesión se reinicia para
/// usarlos y el asistente lo confirma en la sesión nueva (`[VOZ]` / `[IDIOMA]`).
const String restartResult =
    'ok. The session restarts now to apply the change. Say nothing now: you will '
    'confirm it right after the restart.';

/// Modo reunión: cuánto tiempo atrás se busca el nombre del asistente en lo que
/// se oyó para dejarlo responder.
const Duration meetingNameWindow = Duration(seconds: 10);

/// Minúsculas y sin tildes, para comparar nombres en la transcripción.
String normalizeForMatch(String text) {
  const from = 'áàäâéèëêíìïîóòöôúùüûñ';
  const to = 'aaaaeeeeiiiioooouuuun';
  final lower = text.toLowerCase().trim();
  final out = StringBuffer();
  for (final ch in lower.split('')) {
    final i = from.indexOf(ch);
    out.write(i >= 0 ? to[i] : ch);
  }
  return out.toString();
}

/// Si [text] nombra a [name] como palabra completa. Tolera una letra de
/// diferencia en nombres de 4 letras o más, porque la transcripción a veces los
/// escribe mal ("Área" por "Aria"); los nombres cortos deben coincidir exacto
/// para no confundirse con palabras comunes ("Sol" y "sal").
bool mentionsName(String text, String name) {
  final target = normalizeForMatch(name).split(RegExp(r'[^a-z0-9]+')).first;
  if (target.isEmpty) return false;
  final tolerance = target.length >= 4 ? 1 : 0;
  return normalizeForMatch(text)
      .split(RegExp(r'[^a-z0-9]+'))
      .any((word) => _editDistance(word, target) <= tolerance);
}

int _editDistance(String a, String b) {
  if ((a.length - b.length).abs() > 1) return 2; // basta saber que es > 1
  var previous = List<int>.generate(b.length + 1, (j) => j);
  for (var i = 1; i <= a.length; i++) {
    final current = [i, ...List<int>.filled(b.length, 0)];
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      current[j] = [
        previous[j] + 1,
        current[j - 1] + 1,
        previous[j - 1] + cost,
      ].reduce((x, y) => x < y ? x : y);
    }
    previous = current;
  }
  return previous[b.length];
}

/// "Silencio total" en los idiomas de la app (normalizado: sin tildes).
const Set<String> totalSilencePhrases = {
  'silencio total', // es y pt ("silêncio total" sin tildes)
  'total silence',
  'silence total',
  'silenzio totale',
};

/// Si la persona pidió silencio total en [text].
bool asksTotalSilence(String text) {
  final words = normalizeForMatch(
    text,
  ).replaceAll(RegExp(r'[^a-z]+'), ' ').trim();
  return totalSilencePhrases.any(words.contains);
}

/// Pausar o reanudar las descripciones (normalizado). Incluye "escribir": en
/// la prueba de CP-LAZA-107 la transcripción oyó "deja escribir" y "vuelve a
/// escribir", y el asistente respondió "Entendido" sin llamar a la función.
const Set<String> pauseDescriptionPhrases = {
  'deja de describir',
  'deja de escribir',
  'deja escribir',
  'no describas',
  'para de describir',
  'stop describing',
};
const Set<String> resumeDescriptionPhrases = {
  'vuelve a describir',
  'vuelve a escribir',
  'sigue describiendo',
  'describe de nuevo',
  'resume describing',
  'start describing again',
};

/// `true` si [text] pide pausar las descripciones, `false` si pide
/// reanudarlas y `null` si no pide ninguna de las dos.
bool? asksDescriptions(String text) {
  final words = normalizeForMatch(
    text,
  ).replaceAll(RegExp(r'[^a-z]+'), ' ').trim();
  if (resumeDescriptionPhrases.any(words.contains)) return true;
  if (pauseDescriptionPhrases.any(words.contains)) return false;
  return null;
}

/// Reintentos automáticos cuando no se puede conectar con el backend.
const int maxConnectionRetries = 3;

/// Avisos hablados cuando el asistente no puede hablar (sin conexión, sin cuota…).
enum LiveNotice {
  retrying,
  connectionFailed,
  sessionPaused,
  quotaExceeded,
  serverMisconfigured,
  billingExhausted,
  permissionDenied,
  permissionBlocked,
  stopped,

  /// Alerta SOS enviada sola con la sesión ya cerrada (no hay asistente que lo
  /// diga).
  sosSent,
  sosFailed,

  /// Primera sesión (HU-017): pide quitar la optimización de batería para que
  /// la sesión siga con la pantalla bloqueada; la variante Xiaomi agrega el
  /// ajuste del fabricante.
  batteryExemption,
  batteryExemptionXiaomi,
}

/// Avisos informativos que la persona puede silenciar por voz (`set_system_cues`).
/// Los demás explican cómo recuperarse de un error y suenan siempre.
const Set<LiveNotice> mutableNotices = {
  LiveNotice.retrying,
  LiveNotice.stopped,
};

const Map<String, Map<LiveNotice, String>> _notices = {
  'es': {
    LiveNotice.retrying: 'Perdí la conexión con el servidor. Reintentando.',
    LiveNotice.connectionFailed:
        'No se pudo conectar con el servidor. Toca la pantalla para reintentar.',
    LiveNotice.sessionPaused:
        'La sesión con el asistente terminó. Toca la pantalla para continuar.',
    LiveNotice.quotaExceeded:
        'El servicio del asistente no está disponible por ahora. Intenta más tarde.',
    LiveNotice.serverMisconfigured:
        'El servidor del asistente no está configurado. Avisa al equipo de soporte.',
    LiveNotice.billingExhausted:
        'El servicio del asistente se quedó sin saldo. Pide a quien administra Lazarus que lo recargue.',
    LiveNotice.permissionDenied:
        'Necesito permiso de micrófono para acompañarte. Toca la pantalla para intentarlo de nuevo.',
    LiveNotice.permissionBlocked:
        'El permiso de micrófono está desactivado. Toca la pantalla para abrir los ajustes y activarlo.',
    LiveNotice.stopped: 'Asistente detenido.',
    LiveNotice.sosSent:
        'Alerta enviada a tu contacto de emergencia. Detente en un lugar seguro y espera.',
    LiveNotice.sosFailed:
        'No se pudo enviar la alerta. Pide ayuda a alguien cerca o llama al 123.',
    LiveNotice.batteryExemption:
        'Antes de empezar: para que siga contigo con la pantalla bloqueada, permite que Lazarus funcione sin restricciones de batería. Luego toca la pantalla para empezar.',
    LiveNotice.batteryExemptionXiaomi:
        'Antes de empezar: para que siga contigo con la pantalla bloqueada, permite que Lazarus funcione sin restricciones de batería. En los teléfonos Xiaomi, además, en Ajustes, Aplicaciones, Lazarus, Ahorro de batería, elige Sin restricciones. Luego toca la pantalla para empezar.',
  },
  'en': {
    LiveNotice.retrying: 'I lost the connection to the server. Retrying.',
    LiveNotice.connectionFailed:
        'Could not connect to the server. Tap the screen to try again.',
    LiveNotice.sessionPaused:
        'The session with the assistant ended. Tap the screen to continue.',
    LiveNotice.quotaExceeded:
        'The assistant service is not available right now. Try again later.',
    LiveNotice.serverMisconfigured:
        'The assistant server is not configured. Please contact support.',
    LiveNotice.billingExhausted:
        'The assistant service has run out of credit. Ask whoever manages Lazarus to top it up.',
    LiveNotice.permissionDenied:
        'I need microphone permission to help you. Tap the screen to try again.',
    LiveNotice.permissionBlocked:
        'Microphone permission is turned off. Tap the screen to open settings and turn it on.',
    LiveNotice.stopped: 'Assistant stopped.',
    LiveNotice.sosSent:
        'Alert sent to your emergency contact. Stop in a safe place and wait.',
    LiveNotice.sosFailed:
        'The alert could not be sent. Ask someone nearby for help or call 123.',
    LiveNotice.batteryExemption:
        'Before we start: so I can stay with you with the screen locked, allow Lazarus to run without battery restrictions. Then tap the screen to start.',
    LiveNotice.batteryExemptionXiaomi:
        'Before we start: so I can stay with you with the screen locked, allow Lazarus to run without battery restrictions. On Xiaomi phones, also go to Settings, Apps, Lazarus, Battery saver, and choose No restrictions. Then tap the screen to start.',
  },
  'fr': {
    LiveNotice.retrying: 'J\'ai perdu la connexion au serveur. Nouvel essai.',
    LiveNotice.connectionFailed:
        'Connexion au serveur impossible. Touchez l\'écran pour réessayer.',
    LiveNotice.sessionPaused:
        'La session avec l\'assistant est terminée. Touchez l\'écran pour continuer.',
    LiveNotice.quotaExceeded:
        'Le service de l\'assistant est indisponible. Réessayez plus tard.',
    LiveNotice.serverMisconfigured:
        'Le serveur de l\'assistant n\'est pas configuré. Contactez le support.',
    LiveNotice.billingExhausted:
        'Le service de l\'assistant n\'a plus de crédit. Demande à la personne qui gère Lazarus de le recharger.',
    LiveNotice.permissionDenied:
        'J\'ai besoin de l\'accès au micro pour vous accompagner. Touchez l\'écran pour réessayer.',
    LiveNotice.permissionBlocked:
        'L\'accès au micro est désactivé. Touchez l\'écran pour ouvrir les réglages et l\'activer.',
    LiveNotice.stopped: 'Assistant arrêté.',
    LiveNotice.sosSent:
        'Alerte envoyée à ton contact d\'urgence. Arrête-toi dans un endroit sûr et attends.',
    LiveNotice.sosFailed:
        'L\'alerte n\'a pas pu être envoyée. Demande de l\'aide à quelqu\'un à côté ou appelle le 123.',
    LiveNotice.batteryExemption:
        'Avant de commencer : pour rester avec toi écran verrouillé, autorise Lazarus à fonctionner sans restriction de batterie. Ensuite, touche l\'écran pour commencer.',
    LiveNotice.batteryExemptionXiaomi:
        'Avant de commencer : pour rester avec toi écran verrouillé, autorise Lazarus à fonctionner sans restriction de batterie. Sur les téléphones Xiaomi, va aussi dans Paramètres, Applications, Lazarus, Économiseur de batterie, et choisis Aucune restriction. Ensuite, touche l\'écran pour commencer.',
  },
  'pt': {
    LiveNotice.retrying: 'Perdi a conexão com o servidor. Tentando de novo.',
    LiveNotice.connectionFailed:
        'Não foi possível conectar ao servidor. Toque na tela para tentar de novo.',
    LiveNotice.sessionPaused:
        'A sessão com o assistente terminou. Toque na tela para continuar.',
    LiveNotice.quotaExceeded:
        'O serviço do assistente não está disponível agora. Tente mais tarde.',
    LiveNotice.serverMisconfigured:
        'O servidor do assistente não está configurado. Avise o suporte.',
    LiveNotice.billingExhausted:
        'O serviço do assistente ficou sem saldo. Peça a quem administra o Lazarus para recarregar.',
    LiveNotice.permissionDenied:
        'Preciso de permissão de microfone para te acompanhar. Toque na tela para tentar de novo.',
    LiveNotice.permissionBlocked:
        'A permissão de microfone está desativada. Toque na tela para abrir os ajustes e ativá-la.',
    LiveNotice.stopped: 'Assistente parado.',
    LiveNotice.sosSent:
        'Alerta enviado ao seu contato de emergência. Pare em um lugar seguro e espere.',
    LiveNotice.sosFailed:
        'Não foi possível enviar o alerta. Peça ajuda a alguém por perto ou ligue para o 123.',
    LiveNotice.batteryExemption:
        'Antes de começar: para eu continuar com você com a tela bloqueada, permita que o Lazarus funcione sem restrições de bateria. Depois toque na tela para começar.',
    LiveNotice.batteryExemptionXiaomi:
        'Antes de começar: para eu continuar com você com a tela bloqueada, permita que o Lazarus funcione sem restrições de bateria. Nos telefones Xiaomi, também vá em Configurações, Aplicativos, Lazarus, Economia de bateria, e escolha Sem restrições. Depois toque na tela para começar.',
  },
  'it': {
    LiveNotice.retrying: 'Ho perso la connessione al server. Riprovo.',
    LiveNotice.connectionFailed:
        'Impossibile connettersi al server. Tocca lo schermo per riprovare.',
    LiveNotice.sessionPaused:
        'La sessione con l\'assistente è terminata. Tocca lo schermo per continuare.',
    LiveNotice.quotaExceeded:
        'Il servizio dell\'assistente non è disponibile ora. Riprova più tardi.',
    LiveNotice.serverMisconfigured:
        'Il server dell\'assistente non è configurato. Contatta l\'assistenza.',
    LiveNotice.billingExhausted:
        'Il servizio dell\'assistente ha esaurito il credito. Chiedi a chi gestisce Lazarus di ricaricarlo.',
    LiveNotice.permissionDenied:
        'Mi serve il permesso del microfono per accompagnarti. Tocca lo schermo per riprovare.',
    LiveNotice.permissionBlocked:
        'Il permesso del microfono è disattivato. Tocca lo schermo per aprire le impostazioni e attivarlo.',
    LiveNotice.stopped: 'Assistente fermato.',
    LiveNotice.sosSent:
        'Avviso inviato al tuo contatto di emergenza. Fermati in un luogo sicuro e aspetta.',
    LiveNotice.sosFailed:
        'Non è stato possibile inviare l\'avviso. Chiedi aiuto a qualcuno vicino o chiama il 123.',
    LiveNotice.batteryExemption:
        'Prima di iniziare: per restare con te a schermo bloccato, consenti a Lazarus di funzionare senza restrizioni della batteria. Poi tocca lo schermo per iniziare.',
    LiveNotice.batteryExemptionXiaomi:
        'Prima di iniziare: per restare con te a schermo bloccato, consenti a Lazarus di funzionare senza restrizioni della batteria. Sui telefoni Xiaomi, vai anche in Impostazioni, App, Lazarus, Risparmio batteria, e scegli Nessuna restrizione. Poi tocca lo schermo per iniziare.',
  },
};

/// Texto del aviso en el idioma de la persona (español si no está disponible).
String noticeText(LiveNotice notice, String language) =>
    (_notices[language] ?? _notices['es']!)[notice]!;

enum LiveStatus { idle, connecting, connected, error }

/// Qué disparar al completarse el setup: saludo normal, muestra de voz o
/// confirmación de idioma (tras un cambio, sin repetir toda la presentación), o
/// confirmación de micrófono reactivado.
enum _PendingKickoff { intro, voice, language, micOn, cameraOff, cameraOn }

/// Estado observable por la UI. Los detalles de orquestación (contadores de
/// chunks, si hay audífonos, si el asistente sigue sonando…) son detalle
/// interno del [LiveController] y no viven aquí porque la UI no los necesita.
@immutable
class LiveUiState {
  const LiveUiState({
    this.status = LiveStatus.idle,
    this.language = 'es',
    this.userTranscript = '',
    this.assistantTranscript = '',
    this.meetingMode = false,
    this.micMuted = false,
  });

  final LiveStatus status;
  final String language;
  final String userTranscript;
  final String assistantTranscript;

  /// Modo A: el mic sigue abierto para oír y recordar; el comportamiento
  /// callado lo aplica el prompt del asistente.
  final bool meetingMode;

  /// Modo B: silencio total, no se envía mic/cámara.
  final bool micMuted;

  bool get isLive =>
      status == LiveStatus.connecting || status == LiveStatus.connected;

  String get statusLabel {
    if (micMuted) return 'Silencio total. Toca la pantalla para reactivar.';
    if (status == LiveStatus.connected && meetingMode) {
      return 'Modo reunión: escuchando en silencio. Llámame por mi nombre.';
    }
    return switch (status) {
      LiveStatus.idle => 'Toca para empezar',
      LiveStatus.connecting => 'Conectando…',
      LiveStatus.connected => 'Escuchando',
      LiveStatus.error => 'Error de conexión. Toca para reintentar.',
    };
  }

  LiveUiState copyWith({
    LiveStatus? status,
    String? language,
    String? userTranscript,
    String? assistantTranscript,
    bool? meetingMode,
    bool? micMuted,
  }) {
    return LiveUiState(
      status: status ?? this.status,
      language: language ?? this.language,
      userTranscript: userTranscript ?? this.userTranscript,
      assistantTranscript: assistantTranscript ?? this.assistantTranscript,
      meetingMode: meetingMode ?? this.meetingMode,
      micMuted: micMuted ?? this.micMuted,
    );
  }
}

class LiveController extends Notifier<LiveUiState> {
  late final LiveSessionRepository _session;
  late final MediaRepository _media;
  late final LiveSettingsRepository _settings;
  late final SessionTelemetry _telemetry;
  late final BackgroundSessionRepository _background;

  // Detalle interno de orquestación: no forma parte de LiveUiState porque la
  // UI no lo necesita para renderizar.
  int _micChunks = 0; // diagnóstico: chunks de mic enviados
  int _audioInChunks = 0; // diagnóstico: chunks de audio recibidos
  bool _onSpeaker = true; // sin audífonos → altavoz (anti-eco medio-dúplex)
  bool _assistantActive = false; // el asistente está sonando

  /// Lo que el asistente lleva dicho en el turno actual (Gemini lo transcribe por
  /// fragmentos). Se escribe completo en el log al terminar o interrumpirse el
  /// turno: es la evidencia de QA de lo que dijo.
  final StringBuffer _assistantSaid = StringBuffer();
  bool _assistantTurnDone = false; // terminó el turno (audio puede drenar)
  bool _audioDrained = false; // la cola de reproducción ya se vació

  /// Audio del asistente encolado desde que la cola se vació por última vez (ms
  /// estimados). Sirve de red de seguridad: si Android nunca avisa que el audio
  /// terminó, el micrófono se reabre por tiempo para que la app no quede sorda.
  int _queuedAudioMs = 0;
  Timer? _drainFallback;
  _PendingKickoff _pendingKickoff = _PendingKickoff.intro;
  int _retryAttempts = 0; // reintentos de conexión consumidos
  bool _openSettingsOnTap = false; // permisos bloqueados: el toque abre ajustes
  bool _cameraAllowed = true; // false = sin permiso de cámara (solo audio)
  bool _everConnected = false; // hubo setupComplete en esta sesión de uso

  /// Pantalla bloqueada (HU-017): el servicio en primer plano mantiene la
  /// sesión; la cámara se pausa mientras la app no está visible.
  bool _backgroundOn = false;
  bool _visible = true;
  bool _cameraPaused = false;

  /// La sesión actual se abrió con la pantalla bloqueada: no tiene ninguna
  /// imagen y su system prompt lo sabe (HU-017).
  bool _sessionBlind = false;

  /// Cambio de sesión pendiente al bloquear o desbloquear la pantalla.
  Timer? _cameraSwitch;

  /// Modo reunión: lo que se oyó hace poco (para saber si llamaron al asistente
  /// por su nombre) y el audio del turno actual retenido hasta saberlo.
  final List<({DateTime at, String text})> _heard = [];
  final List<String> _heldAudio = [];
  bool _turnAllowed = false; // este turno puede sonar aunque sea modo reunión

  /// La persona pidió "silencio total": si el asistente no llama a
  /// `set_microphone`, la app lo aplica igual al terminar su turno (privacidad).
  bool _silenceRequested = false;

  /// La persona pidió pausar (`false`) o reanudar (`true`) las descripciones:
  /// si el asistente no llama a `set_descriptions`, la app lo guarda igual.
  bool? _describingRequested;

  /// Acciones que esperan a que suene la próxima respuesta del asistente: la
  /// cuenta de la confirmación SOS arranca cuando termina la pregunta, y una
  /// llamada empieza cuando el asistente terminó de avisarla.
  final List<void Function()> _afterSpeech = [];
  bool _afterSpeechHeard = false; // ya sonó audio de esa respuesta
  Timer? _afterSpeechFallback;

  /// Ciclo de observación (HU-040): Gemini Live no habla si nadie le habla, así
  /// que con todos callados la app le envía `[OBSERVA]` cada pocos segundos para
  /// que mire la imagen y avise de un riesgo.
  Timer? _observeTimer;
  DateTime _lastActivity = DateTime.now(); // última vez que alguien habló
  DateTime? _observeSentAt; // `[OBSERVA]` en curso, esperando respuesta
  bool _observeAnswered = false;

  /// Latencia voz a voz (HU-015): última vez que el micrófono captó voz y si
  /// la persona habló después de la última respuesta del asistente.
  DateTime? _lastVoiceAt;
  bool _voicePending = false;

  /// Se espera una respuesta del asistente (a la voz de la persona, al saludo,
  /// a una función o a otro mensaje de la app) y aún no terminó: no se observa,
  /// porque `[OBSERVA]` la cortaría.
  bool _replyPending = false;
  bool _replyStarted = false; // ya empezó a sonar esa respuesta
  DateTime? _replyWaitFrom;
  DateTime? _lastReplyEnd;
  int _loudChunks = 0; // fragmentos seguidos con voz (el ruido es suelto)

  @override
  LiveUiState build() {
    _session = ref.read(liveSessionRepositoryProvider);
    _media = ref.read(mediaRepositoryProvider);
    _settings = ref.read(liveSettingsRepositoryProvider);
    _telemetry = ref.read(sessionTelemetryProvider);
    _background = ref.read(backgroundSessionRepositoryProvider);
    _background.onStopRequested(_stopFromNotification);
    ref.onDispose(_teardown);
    ref.onDispose(_stopBackground);
    ref.onDispose(() => _afterSpeechFallback?.cancel());
    // Español por defecto; si la persona cambió el idioma por voz, se conserva.
    return LiveUiState(language: _settings.getLanguage());
  }

  void _teardown() {
    _cameraSwitch?.cancel();
    _cameraSwitch = null;
    _stopObserving();
    _cameraPaused = false;
    _heldAudio.clear();
    _turnAllowed = false;
    // Lo que alcanzó a decir en esta sesión se registra aquí: si no, se pegaría
    // al primer turno de la sesión siguiente.
    _logAssistantSaid(' (cortado al cerrar la sesión)');
    _drainFallback?.cancel();
    _media.stopMic();
    _media.stopCamera();
    _media.destroyPlayer();
    _session.disconnect();
  }

  Future<void> connect() async {
    if (state.isLive) return;
    _retryAttempts = 0;
    // Permisos negados de forma permanente: el toque abre los ajustes; al
    // volver, el siguiente toque los pide de nuevo.
    if (_openSettingsOnTap) {
      _openSettingsOnTap = false;
      await _media.openPermissionSettings();
      return;
    }
    final access = await _media.requestPermissions();
    if (!ref.mounted) return;
    // Sin cámara la sesión sigue solo con audio: el asistente lo avisa al saludar.
    _cameraAllowed = access.camera;
    if (!_cameraAllowed) {
      _log('[Lazarus] cámara: sin permiso → modo solo audio');
    }
    switch (access.microphone) {
      case MediaPermission.granted:
        break;
      case MediaPermission.denied:
        state = state.copyWith(status: LiveStatus.error);
        _announce(LiveNotice.permissionDenied);
        return;
      case MediaPermission.blocked:
        _openSettingsOnTap = true;
        state = state.copyWith(status: LiveStatus.error);
        _announce(LiveNotice.permissionBlocked);
        return;
    }
    if (await _askBatteryExemptionOnce() || !ref.mounted) return;
    // La sesión sigue con la pantalla bloqueada (HU-017).
    unawaited(_startBackground());
    // La ubicación acompaña a la sesión; sin permiso la sesión sigue igual.
    unawaited(ref.read(locationControllerProvider.notifier).start());
    _openSession(state.language);
  }

  /// La primera vez, antes de empezar, pide excluir a Lazarus de la optimización
  /// de batería (si no, Android puede suspenderla con la pantalla bloqueada) y lo
  /// explica en voz alta, con el ajuste extra de Xiaomi. Esa vez no se abre la
  /// sesión (el saludo se cruzaría con el aviso y el diálogo): la persona vuelve a
  /// tocar la pantalla. Devuelve `true` si se pidió.
  Future<bool> _askBatteryExemptionOnce() async {
    if (_settings.getBatteryExemptionAsked()) return false;
    await _settings.setBatteryExemptionAsked();
    final status = await _background.batteryStatus();
    if (status.exempt || !ref.mounted) return false;
    _announce(
      status.manufacturer == 'xiaomi'
          ? LiveNotice.batteryExemptionXiaomi
          : LiveNotice.batteryExemption,
    );
    final exempt = await _background.requestBatteryExemption();
    _log(
      '[Lazarus] batería: ${exempt ? "sin restricciones" : "sigue con optimización"}',
    );
    return true;
  }

  Future<void> _startBackground() async {
    if (_backgroundOn) return;
    _backgroundOn = true;
    final started = await _background.start();
    _log(
      started
          ? '[Lazarus] segundo plano: activo (puede bloquear la pantalla)'
          : '[Lazarus] segundo plano: Android no lo permitió',
    );
    if (!started) _backgroundOn = false;
  }

  void _stopBackground() {
    if (!_backgroundOn) return;
    _backgroundOn = false;
    unawaited(_background.stop());
    _log('[Lazarus] segundo plano: detenido');
  }

  /// "Detener" en la notificación: lo mismo que el botón de la pantalla.
  void _stopFromNotification() {
    if (!ref.mounted) return;
    _log('[Lazarus] Detener desde la notificación');
    if (_backgroundOn || state.isLive) {
      disconnect();
    } else {
      _stopBackground();
    }
  }

  /// La app dejó de verse (pantalla bloqueada u otra app encima) o volvió.
  /// Android no deja usar la cámara sin la app visible. Avisarle al asistente
  /// no basta: en la caminata de CP-LAZA-45 siguió describiendo la última imagen
  /// como si fuera lo que la persona tenía delante, y hasta dio indicaciones con
  /// ella. Por eso, al bloquear se abre una sesión nueva sin ninguna imagen, en
  /// modo pantalla bloqueada; al desbloquear, tras una espera por si fue sin
  /// querer, se vuelve a una sesión con cámara (HU-017).
  void onVisibilityChanged(bool visible) {
    if (visible == _visible) return;
    _visible = visible;
    if (!visible) _pauseCamera();
    _syncCameraSession();
  }

  /// El asistente recibe imágenes ahora: hay permiso, la sesión no es de
  /// pantalla bloqueada y la cámara no está en pausa.
  bool get _canSee => _cameraAllowed && !_sessionBlind && !_cameraPaused;

  bool get _sessionUp =>
      _session.connected && state.status == LiveStatus.connected;

  void _pauseCamera() {
    if (!_cameraAllowed || _cameraPaused || !_sessionUp) return;
    _cameraPaused = true;
    _stopObserving();
    unawaited(_media.stopCamera());
    _log('[Lazarus] pantalla bloqueada: cámara en pausa (sigue el audio)');
    _telemetry.event('camera', {'paused': true});
  }

  /// Deja la sesión acorde con la pantalla: sin imágenes si está bloqueada y
  /// con cámara si no. Al bloquear cambia enseguida; al desbloquear, espera.
  void _syncCameraSession() {
    _cameraSwitch?.cancel();
    _cameraSwitch = null;
    if (!_cameraAllowed || !_sessionUp) return;
    final blind = !_visible;
    if (blind == _sessionBlind) {
      // Desbloqueo antes del cambio: la sesión aún tiene cámara, se reanuda.
      if (!blind) _resumeCamera();
      return;
    }
    // En silencio total o en modo reunión no se cambia: el aviso sonaría. Se
    // hace al salir de esos modos.
    if (state.micMuted || state.meetingMode) return;
    _cameraSwitch = Timer(
      blind ? Duration.zero : ref.read(cameraUnlockDelayProvider),
      _switchCameraSession,
    );
  }

  void _switchCameraSession() {
    _cameraSwitch = null;
    if (!ref.mounted || !_sessionUp) return;
    final blind = !_visible;
    if (blind == _sessionBlind) return;
    _log(
      blind
          ? '[Lazarus] pantalla bloqueada: sesión nueva sin imágenes'
          : '[Lazarus] pantalla desbloqueada: sesión nueva con cámara',
    );
    _telemetry.event('camera_session', {'screen_locked': blind});
    _pendingKickoff = blind
        ? _PendingKickoff.cameraOff
        : _PendingKickoff.cameraOn;
    _teardown();
    _openSession(state.language);
  }

  void _resumeCamera() {
    if (!_cameraPaused) return;
    _cameraPaused = false;
    if (!_sessionUp) return;
    unawaited(_startCamera());
    _log('[Lazarus] pantalla desbloqueada: cámara de vuelta');
    _telemetry.event('camera', {'paused': false});
  }

  Future<void> _startCamera() async {
    await _media.startCamera((jpeg) {
      // Silencio total (Modo B): tampoco enviar cámara (privacidad).
      if (state.micMuted) return;
      _session.sendImage(jpeg);
    });
    if (ref.mounted && !_cameraPaused) _startObserving();
  }

  void _openSession(String lang) {
    if (_session.connected) return;
    state = state.copyWith(
      status: LiveStatus.connecting,
      userTranscript: '',
      assistantTranscript: '',
    );

    final voice = _settings.getVoice();
    _sessionBlind = _cameraAllowed && !_visible;
    _session.connect(
      language: lang,
      voice: voice.isEmpty ? null : voice,
      assistantName: _settings.getAssistantName(),
      userName: _settings.getUserName(),
      verbosity: _settings.getVerbosity(),
      describing: _settings.getDescribing(),
      camera: _cameraAllowed,
      screenLocked: _sessionBlind,
      onResponse: _handleResponse,
      onClose: (cause) {
        _log('[Lazarus] sesión cerrada: ${cause.name}');
        _telemetry.event('session_closed', {'cause': cause.name});
        if (!ref.mounted) return;
        _teardown();
        _onSessionClosed(cause, lang);
      },
      onError: (e) {
        _log('[Lazarus] error de conexión: $e');
        _telemetry.event('error', {'kind': 'connection'});
        if (!ref.mounted) return;
        _teardown();
        _retryOrFail(lang);
      },
    );
  }

  void _announce(LiveNotice notice) {
    if (mutableNotices.contains(notice) && _settings.getSystemCuesMuted()) {
      _log('[Lazarus] aviso silenciado: ${notice.name}');
      return;
    }
    _log('[Lazarus] aviso: ${notice.name}');
    ref.read(announcerProvider)(
      noticeText(notice, state.language),
      state.language,
    );
  }

  /// La sesión terminó sin que la app la cerrara: decide según la causa.
  void _onSessionClosed(LiveCloseCause cause, String lang) {
    // En silencio total no se reconecta (privacidad): se retoma al tocar.
    if (state.micMuted) {
      state = state.copyWith(status: LiveStatus.idle);
      return;
    }
    if (cause != LiveCloseCause.upstreamError &&
        cause != LiveCloseCause.unknown) {
      _endTelemetry(cause.name);
    }
    switch (cause) {
      case LiveCloseCause.upstreamEnded:
        // Gemini cerró la sesión (p. ej. límite de duración): se retoma cuando la
        // persona vuelve a tocar la pantalla, con una confirmación corta en lugar
        // de la presentación completa.
        if (_everConnected) _pendingKickoff = _PendingKickoff.micOn;
        state = state.copyWith(status: LiveStatus.idle);
        _announce(LiveNotice.sessionPaused);
      case LiveCloseCause.quotaExceeded:
        state = state.copyWith(status: LiveStatus.error);
        _announce(LiveNotice.quotaExceeded);
      case LiveCloseCause.serverMisconfigured:
        state = state.copyWith(status: LiveStatus.error);
        _announce(LiveNotice.serverMisconfigured);
      case LiveCloseCause.billingExhausted:
        // No se reintenta: sin saldo, cada intento falla igual (en la prueba,
        // 8 reintentos seguidos con "Perdí la conexión").
        state = state.copyWith(status: LiveStatus.error);
        _announce(LiveNotice.billingExhausted);
      case LiveCloseCause.protocolError:
        state = state.copyWith(status: LiveStatus.error);
        _announce(LiveNotice.connectionFailed);
      case LiveCloseCause.upstreamError:
      case LiveCloseCause.unknown:
        _retryOrFail(lang);
    }
  }

  /// Sin conexión con el backend: avisa y reintenta con espera creciente; al
  /// agotar los reintentos deja el estado de error (tocar la pantalla reintenta).
  void _retryOrFail(String lang) {
    if (_retryAttempts >= maxConnectionRetries) {
      _endTelemetry('connection_failed');
      state = state.copyWith(status: LiveStatus.error);
      _announce(LiveNotice.connectionFailed);
      return;
    }
    final delay = ref.read(retryDelayProvider)(_retryAttempts);
    // Se avisa solo en el primer reintento: la frase dura más que la espera
    // entre intentos y cada aviso nuevo cortaría el anterior a la mitad.
    if (_retryAttempts == 0) _announce(LiveNotice.retrying);
    _retryAttempts++;
    _telemetry.event('reconnect', {'attempt': _retryAttempts});
    state = state.copyWith(status: LiveStatus.connecting);
    // Si la sesión ya había funcionado, al volver basta una confirmación corta.
    if (_everConnected) _pendingKickoff = _PendingKickoff.micOn;
    Future.delayed(delay, () {
      if (!ref.mounted || state.status != LiveStatus.connecting) return;
      _openSession(lang);
    });
  }

  /// Arranca mic + cámara una vez que el asistente confirma la sesión.
  Future<void> _startMedia() async {
    try {
      _onSpeaker = !(await _media.isHeadsetConnected());
      _assistantActive = false;
      _assistantTurnDone = false;
      _audioDrained = false;
      if (!ref.mounted) return;
      state = state.copyWith(meetingMode: false, micMuted: false);
      _log(
        '[Lazarus] salida: ${_onSpeaker ? "ALTAVOZ (medio-dúplex anti-eco)" : "AUDÍFONOS (full-duplex)"}',
      );

      await _media.initPlayer(() {
        _audioDrained = true;
        _queuedAudioMs = 0;
        _reopenMicIfTurnOver('fin del audio y turnComplete');
      });

      _micChunks = 0;
      _audioInChunks = 0;
      await _media.startMic((pcm) {
        // Silencio total (Modo B): no enviar nada hasta reactivar.
        if (state.micMuted) return;
        // En altavoz, no enviar mientras el asistente suena (anti-eco).
        if (_onSpeaker && _assistantActive) return;
        _trackVoice(pcm);
        _micChunks++;
        if (_micChunks == 1) _log('[Lazarus] mic: primer chunk enviado');
        if (_micChunks % 50 == 0) _log('[Lazarus] mic: $_micChunks chunks');
        _session.sendAudio(pcm);
      });

      if (!_cameraAllowed) {
        _log('[Lazarus] media activa (solo micrófono: sin permiso de cámara)');
        return;
      }
      if (!_visible || _sessionBlind) {
        // Sesión de pantalla bloqueada: sin imágenes; la cámara vuelve con la
        // sesión que se abre al desbloquear.
        _cameraPaused = true;
        _log('[Lazarus] media activa (solo micrófono: pantalla bloqueada)');
        return;
      }
      await _startCamera();
      _log('[Lazarus] media activa (mic + cámara)');
    } catch (e) {
      _log('[Lazarus] fallo al arrancar media: $e');
    }
  }

  /// Botón Detener: cierra la sesión; la próxima empieza con la presentación.
  /// Botón Detener: cierra la sesión, libera micrófono y cámara y avisa con una
  /// frase corta (sin reconectar).
  void disconnect() {
    _teardown();
    _stopBackground();
    _endTelemetry('stopped');
    ref.read(locationControllerProvider.notifier).stop();
    _everConnected = false;
    _pendingKickoff = _PendingKickoff.intro;
    if (!ref.mounted) return;
    // Los modos de silencio son de sesión: Detener los termina.
    state = state.copyWith(
      status: LiveStatus.idle,
      meetingMode: false,
      micMuted: false,
    );
    _announce(LiveNotice.stopped);
  }

  /// Toque en pantalla: si está en silencio total, reactiva el micrófono; si
  /// no, arranca la sesión cuando aún no está en marcha.
  void onTap() {
    if (state.micMuted) {
      _resumeFromMute();
    } else if (!state.isLive) {
      connect();
    }
  }

  /// Sale del silencio total (Modo B): vuelve a enviar mic/cámara y pide al
  /// asistente una confirmación corta de que ya vuelve a escuchar.
  void _resumeFromMute() {
    state = state.copyWith(micMuted: false);
    if (_session.connected && _cameraAllowed && _sessionBlind == _visible) {
      // La pantalla cambió durante el silencio: la sesión nueva confirma.
      _switchCameraSession();
    } else if (_session.connected) {
      // Sesión aún viva: reanuda el envío y pide confirmación, sin reconectar.
      _expectReply();
      _session.sendMicResumed();
    } else {
      // La sesión se cerró durante el silencio (el backend la cierra por
      // inactividad al no recibir mic ni cámara). Reconecta con confirmación
      // corta, sin repetir la presentación completa.
      _pendingKickoff = _PendingKickoff.micOn;
      _teardown();
      _openSession(state.language);
    }
  }

  void _handleResponse(LiveResponse message) {
    if (!ref.mounted) return;
    switch (message.type) {
      case LiveResponseType.setupComplete:
        _log('[Lazarus] setupComplete → sesión lista, arrancando media');
        state = state.copyWith(status: LiveStatus.connected);
        _telemetry.event('session_start', {
          'language': state.language,
          'resumed': _pendingKickoff != _PendingKickoff.intro,
          'camera': _cameraAllowed,
          'screen_locked': _sessionBlind,
        });
        _retryAttempts = 0;
        _everConnected = true;
        switch (_pendingKickoff) {
          case _PendingKickoff.voice:
            _expectReply();
            _session.sendVoiceSample();
          case _PendingKickoff.language:
            _expectReply();
            _session.sendLanguageChanged();
          case _PendingKickoff.micOn:
            _expectReply();
            _session.sendMicResumed();
          case _PendingKickoff.cameraOff:
            _expectReply();
            _session.sendCameraPaused();
          case _PendingKickoff.cameraOn:
            _expectReply();
            _session.sendCameraResumed();
          case _PendingKickoff.intro:
            _expectReply();
            _session.sendKickoff();
        }
        _pendingKickoff = _PendingKickoff.intro;
        _markActivity();
        _startMedia();
        // La pantalla cambió mientras se conectaba.
        _syncCameraSession();
      case LiveResponseType.inputTranscription:
        final t = message.data as LiveTranscription;
        _log('[Lazarus] te escuché (transcripción): "${t.text}"');
        state = state.copyWith(userTranscript: t.text);
        _remember(t.text);
        // La persona habla: el ciclo de observación espera su respuesta. La
        // transcripción respalda al nivel del micrófono, que no capta una voz
        // baja (CP-LAZA-107: preguntas cortadas por [OBSERVA]).
        _observeSentAt = null;
        _expectReply();
        // Respaldo de la latencia voz a voz cuando el micrófono no detectó la
        // voz (habla baja): la transcripción llega poco después de la voz.
        final heardAt = DateTime.now();
        final voice = _lastVoiceAt;
        if (voice == null ||
            heardAt.difference(voice) > const Duration(milliseconds: 1500)) {
          _lastVoiceAt = heardAt;
        }
        _voicePending = true;
        // Está respondiendo a "¿Envío la alerta…?": la cuenta espera.
        ref.read(sosControllerProvider.notifier).personSpoke();
        if (asksTotalSilence(_recentHeard())) _silenceRequested = true;
        final describing = asksDescriptions(_recentHeard());
        if (describing != null) _describingRequested = describing;
        if (_heldAudio.isNotEmpty && _calledByName()) {
          _allowTurn('lo llamaron por su nombre');
        }
      case LiveResponseType.outputTranscription:
        final t = message.data as LiveTranscription;
        _assistantSaid.write(t.text);
        state = state.copyWith(assistantTranscript: _assistantSaid.toString());
      case LiveResponseType.toolCall:
        _markActivity();
        final call = message.data as LiveToolCall;
        _telemetry.event('tool_call', {
          'names': [for (final f in call.functionCalls) f.name],
        });
        _handleToolCall(call);
      case LiveResponseType.audio:
        final pcm = message.data as String;
        // Modo reunión: calla salvo que lo llamen por su nombre. El audio se
        // retiene hasta saberlo (la transcripción puede llegar después).
        if (state.meetingMode && !_turnAllowed) {
          if (_calledByName()) {
            _allowTurn('lo llamaron por su nombre');
          } else {
            if (_heldAudio.isEmpty) {
              _log('[Lazarus] modo reunión: respuesta retenida');
            }
            _heldAudio.add(pcm);
            return;
          }
        }
        _turnAllowed = _turnAllowed || state.meetingMode;
        _releaseHeldAudio();
        _playAssistantAudio(pcm);
      case LiveResponseType.interrupted:
        _logAssistantSaid(
          _endMeetingTurn() ? ' (descartado: modo reunión)' : ' (interrumpido)',
        );
        _log('[Lazarus] INTERRUMPIDO (barge-in: el usuario habló encima)');
        _telemetry.event('interrupted');
        _assistantActive = false;
        _assistantTurnDone = false;
        _drainFallback?.cancel();
        _queuedAudioMs = 0;
        final stopwatch = Stopwatch()..start();
        _media.interruptPlayback().then((_) {
          _log(
            '[Lazarus] reproducción detenida en ${stopwatch.elapsedMilliseconds} ms',
          );
        });
      case LiveResponseType.turnComplete:
        _logAssistantSaid(
          _endMeetingTurn() ? ' (descartado: modo reunión)' : '',
        );
        _applyRequestedSilence();
        _applyRequestedDescriptions();
        // El asistente terminó de generar; el audio aún puede estar drenando.
        // El mic se reabrirá cuando la cola se vacíe (onDrained). Si el
        // drenado llegó primero (respuesta corta), reabre ya mismo.
        _log('[Lazarus] turnComplete (asistente terminó su turno)');
        _telemetry.event('turn_complete');
        if (_replyStarted) {
          // Terminó la respuesta esperada; la observación sigue tras una pausa.
          _replyPending = false;
          _replyStarted = false;
          _lastReplyEnd = DateTime.now();
        }
        _endObserve();
        _markActivity();
        _assistantTurnDone = true;
        if (_audioDrained) {
          _reopenMicIfTurnOver('turnComplete tras el fin del audio');
        } else if (_assistantActive) {
          _drainFallback?.cancel();
          _drainFallback = Timer(
            Duration(milliseconds: _queuedAudioMs) +
                ref.read(drainFallbackMarginProvider),
            () => _reopenMicIfTurnOver('por tiempo: no llegó el fin del audio'),
          );
        }
      case LiveResponseType.text:
      case LiveResponseType.unknown:
        break;
    }
  }

  /// Reproduce un fragmento de audio del asistente (en altavoz cierra el mic).
  void _playAssistantAudio(String pcm) {
    _audioInChunks++;
    if (_afterSpeech.isNotEmpty) _afterSpeechHeard = true;
    if (_audioInChunks == 1) {
      _log(
        '[Lazarus] audio del asistente: primer chunk recibido → reproduciendo',
      );
    }
    // El asistente está sonando → en altavoz, cierra el mic (anti-eco).
    if (!_assistantActive) {
      _log('[Lazarus] asistente: INICIA turno de audio');
      if (_replyPending) _replyStarted = true;
      final sent = _observeSentAt;
      if (sent != null && !_observeAnswered) {
        _observeAnswered = true;
        final ms = DateTime.now().difference(sent).inMilliseconds;
        _log('[Lazarus] observa: respondió en $ms ms');
        _telemetry.event('observe', {'answered': true, 'ms': ms});
      } else if (_voicePending && _lastVoiceAt != null) {
        final ms = DateTime.now().difference(_lastVoiceAt!).inMilliseconds;
        _log('[Lazarus] latencia voz a voz: $ms ms');
        _telemetry.voiceToVoice(ms);
      }
      _voicePending = false;
      // Mientras habla, la persona no puede contestar a "¿Envío la alerta…?".
      ref.read(sosControllerProvider.notifier).assistantSpeaking();
    }
    _assistantActive = true;
    _assistantTurnDone = false;
    _audioDrained = false;
    _drainFallback?.cancel();
    // base64 → bytes (×3/4) → muestras de 16 bits (÷2) → ms a 24 kHz (÷24).
    _queuedAudioMs += pcm.length * 3 ~/ 4 ~/ 48;
    _media.playAudio(pcm);
  }

  void _markActivity() => _lastActivity = DateTime.now();

  /// Marca cuándo el micrófono captó voz por última vez (latencia voz a voz).
  void _trackVoice(String base64Pcm) {
    final double level;
    try {
      level = pcm16Level(base64Decode(base64Pcm));
    } on FormatException {
      return; // fragmento ilegible: no cuenta como voz
    }
    if (level < ref.read(voiceLevelThresholdProvider)) {
      _loudChunks = 0;
      return;
    }
    // Voz sostenida (unos 300 ms): pasos o golpes sueltos no cuentan. En la
    // prueba, el ruido al caminar frenó la observación hasta 15 s.
    if (++_loudChunks < 3) return;
    _lastVoiceAt = DateTime.now();
    _voicePending = true;
    _expectReply();
  }

  /// La app o la persona dijeron algo que el asistente va a responder.
  void _expectReply() {
    _replyPending = true;
    _replyStarted = false;
    _replyWaitFrom = DateTime.now();
    _markActivity();
  }

  /// Cierra la telemetría de la sesión con la mediana y el percentil 90.
  void _endTelemetry(String reason) {
    final s = _telemetry.endSession(reason);
    if (s.count > 0) {
      _log(
        '[Lazarus] latencia voz a voz: ${s.count} respuestas, mediana ${s.medianMs} ms, p90 ${s.p90Ms} ms',
      );
    }
    _lastVoiceAt = null;
    _voicePending = false;
  }

  void _startObserving() {
    _observeTimer?.cancel();
    _observeSentAt = null;
    _markActivity();
    _observeTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _maybeObserve(),
    );
  }

  void _stopObserving() {
    _observeTimer?.cancel();
    _observeTimer = null;
    _observeSentAt = null;
  }

  /// Envía `[OBSERVA]` solo con todos callados: ni la persona ni el asistente
  /// hablan, no hay una respuesta pendiente, no es modo reunión ni silencio
  /// total y no hay una alerta SOS en curso (criterio 4 de HU-040).
  void _maybeObserve() {
    if (!ref.mounted || !_session.connected) return;
    if (state.status != LiveStatus.connected) return;
    if (state.meetingMode || state.micMuted || !_cameraAllowed) return;
    if (_cameraPaused) return;
    if (_assistantActive) return;
    if (ref.read(sosControllerProvider) != SosStatus.idle) return;
    final now = DateTime.now();
    // Se espera una respuesta (o un tiempo máximo) antes de observar, para no
    // cortarla; y tras una respuesta, una pausa por si la persona sigue.
    final waitFrom = _replyWaitFrom;
    if (_replyPending &&
        waitFrom != null &&
        now.difference(waitFrom) < ref.read(observeReplyWaitProvider)) {
      return;
    }
    final replyEnd = _lastReplyEnd;
    if (replyEnd != null &&
        now.difference(replyEnd) < ref.read(observeAfterReplyProvider)) {
      return;
    }
    final sent = _observeSentAt;
    if (sent != null) {
      if (now.difference(sent) < ref.read(observeTimeoutProvider)) return;
      _endObserve();
    }
    if (now.difference(_lastActivity) < ref.read(observePeriodProvider)) return;
    _observeSentAt = now;
    _observeAnswered = false;
    _lastActivity = now;
    // En pausa la app lo dice en el propio mensaje: el modelo no siempre
    // recuerda que se pausó a mitad de la sesión (CP-LAZA-107).
    _session.sendObserve(risksOnly: !_settings.getDescribing());
  }

  /// Cierra el `[OBSERVA]` en curso; si el asistente no habló, calló (correcto
  /// cuando no hay riesgo ni nada nuevo).
  void _endObserve() {
    if (_observeSentAt == null) return;
    if (!_observeAnswered) {
      _log('[Lazarus] observa: calló');
      _telemetry.event('observe', {'answered': false});
    }
    _observeSentAt = null;
  }

  /// Guarda lo que se oyó en los últimos segundos (modo reunión).
  void _remember(String text) {
    final now = DateTime.now();
    _heard
      ..removeWhere((h) => now.difference(h.at) > meetingNameWindow)
      ..add((at: now, text: text));
  }

  /// En modo reunión, si alguien dijo el nombre del asistente hace poco.
  bool _calledByName() {
    return mentionsName(_recentHeard(), _settings.getAssistantName());
  }

  /// Lo que se oyó en los últimos segundos, unido.
  String _recentHeard() {
    final now = DateTime.now();
    return _heard
        .where((h) => now.difference(h.at) <= meetingNameWindow)
        .map((h) => h.text)
        .join();
  }

  /// Red de seguridad del silencio total: el asistente dijo que se silenciaba
  /// pero no llamó a la función, así que la app deja de enviar igual.
  void _applyRequestedSilence() {
    if (!_silenceRequested) return;
    _silenceRequested = false;
    _heard.clear();
    if (state.micMuted) return;
    _log(
      '[Lazarus] silencio total aplicado por la app (el asistente no llamó a set_microphone)',
    );
    state = state.copyWith(micMuted: true);
  }

  /// Red de seguridad de "deja de describir" / "vuelve a describir": el
  /// asistente respondió sin llamar a `set_descriptions`, así que la app guarda
  /// el ajuste igual (persiste para la próxima sesión).
  void _applyRequestedDescriptions() {
    final wanted = _describingRequested;
    if (wanted == null) return;
    _describingRequested = null;
    if (_settings.getDescribing() == wanted) return;
    _settings.setDescribing(wanted);
    _log(
      '[Lazarus] descripciones ${wanted ? "reanudadas" : "en pausa"} por la app (el asistente no llamó a set_descriptions)',
    );
  }

  /// Este turno puede sonar en modo reunión: suelta el audio retenido.
  void _allowTurn(String reason) {
    if (_turnAllowed) return;
    _turnAllowed = true;
    _log('[Lazarus] modo reunión: responde ($reason)');
    _releaseHeldAudio();
  }

  void _releaseHeldAudio() {
    if (_heldAudio.isEmpty) return;
    final held = List<String>.of(_heldAudio);
    _heldAudio.clear();
    held.forEach(_playAssistantAudio);
  }

  /// Fin del turno del asistente: lo retenido y no autorizado se descarta.
  /// Devuelve si hubo audio descartado.
  bool _endMeetingTurn() {
    final discarded = _heldAudio.isNotEmpty;
    if (discarded) {
      _log(
        '[Lazarus] modo reunión: respuesta descartada (no lo llamaron por su nombre)',
      );
    }
    _heldAudio.clear();
    _turnAllowed = false;
    return discarded;
  }

  /// Medio-dúplex: el micrófono se reabre cuando el audio terminó **y** llegó
  /// `turnComplete`, en cualquier orden.
  void _reopenMicIfTurnOver(String reason) {
    if (!_assistantActive || !_assistantTurnDone) return;
    _drainFallback?.cancel();
    _assistantActive = false;
    if (_onSpeaker) _log('[Lazarus] mic: reabierto ($reason)');
    ref.read(sosControllerProvider.notifier).assistantFinished();
    if (_afterSpeechHeard) _runAfterSpeech();
  }

  /// Ejecuta [action] cuando termine de sonar la próxima respuesta del
  /// asistente, o pasado el tiempo de respaldo si no llega a sonar.
  void _whenAssistantFinishes(void Function() action) {
    _afterSpeech.add(action);
    _afterSpeechFallback?.cancel();
    _afterSpeechFallback = Timer(
      ref.read(sosQuestionFallbackProvider),
      _runAfterSpeech,
    );
  }

  void _runAfterSpeech() {
    _afterSpeechFallback?.cancel();
    _afterSpeechFallback = null;
    _afterSpeechHeard = false;
    final actions = List.of(_afterSpeech);
    _afterSpeech.clear();
    for (final action in actions) {
      action();
    }
  }

  /// La alerta se envió sola (nadie respondió a la confirmación): el asistente
  /// lo dice; si la sesión ya no está, lo dice la voz del teléfono.
  void _onSosAutoSent(String result) {
    if (!ref.mounted) return;
    if (_session.connected && state.status == LiveStatus.connected) {
      _turnAllowed = true; // debe sonar aunque esté en modo reunión
      _expectReply();
      _session.sendSosResult(result);
    } else {
      _announce(
        result.startsWith('sent') ? LiveNotice.sosSent : LiveNotice.sosFailed,
      );
    }
  }

  /// Llamada telefónica: el asistente se pausa (libera micrófono y altavoz) y
  /// al volver basta tocar la pantalla para retomar con una confirmación corta.
  void _startCall(CallTarget to) {
    if (!ref.mounted) return;
    _log('[Lazarus] llamada (${to.name}): asistente en pausa');
    _teardown();
    if (_everConnected) _pendingKickoff = _PendingKickoff.micOn;
    state = state.copyWith(
      status: LiveStatus.idle,
      meetingMode: false,
      micMuted: false,
    );
    ref.read(sosControllerProvider.notifier).placeCall(to);
  }

  void _logAssistantSaid([String note = '']) {
    final said = _assistantSaid.toString().trim();
    _assistantSaid.clear();
    if (said.isEmpty) return;
    _log('[Lazarus] asistente dijo$note: "$said"');
  }

  /// Personalización por voz: el asistente pidió ejecutar una o más funciones.
  void _handleToolCall(LiveToolCall toolCall) {
    _log(
      '[Lazarus] toolCall: ${toolCall.functionCalls.map((c) => "${c.name}(${c.args})").join(", ")}',
    );
    String? reconnectLang;
    var reconnectVoice = false;
    bool? meetingMode; // Modo A on/off (si aparece set_meeting_mode)
    bool? micActive; // Modo B: mic activo/apagado (si aparece set_microphone)
    // Funciones que tardan (GPS, SMS, permisos): se responde al terminar todas.
    final waits = <Future<void>>[];
    final sos = ref.read(sosControllerProvider.notifier);
    final results =
        <
          String,
          String
        >{}; // id de la llamada -> resultado si no es un ok simple

    for (final call in toolCall.functionCalls) {
      switch (call.name) {
        case 'set_assistant_name':
          final name = (call.args['name'] ?? '').toString().trim();
          if (name.isNotEmpty) _settings.setAssistantName(name);
        case 'set_user_name':
          final name = (call.args['name'] ?? '').toString().trim();
          if (name.isNotEmpty) _settings.setUserName(name);
        case 'set_voice':
          // Se acepta "aoede" o "AOEDE": se guarda con el nombre exacto de la voz.
          final asked = (call.args['voice'] ?? '')
              .toString()
              .trim()
              .toLowerCase();
          final voice = liveVoices.firstWhere(
            (v) => v.toLowerCase() == asked,
            orElse: () => '',
          );
          if (voice.isEmpty) {
            results[call.id] = unsupportedVoiceResult;
          } else {
            _settings.setVoice(voice);
            reconnectVoice = true;
            results[call.id] = restartResult;
          }
        case 'set_language':
          final lang = (call.args['language'] ?? '').toString();
          if (!liveLanguages.contains(lang)) {
            // Gemini puede pedir un idioma fuera de la lista (p. ej. ruso): no se
            // cambia nada y el asistente se lo explica a la persona.
            results[call.id] = unsupportedLanguageResult;
          } else {
            reconnectLang = lang;
            _settings.setLanguage(lang);
            results[call.id] = restartResult;
          }
        case 'set_verbosity':
          final level = (call.args['level'] ?? '').toString();
          if (level == 'concise' || level == 'detailed') {
            _settings.setVerbosity(level);
          }
        case 'set_descriptions':
          _settings.setDescribing(call.args['enabled'] == true);
          _describingRequested = null;
        case 'set_system_cues':
          // enabled=true => avisos activos => no silenciado.
          _settings.setSystemCuesMuted(call.args['enabled'] != true);
        case 'set_meeting_mode':
          meetingMode = call.args['enabled'] == true;
        case 'set_microphone':
          micActive = call.args['active'] != false;
          _silenceRequested = false;
        case 'get_location':
          // La dirección se busca en el geocodificador.
          waits.add(
            ref
                .read(locationControllerProvider.notifier)
                .describeForAssistant(canSee: _canSee)
                .then((where) {
                  _log('[Lazarus] ubicación para el asistente: $where');
                  results[call.id] = where;
                }),
          );
        case 'set_emergency_contact':
          waits.add(
            sos
                .setContact(
                  (call.args['name'] ?? '').toString(),
                  (call.args['phone'] ?? '').toString(),
                )
                .then((r) => results[call.id] = r),
          );
        case 'trigger_sos':
          // La pregunta de confirmación y el resultado deben sonar siempre.
          _allowTurn('alerta SOS');
          waits.add(
            sos.trigger().then((r) {
              _log('[Lazarus] SOS para el asistente: $r');
              results[call.id] = r;
              if (ref.read(sosControllerProvider) ==
                  SosStatus.awaitingConfirmation) {
                _whenAssistantFinishes(
                  () => sos.startCountdown(_onSosAutoSent),
                );
              }
            }),
          );
        case 'cancel_sos':
          results[call.id] = sos.cancel();
        case 'call_phone':
          final to = call.args['to'] == 'emergency'
              ? CallTarget.emergency
              : CallTarget.contact;
          final r = sos.prepareCall(to);
          results[call.id] = r;
          if (r.startsWith('ok')) _whenAssistantFinishes(() => _startCall(to));
      }
    }

    // Aplica los modos de silencio (afectan captura y UI). No persisten.
    if (meetingMode != null || micActive != null) {
      state = state.copyWith(
        meetingMode: meetingMode,
        micMuted: micActive != null ? !micActive : null,
      );
    }
    // La confirmación de entrar o salir del modo reunión sí debe sonar.
    if (meetingMode != null) _allowTurn('entra o sale del modo reunión');
    // Si la pantalla cambió durante la reunión, la sesión se ajusta al salir.
    if (meetingMode == false) _whenAssistantFinishes(_syncCameraSession);

    void respond() {
      _expectReply(); // tras la función, el asistente sigue hablando
      _session.sendToolResponse([
        for (final c in toolCall.functionCalls)
          (id: c.id, name: c.name, result: results[c.id] ?? 'ok'),
      ]);
    }

    if (waits.isEmpty) {
      respond();
    } else {
      Future.wait(waits).then((_) {
        if (ref.mounted) respond();
      });
    }

    // Cambiar idioma o voz exige una sesión nueva (ambos se fijan en el setup).
    if (reconnectLang != null || reconnectVoice) {
      final lang = reconnectLang ?? state.language;
      _pendingKickoff = reconnectLang != null
          ? _PendingKickoff.language
          : _PendingKickoff.voice;
      if (reconnectLang != null) {
        state = state.copyWith(language: reconnectLang);
      }
      Future.delayed(const Duration(milliseconds: 600), () {
        if (!ref.mounted) return;
        _teardown();
        _openSession(lang);
      });
    }
  }
}
