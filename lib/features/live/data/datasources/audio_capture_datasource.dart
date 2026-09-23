/// Captura audio del micrófono a 16 kHz y emite chunks PCM 16-bit en base64.
///
/// El paquete `record`
/// entrega ya PCM 16-bit little-endian crudo vía `startStream`, así que solo hay
/// que codificar a base64 (la conversión a Int16 la hace el plugin).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:record/record.dart';

class AudioStreamer {
  AudioStreamer(this._onChunk);

  final void Function(String base64Pcm) _onChunk;

  static const int sampleRate = 16000; // Gemini requiere 16 kHz

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  bool _streaming = false;

  /// Pide permiso de micrófono (lo solicita si aún no está concedido).
  Future<bool> hasPermission() => _recorder.hasPermission();

  Future<void> start() async {
    if (_streaming) return;
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        echoCancel: true,
        noiseSuppress: true,
        autoGain: true,
      ),
    );
    _streaming = true;
    _sub = stream.listen((chunk) {
      if (!_streaming || chunk.isEmpty) return;
      _onChunk(base64Encode(chunk));
    });
  }

  Future<void> stop() async {
    if (!_streaming && _sub == null) return; // ya detenido: evita doble dispose
    _streaming = false;
    await _sub?.cancel();
    _sub = null;
    try {
      await _recorder.stop();
      await _recorder.dispose();
    } catch (_) {
      // El recorder pudo haberse soltado ya (p. ej. doble teardown al cerrar la
      // sesión); ignoramos el PlatformException para no romper el cierre.
    }
  }
}
