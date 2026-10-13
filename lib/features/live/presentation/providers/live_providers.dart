/// Inyección de dependencias del feature "live" (equivalente a `auth_providers.dart`
/// en el manual de arquitectura): conecta datasources, repositories y el
/// controller. Los widgets nunca instancian nada de esto directamente, solo
/// leen/observan estos providers.
library;

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/repositories/background_session_repository_impl.dart';
import '../../data/repositories/live_session_repository_impl.dart';
import '../../data/repositories/live_settings_repository_impl.dart';
import '../../data/repositories/media_repository_impl.dart';
import '../../data/repositories/network_status_repository_impl.dart';
import '../../domain/repositories/background_session_repository.dart';
import '../../domain/repositories/live_session_repository.dart';
import '../../domain/repositories/live_settings_repository.dart';
import '../../domain/repositories/media_repository.dart';
import '../../domain/repositories/network_status_repository.dart';
import '../controllers/live_controller.dart';
import '../../../../core/debug/live_debug.dart';
import '../../../../core/telemetry/session_telemetry.dart';

/// La instancia de `SharedPreferences` ya cargada. Debe sobrescribirse en
/// `main()` con `overrideWithValue` una vez resuelto el `Future` inicial
/// (ver sección 9 del manual de arquitectura: mismo mecanismo que usan los
/// tests para inyectar fakes).
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError(
    'sharedPreferencesProvider debe sobrescribirse en main() con overrideWithValue',
  );
});

final liveSettingsRepositoryProvider = Provider<LiveSettingsRepository>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return LiveSettingsRepositoryImpl(prefs);
});

final liveSessionRepositoryProvider = Provider<LiveSessionRepository>((ref) {
  return LiveSessionRepositoryImpl();
});

final mediaRepositoryProvider = Provider<MediaRepository>((ref) {
  return MediaRepositoryImpl();
});

/// Estado de la red de datos del teléfono (HU-042).
final networkStatusRepositoryProvider = Provider<NetworkStatusRepository>(
  (ref) => NetworkStatusRepositoryImpl(),
);

/// Cada cuánto se recuerda que sigue sin datos (HU-042, regla 5).
final offlineReminderProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 90),
);

/// Cuánto hay que mantener presionada la pantalla para el SOS (HU-042): un
/// toque normal, o uno largo sin querer, no lo inicia.
final sosGestureHoldProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 3),
);

/// Tiempo desde la pregunta del SOS por gesto hasta que se envía sola: la
/// frase dura unos 7 s y luego quedan los 5 s de HU-012.
final sosGestureWindowProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 12),
);

/// Tras un SOS por gesto, espera antes de reconectar para que el aviso del
/// resultado no se solape con el asistente.
final sosResumeDelayProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 8),
);

/// Servicio en primer plano para seguir con la pantalla bloqueada (HU-017).
final backgroundSessionRepositoryProvider =
    Provider<BackgroundSessionRepository>((ref) {
      return BackgroundSessionRepositoryImpl();
    });

/// Voces de la síntesis del sistema por idioma de la app.
const _ttsLocales = {
  'es': 'es-ES',
  'en': 'en-US',
  'fr': 'fr-FR',
  'pt': 'pt-BR',
  'it': 'it-IT',
};

/// Aviso hablado para la persona usuaria cuando no hay asistente que hable (p. ej.
/// sin conexión con el backend), acompañado de una vibración. Con TalkBack activo
/// lo lee el lector de pantalla; sin él, la síntesis de voz del teléfono, para que
/// el aviso se oiga siempre. En pruebas se sustituye por un fake que lo registra.
final announcerProvider =
    Provider<void Function(String message, String language)>((ref) {
      final tts = ref.watch(_systemTtsProvider);
      return (message, language) {
        HapticFeedback.heavyImpact();
        final dispatcher = WidgetsBinding.instance.platformDispatcher;
        final view = dispatcher.implicitView;
        if (dispatcher.accessibilityFeatures.accessibleNavigation &&
            view != null) {
          SemanticsService.sendAnnouncement(
            view,
            message,
            TextDirection.ltr,
            assertiveness: Assertiveness.assertive,
          );
          return;
        }
        tts
            .setLanguage(_ttsLocales[language] ?? _ttsLocales['es']!)
            .then((_) => tts.speak(message))
            .catchError((Object e) {
              liveLog('[Lazarus] aviso sin voz: $e');
              return null;
            });
      };
    });

