/// Contrato de acceso a los dispositivos de captura/reproducción (micrófono,
/// cámara, altavoz y ruta de audio).
///
/// El controller decide *cuándo* enviar mic/cámara (anti-eco, silencio total,
/// etc.); este contrato solo decide *cómo* hablar con el hardware. No sabe nada
/// de `record`, `camera` ni `flutter_pcm_sound`: eso vive en las implementaciones
/// concretas dentro de `data/datasources`.
library;

import '../entities/media_permission.dart';

abstract class MediaRepository {
  /// Pide permisos de micrófono y cámara.
  Future<MediaPermission> requestPermissions();

  /// Abre los ajustes de la app (permisos negados de forma permanente).
  Future<void> openPermissionSettings();

  /// `true` si hay audífonos/auriculares conectados (define full-duplex vs
  /// medio-dúplex).
  Future<bool> isHeadsetConnected();

  Future<void> startMic(void Function(String base64Pcm) onChunk);
  Future<void> stopMic();

  Future<void> startCamera(void Function(String base64Jpeg) onFrame, {int fps});
  Future<void> stopCamera();

  /// Inicializa la reproducción de audio nativo. [onDrained] se invoca cuando
  /// la cola de reproducción se vacía (el asistente dejó de sonar).
  Future<void> initPlayer(void Function() onDrained);

  /// Encola un chunk de audio (base64 PCM) del asistente para reproducción.
  Future<void> playAudio(String base64Pcm);

  /// Vacía la cola de reproducción (barge-in: el usuario interrumpió al
  /// asistente). Termina cuando el audio pendiente ya se descartó.
  Future<void> interruptPlayback();

  Future<void> destroyPlayer();
}
