import 'package:app/features/live/domain/entities/live_message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseLiveMessage', () {
    test('setupComplete', () {
      final r = parseLiveMessage({'setupComplete': {}});
      expect(r.type, LiveResponseType.setupComplete);
    });

    test('audio del asistente en base64', () {
      final r = parseLiveMessage({
        'serverContent': {
          'modelTurn': {
            'parts': [
              {
                'inlineData': {'mimeType': 'audio/pcm', 'data': 'AAAA'},
              },
            ],
          },
        },
      });
      expect(r.type, LiveResponseType.audio);
      expect(r.data, 'AAAA');
    });

    test('interrupted tiene prioridad sobre el resto del contenido', () {
      final r = parseLiveMessage({
        'serverContent': {'interrupted': true, 'turnComplete': true},
      });
      expect(r.type, LiveResponseType.interrupted);
      expect(r.endOfTurn, isTrue);
    });

    test('turnComplete', () {
      final r = parseLiveMessage({
        'serverContent': {'turnComplete': true},
      });
      expect(r.type, LiveResponseType.turnComplete);
    });

    test('transcripción de la voz del usuario', () {
      final r = parseLiveMessage({
        'serverContent': {
          'inputTranscription': {'text': 'hola', 'finished': true},
        },
      });
      expect(r.type, LiveResponseType.inputTranscription);
      final t = r.data as LiveTranscription;
      expect(t.text, 'hola');
      expect(t.finished, isTrue);
    });

    test('toolCall con sus funciones y argumentos', () {
      final r = parseLiveMessage({
        'toolCall': {
          'functionCalls': [
            {
              'id': 'c1',
              'name': 'set_voice',
              'args': {'voice': 'Kore'},
            },
          ],
        },
      });
      expect(r.type, LiveResponseType.toolCall);
      final call = (r.data as LiveToolCall).functionCalls.single;
      expect(call.name, 'set_voice');
      expect(call.args['voice'], 'Kore');
    });

    test('frame desconocido', () {
      expect(parseLiveMessage({'otro': 1}).type, LiveResponseType.unknown);
    });
  });
}
