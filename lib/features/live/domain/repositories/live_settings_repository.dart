/// Contrato de la personalización persistente del asistente.
///
/// No dice nada sobre `SharedPreferences`, `Hive` o cualquier otro mecanismo de
/// persistencia: eso es responsabilidad de la implementación concreta
/// (`LiveSettingsRepositoryImpl`). El controller y la UI solo conocen esta API.
library;

abstract class LiveSettingsRepository {
  String getAssistantName();
  Future<void> setAssistantName(String name);

  /// Nombre de la persona usuaria (vacío si aún no lo ha dicho).
  String getUserName();
  Future<void> setUserName(String name);

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
}
