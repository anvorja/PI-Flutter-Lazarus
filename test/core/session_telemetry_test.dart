/// HU-015: telemetría de sesión sin contenido de la persona.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/core/telemetry/session_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mediana y percentil 90 por rango más cercano', () {
    final s = LatencySummary.of([
      900,
      700,
      1200,
      800,
      1000,
      650,
      1500,
      720,
      880,
      950,
    ]);
    expect(s.count, 10);
    expect(s.medianMs, 880);
    expect(s.p90Ms, 1200);
    expect(LatencySummary.of([]).medianMs, isNull);
  });

  test('cierra la sesión con su resumen y empieza de cero', () {
    final events = <Map<String, Object?>>[];
    final t = SessionTelemetry(events.add, clock: () => DateTime(2026, 10, 6));
    t.voiceToVoice(800);
    t.voiceToVoice(1200);
    final s = t.endSession('stopped');
    expect(s.count, 2);
    expect(events.last['event'], 'session_end');
    expect(events.last['latency_median_ms'], 800);
    expect(t.latenciesMs, isEmpty);
  });

  test('escribe una línea JSON por evento y rota el archivo', () {
    final dir = Directory.systemTemp.createTempSync('lazarus_tel_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/$telemetryFileName');
    final sink = fileTelemetrySink(file, maxBytes: 40);
    sink({'event': 'turn_complete'});
    sink({'event': 'interrupted'});
    sink({'event': 'turn_complete'});
    expect(File('${file.path}.1').existsSync(), isTrue);
    for (final line in file.readAsLinesSync()) {
      expect(jsonDecode(line), isA<Map<String, dynamic>>());
    }
  });

  test('nivel de voz: silencio 0, señal fuerte cerca de 1', () {
    final silence = Uint8List(320);
    final loud = Uint8List(320);
    for (var i = 0; i < 160; i++) {
      loud[2 * i] = 0xFF; // 0x7FFF
      loud[2 * i + 1] = 0x7F;
    }
    expect(pcm16Level(silence), 0);
    expect(pcm16Level(loud), greaterThan(0.99));
  });
}
