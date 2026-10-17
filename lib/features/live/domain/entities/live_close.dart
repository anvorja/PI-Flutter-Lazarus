/// Causa por la que terminó una sesión Live, según el código de cierre que envía
/// el backend. La app la usa para decidir si reconecta sola o avisa a la persona.
library;

enum LiveCloseCause {
  /// Gemini terminó la sesión de forma ordenada (p. ej. al llegar al límite de duración).
  upstreamEnded,

  /// Falló la red o la conexión con Gemini.
  upstreamError,

  /// Se agotó la cuota del servicio de IA.
  quotaExceeded,

  /// El servidor no está configurado (sin API key).
  serverMisconfigured,

  /// El proyecto del servicio de IA se quedó sin saldo: no se arregla
  /// reintentando, alguien tiene que recargarlo.
  billingExhausted,

  /// Quien administra las pruebas puso el servicio en pausa (fuera de las
  /// jornadas de campo, para no gastar saldo).
  servicePaused,

  /// Control de acceso del piloto (HU-044): el teléfono espera aprobación,
  /// está deshabilitado, agotó sus minutos del día o el panel cerró la sesión.
  devicePending,
  deviceDisabled,
  dailyLimit,
  closedByAdmin,

  /// La app envió un primer frame inválido o tardó demasiado.
  protocolError,

  /// Cierre sin código conocido (p. ej. se cayó el socket).
  unknown,
}

/// Traduce el código de cierre del WebSocket a una [LiveCloseCause].
LiveCloseCause liveCloseCauseFromCode(int? code) => switch (code) {
  4001 => LiveCloseCause.upstreamEnded,
  4002 => LiveCloseCause.upstreamError,
  4003 => LiveCloseCause.quotaExceeded,
  4004 => LiveCloseCause.serverMisconfigured,
  4005 => LiveCloseCause.billingExhausted,
  4006 => LiveCloseCause.servicePaused,
  4007 => LiveCloseCause.devicePending,
  4008 => LiveCloseCause.deviceDisabled,
  4009 => LiveCloseCause.dailyLimit,
  4010 => LiveCloseCause.closedByAdmin,
  1008 => LiveCloseCause.protocolError,
  _ => LiveCloseCause.unknown,
};
