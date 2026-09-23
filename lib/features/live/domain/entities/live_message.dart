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

/// Convierte un frame crudo de Gemini en un [LiveResponse], revisando los
/// campos en orden de prioridad.
LiveResponse parseLiveMessage(Map<String, dynamic> raw) {
  final serverContent = (raw['serverContent'] as Map?)?.cast<String, dynamic>();
  final endOfTurn = serverContent?['turnComplete'] == true;

  if (raw['setupComplete'] != null) {
    return const LiveResponse(type: LiveResponseType.setupComplete);
  }
  if (serverContent?['interrupted'] == true) {
    return LiveResponse(
      type: LiveResponseType.interrupted,
      endOfTurn: endOfTurn,
    );
  }
  if (endOfTurn) {
    return const LiveResponse(
      type: LiveResponseType.turnComplete,
      endOfTurn: true,
    );
  }

  final inputTr = (serverContent?['inputTranscription'] as Map?)
      ?.cast<String, dynamic>();
  if (inputTr != null) {
    return LiveResponse(
      type: LiveResponseType.inputTranscription,
      data: LiveTranscription(
        text: (inputTr['text'] ?? '').toString(),
        finished: inputTr['finished'] == true,
      ),
    );
  }

  final outputTr = (serverContent?['outputTranscription'] as Map?)
      ?.cast<String, dynamic>();
  if (outputTr != null) {
    return LiveResponse(
      type: LiveResponseType.outputTranscription,
      data: LiveTranscription(
        text: (outputTr['text'] ?? '').toString(),
        finished: outputTr['finished'] == true,
      ),
    );
  }

  final toolCall = (raw['toolCall'] as Map?)?.cast<String, dynamic>();
  if (toolCall != null) {
    return LiveResponse(
      type: LiveResponseType.toolCall,
      data: LiveToolCall.fromJson(toolCall),
    );
  }

  final modelTurn = (serverContent?['modelTurn'] as Map?)
      ?.cast<String, dynamic>();
  final parts = (modelTurn?['parts'] as List?)
      ?.whereType<Map>()
      .map((e) => e.cast<String, dynamic>())
      .toList();
  if (parts != null && parts.isNotEmpty) {
    final first = parts.first;
    final text = first['text'];
    if (text != null) {
      return LiveResponse(type: LiveResponseType.text, data: text.toString());
    }
    final inlineData = (first['inlineData'] as Map?)?.cast<String, dynamic>();
    final audioData = inlineData?['data'];
    if (audioData != null) {
      return LiveResponse(
        type: LiveResponseType.audio,
        data: audioData.toString(),
      );
    }
  }

  return const LiveResponse(type: LiveResponseType.unknown);
}
