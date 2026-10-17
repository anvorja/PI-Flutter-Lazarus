/// Inyección de dependencias del feature "emergency" (alerta SOS, HU-012). En
/// pruebas se sustituyen por fakes.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../live/presentation/providers/live_providers.dart';
import '../../data/repositories/emergency_repository_impl.dart';
import '../../domain/repositories/emergency_repository.dart';
import '../controllers/sos_controller.dart';

final emergencyRepositoryProvider = Provider<EmergencyRepository>(
  (ref) => EmergencyRepositoryImpl(ref.watch(sharedPreferencesProvider)),
);

/// Cuánto se espera la respuesta a "¿Envío la alerta a…?" antes de enviarla
/// sola (regla 2).
final sosConfirmationWindowProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 5),
);

/// Si la persona habla durante la cuenta, cuánto se espera a que el asistente
/// decida (sí, no) antes de enviarla sola.
final sosAnswerWindowProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 10),
);

/// Tope de la espera cuando la persona habla durante la cuenta (cada vez que
/// habla, la cuenta vuelve a empezar hasta este máximo).
final sosMaxWaitProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 15),
);

/// Tras enviar una alerta, durante este tiempo otra solo se envía si la
/// persona la confirma (nunca sola por silencio).
final sosResendGuardProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 60),
);

/// Si la pregunta nunca llega a sonar (p. ej. el turno se descartó), la cuenta
/// arranca igual pasado este tiempo desde que se pidió la alerta.
final sosQuestionFallbackProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 8),
);

final sosControllerProvider = NotifierProvider<SosController, SosStatus>(
  SosController.new,
);
