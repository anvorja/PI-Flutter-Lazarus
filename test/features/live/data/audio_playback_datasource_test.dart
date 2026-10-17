import 'package:app/features/live/data/datasources/audio_playback_datasource.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_pcm_sound/methods');
  late List<String> calls;
  late Set<String> failing;

  setUp(() {
    calls = [];
    failing = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (failing.contains(call.method)) {
            throw PlatformException(
              code: 'released',
              message: 'motor liberado',
            );
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('reproduce a 24 kHz y la interrupción descarta la cola', () async {
    final player = AudioPlayer();
    await player.play('AAAA');
    calls.clear();

    await player.interrupt();

    expect(calls, ['release', 'setup']);
  });

  test(
    'un fragmento que llega durante la interrupción espera al reinicio',
    () async {
      final player = AudioPlayer();
      await player.init();
      calls.clear();

      final interrupting = player.interrupt();
      final playing = player.play('AAAA');
      await Future.wait([interrupting, playing]);

      expect(calls, ['release', 'setup', 'feed']);
    },
  );

  test(
    'cerrar la sesión con el motor ya liberado no lanza excepciones',
    () async {
      final player = AudioPlayer();
      await player.init();
      failing = {'release', 'feed'};

      final interrupting = player.interrupt();
      await player.destroy();
      await interrupting;
      await player.play('AAAA'); // fragmento tardío tras el cierre

      expect(calls.where((c) => c == 'feed'), isEmpty);
    },
  );
}
