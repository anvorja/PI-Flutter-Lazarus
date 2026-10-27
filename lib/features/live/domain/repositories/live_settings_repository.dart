/// Contrato de la personalización persistente del asistente.
///
/// No dice nada sobre `SharedPreferences`, `Hive` o cualquier otro mecanismo de
/// persistencia: eso es responsabilidad de la implementación concreta
/// (`LiveSettingsRepositoryImpl`). El controller y la UI solo conocen esta API.
library;

/// Idiomas de la app (deben coincidir con los del backend). Español por defecto.
const Set<String> liveLanguages = {'es', 'en', 'fr', 'pt', 'it'};
const String defaultLanguage = 'es';

/// Voces prebuilt de Gemini Live disponibles (deben coincidir con el enum del
/// backend en `live_service.set_voice`). Vacío = voz por defecto del backend.
const List<String> liveVoices = [
  'Charon',
  'Puck',
  'Kore',
  'Fenrir',
  'Aoede',
  'Leda',
  'Orus',
  'Zephyr',
];

abstract class LiveSettingsRepository {
  String getAssistantName();
  Future<void> setAssistantName(String name);

  /// Nombre de la persona usuaria (vacío si aún no lo ha dicho).
  String getUserName();
  Future<void> setUserName(String name);

  /// Idioma de la sesión (`es` por defecto). Solo cambia por comando de voz.
  String getLanguage();
  Future<void> setLanguage(String language);

  /// Voz elegida (vacío = el backend usa su voz por defecto).
  String getVoice();
  Future<void> setVoice(String voice);

  /// Nivel de detalle (`concise` | `detailed`).
  String getVerbosity();
  Future<void> setVerbosity(String level);

  /// Si las descripciones automáticas del entorno están activas.
  bool getDescribing();
  Future<void> setDescribing(bool enabled);

  /// Si los avisos del sistema están silenciados.
  bool getSystemCuesMuted();
  Future<void> setSystemCuesMuted(bool muted);

  /// Si ya se pidió excluir a Lazarus de la optimización de batería (HU-017).
  /// Se vuelve a pedir solo si Android cerró la app en una sesión.
  bool getBatteryExemptionAsked();
  Future<void> setBatteryExemptionAsked();

  /// Cuándo empezó la sesión que sigue abierta; Detener lo borra (`null`). Si
  /// al volver queda una hora y Android cerró la app después, esa sesión no
  /// terminó con Detener (HU-017).
  DateTime? getLastSessionStart();
  Future<void> setLastSessionStart(DateTime? at);
}
