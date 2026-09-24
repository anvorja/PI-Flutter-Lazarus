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

import '../../data/repositories/live_session_repository_impl.dart';
import '../../data/repositories/live_settings_repository_impl.dart';
import '../../data/repositories/media_repository_impl.dart';
import '../../domain/repositories/live_session_repository.dart';
import '../../domain/repositories/live_settings_repository.dart';
import '../../domain/repositories/media_repository.dart';
import '../controllers/live_controller.dart';

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
      final tts = FlutterTts();
      ref.onDispose(tts.stop);
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
              debugPrint('[Lazarus] aviso sin voz: $e');
              return null;
            });
      };
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

final liveControllerProvider = NotifierProvider<LiveController, LiveUiState>(
  LiveController.new,
);
