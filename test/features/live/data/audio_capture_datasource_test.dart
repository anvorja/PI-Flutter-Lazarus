import 'dart:async';
import 'dart:typed_data';

import 'package:app/features/live/data/datasources/audio_capture_datasource.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';

/// Grabadora simulada: `startStream` tarda lo que diga la prueba.
class FakeRecorder implements AudioRecorder {
  final started = Completer<void>();
  final chunks = StreamController<Uint8List>();
  RecordConfig? config;
  int stops = 0;
  int disposes = 0;

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    this.config = config;
    await started.future;
    return chunks.stream;
  }

  @override
  Future<String?> stop() async {
    stops++;
    return null;
  }

  @override
  Future<void> dispose() async => disposes++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('captura PCM 16 bits, 16 kHz, mono y envía cada fragmento', () async {
    final recorder = FakeRecorder()..started.complete();
    final sent = <String>[];
    final streamer = AudioStreamer(sent.add, recorder: recorder);

    await streamer.start();
    recorder.chunks.add(Uint8List.fromList([1, 2, 3, 4]));
    await Future<void>.delayed(Duration.zero);

    expect(recorder.config!.encoder, AudioEncoder.pcm16bits);
    expect(recorder.config!.sampleRate, 16000);
    expect(recorder.config!.numChannels, 1);
    expect(sent, ['AQIDBA==']);

    await streamer.stop();
    expect(recorder.stops, 1);
    expect(recorder.disposes, 1);
  });

  test('detener mientras el micrófono arranca no lo deja capturando', () async {
    final recorder = FakeRecorder();
    final sent = <String>[];
    final streamer = AudioStreamer(sent.add, recorder: recorder);

    final starting = streamer.start();
    await streamer.stop(); // la sesión se cierra antes de que arranque
    recorder.started.complete();
    await starting;

    recorder.chunks.add(Uint8List.fromList([1, 2]));
    await Future<void>.delayed(Duration.zero);

    expect(recorder.stops, 1);
    expect(recorder.disposes, 1);
    expect(sent, isEmpty);
  });
}
