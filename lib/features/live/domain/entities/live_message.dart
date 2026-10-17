/// Modelos tipados de los mensajes de la Gemini Live API (vía proxy del backend).
///
/// El proxy reenvía
/// los frames crudos de Gemini tal cual; aquí los normalizamos a un [LiveResponse]
/// simple de consumir.
library;

/// Tipo de respuesta normalizada que emite el cliente Live.
enum LiveResponseType {
  setupComplete,
  audio,
  text,
  inputTranscription,
  outputTranscription,
  interrupted,
  turnComplete,
  toolCall,
  unknown,
}

/// Una transcripción (de la voz del usuario o de la salida del asistente).
class LiveTranscription {
  const LiveTranscription({required this.text, required this.finished});

  final String text;
  final bool finished;
}

/// Una función que Gemini pide ejecutar (personalización por voz).
class LiveFunctionCall {
  const LiveFunctionCall({
    required this.id,
    required this.name,
    required this.args,
  });

  final String id;
  final String name;
  final Map<String, dynamic> args;

  factory LiveFunctionCall.fromJson(Map<String, dynamic> json) {
    return LiveFunctionCall(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      args: (json['args'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
  }
}

/// Conjunto de llamadas a función recibidas en un `toolCall`.
class LiveToolCall {
  const LiveToolCall({required this.functionCalls});

  final List<LiveFunctionCall> functionCalls;

  factory LiveToolCall.fromJson(Map<String, dynamic> json) {
    final raw = (json['functionCalls'] as List?) ?? const [];
    return LiveToolCall(
      functionCalls: raw
          .whereType<Map>()
          .map((e) => LiveFunctionCall.fromJson(e.cast<String, dynamic>()))
          .toList(),
    );
  }
}

/// Respuesta normalizada del cliente Live.
class LiveResponse {
  const LiveResponse({required this.type, this.data, this.endOfTurn = false});

  final LiveResponseType type;

  /// Carga útil según [type]:
  /// - [LiveResponseType.audio] -> String base64 (PCM 24 kHz)
  /// - [LiveResponseType.text] -> String
  /// - [LiveResponseType.inputTranscription] / outputTranscription -> [LiveTranscription]
  /// - [LiveResponseType.toolCall] -> [LiveToolCall]
  final Object? data;

  final bool endOfTurn;
}

/// Convierte un frame crudo de Gemini en los [LiveResponse] que contiene, en
/// orden. Un mismo frame puede traer a la vez, por ejemplo, la transcripción de
/// lo que dice el asistente y su audio, o la voz de la persona y el fin del
/// turno: devolver solo uno perdía el resto (audio que no sonaba, nombres que no
/// llegaban a la transcripción). El fin del turno va siempre al final.
List<LiveResponse> parseLiveMessages(Map<String, dynamic> raw) {
  final out = <LiveResponse>[];
  final serverContent = (raw['serverContent'] as Map?)?.cast<String, dynamic>();
  final interrupted = serverContent?['interrupted'] == true;
  final endOfTurn = serverContent?['turnComplete'] == true;

  if (raw['setupComplete'] != null) {
    out.add(const LiveResponse(type: LiveResponseType.setupComplete));
  }

  final inputTr = (serverContent?['inputTranscription'] as Map?)
      ?.cast<String, dynamic>();
  if (inputTr != null) {
    out.add(
      LiveResponse(
        type: LiveResponseType.inputTranscription,
        data: LiveTranscription(
          text: (inputTr['text'] ?? '').toString(),
          finished: inputTr['finished'] == true,
        ),
      ),
    );
  }

  // La persona habló encima: lo que el asistente traía en este frame ya no
  // debe sonar.
  if (interrupted) {
    out.add(
      LiveResponse(type: LiveResponseType.interrupted, endOfTurn: endOfTurn),
    );
    return out;
  }

  final toolCall = (raw['toolCall'] as Map?)?.cast<String, dynamic>();
  if (toolCall != null) {
    out.add(
      LiveResponse(
        type: LiveResponseType.toolCall,
        data: LiveToolCall.fromJson(toolCall),
      ),
    );
  }

  final modelTurn = (serverContent?['modelTurn'] as Map?)
      ?.cast<String, dynamic>();
  final parts = (modelTurn?['parts'] as List?)?.whereType<Map>().map(
    (e) => e.cast<String, dynamic>(),
  );
  for (final part in parts ?? const <Map<String, dynamic>>[]) {
    final text = part['text'];
    final audio = (part['inlineData'] as Map?)?['data'];
    if (text != null) {
      out.add(LiveResponse(type: LiveResponseType.text, data: text.toString()));
    } else if (audio != null) {
      out.add(
        LiveResponse(type: LiveResponseType.audio, data: audio.toString()),
      );
    }
  }

  final outputTr = (serverContent?['outputTranscription'] as Map?)
      ?.cast<String, dynamic>();
  if (outputTr != null) {
    out.add(
      LiveResponse(
        type: LiveResponseType.outputTranscription,
        data: LiveTranscription(
          text: (outputTr['text'] ?? '').toString(),
          finished: outputTr['finished'] == true,
        ),
      ),
    );
  }

  if (endOfTurn) {
    out.add(
      const LiveResponse(type: LiveResponseType.turnComplete, endOfTurn: true),
    );
  }

  if (out.isEmpty) out.add(const LiveResponse(type: LiveResponseType.unknown));
  return out;
}
