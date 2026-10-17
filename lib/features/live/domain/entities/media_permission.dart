/// Resultado de pedir los permisos de micrófono y cámara.
library;

enum MediaPermission {
  /// Ambos concedidos.
  granted,

  /// Alguno negado; se puede volver a pedir.
  denied,

  /// Alguno negado de forma permanente: solo se activa desde los ajustes.
  blocked,
}

/// Permisos de la sesión: el micrófono es obligatorio; sin cámara la sesión sigue
/// en modo solo audio.
typedef MediaAccess = ({MediaPermission microphone, bool camera});
