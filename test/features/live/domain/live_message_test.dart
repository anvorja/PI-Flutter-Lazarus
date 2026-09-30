import 'package:app/features/live/domain/entities/live_message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseLiveMessages', () {
    List<LiveResponseType> types(Map<String, dynamic> raw) =>
        parseLiveMessages(raw).map((r) => r.type).toList();

    test('setupComplete', () {
      expect(types({'setupComplete': {}}), [LiveResponseType.setupComplete]);
    });

    test('audio del asistente en base64', () {
      final r = parseLiveMessages({
        'serverContent': {
          'modelTurn': {
            'parts': [
              {
                'inlineData': {'mimeType': 'audio/pcm', 'data': 'AAAA'},
              },
            ],
          },
        },
      }).single;
      expect(r.type, LiveResponseType.audio);
      expect(r.data, 'AAAA');
    });

    test('interrupted descarta el contenido del asistente de ese frame', () {
      final r = parseLiveMessages({
        'serverContent': {
          'interrupted': true,
          'turnComplete': true,
          'modelTurn': {
            'parts': [
              {
                'inlineData': {'data': 'AAAA'},
              },
            ],
          },
        },
      });
      expect(r.map((e) => e.type), [LiveResponseType.interrupted]);
      expect(r.single.endOfTurn, isTrue);
    });

    test('turnComplete', () {
      expect(
        types({
          'serverContent': {'turnComplete': true},
        }),
        [LiveResponseType.turnComplete],
      );
    });

    test('transcripción de la voz del usuario', () {
      final t =
          parseLiveMessages({
                'serverContent': {
                  'inputTranscription': {'text': 'hola', 'finished': true},
                },
              }).single.data
              as LiveTranscription;
      expect(t.text, 'hola');
      expect(t.finished, isTrue);
    });

    test('toolCall con sus funciones y argumentos', () {
      final r = parseLiveMessages({
        'toolCall': {
          'functionCalls': [
            {
              'id': 'c1',
              'name': 'set_voice',
              'args': {'voice': 'Kore'},
            },
          ],
        },
      }).single;
      expect(r.type, LiveResponseType.toolCall);
      final call = (r.data as LiveToolCall).functionCalls.single;
      expect(call.name, 'set_voice');
      expect(call.args['voice'], 'Kore');
    });

    test('frame desconocido', () {
      expect(types({'otro': 1}), [LiveResponseType.unknown]);
    });

    // CP-LAZA-37: el "Entendido." se vio en el log pero no sonó.
    test('transcripción y audio en el mismo frame: llegan los dos', () {
      final r = parseLiveMessages({
        'serverContent': {
          'outputTranscription': {'text': 'Entendido.'},
          'modelTurn': {
            'parts': [
              {
                'inlineData': {'data': 'AAAA'},
              },
              {
                'inlineData': {'data': 'BBBB'},
              },
            ],
          },
          'turnComplete': true,
        },
      });
      expect(r.map((e) => e.type), [
        LiveResponseType.audio,
        LiveResponseType.audio,
        LiveResponseType.outputTranscription,
        LiveResponseType.turnComplete,
      ]);
      expect(r.take(2).map((e) => e.data), ['AAAA', 'BBBB']);
    });

    // CP-LAZA-37: "Aria, ¿qué se dijo?" llegó sin el nombre.
    test(
      'voz de la persona y fin del turno en el mismo frame: llegan los dos',
      () {
        final r = parseLiveMessages({
          'serverContent': {
            'inputTranscription': {'text': ' Aria'},
            'turnComplete': true,
          },
        });
        expect(r.map((e) => e.type), [
          LiveResponseType.inputTranscription,
          LiveResponseType.turnComplete,
        ]);
        expect((r.first.data as LiveTranscription).text, ' Aria');
      },
    );

    test('voz de la persona e interrupción en el mismo frame', () {
      expect(
        types({
          'serverContent': {
            'inputTranscription': {'text': ' Aria'},
            'interrupted': true,
          },
        }),
        [LiveResponseType.inputTranscription, LiveResponseType.interrupted],
      );
    });
  });
}
