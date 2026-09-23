/// Estado + lógica de la sesión Live (equivalente a `auth_controller.dart` en
/// el manual de arquitectura). Orquesta [LiveSessionRepository] y
/// [MediaRepository]: decide cuándo conectar, cuándo silenciar el mic
/// (anti-eco / silencio total) y cómo reaccionar a cada [LiveResponse]. La UI
/// (`LiveHomePage`) solo observa el [LiveUiState] expuesto y dispara acciones;
/// no conoce WebSockets, audio nativo ni cámara.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/live_close.dart';
import '../../domain/entities/live_message.dart';
import '../../domain/repositories/live_session_repository.dart';
import '../../domain/repositories/live_settings_repository.dart';
import '../../domain/repositories/media_repository.dart';
import '../providers/live_providers.dart';

/// Activa las trazas de diagnóstico `[Lazarus]` de la sesión Live (mic, turnos,
/// toolCalls, transcripciones…). Ponlo en `false` para producción.
const bool _kLiveDebug = true;

void _log(String message) {
  if (_kLiveDebug) debugPrint(message);
}

const _validLanguages = {'es', 'en', 'fr', 'pt', 'it'};

/// Reintentos automáticos cuando no se puede conectar con el backend.
const int maxConnectionRetries = 3;

/// Avisos hablados cuando el asistente no puede hablar (sin conexión, sin cuota…).
enum LiveNotice {
  retrying,
  connectionFailed,
  sessionPaused,
  quotaExceeded,
  serverMisconfigured,
}

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
  },
};

/// Texto del aviso en el idioma de la persona (español si no está disponible).
String noticeText(LiveNotice notice, String language) =>
    (_notices[language] ?? _notices['es']!)[notice]!;

enum LiveStatus { idle, connecting, connected, error }

