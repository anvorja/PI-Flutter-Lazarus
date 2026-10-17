/// Telemetría de sesión (HU-015): eventos y latencias en JSON, una línea por
/// evento, en `telemetry.jsonl` (carpeta de la evidencia de campo). No lleva
/// audio, imágenes ni texto de la persona ni del asistente: solo tipos de
/// evento, nombres de función, códigos de cierre y tiempos.
///
///   adb pull /sdcard/Android/data/com.lazarus.app/files/telemetry.jsonl
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

const String telemetryFileName = 'telemetry.jsonl';

/// Destino de los eventos (archivo en el teléfono; en pruebas, una lista).
typedef TelemetrySink = void Function(Map<String, Object?> event);

/// Archivo con rotación: al pasar [maxBytes] queda como `.1` y empieza otro.
TelemetrySink fileTelemetrySink(File file, {int maxBytes = 1024 * 1024}) {
  return (event) {
    try {
      if (file.existsSync() && file.lengthSync() > maxBytes) {
        file.renameSync('${file.path}.1');
      }
      file.writeAsStringSync(
        '${jsonEncode(event)}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Sin espacio o sin acceso: la telemetría no debe tumbar la app.
    }
  };
}

class SessionTelemetry {
  SessionTelemetry(this._sink, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final TelemetrySink _sink;
  final DateTime Function() _clock;
  final List<int> _latenciesMs = [];

  /// Latencias voz a voz de la sesión en curso (ms).
  List<int> get latenciesMs => List.unmodifiable(_latenciesMs);

  void event(String type, [Map<String, Object?> fields = const {}]) {
    _sink({'t': _clock().toIso8601String(), 'event': type, ...fields});
  }

  /// Del fin de la voz de la persona al primer audio de la respuesta.
  void voiceToVoice(int ms) {
    _latenciesMs.add(ms);
    event('latency', {'kind': 'voice_to_voice', 'ms': ms});
  }

  /// Cierra la sesión con su resumen (mediana y percentil 90) y lo devuelve.
  LatencySummary endSession(String reason) {
    final summary = LatencySummary.of(_latenciesMs);
    event('session_end', {'reason': reason, ...summary.toJson()});
    _latenciesMs.clear();
    return summary;
  }
}

class LatencySummary {
  const LatencySummary(this.count, this.medianMs, this.p90Ms);

  /// Mediana y percentil 90 por el método del rango más cercano.
  factory LatencySummary.of(List<int> values) {
    if (values.isEmpty) return const LatencySummary(0, null, null);
    final sorted = [...values]..sort();
    int rank(double p) =>
        sorted[((p * sorted.length).ceil() - 1).clamp(0, sorted.length - 1)];
    return LatencySummary(sorted.length, rank(0.5), rank(0.9));
  }

  final int count;
  final int? medianMs;
  final int? p90Ms;

  Map<String, Object?> toJson() => {
    'latency_count': count,
    'latency_median_ms': medianMs,
    'latency_p90_ms': p90Ms,
  };
}

/// Nivel RMS de un fragmento PCM de 16 bits (0 = silencio, 1 = máximo).
double pcm16Level(List<int> bytes) {
  if (bytes.length < 2) return 0;
  var sum = 0.0;
  final n = bytes.length ~/ 2;
  for (var i = 0; i < n; i++) {
    var v = bytes[2 * i] | (bytes[2 * i + 1] << 8);
    if (v >= 0x8000) v -= 0x10000;
    sum += v * v;
  }
  return (math.sqrt(sum / n) / 32768.0).clamp(0, 1).toDouble();
}
