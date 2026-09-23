/// Implementación concreta de [MediaRepository] sobre los data sources de
/// captura/reproducción (`record`, `camera`, `flutter_pcm_sound` y el canal
/// nativo de ruta de audio).
library;

import 'package:permission_handler/permission_handler.dart';

import '../../domain/repositories/media_repository.dart';
import '../datasources/audio_capture_datasource.dart';
import '../datasources/audio_playback_datasource.dart';
import '../datasources/audio_route_datasource.dart' as audio_route;
import '../datasources/video_capture_datasource.dart';

class MediaRepositoryImpl implements MediaRepository {
  AudioStreamer? _audioStreamer;
  AudioPlayer? _audioPlayer;
  VideoStreamer? _videoStreamer;

  @override
  Future<bool> requestPermissions() async {
    final statuses = await [Permission.microphone, Permission.camera].request();
    return statuses.values.every((s) => s.isGranted);
  }

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
    final streamer = VideoStreamer(onFrame);
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
  void interruptPlayback() => _audioPlayer?.interrupt();

  @override
  Future<void> destroyPlayer() async {
    final player = _audioPlayer;
    _audioPlayer = null;
    await player?.destroy();
  }
}
