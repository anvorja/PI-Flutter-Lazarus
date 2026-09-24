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

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

class AudioPlayer {
  AudioPlayer({this.onDrained});

  static const int sampleRate = 24000; // Gemini emite a 24 kHz

  /// Se invoca cuando la cola de reproducción se vacía (el asistente terminó de
  /// sonar). Lo usa el modo medio-dúplex para reabrir el micrófono en altavoz.
  final void Function()? onDrained;

  bool _initialized = false;
  bool _destroyed = false; // tras cerrar la sesión no se vuelve a inicializar
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
    if (_destroyed) return;
    if (!_initialized) await init();
    // Espera a que termine un posible reinicio por interrupción en curso.
    if (_resetting != null) await _resetting;
    // La sesión pudo cerrarse mientras tanto: no se alimenta un motor liberado.
    if (!_initialized) return;
    final Uint8List bytes = base64Decode(base64Pcm);
    await _guard(
      'feed',
      () => FlutterPcmSound.feed(
        PcmArrayInt16(
          bytes: bytes.buffer.asByteData(
            bytes.offsetInBytes,
            bytes.lengthInBytes,
          ),
        ),
      ),
    );
  }

  /// Vacía la cola de reproducción (cuando Gemini es interrumpido). Reinicia el
  /// motor para descartar el audio aún sin reproducir; termina cuando el audio
  /// pendiente ya se descartó.
  Future<void> interrupt() {
    if (!_initialized) return Future.value();
    return _resetting ??= _reset();
  }

  Future<void> _reset() async {
    await _guard('release', FlutterPcmSound.release);
    if (_initialized) {
      await _guard(
        'setup',
        () => FlutterPcmSound.setup(sampleRate: sampleRate, channelCount: 1),
      );
    }
    _resetting = null;
  }

  Future<void> destroy() async {
    _destroyed = true;
    if (!_initialized) return;
    _initialized = false;
    if (_resetting != null) await _resetting;
    await _guard('release', FlutterPcmSound.release);
  }

  /// El motor nativo puede estar ya liberado (cierre durante una interrupción o
  /// un chunk tardío); el error se registra y no rompe el cierre de la sesión.
  Future<void> _guard(String op, Future<void> Function() call) async {
    try {
      await call();
    } on PlatformException catch (e) {
      debugPrint('[Lazarus] reproductor ($op): ${e.message}');
    }
  }
}