/// Síntesis de voz del teléfono, compartida por el aviso y su corte.
final _systemTtsProvider = Provider<FlutterTts>((ref) {
  final tts = FlutterTts();
  ref.onDispose(tts.stop);
  return tts;
});

/// Corta el aviso del teléfono que siga sonando. Se usa al abrir el micrófono
/// de una sesión nueva: si no, el asistente oye el aviso (p. ej. el de sin datos
/// al volver la conexión) como si lo dijera la persona.
final announcerStopProvider = Provider<void Function()>((ref) {
  final tts = ref.watch(_systemTtsProvider);
  return () => tts.stop().catchError((Object e) {
    liveLog('[Lazarus] aviso: no se pudo cortar: $e');
    return null;
  });
});

/// Espera antes del reintento número [attempt] (0, 1, 2…): 1 s, 2 s, 4 s.
final retryDelayProvider = Provider<Duration Function(int attempt)>((ref) {
  return (attempt) => Duration(seconds: 1 << attempt);
});

/// Margen de la red de seguridad del medio-dúplex: tras `turnComplete`, si no
/// llega el aviso de fin del audio, el micrófono se reabre cuando pasa la
/// duración estimada del audio pendiente más este margen.
final drainFallbackMarginProvider = Provider<Duration>(
  (ref) => const Duration(milliseconds: 1500),
);

/// Telemetría de sesión (HU-015): eventos y latencias sin contenido de la
/// persona. En la app va a `files/telemetry.jsonl` (ver `main.dart`); por
/// defecto, en pruebas, no se escribe en ningún lado.
final sessionTelemetryProvider = Provider<SessionTelemetry>(
  (ref) => SessionTelemetry((_) {}),
);

/// Nivel RMS del micrófono a partir del cual se considera que la persona habla
/// (para medir la latencia voz a voz).
final voiceLevelThresholdProvider = Provider<double>((ref) => 0.04);

/// Ciclo de observación (HU-040): cada cuánto, con todos callados, la app le
/// pide al asistente que mire la imagen y avise si hay un riesgo.
/// 2 s: en la prueba del 6 de octubre, con 3 s más la respuesta (≈ 2,7 s) un
/// aviso llegaba hasta 7 s después de que el obstáculo apareció en la cámara.
final observePeriodProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 2),
);

/// Tras la voz de la persona, cuánto se espera su respuesta antes de volver a
/// observar. `[OBSERVA]` cuenta como actividad para Gemini: enviado mientras el
/// asistente prepara una respuesta, la interrumpe (prueba del 6 de octubre:
/// "vuelve a describir" quedó cortado y sin aplicar). La latencia voz a voz
/// medida llegó a 6 s.
final observeReplyWaitProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 12),
);

/// Pausa tras una respuesta a la persona antes de volver a observar: suele
/// seguir hablando (en la prueba, preguntas seguidas por la licuadora).
final observeAfterReplyProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 4),
);

/// Si tras un `[OBSERVA]` el asistente no responde en este tiempo, calló.
final observeTimeoutProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 8),
);

/// Espera tras desbloquear la pantalla antes de volver a la sesión con cámara
/// (HU-017): un desbloqueo sin querer en el bolsillo no corta la conversación.
final cameraUnlockDelayProvider = Provider<Duration>(
  (ref) => const Duration(milliseconds: 1500),
);

/// Reloj del teléfono para `get_time` (LAZA-115); en pruebas se fija la hora.
final liveClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

final liveControllerProvider = NotifierProvider<LiveController, LiveUiState>(
  LiveController.new,
);
