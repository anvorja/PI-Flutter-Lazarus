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
  AudioStreamer(this._onChunk, {AudioRecorder? recorder})
    : _recorder = recorder ?? AudioRecorder();

  final void Function(String base64Pcm) _onChunk;

  static const int sampleRate = 16000; // Gemini requiere 16 kHz

  final AudioRecorder _recorder;
  StreamSubscription<Uint8List>? _sub;
  bool _streaming = false;

  /// `start` está esperando al plugin; si llega un `stop` en ese momento, se
  /// libera el micrófono apenas arranque en lugar de dejarlo capturando.
  bool _starting = false;
  bool _stopRequested = false;

  /// Pide permiso de micrófono (lo solicita si aún no está concedido).
  Future<bool> hasPermission() => _recorder.hasPermission();

  Future<void> start() async {
    if (_streaming || _starting) return;
    _starting = true;
    _stopRequested = false;
    final Stream<Uint8List> stream;
    try {
      stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: sampleRate,
          numChannels: 1,
          echoCancel: true,
          noiseSuppress: true,
          autoGain: true,
        ),
      );
    } finally {
      _starting = false;
    }
    if (_stopRequested) {
      await _release();
      return;
    }
    _streaming = true;
    _sub = stream.listen((chunk) {
      if (!_streaming || chunk.isEmpty) return;
      _onChunk(base64Encode(chunk));
    });
  }

  Future<void> stop() async {
    if (_starting) {
      _stopRequested = true;
      return;
    }
    if (!_streaming && _sub == null) return; // ya detenido: evita doble dispose
    _streaming = false;
    await _sub?.cancel();
    _sub = null;
    await _release();
  }

  Future<void> _release() async {
    try {
      await _recorder.stop();
      await _recorder.dispose();
    } catch (_) {
      // El recorder pudo haberse soltado ya (p. ej. doble teardown al cerrar la
      // sesión); ignoramos el PlatformException para no romper el cierre.
    }
  }
}
