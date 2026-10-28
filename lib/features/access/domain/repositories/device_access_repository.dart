/// Acceso del teléfono al piloto (HU-044 y HU-045): el registro en el panel,
/// su estado, la subida de los logs de campo y los perfiles de ruta (HU-022).
library;

abstract class DeviceAccessRepository {
  /// Token ya guardado, sin red: la sesión no espera al registro.
  String? get savedToken;

  /// Token del teléfono; lo registra la primera vez. `null` si no se pudo
  /// (sin red o con un backend anterior): la sesión sigue sin él.
  Future<String?> token();

  /// El servidor cerró la sesión como "pendiente": si el panel ya no conoce
  /// este teléfono (p. ej. se eliminó), lo registra de nuevo ya, para que
  /// aparezca en el panel sin tener que tocar Detener e iniciar otra vez.
  Future<void> registerAgainIfUnknown();

  /// ¿El panel pidió subir los logs? `false` si no se sabe.
  Future<bool> uploadRequested();

  /// Sube lo nuevo de cada archivo de evidencia desde la última subida.
  /// Devuelve cuántos archivos subió (0 si no había nada o falló).
  Future<int> uploadLogs();

  /// Perfiles de ruta curados en JSON (HU-022). Sin red, los últimos que se
  /// descargaron; `null` si nunca se descargó ninguno.
  Future<String?> routeProfiles();
}
