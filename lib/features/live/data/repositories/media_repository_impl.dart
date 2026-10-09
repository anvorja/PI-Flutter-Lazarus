/// Implementación concreta de [MediaRepository] sobre los data sources de
/// captura/reproducción (`record`, `camera`, `flutter_pcm_sound` y el canal
/// nativo de ruta de audio).
library;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../domain/entities/media_permission.dart';
import '../../domain/repositories/media_repository.dart';
import '../datasources/audio_capture_datasource.dart';
import '../datasources/audio_playback_datasource.dart';
import '../datasources/audio_route_datasource.dart' as audio_route;
import '../datasources/frame_archive.dart';
import '../datasources/video_capture_datasource.dart';
import '../../../../core/debug/live_debug.dart';

class MediaRepositoryImpl implements MediaRepository {
  AudioStreamer? _audioStreamer;
  AudioPlayer? _audioPlayer;
  VideoStreamer? _videoStreamer;

  /// Evidencia de las pruebas: las fotos de los últimos 10 minutos, solo en
  /// depuración. En producción no se guarda ninguna.
  final FrameArchive? _archive = kDebugMode
      ? FrameArchive(getApplicationSupportDirectory)
      : null;
  bool _cacheCleaned = false;

  @override
  Future<MediaAccess> requestPermissions() async {
    // Notificaciones (Android 13+): sin ellas no se ve "Lazarus está activo" ni
    // su botón Detener (HU-017); la sesión funciona igual si se niega.
    final statuses = await [
      Permission.microphone,
      Permission.camera,
      Permission.notification,
    ].request();
    final mic = statuses[Permission.microphone];
    final microphone = mic != null && mic.isGranted
        ? MediaPermission.granted
        : (mic != null && mic.isPermanentlyDenied)
        ? MediaPermission.blocked
        : MediaPermission.denied;
    final camera = statuses[Permission.camera]?.isGranted ?? false;
    return (microphone: microphone, camera: camera);
  }

  @override
  Future<void> openPermissionSettings() => openAppSettings();

  @override
  Future<bool> isHeadsetConnected() => audio_route.isHeadsetConnected();

  @override
  Future<void> startMic(void Function(String base64Pcm) onChunk) async {
    final streamer = AudioStreamer(onChunk);
    _audioStreamer = streamer;
    await streamer.start();
  }

  @override
  Future<void> stopMic() async {
    final streamer = _audioStreamer;
    _audioStreamer = null;
    await streamer?.stop();
  }

  @override
  Future<void> startCamera(
    void Function(String base64Jpeg) onFrame, {
    int fps = 1,
  }) async {
    if (!_cacheCleaned) {
      _cacheCleaned = true;
      final cache = await getTemporaryDirectory();
      final deleted = await deleteLeftoverCaptures(cache);
      if (deleted > 0) {
        liveLog('[Lazarus] cámara: $deleted fotos viejas borradas');
      }
    }
    final streamer = VideoStreamer(onFrame, archive: _archive);
    _videoStreamer = streamer;
    await streamer.start(fps: fps);
  }

  @override
  Future<void> stopCamera() async {
    final streamer = _videoStreamer;
    _videoStreamer = null;
    await streamer?.stop();
  }

  @override
  Future<void> initPlayer(void Function() onDrained) async {
    final player = AudioPlayer(onDrained: onDrained);
    _audioPlayer = player;
    await player.init();
  }

  @override
  Future<void> playAudio(String base64Pcm) async {
    await _audioPlayer?.play(base64Pcm);
  }

  @override
  Future<void> interruptPlayback() async => _audioPlayer?.interrupt();

  @override
  Future<void> destroyPlayer() async {
    final player = _audioPlayer;
    _audioPlayer = null;
    await player?.destroy();
  }
}
