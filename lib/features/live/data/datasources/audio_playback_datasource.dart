/// Reproduce el audio nativo (PCM 16-bit 24 kHz) que devuelve Gemini.
///
/// Usa `flutter_pcm_sound`,
/// que reproduce PCM crudo de baja latencia encolando buffers con `feed`. Los
/// bytes de Gemini ya son PCM 16-bit little-endian → se pasan tal cual.
///
/// Nota: esta versión de `flutter_pcm_sound` no tiene `clear()`/flush; la
/// interrupción (cuando el usuario habla encima) se hace con `release()` +
/// `setup()`, que vacía la cola al reinicializar el motor.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

class AudioPlayer {
  AudioPlayer({this.onDrained});

  static const int sampleRate = 24000; // Gemini emite a 24 kHz

  /// Se invoca cuando la cola de reproducción se vacía (el asistente terminó de
  /// sonar). Lo usa el modo medio-dúplex para reabrir el micrófono en altavoz.
  final void Function()? onDrained;

  bool _initialized = false;
  Future<void>? _resetting;

  Future<void> init() async {
    if (_initialized) return;
    await FlutterPcmSound.setLogLevel(LogLevel.none);
    await FlutterPcmSound.setup(sampleRate: sampleRate, channelCount: 1);
    // El callback se dispara en eventos de buffer; nos interesa el de "vacío"
    // (remainingFrames == 0) = el asistente dejó de sonar.
    FlutterPcmSound.setFeedThreshold(sampleRate ~/ 10); // ~100 ms
    FlutterPcmSound.setFeedCallback((remainingFrames) {
      if (remainingFrames == 0) onDrained?.call();
    });
    _initialized = true;
  }

  /// Encola un chunk de audio (base64 PCM 24 kHz) para reproducción inmediata.
  Future<void> play(String base64Pcm) async {
    if (!_initialized) await init();
    // Espera a que termine un posible reinicio por interrupción en curso.
    if (_resetting != null) await _resetting;
    final Uint8List bytes = base64Decode(base64Pcm);
    await FlutterPcmSound.feed(
      PcmArrayInt16(
        bytes: bytes.buffer.asByteData(
          bytes.offsetInBytes,
          bytes.lengthInBytes,
        ),
      ),
    );
  }

  /// Vacía la cola de reproducción (cuando Gemini es interrumpido). Reinicia el
  /// motor para descartar el audio aún sin reproducir.
  void interrupt() {
    if (!_initialized) return;
    _resetting = _reset();
  }

  Future<void> _reset() async {
    await FlutterPcmSound.release();
    await FlutterPcmSound.setup(sampleRate: sampleRate, channelCount: 1);
    _resetting = null;
  }

  Future<void> destroy() async {
    if (!_initialized) return;
    _initialized = false;
    await FlutterPcmSound.release();
  }
}