/// Qué disparar al completarse el setup: saludo normal o muestra de voz (tras
/// un cambio de voz, para oírla sin repetir toda la presentación).
enum _PendingKickoff { intro, voice, micOn }

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

  // Detalle interno de orquestación: no forma parte de LiveUiState porque la
  // UI no lo necesita para renderizar.
  int _micChunks = 0; // diagnóstico: chunks de mic enviados
  int _audioInChunks = 0; // diagnóstico: chunks de audio recibidos
  bool _onSpeaker = true; // sin audífonos → altavoz (anti-eco medio-dúplex)
  bool _assistantActive = false; // el asistente está sonando
  bool _assistantTurnDone = false; // terminó el turno (audio puede drenar)
  bool _audioDrained = false; // la cola de reproducción ya se vació
  _PendingKickoff _pendingKickoff = _PendingKickoff.intro;
  int _retryAttempts = 0; // reintentos de conexión consumidos
  bool _everConnected = false; // hubo setupComplete en esta sesión de uso

  @override
  LiveUiState build() {
    _session = ref.read(liveSessionRepositoryProvider);
    _media = ref.read(mediaRepositoryProvider);
    _settings = ref.read(liveSettingsRepositoryProvider);
    ref.onDispose(_teardown);
    return const LiveUiState();
  }

  void _teardown() {
    _media.stopMic();
    _media.stopCamera();
    _media.destroyPlayer();
    _session.disconnect();
  }

  Future<void> connect() async {
    if (state.isLive) return;
    _retryAttempts = 0;
    final granted = await _media.requestPermissions();
    if (!ref.mounted) return;
    if (!granted) {
      state = state.copyWith(status: LiveStatus.error);
      return;
    }
    _openSession(state.language);
  }

  void _openSession(String lang) {
    if (_session.connected) return;
    state = state.copyWith(
      status: LiveStatus.connecting,
      userTranscript: '',
      assistantTranscript: '',
    );

    final voice = _settings.getVoice();
    _session.connect(
      language: lang,
      voice: voice.isEmpty ? null : voice,
      assistantName: _settings.getAssistantName(),
      userName: _settings.getUserName(),
      verbosity: _settings.getVerbosity(),
      describing: _settings.getDescribing(),
      onResponse: _handleResponse,
      onClose: (cause) {
        _log('[Lazarus] sesión cerrada: ${cause.name}');
        if (!ref.mounted) return;
        _teardown();
        _onSessionClosed(cause, lang);
      },
      onError: (e) {
        _log('[Lazarus] error de conexión: $e');
        if (!ref.mounted) return;
        _teardown();
        _retryOrFail(lang);
      },
    );
  }

  void _announce(LiveNotice notice) {
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
      state = state.copyWith(status: LiveStatus.error);
      _announce(LiveNotice.connectionFailed);
      return;
    }
    final delay = ref.read(retryDelayProvider)(_retryAttempts);
    _retryAttempts++;
    state = state.copyWith(status: LiveStatus.connecting);
    _announce(LiveNotice.retrying);
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
        if (_assistantTurnDone) _assistantActive = false;
      });

      _micChunks = 0;
      _audioInChunks = 0;
      await _media.startMic((pcm) {
        // Silencio total (Modo B): no enviar nada hasta reactivar.
        if (state.micMuted) return;
        // En altavoz, no enviar mientras el asistente suena (anti-eco).
        if (_onSpeaker && _assistantActive) return;
        _micChunks++;
        if (_micChunks == 1) _log('[Lazarus] mic: primer chunk enviado');
        if (_micChunks % 50 == 0) _log('[Lazarus] mic: $_micChunks chunks');
        _session.sendAudio(pcm);
      });

      await _media.startCamera((jpeg) {
        // Silencio total (Modo B): tampoco enviar cámara (privacidad).
        if (state.micMuted) return;
        _session.sendImage(jpeg);
      });
      _log('[Lazarus] media activa (mic + cámara)');
    } catch (e) {
      _log('[Lazarus] fallo al arrancar media: $e');
    }
  }

  /// Botón Detener: cierra la sesión; la próxima empieza con la presentación.
  void disconnect() {
    _teardown();
    _everConnected = false;
    _pendingKickoff = _PendingKickoff.intro;
    if (ref.mounted) state = state.copyWith(status: LiveStatus.idle);
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
    if (_session.connected) {
      // Sesión aún viva: reanuda el envío y pide confirmación, sin reconectar.
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
        _retryAttempts = 0;
        _everConnected = true;
        switch (_pendingKickoff) {
          case _PendingKickoff.voice:
            _session.sendVoiceSample();
          case _PendingKickoff.micOn:
            _session.sendMicResumed();
          case _PendingKickoff.intro:
            _session.sendKickoff();
        }
        _pendingKickoff = _PendingKickoff.intro;
        _startMedia();
      case LiveResponseType.inputTranscription:
        final t = message.data as LiveTranscription;
        _log('[Lazarus] te escuché (transcripción): "${t.text}"');
        state = state.copyWith(userTranscript: t.text);
      case LiveResponseType.outputTranscription:
        final t = message.data as LiveTranscription;
        state = state.copyWith(assistantTranscript: t.text);
      case LiveResponseType.toolCall:
        _handleToolCall(message.data as LiveToolCall);
      case LiveResponseType.audio:
        _audioInChunks++;
        if (_audioInChunks == 1) {
          _log(
            '[Lazarus] audio del asistente: primer chunk recibido → reproduciendo',
          );
        }
        // El asistente está sonando → en altavoz, cierra el mic (anti-eco).
        if (!_assistantActive) {
          _log('[Lazarus] asistente: INICIA turno de audio');
        }
        _assistantActive = true;
        _assistantTurnDone = false;
        _audioDrained = false;
        _media.playAudio(message.data as String);
      case LiveResponseType.interrupted:
        _log('[Lazarus] INTERRUMPIDO (barge-in: el usuario habló encima)');
        _assistantActive = false;
        _assistantTurnDone = false;
        _media.interruptPlayback();
      case LiveResponseType.turnComplete:
        // El asistente terminó de generar; el audio aún puede estar drenando.
        // El mic se reabrirá cuando la cola se vacíe (onDrained). Si el
        // drenado llegó primero (respuesta corta), reabre ya mismo.
        _log('[Lazarus] turnComplete (asistente terminó su turno)');
        _assistantTurnDone = true;
        if (_audioDrained) _assistantActive = false;
      case LiveResponseType.text:
      case LiveResponseType.unknown:
        break;
    }
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

    for (final call in toolCall.functionCalls) {
      switch (call.name) {
        case 'set_assistant_name':
          final name = (call.args['name'] ?? '').toString().trim();
          if (name.isNotEmpty) _settings.setAssistantName(name);
        case 'set_user_name':
          final name = (call.args['name'] ?? '').toString().trim();
          if (name.isNotEmpty) _settings.setUserName(name);
        case 'set_voice':
          final voice = (call.args['voice'] ?? '').toString().trim();
          if (voice.isNotEmpty) {
            _settings.setVoice(voice);
            reconnectVoice = true;
          }
        case 'set_language':
          final lang = (call.args['language'] ?? '').toString();
          if (_validLanguages.contains(lang)) reconnectLang = lang;
        case 'set_verbosity':
          final level = (call.args['level'] ?? '').toString();
          if (level == 'concise' || level == 'detailed') {
            _settings.setVerbosity(level);
          }
        case 'set_descriptions':
          _settings.setDescribing(call.args['enabled'] == true);
        case 'set_system_cues':
          // enabled=true => avisos activos => no silenciado.
          _settings.setSystemCuesMuted(call.args['enabled'] != true);
        case 'set_meeting_mode':
          meetingMode = call.args['enabled'] == true;
        case 'set_microphone':
          micActive = call.args['active'] != false;
      }
    }

    // Aplica los modos de silencio (afectan captura y UI). No persisten.
    if (meetingMode != null || micActive != null) {
      state = state.copyWith(
        meetingMode: meetingMode,
        micMuted: micActive != null ? !micActive : null,
      );
    }

    _session.sendToolResponse([
      for (final c in toolCall.functionCalls) (id: c.id, name: c.name),
    ]);

    // Cambiar idioma o voz exige una sesión nueva (ambos se fijan en el setup).
    if (reconnectLang != null || reconnectVoice) {
      final lang = reconnectLang ?? state.language;
      _pendingKickoff = reconnectLang != null
          ? _PendingKickoff.intro
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
