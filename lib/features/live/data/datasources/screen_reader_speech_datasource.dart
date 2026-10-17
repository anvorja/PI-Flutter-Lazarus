/// Voz de TalkBack (canal nativo `lazarus/screen_reader_speech`, HU-023).
///
/// En altavoz, el micrófono capta lo que lee TalkBack como si lo dijera la
/// persona ("…mantén pulsado para enviar una alerta SOS"). El canal emite
/// `true` mientras suena el audio de accesibilidad y `false` al terminar.
library;

import 'package:flutter/services.dart';

const _channel = EventChannel('lazarus/screen_reader_speech');

/// `true` mientras TalkBack habla. En plataformas sin implementación nativa
/// no emite nada.
Stream<bool> screenReaderSpeech() => _channel
    .receiveBroadcastStream()
    .map((event) => event == true)
    .handleError((Object _) {}, test: (e) => e is MissingPluginException);
