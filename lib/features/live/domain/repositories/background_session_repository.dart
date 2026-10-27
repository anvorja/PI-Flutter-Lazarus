/// Contrato del funcionamiento con la pantalla bloqueada (HU-017).
///
/// Mientras dura la sesión, un servicio en primer plano de Android evita que el
/// sistema suspenda la app: siguen el micrófono, el audio, el GPS y la conexión
/// con el asistente. El controller decide *cuándo* arrancarlo y detenerlo; este
/// contrato no sabe nada de canales nativos ni notificaciones.
library;

/// Si Lazarus ya está excluida de la optimización de batería y la marca del
/// teléfono (en minúsculas), para dar la instrucción del fabricante.
typedef BatteryStatus = ({bool exempt, String manufacturer});

/// Cómo terminó la última vez el proceso de la app, según Android (11+).
/// `kind`: `system` (memoria baja u otro cierre del sistema), `user`, `crash` u
/// `other`; `reason` es el código de Android y `at`, la hora del cierre.
typedef ProcessExit = ({
  String kind,
  int reason,
  String description,
  DateTime at,
});

abstract class BackgroundSessionRepository {
  /// Arranca el servicio con su notificación "Lazarus está activo". `false` si
  /// Android no lo permitió (p. ej. la app ya no estaba visible).
  Future<bool> start();

  /// Detiene el servicio y quita la notificación.
  Future<void> stop();

  /// La persona pulsó "Detener" en la notificación.
  void onStopRequested(void Function() callback);

  Future<BatteryStatus> batteryStatus();

  /// Abre el diálogo del sistema para excluir a Lazarus de la optimización de
  /// batería; termina cuando la persona lo cierra (`true` si quedó excluida).
  Future<bool> requestBatteryExemption();

  /// El último cierre del proceso, o `null` si Android no lo informa.
  Future<ProcessExit?> lastExit();
}
