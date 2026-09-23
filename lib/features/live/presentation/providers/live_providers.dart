/// Inyección de dependencias del feature "live" (equivalente a `auth_providers.dart`
/// en el manual de arquitectura): conecta datasources, repositories y el
/// controller. Los widgets nunca instancian nada de esto directamente, solo
/// leen/observan estos providers.
library;

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

/// Aviso hablado para la persona usuaria cuando no hay asistente que hable (p. ej.
/// sin conexión con el backend). Lo lee el lector de pantalla y va acompañado de
/// una vibración. En pruebas se sustituye por un fake que registra los avisos.
final announcerProvider = Provider<void Function(String message)>((ref) {
  return (message) {
    HapticFeedback.heavyImpact();
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view != null) {
      SemanticsService.sendAnnouncement(
        view,
        message,
        TextDirection.ltr,
        assertiveness: Assertiveness.assertive,
      );
    }
  };
});

/// Espera antes del reintento número [attempt] (0, 1, 2…): 1 s, 2 s, 4 s.
final retryDelayProvider = Provider<Duration Function(int attempt)>((ref) {
  return (attempt) => Duration(seconds: 1 << attempt);
});

final liveControllerProvider = NotifierProvider<LiveController, LiveUiState>(
  LiveController.new,
);
