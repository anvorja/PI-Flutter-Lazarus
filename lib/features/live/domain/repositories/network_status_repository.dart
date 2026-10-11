/// Estado de la red de datos del teléfono (HU-042): distingue "el teléfono no
/// tiene datos" de "el servidor no responde", para decir el aviso correcto y
/// no gastar reintentos mientras no hay datos.
library;

abstract class NetworkStatusRepository {
  /// `true` si el teléfono tiene alguna red de datos (móviles o Wi-Fi).
  Future<bool> isOnline();

  /// Cambios de estado: emite `false` al quedarse sin datos y `true` al volver.
  Stream<bool> onlineChanges();
}
