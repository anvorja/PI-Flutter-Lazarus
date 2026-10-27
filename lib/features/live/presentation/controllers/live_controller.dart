/// Estado + lógica de la sesión Live (equivalente a `auth_controller.dart` en
/// el manual de arquitectura). Orquesta [LiveSessionRepository] y
/// [MediaRepository]: decide cuándo conectar, cuándo silenciar el mic
/// (anti-eco / silencio total) y cómo reaccionar a cada [LiveResponse]. La UI
/// (`LiveHomePage`) solo observa el [LiveUiState] expuesto y dispara acciones;
/// no conoce WebSockets, audio nativo ni cámara.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/live_close.dart';
import '../../domain/entities/live_message.dart';
import '../../domain/entities/media_permission.dart';
import '../../domain/repositories/background_session_repository.dart';
import '../../domain/repositories/live_session_repository.dart';
import '../../domain/repositories/live_settings_repository.dart';
import '../../domain/repositories/media_repository.dart';
import '../../domain/repositories/network_status_repository.dart';
import '../../../access/presentation/providers/access_providers.dart';
import '../../../emergency/domain/repositories/emergency_repository.dart';
import '../../../emergency/presentation/controllers/sos_controller.dart';
import '../../../emergency/presentation/providers/emergency_providers.dart';
import '../../../field_notes/domain/entities/field_note.dart';
import '../../../field_notes/presentation/providers/field_notes_providers.dart';
import '../../../location/domain/entities/location_fix.dart';
import '../../../location/presentation/providers/location_providers.dart';
import '../../../routes/domain/route_guide.dart';
import '../../../routes/domain/route_profile.dart';
import '../../../routes/domain/unicentro_schedule.dart';
import '../../../routes/presentation/providers/routes_providers.dart';
import '../providers/live_providers.dart';
import '../../../../core/debug/live_debug.dart';
import '../../../../core/telemetry/session_telemetry.dart';

/// Trazas de diagnóstico `[Lazarus]` (mic, turnos, toolCalls, transcripciones):
/// solo en builds de depuración (HU-015).
void _log(String message) => liveLog(message);

/// Respuesta a `set_language` con un idioma que la app no tiene: el asistente la
/// recibe y le explica a la persona, en el idioma actual, cuáles hay.
const String unsupportedLanguageResult =
    'error: unsupported language. The language was not changed. Tell the person, '
    'in the current language, that it is not available yet and that you can speak '
    'Spanish, English, French, Portuguese or Italian.';

/// Respuesta a `set_voice` con una voz que no existe: no se cambia nada.
const String unsupportedVoiceResult =
    'error: unsupported voice. The voice was not changed. Tell the person, in one '
    'sentence, that it is not available and name the available voices: Charon, '
    'Puck, Kore, Fenrir, Aoede, Leda, Orus and Zephyr.';

/// Respuesta a `set_voice` o `set_language` aplicados: la sesión se reinicia para
/// usarlos y el asistente lo confirma en la sesión nueva (`[VOZ]` / `[IDIOMA]`).
const String restartResult =
    'ok. The session restarts now to apply the change. Say nothing now: you will '
    'confirm it right after the restart.';

/// Modo reunión: cuánto tiempo atrás se busca el nombre del asistente en lo que
/// se oyó para dejarlo responder.
const Duration meetingNameWindow = Duration(seconds: 10);

/// "Ya pasó el tropel" (HU-019, regla 6): el segundo pedido debe llegar dentro
/// de este plazo, y no antes de [disturbanceLiftMinGap] (el asistente no puede
/// confirmar por su cuenta en el mismo turno).
const Duration disturbanceLiftWindow = Duration(minutes: 3);
const Duration disturbanceLiftMinGap = Duration(seconds: 4);

/// Tras terminar de hablar TalkBack, el micrófono sigue en pausa este tiempo
/// (la cola de su voz en el altavoz).
const Duration screenReaderSpeechTail = Duration(milliseconds: 300);

/// Minúsculas y sin tildes, para comparar nombres en la transcripción.
String normalizeForMatch(String text) {
  const from = 'áàäâãéèëêíìïîóòöôõúùüûñç';
  const to = 'aaaaaeeeeiiiiooooouuuunc';
  final lower = text.toLowerCase().trim();
  final out = StringBuffer();
  for (final ch in lower.split('')) {
    final i = from.indexOf(ch);
    out.write(i >= 0 ? to[i] : ch);
  }
  return out.toString();
}

/// Si [text] nombra a [name] como palabra completa. Tolera una letra de
/// diferencia en nombres de 4 letras o más, porque la transcripción a veces los
/// escribe mal ("Área" por "Aria"); los nombres cortos deben coincidir exacto
/// para no confundirse con palabras comunes ("Sol" y "sal").
bool mentionsName(String text, String name) {
  final target = normalizeForMatch(name).split(RegExp(r'[^a-z0-9]+')).first;
  if (target.isEmpty) return false;
  final tolerance = target.length >= 4 ? 1 : 0;
  return normalizeForMatch(text)
      .split(RegExp(r'[^a-z0-9]+'))
      .any((word) => _editDistance(word, target) <= tolerance);
}

int _editDistance(String a, String b) {
  if ((a.length - b.length).abs() > 1) return 2; // basta saber que es > 1
  var previous = List<int>.generate(b.length + 1, (j) => j);
  for (var i = 1; i <= a.length; i++) {
    final current = [i, ...List<int>.filled(b.length, 0)];
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      current[j] = [
        previous[j] + 1,
        current[j - 1] + 1,
        previous[j - 1] + cost,
      ].reduce((x, y) => x < y ? x : y);
    }
    previous = current;
  }
  return previous[b.length];
}

/// "Silencio total" en los idiomas de la app (normalizado: sin tildes).
const Set<String> totalSilencePhrases = {
  'silencio total', // es y pt ("silêncio total" sin tildes)
  'total silence',
  'silence total',
  'silenzio totale',
};

/// Si la persona pidió silencio total en [text].
bool asksTotalSilence(String text) {
  final words = normalizeForMatch(
    text,
  ).replaceAll(RegExp(r'[^a-z]+'), ' ').trim();
  return totalSilencePhrases.any(words.contains);
}

/// Quita las marcas internas de Gemini que a veces se cuelan en la
/// transcripción (`<ctrl46>`, visto en la Fase 0) para no mostrarlas ni
/// registrarlas como si las hubiera dicho.
String withoutControlTokens(String text) =>
    text.replaceAll(RegExp(r'<ctrl\d+>'), '');

/// Transcripción con palabras de verdad: letras latinas, sin `<noise>`. Con
/// ruido, la transcripción escribe cosas en tailandés, hindi o japonés.
bool isSpokenWords(String text) =>
    !text.contains('<noise>') &&
    RegExp(r'[A-Za-zÁÉÍÓÚÜÑáéíóúüñÀ-ÿ]{2,}').hasMatch(text);

/// Fin de la voz para la latencia: el último momento con voz en el micrófono,
/// salvo que quede más de 1,5 s después de la última palabra transcrita (el
/// ruido de la calle lo mantiene alto hasta que responde el asistente) o más
/// de 3 s antes: entonces es de una frase anterior y esta se dijo en voz baja
/// (prueba del 21-oct: "Bruno" midió 18 s en lugar de 4 s).
DateTime endOfSpeech(DateTime? lastLoud, DateTime lastWord) {
  if (lastLoud == null) return lastWord;
  final limit = lastWord.add(const Duration(milliseconds: 1500));
  final stale = lastWord.subtract(const Duration(seconds: 3));
  return lastLoud.isAfter(limit) || lastLoud.isBefore(stale)
      ? lastWord
      : lastLoud;
}

/// Pedido de nota de campo (HU-024) en lo que dijo la persona: el texto a
/// anotar, sin "anota que…". Si "anota" va al final ("estoy en la estación,
/// anota"), se toma lo anterior. `null` si no hay pedido o queda vacío.
String? noteRequestText(String heard) {
  const from = 'áàäâéèëêíìïîóòöôúùüûñ';
  const to = 'aaaaeeeeiiiioooouuuun';
  final lower = heard.toLowerCase();
  final norm = StringBuffer();
  for (final ch in lower.split('')) {
    final i = from.indexOf(ch);
    norm.write(i >= 0 ? to[i] : ch);
  }
  final match = RegExp(
    r'\b(anota|anote|apunta|apunte|toma nota|note that|write down|annota|note)\b'
    r'(\s+(que|de|that|che|of))?',
  ).firstMatch(norm.toString());
  if (match == null) return null;
  String clean(String t) =>
      t.replaceAll(RegExp(r'^[\s.,;:¿?¡!]+|[\s.,;:¿?¡!]+$'), '').trim();
  final after = clean(heard.substring(match.end));
  if (after.isNotEmpty) return after;
  final before = clean(heard.substring(0, match.start));
  return before.isEmpty ? null : before;
}

/// La nota solo marca el lugar ("posición", "coordenadas", "guarda posición"):
/// en la jornada del 24-oct un participante dejó 15 así, sin decir qué había.
bool isPlaceMarkerNote(String text) {
  const marker = {
    'posicion',
    'coordenadas',
    'coordenada',
    'ubicacion',
    'guarda',
    'guarde',
    'guardar',
    'guardada',
    'actual',
    'mi',
    'la',
    'esta',
    'este',
    'punto',
    'aqui',
    'note',
    'position',
    'location',
    'coordinates',
    'save',
    'here',
  };
  final words = normalizeForMatch(
    text,
  ).split(RegExp(r'[^a-z]+')).where((w) => w.isNotEmpty).toList();
  return words.isNotEmpty && words.every(marker.contains);
}

/// El asistente dijo que anotó ("Anotado.", "Noted.", "Noté.", "Annotato.").
bool saysNoted(String said) => RegExp(
  r'\b(anotad[oa]|apuntad[oa]|noted|note|annotato)\b',
).hasMatch(normalizeForMatch(said));

/// Pausar o reanudar las descripciones (normalizado). Incluye "escribir": en
/// la prueba de CP-LAZA-107 la transcripción oyó "deja escribir" y "vuelve a
/// escribir", y el asistente respondió "Entendido" sin llamar a la función.
const Set<String> pauseDescriptionPhrases = {
  'deja de describir',
  'deja de escribir',
  'deja escribir',
  'no describas',
  'para de describir',
  'stop describing',
};
const Set<String> resumeDescriptionPhrases = {
  'vuelve a describir',
  'vuelve a escribir',
  'sigue describiendo',
  'describe de nuevo',
  'resume describing',
  'start describing again',
};

/// `true` si [text] pide pausar las descripciones, `false` si pide
/// reanudarlas y `null` si no pide ninguna de las dos.
bool? asksDescriptions(String text) {
  final words = normalizeForMatch(
    text,
  ).replaceAll(RegExp(r'[^a-z]+'), ' ').trim();
  if (resumeDescriptionPhrases.any(words.contains)) return true;
  if (pauseDescriptionPhrases.any(words.contains)) return false;
  return null;
}

/// Salir del modo reunión (normalizado). Solo cuenta si además lo llaman por
/// su nombre: "ya puedes hablar" puede ir dirigido a otra persona.
const Set<String> leaveMeetingPhrases = {
  'puedes hablar', // es; también "ya puedes hablar"
  'salimos de la reunion',
  'termino la reunion',
  'se acabo la reunion',
  'sal del modo reunion',
  'vuelve a hablar', // es; prueba del 21-oct: "vuelve a hablar, el modo…"
  'modo reunion se acabo',
  'se acabo el modo reunion',
  'you can talk',
  'you can speak',
  'meeting is over',
  'tu peux parler',
  'pode falar', // pt; también "já pode falar"
  'puoi parlare',
};

/// Si la persona pidió salir del modo reunión en [text].
bool asksLeaveMeeting(String text) {
  final words = normalizeForMatch(
    text,
  ).replaceAll(RegExp(r'[^a-z]+'), ' ').trim();
  return leaveMeetingPhrases.any(words.contains);
}

/// Entrar en modo reunión (normalizado). En la prueba del 21-oct, "Silencio,
/// voy a estar en una reunión" no activó el modo hasta 30 s después, con la
/// reunión ya empezada.
const Set<String> enterMeetingPhrases = {
  'modo reunion', // es
  'modo de reunion', // prueba del 21-oct: "voy a estar en modo de reunión"
  'modo reuniao', // pt
  'estoy en una reunion',
  'voy a estar en una reunion',
  'voy a entrar a una reunion',
  'entro a una reunion',
  'meeting mode',
  'i am in a meeting',
  'mode reunion',
  'modalita riunione',
};

/// Si la persona pidió entrar en modo reunión en [text] (y no salir de él:
/// "el modo reunión se acabó" también nombra el modo).
bool asksMeetingMode(String text) {
  if (asksLeaveMeeting(text)) return false;
  final words = normalizeForMatch(
    text,
  ).replaceAll(RegExp(r'[^a-z]+'), ' ').trim();
  if (RegExp(
    r'\b(sal|salir|acabo|termino|desactiva|quita)\b',
  ).hasMatch(words)) {
    return false;
  }
  return enterMeetingPhrases.any(words.contains);
}

/// Palabras que pueden acompañar a "SOS" sin cambiar el pedido.
const Set<String> _sosCompanions = {
  'ayuda',
  'auxilio',
  'socorro',
  'urgente',
  'emergencia',
  'alerta',
  'una',
  'la',
  'el',
  'por',
  'favor',
  'envia',
  'enviar',
  'manda',
  'mandar',
  'help',
  'please',
  'send',
  'ajuda',
  'aiuto',
  'aide',
  'secours',
};

/// Si [turn] es un pedido de SOS: "SOS", "S O S" o "ese o ese", solo o con
/// palabras como "ayuda" o el nombre del asistente. Una pregunta sobre el SOS
/// ("¿qué hace el SOS?") no cuenta. En la prueba del 21-oct, el asistente oyó
/// "S o s" y cerró el turno sin llamar a `trigger_sos`.
bool asksSos(String turn, {String name = ''}) {
  if (turn.contains('?') || turn.contains('¿')) return false;
  final words = normalizeForMatch(
    turn,
  ).replaceAll(RegExp(r'[^a-z]+'), ' ').trim();
  final sos = RegExp(r'\b(s ?o ?s|ese o ese)\b');
  if (!sos.hasMatch(words)) return false;
  final assistant = normalizeForMatch(name).replaceAll(RegExp(r'[^a-z]+'), '');
  return words
      .replaceAll(sos, ' ')
      .split(' ')
      .where((w) => w.isNotEmpty && w != assistant)
      .every(_sosCompanions.contains);
}

/// Respuesta de `get_time` (LAZA-115): la hora y la fecha del reloj del
/// teléfono, que ya está en la zona horaria de la persona (en Colombia, UTC-5).
/// El asistente no conoce la hora y, sin esto, decía la del servidor.
String describeLocalTime(DateTime now) {
  const weekdays = [
    'monday',
    'tuesday',
    'wednesday',
    'thursday',
    'friday',
    'saturday',
    'sunday',
  ];
  String two(int n) => n.toString().padLeft(2, '0');
  final date = '${now.year}-${two(now.month)}-${two(now.day)}';
  return 'ok: hora local del teléfono ${two(now.hour)}:${two(now.minute)} '
      '(formato de 24 horas), ${weekdays[now.weekday - 1]} $date. Dila en el '
      'idioma de la persona, sin mencionar zonas horarias.';
}

/// Reintentos automáticos cuando no se puede conectar con el backend.
const int maxConnectionRetries = 3;

/// Avisos hablados cuando el asistente no puede hablar (sin conexión, sin cuota…).
enum LiveNotice {
  retrying,
  connectionFailed,
  sessionPaused,
  quotaExceeded,
  serverMisconfigured,
  billingExhausted,
  permissionDenied,
  permissionBlocked,
  stopped,

  /// Primer toque de Detener (jornada del 24-oct): con TalkBack, un doble toque
  /// en cualquier parte activa el botón enfocado y la app se detenía sin querer.
  stopConfirm,

  /// Alerta SOS enviada sola con la sesión ya cerrada (no hay asistente que lo
  /// diga).
  sosSent,
  sosFailed,

  /// Primera sesión (HU-017): pide quitar la optimización de batería para que
  /// la sesión siga con la pantalla bloqueada; la variante Xiaomi agrega el
  /// ajuste del fabricante.
  batteryExemption,
  batteryExemptionXiaomi,

  /// Sin datos móviles (HU-042): lo dice el teléfono, porque el asistente no
  /// puede hablar sin red. No se puede silenciar (aviso de seguridad).
  noData,
  noDataReminder,

  /// SOS con el gesto, sin el asistente (HU-042). `{name}`: el contacto.
  sosGestureConfirm,

  /// SOS por voz cuya pregunta del asistente no sonó (se cortó antes).
  sosVoiceConfirm,
  sosCancelled,
  sosUnconfirmed,
  sosNoContact,

  /// Entró al modo reunión (LAZA-113): lo dice el teléfono, porque la
  /// confirmación del asistente no siempre se alcanza a oír.
  meetingOn,

  /// El administrador puso Lazarus en pausa (fuera de las jornadas de campo).
  servicePaused,

  /// Control de acceso del piloto (HU-044).
  devicePending,
  deviceDisabled,
  dailyLimit,
  closedByAdmin,

  /// Solo con TalkBack (HU-023): sin lector de pantalla la persona oye el
  /// saludo del asistente y el silencio lo confirma el propio asistente.
  connecting,
  muted,
}

/// Avisos que solo lee TalkBack (HU-023): sin lector de pantalla no suenan.
const Set<LiveNotice> screenReaderNotices = {
  LiveNotice.connecting,
  LiveNotice.muted,
};

/// Avisos informativos que la persona puede silenciar por voz (`set_system_cues`).
/// Los demás explican cómo recuperarse de un error y suenan siempre.
const Set<LiveNotice> mutableNotices = {
  LiveNotice.retrying,
  LiveNotice.stopped,
};

const Map<String, Map<LiveNotice, String>> _notices = {
  'es': {
    LiveNotice.retrying: 'Perdí la conexión con el servidor. Reintentando.',
    LiveNotice.connectionFailed:
        'No se pudo conectar con el servidor. Toca la pantalla para reintentar.',
    LiveNotice.sessionPaused:
        'La sesión con el asistente terminó. Toca la pantalla para continuar.',
    LiveNotice.quotaExceeded:
        'El servicio del asistente no está disponible por ahora. Intenta más tarde.',
    LiveNotice.serverMisconfigured:
        'El servidor del asistente no está configurado. Avisa al equipo de soporte.',
    LiveNotice.billingExhausted:
        'El servicio del asistente se quedó sin saldo. Pide a quien administra Lazarus que lo recargue.',
    LiveNotice.permissionDenied:
        'Necesito permiso de micrófono para acompañarte. Toca la pantalla para intentarlo de nuevo.',
    LiveNotice.permissionBlocked:
        'El permiso de micrófono está desactivado. Toca la pantalla para abrir los ajustes y activarlo.',
    LiveNotice.stopped: 'Asistente detenido.',
    LiveNotice.stopConfirm:
        '¿Detener el asistente? Toca el botón otra vez para confirmar.',
    LiveNotice.sosSent:
        'Alerta enviada a tu contacto de emergencia. Detente en un lugar seguro y espera.',
    LiveNotice.sosFailed:
        'No se pudo enviar la alerta. Pide ayuda a alguien cerca o llama al 123.',
    LiveNotice.batteryExemption:
        'Antes de empezar: para que siga contigo con la pantalla bloqueada, permite que Lazarus funcione sin restricciones de batería. Luego toca la pantalla para empezar.',
    LiveNotice.batteryExemptionXiaomi:
        'Antes de empezar: para que siga contigo con la pantalla bloqueada, permite que Lazarus funcione sin restricciones de batería. En los teléfonos Xiaomi, además, en Ajustes, Aplicaciones, Lazarus, Ahorro de batería, elige Sin restricciones. Luego toca la pantalla para empezar.',
    LiveNotice.noData:
        'Me quedé sin datos móviles y no puedo hablar con el asistente. Para pedir ayuda, mantén presionada la pantalla tres segundos. Tu recorrido se sigue registrando y me reconecto cuando vuelvan los datos.',
    LiveNotice.noDataReminder:
        'Sigo sin datos móviles. Para pedir ayuda, mantén presionada la pantalla tres segundos.',
    LiveNotice.sosGestureConfirm:
        'Alerta de emergencia para {name}. Para enviarla ya, vuelve a mantener presionada la pantalla. Para cancelar, toca una vez. Si no haces nada, se envía en unos segundos.',
    LiveNotice.sosVoiceConfirm:
        '¿Envío la alerta a {name}? Di sí o no. Para cancelar, también puedes tocar la pantalla. Si no respondes, se envía en unos segundos.',
    LiveNotice.sosCancelled: 'Alerta cancelada.',
    LiveNotice.sosUnconfirmed:
        'Envié la alerta, pero la red no confirmó que llegó. Si puedes, llama a tu contacto o al 123.',
    LiveNotice.sosNoContact:
        'No tienes contacto de emergencia. Abro el marcador con el 123: el botón de llamar está abajo, en el centro de la pantalla.',
    LiveNotice.meetingOn:
        'Modo reunión. Te escucho en silencio; para hablarme, llámame por mi nombre.',
    LiveNotice.servicePaused:
        'Lazarus está en pausa por ahora. Quien coordina las pruebas lo activará de nuevo para la próxima jornada.',
    LiveNotice.devicePending:
        'Este teléfono está esperando la aprobación de quien coordina las pruebas. Avísale y vuelve a intentarlo.',
    LiveNotice.deviceDisabled:
        'Este teléfono no tiene acceso a Lazarus por ahora. Habla con quien coordina las pruebas.',
    LiveNotice.dailyLimit:
        'Se acabó el tiempo de uso de hoy en este teléfono. Mañana podrás usar Lazarus de nuevo.',
    LiveNotice.closedByAdmin:
        'Quien coordina las pruebas cerró la sesión. Toca la pantalla si necesitas volver a empezar.',
    LiveNotice.connecting: 'Conectando con el asistente.',
    LiveNotice.muted:
        'Silencio total. Para reactivar el asistente, toca dos veces la pantalla.',
  },
  'en': {
    LiveNotice.retrying: 'I lost the connection to the server. Retrying.',
    LiveNotice.connectionFailed:
        'Could not connect to the server. Tap the screen to try again.',
    LiveNotice.sessionPaused:
        'The session with the assistant ended. Tap the screen to continue.',
    LiveNotice.quotaExceeded:
        'The assistant service is not available right now. Try again later.',
    LiveNotice.serverMisconfigured:
        'The assistant server is not configured. Please contact support.',
    LiveNotice.billingExhausted:
        'The assistant service has run out of credit. Ask whoever manages Lazarus to top it up.',
    LiveNotice.permissionDenied:
        'I need microphone permission to help you. Tap the screen to try again.',
    LiveNotice.permissionBlocked:
        'Microphone permission is turned off. Tap the screen to open settings and turn it on.',
    LiveNotice.stopped: 'Assistant stopped.',
    LiveNotice.stopConfirm:
        'Stop the assistant? Tap the button again to confirm.',
    LiveNotice.sosSent:
        'Alert sent to your emergency contact. Stop in a safe place and wait.',
    LiveNotice.sosFailed:
        'The alert could not be sent. Ask someone nearby for help or call 123.',
    LiveNotice.batteryExemption:
        'Before we start: so I can stay with you with the screen locked, allow Lazarus to run without battery restrictions. Then tap the screen to start.',
    LiveNotice.batteryExemptionXiaomi:
        'Before we start: so I can stay with you with the screen locked, allow Lazarus to run without battery restrictions. On Xiaomi phones, also go to Settings, Apps, Lazarus, Battery saver, and choose No restrictions. Then tap the screen to start.',
    LiveNotice.noData:
        'I lost mobile data and cannot talk to the assistant. To ask for help, press and hold the screen for three seconds. Your route is still being recorded and I will reconnect when data comes back.',
    LiveNotice.noDataReminder:
        'Still no mobile data. To ask for help, press and hold the screen for three seconds.',
    LiveNotice.sosGestureConfirm:
        'Emergency alert for {name}. To send it now, press and hold the screen again. To cancel, tap once. If you do nothing, it is sent in a few seconds.',
    LiveNotice.sosVoiceConfirm:
        'Shall I send the alert to {name}? Say yes or no. To cancel, you can also tap the screen. If you do not answer, it is sent in a few seconds.',
    LiveNotice.sosCancelled: 'Alert cancelled.',
    LiveNotice.sosUnconfirmed:
        'I sent the alert, but the network did not confirm it arrived. If you can, call your contact or 123.',
    LiveNotice.sosNoContact:
        'You have no emergency contact. I am opening the dialer with 123: the call button is at the bottom center of the screen.',
    LiveNotice.meetingOn:
        'Meeting mode. I am listening quietly; to talk to me, call me by my name.',
    LiveNotice.servicePaused:
        'Lazarus is paused for now. The person coordinating the tests will turn it back on for the next session.',
    LiveNotice.devicePending:
        'This phone is waiting for approval from the person coordinating the tests. Let them know and try again.',
    LiveNotice.deviceDisabled:
        'This phone does not have access to Lazarus for now. Talk to the person coordinating the tests.',
    LiveNotice.dailyLimit:
        'Today\'s usage time on this phone is over. You can use Lazarus again tomorrow.',
    LiveNotice.closedByAdmin:
        'The person coordinating the tests closed the session. Tap the screen if you need to start again.',
    LiveNotice.connecting: 'Connecting to the assistant.',
    LiveNotice.muted:
        'Total silence. To turn the assistant back on, double-tap the screen.',
  },
  'fr': {
    LiveNotice.retrying: 'J\'ai perdu la connexion au serveur. Nouvel essai.',
    LiveNotice.connectionFailed:
        'Connexion au serveur impossible. Touchez l\'écran pour réessayer.',
    LiveNotice.sessionPaused:
        'La session avec l\'assistant est terminée. Touchez l\'écran pour continuer.',
    LiveNotice.quotaExceeded:
        'Le service de l\'assistant est indisponible. Réessayez plus tard.',
    LiveNotice.serverMisconfigured:
        'Le serveur de l\'assistant n\'est pas configuré. Contactez le support.',
    LiveNotice.billingExhausted:
        'Le service de l\'assistant n\'a plus de crédit. Demande à la personne qui gère Lazarus de le recharger.',
    LiveNotice.permissionDenied:
        'J\'ai besoin de l\'accès au micro pour vous accompagner. Touchez l\'écran pour réessayer.',
    LiveNotice.permissionBlocked:
        'L\'accès au micro est désactivé. Touchez l\'écran pour ouvrir les réglages et l\'activer.',
    LiveNotice.stopped: 'Assistant arrêté.',
    LiveNotice.stopConfirm:
        "Arrêter l'assistant ? Touche le bouton encore une fois pour confirmer.",
    LiveNotice.sosSent:
        'Alerte envoyée à ton contact d\'urgence. Arrête-toi dans un endroit sûr et attends.',
    LiveNotice.sosFailed:
        'L\'alerte n\'a pas pu être envoyée. Demande de l\'aide à quelqu\'un à côté ou appelle le 123.',
    LiveNotice.batteryExemption:
        'Avant de commencer : pour rester avec toi écran verrouillé, autorise Lazarus à fonctionner sans restriction de batterie. Ensuite, touche l\'écran pour commencer.',
    LiveNotice.batteryExemptionXiaomi:
        'Avant de commencer : pour rester avec toi écran verrouillé, autorise Lazarus à fonctionner sans restriction de batterie. Sur les téléphones Xiaomi, va aussi dans Paramètres, Applications, Lazarus, Économiseur de batterie, et choisis Aucune restriction. Ensuite, touche l\'écran pour commencer.',
    LiveNotice.noData:
        'Je n\'ai plus de données mobiles et je ne peux pas parler à l\'assistant. Pour demander de l\'aide, maintiens l\'écran appuyé trois secondes. Ton trajet est toujours enregistré et je me reconnecte quand les données reviennent.',
    LiveNotice.noDataReminder:
        'Toujours pas de données mobiles. Pour demander de l\'aide, maintiens l\'écran appuyé trois secondes.',
    LiveNotice.sosGestureConfirm:
        'Alerte d\'urgence pour {name}. Pour l\'envoyer maintenant, maintiens de nouveau l\'écran appuyé. Pour annuler, touche une fois. Si tu ne fais rien, elle part dans quelques secondes.',
    LiveNotice.sosVoiceConfirm:
        'J\'envoie l\'alerte à {name} ? Dis oui ou non. Pour annuler, tu peux aussi toucher l\'écran. Si tu ne réponds pas, elle part dans quelques secondes.',
    LiveNotice.sosCancelled: 'Alerte annulée.',
    LiveNotice.sosUnconfirmed:
        'J\'ai envoyé l\'alerte, mais le réseau n\'a pas confirmé qu\'elle est arrivée. Si tu peux, appelle ton contact ou le 123.',
    LiveNotice.sosNoContact:
        'Tu n\'as pas de contact d\'urgence. J\'ouvre le clavier avec le 123 : le bouton d\'appel est en bas, au centre de l\'écran.',
    LiveNotice.meetingOn:
        'Mode réunion. Je t\'écoute en silence ; pour me parler, appelle-moi par mon nom.',
    LiveNotice.servicePaused:
        'Lazarus est en pause pour le moment. La personne qui coordonne les essais le réactivera pour la prochaine séance.',
    LiveNotice.devicePending:
        'Ce téléphone attend l\'approbation de la personne qui coordonne les essais. Préviens-la et réessaie.',
    LiveNotice.deviceDisabled:
        'Ce téléphone n\'a pas accès à Lazarus pour le moment. Parle à la personne qui coordonne les essais.',
    LiveNotice.dailyLimit:
        'Le temps d\'utilisation d\'aujourd\'hui est écoulé sur ce téléphone. Tu pourras utiliser Lazarus demain.',
    LiveNotice.closedByAdmin:
        'La personne qui coordonne les essais a fermé la session. Touche l\'écran si tu dois recommencer.',
    LiveNotice.connecting: 'Connexion à l\'assistant.',
    LiveNotice.muted:
        'Silence total. Pour réactiver l\'assistant, touche deux fois l\'écran.',
  },
  'pt': {
    LiveNotice.retrying: 'Perdi a conexão com o servidor. Tentando de novo.',
    LiveNotice.connectionFailed:
        'Não foi possível conectar ao servidor. Toque na tela para tentar de novo.',
    LiveNotice.sessionPaused:
        'A sessão com o assistente terminou. Toque na tela para continuar.',
    LiveNotice.quotaExceeded:
        'O serviço do assistente não está disponível agora. Tente mais tarde.',
    LiveNotice.serverMisconfigured:
        'O servidor do assistente não está configurado. Avise o suporte.',
    LiveNotice.billingExhausted:
        'O serviço do assistente ficou sem saldo. Peça a quem administra o Lazarus para recarregar.',
    LiveNotice.permissionDenied:
        'Preciso de permissão de microfone para te acompanhar. Toque na tela para tentar de novo.',
    LiveNotice.permissionBlocked:
        'A permissão de microfone está desativada. Toque na tela para abrir os ajustes e ativá-la.',
    LiveNotice.stopped: 'Assistente parado.',
    LiveNotice.stopConfirm:
        'Parar o assistente? Toque no botão de novo para confirmar.',
    LiveNotice.sosSent:
        'Alerta enviado ao seu contato de emergência. Pare em um lugar seguro e espere.',
    LiveNotice.sosFailed:
        'Não foi possível enviar o alerta. Peça ajuda a alguém por perto ou ligue para o 123.',
    LiveNotice.batteryExemption:
        'Antes de começar: para eu continuar com você com a tela bloqueada, permita que o Lazarus funcione sem restrições de bateria. Depois toque na tela para começar.',
    LiveNotice.batteryExemptionXiaomi:
        'Antes de começar: para eu continuar com você com a tela bloqueada, permita que o Lazarus funcione sem restrições de bateria. Nos telefones Xiaomi, também vá em Configurações, Aplicativos, Lazarus, Economia de bateria, e escolha Sem restrições. Depois toque na tela para começar.',
    LiveNotice.noData:
        'Fiquei sem dados móveis e não consigo falar com o assistente. Para pedir ajuda, mantenha a tela pressionada por três segundos. Seu trajeto continua sendo registrado e eu me reconecto quando os dados voltarem.',
    LiveNotice.noDataReminder:
        'Continuo sem dados móveis. Para pedir ajuda, mantenha a tela pressionada por três segundos.',
    LiveNotice.sosGestureConfirm:
        'Alerta de emergência para {name}. Para enviar agora, mantenha a tela pressionada de novo. Para cancelar, toque uma vez. Se não fizer nada, ele é enviado em alguns segundos.',
    LiveNotice.sosVoiceConfirm:
        'Envio o alerta para {name}? Diga sim ou não. Para cancelar, também pode tocar na tela. Se não responder, ele é enviado em alguns segundos.',
    LiveNotice.sosCancelled: 'Alerta cancelado.',
    LiveNotice.sosUnconfirmed:
        'Enviei o alerta, mas a rede não confirmou que chegou. Se puder, ligue para o seu contato ou para o 123.',
    LiveNotice.sosNoContact:
        'Você não tem contato de emergência. Vou abrir o discador com o 123: o botão de ligar fica embaixo, no centro da tela.',
    LiveNotice.meetingOn:
        'Modo reunião. Estou ouvindo em silêncio; para falar comigo, me chame pelo nome.',
    LiveNotice.servicePaused:
        'O Lazarus está em pausa por enquanto. Quem coordena os testes vai ativá-lo de novo para a próxima jornada.',
    LiveNotice.devicePending:
        'Este telefone está esperando a aprovação de quem coordena os testes. Avise e tente de novo.',
    LiveNotice.deviceDisabled:
        'Este telefone não tem acesso ao Lazarus por enquanto. Fale com quem coordena os testes.',
    LiveNotice.dailyLimit:
        'O tempo de uso de hoje neste telefone acabou. Amanhã você poderá usar o Lazarus de novo.',
    LiveNotice.closedByAdmin:
        'Quem coordena os testes encerrou a sessão. Toque na tela se precisar começar de novo.',
    LiveNotice.connecting: 'Conectando ao assistente.',
    LiveNotice.muted:
        'Silêncio total. Para reativar o assistente, toque duas vezes na tela.',
  },
  'it': {
    LiveNotice.retrying: 'Ho perso la connessione al server. Riprovo.',
    LiveNotice.connectionFailed:
        'Impossibile connettersi al server. Tocca lo schermo per riprovare.',
    LiveNotice.sessionPaused:
        'La sessione con l\'assistente è terminata. Tocca lo schermo per continuare.',
    LiveNotice.quotaExceeded:
        'Il servizio dell\'assistente non è disponibile ora. Riprova più tardi.',
    LiveNotice.serverMisconfigured:
        'Il server dell\'assistente non è configurato. Contatta l\'assistenza.',
    LiveNotice.billingExhausted:
        'Il servizio dell\'assistente ha esaurito il credito. Chiedi a chi gestisce Lazarus di ricaricarlo.',
    LiveNotice.permissionDenied:
        'Mi serve il permesso del microfono per accompagnarti. Tocca lo schermo per riprovare.',
    LiveNotice.permissionBlocked:
        'Il permesso del microfono è disattivato. Tocca lo schermo per aprire le impostazioni e attivarlo.',
    LiveNotice.stopped: 'Assistente fermato.',
    LiveNotice.stopConfirm:
        "Fermare l'assistente? Tocca di nuovo il pulsante per confermare.",
    LiveNotice.sosSent:
        'Avviso inviato al tuo contatto di emergenza. Fermati in un luogo sicuro e aspetta.',
    LiveNotice.sosFailed:
        'Non è stato possibile inviare l\'avviso. Chiedi aiuto a qualcuno vicino o chiama il 123.',
    LiveNotice.batteryExemption:
        'Prima di iniziare: per restare con te a schermo bloccato, consenti a Lazarus di funzionare senza restrizioni della batteria. Poi tocca lo schermo per iniziare.',
    LiveNotice.batteryExemptionXiaomi:
        'Prima di iniziare: per restare con te a schermo bloccato, consenti a Lazarus di funzionare senza restrizioni della batteria. Sui telefoni Xiaomi, vai anche in Impostazioni, App, Lazarus, Risparmio batteria, e scegli Nessuna restrizione. Poi tocca lo schermo per iniziare.',
    LiveNotice.noData:
        'Sono rimasto senza dati mobili e non posso parlare con l\'assistente. Per chiedere aiuto, tieni premuto lo schermo per tre secondi. Il tuo percorso continua a essere registrato e mi riconnetto quando tornano i dati.',
    LiveNotice.noDataReminder:
        'Ancora niente dati mobili. Per chiedere aiuto, tieni premuto lo schermo per tre secondi.',
    LiveNotice.sosGestureConfirm:
        'Avviso di emergenza per {name}. Per inviarlo subito, tieni premuto di nuovo lo schermo. Per annullare, tocca una volta. Se non fai nulla, viene inviato tra pochi secondi.',
    LiveNotice.sosVoiceConfirm:
        'Invio l\'avviso a {name}? Di sì o no. Per annullare, puoi anche toccare lo schermo. Se non rispondi, viene inviato tra pochi secondi.',
    LiveNotice.sosCancelled: 'Avviso annullato.',
    LiveNotice.sosUnconfirmed:
        'Ho inviato l\'avviso, ma la rete non ha confermato che sia arrivato. Se puoi, chiama il tuo contatto o il 123.',
    LiveNotice.sosNoContact:
        'Non hai un contatto di emergenza. Apro il tastierino con il 123: il pulsante di chiamata è in basso, al centro dello schermo.',
    LiveNotice.meetingOn:
        'Modalità riunione. Ascolto in silenzio; per parlarmi, chiamami per nome.',
    LiveNotice.servicePaused:
        'Lazarus è in pausa per ora. Chi coordina le prove lo riattiverà per la prossima sessione.',
    LiveNotice.devicePending:
        'Questo telefono aspetta l\'approvazione di chi coordina le prove. Avvisalo e riprova.',
    LiveNotice.deviceDisabled:
        'Questo telefono non ha accesso a Lazarus per ora. Parla con chi coordina le prove.',
    LiveNotice.dailyLimit:
        'Il tempo di utilizzo di oggi su questo telefono è finito. Domani potrai usare di nuovo Lazarus.',
    LiveNotice.closedByAdmin:
        'Chi coordina le prove ha chiuso la sessione. Tocca lo schermo se devi ricominciare.',
    LiveNotice.connecting: 'Connessione all\'assistente.',
    LiveNotice.muted:
        'Silenzio totale. Per riattivare l\'assistente, tocca due volte lo schermo.',
  },
};

/// Con TalkBack un toque solo enfoca: los gestos de la app son tocar dos veces
/// y tocar dos veces y mantener (HU-023). Cambia las instrucciones de los
/// avisos a esos gestos, en el idioma de la persona.
const Map<String, List<(String, String)>> _screenReaderGestures = {
  'es': [
    (r'([Tt])oca la pantalla', r'$1oca dos veces la pantalla'),
    (
      r'mantén presionada la pantalla tres segundos',
      r'toca dos veces y mantén presionada la pantalla',
    ),
    (
      r'vuelve a mantener presionada la pantalla',
      r'vuelve a tocar dos veces y mantener presionada la pantalla',
    ),
    (r'toca una vez', r'toca dos veces'),
  ],
  'en': [
    (r'(?<!-)\b([Tt])ap the screen', r'double-tap the screen'),
    (
      r'press and hold the screen for three seconds',
      r'double-tap and hold the screen',
    ),
    (
      r'press and hold the screen again',
      r'double-tap and hold the screen again',
    ),
    (r'tap once', r'double-tap'),
  ],
  'fr': [
    (r"([Tt])ouchez l'écran", r"$1ouchez deux fois l'écran"),
    (r"([Tt])ouche l'écran", r"$1ouche deux fois l'écran"),
    (
      r"maintiens l'écran appuyé trois secondes",
      r"touche deux fois l'écran et maintiens-le appuyé",
    ),
    (
      r"maintiens de nouveau l'écran appuyé",
      r"touche de nouveau deux fois l'écran et maintiens-le appuyé",
    ),
    (r'touche une fois', r'touche deux fois'),
  ],
  'pt': [
    (r'([Tt])oque na tela', r'$1oque duas vezes na tela'),
    (
      r'mantenha a tela pressionada por três segundos',
      r'toque duas vezes e mantenha a tela pressionada',
    ),
    (
      r'mantenha a tela pressionada de novo',
      r'toque duas vezes e mantenha a tela pressionada de novo',
    ),
    (r'toque uma vez', r'toque duas vezes'),
  ],
  'it': [
    (r'([Tt])occa lo schermo', r'$1occa due volte lo schermo'),
    (
      r'tieni premuto lo schermo per tre secondi',
      r'tocca due volte e tieni premuto lo schermo',
    ),
    (
      r'tieni premuto di nuovo lo schermo',
      r'tocca due volte e tieni premuto di nuovo lo schermo',
    ),
    (r'tocca una volta', r'tocca due volte'),
  ],
};

/// [text] con los gestos de TalkBack en lugar de los táctiles.
String withScreenReaderGestures(String text, String language) {
  var out = text;
  for (final (pattern, replacement)
      in _screenReaderGestures[language] ?? _screenReaderGestures['es']!) {
    out = out.replaceAllMapped(
      RegExp(pattern),
      (m) => replacement.replaceAllMapped(
        RegExp(r'\$(\d)'),
        (g) => m.group(int.parse(g.group(1)!)) ?? '',
      ),
    );
  }
  // "double-tap the screen" al inicio de frase.
  return out.replaceAllMapped(
    RegExp(r'(^|\. )double-tap'),
    (m) => '${m.group(1)}Double-tap',
  );
}

/// Texto del aviso en el idioma de la persona (español si no está disponible).
/// [name] reemplaza `{name}` (el contacto de emergencia).
String noticeText(LiveNotice notice, String language, {String name = ''}) =>
    (_notices[language] ?? _notices['es']!)[notice]!.replaceAll('{name}', name);

/// `offline`: sin datos móviles, a la espera de que vuelvan (HU-042).
/// `sos`: alerta SOS con el gesto, esperando confirmación (HU-042).
enum LiveStatus { idle, connecting, connected, error, offline, sos }

/// Qué disparar al completarse el setup: saludo normal, muestra de voz o
/// confirmación de idioma (tras un cambio, sin repetir toda la presentación), o
/// confirmación de micrófono reactivado.
enum _PendingKickoff { intro, voice, language, micOn, cameraOff, cameraOn }

/// Estado observable por la UI. Los detalles de orquestación (contadores de
/// chunks, si hay audífonos, si el asistente sigue sonando…) son detalle
/// interno del [LiveController] y no viven aquí porque la UI no los necesita.
@immutable
class LiveUiState {
  const LiveUiState({
    this.status = LiveStatus.idle,
    this.language = 'es',
    this.userTranscript = '',
    this.assistantTranscript = '',
    this.meetingMode = false,
    this.micMuted = false,
  });

  final LiveStatus status;
  final String language;
  final String userTranscript;
  final String assistantTranscript;

  /// Modo A: el mic sigue abierto para oír y recordar; el comportamiento
  /// callado lo aplica el prompt del asistente.
  final bool meetingMode;

  /// Modo B: silencio total, no se envía mic/cámara.
  final bool micMuted;

  /// Lo que lee TalkBack sobre el área de la pantalla (HU-023): el estado, sin
  /// las instrucciones de toque, que van en [tapHint] y [longPressHint].
  String get screenReaderLabel {
    if (micMuted) return 'Silencio total';
    if (status == LiveStatus.connected && meetingMode) {
      return 'Modo reunión: escuchando en silencio. Llámame por mi nombre.';
    }
    return switch (status) {
      LiveStatus.idle => 'Iniciar asistente',
      LiveStatus.connecting => 'Conectando',
      LiveStatus.connected => 'Asistente escuchando',
      LiveStatus.error => 'Error de conexión',
      LiveStatus.offline => 'Sin datos móviles',
      LiveStatus.sos => 'Alerta SOS pendiente',
    };
  }

  /// Qué hace el doble toque de TalkBack ("Toca dos veces para…"), o `null`
  /// si tocar no hace nada en este estado (no se ofrece la acción).
  String? get tapHint {
    if (micMuted) return 'reactivar el asistente';
    return switch (status) {
      LiveStatus.idle => 'iniciar el asistente',
      LiveStatus.error => 'reintentar',
      LiveStatus.sos => 'cancelar la alerta',
      LiveStatus.connecting ||
      LiveStatus.connected ||
      LiveStatus.offline => null,
    };
  }

  /// Qué hace tocar dos veces y mantener (el gesto SOS de HU-042).
  String get longPressHint => status == LiveStatus.sos
      ? 'enviar la alerta ya'
      : 'enviar una alerta SOS';

  bool get isLive =>
      status == LiveStatus.connecting ||
      status == LiveStatus.connected ||
      status == LiveStatus.offline ||
      status == LiveStatus.sos;

  String get statusLabel {
    if (micMuted) return 'Silencio total. Toca la pantalla para reactivar.';
    if (status == LiveStatus.connected && meetingMode) {
      return 'Modo reunión: escuchando en silencio. Llámame por mi nombre.';
    }
    return switch (status) {
      LiveStatus.idle => 'Toca para empezar',
      LiveStatus.connecting => 'Conectando…',
      LiveStatus.connected => 'Escuchando',
      LiveStatus.error => 'Error de conexión. Toca para reintentar.',
      LiveStatus.offline =>
        'Sin datos móviles. Mantén presionado 3 segundos para pedir ayuda.',
      LiveStatus.sos =>
        'Alerta SOS: mantén presionado para enviarla ya, toca para cancelar.',
    };
  }

  LiveUiState copyWith({
    LiveStatus? status,
    String? language,
    String? userTranscript,
    String? assistantTranscript,
    bool? meetingMode,
    bool? micMuted,
  }) {
    return LiveUiState(
      status: status ?? this.status,
      language: language ?? this.language,
      userTranscript: userTranscript ?? this.userTranscript,
      assistantTranscript: assistantTranscript ?? this.assistantTranscript,
      meetingMode: meetingMode ?? this.meetingMode,
      micMuted: micMuted ?? this.micMuted,
    );
  }
}

class LiveController extends Notifier<LiveUiState> {
  late final LiveSessionRepository _session;
  late final MediaRepository _media;
  late final LiveSettingsRepository _settings;
  late final SessionTelemetry _telemetry;
  late final BackgroundSessionRepository _background;
  late final NetworkStatusRepository _network;

  /// El teléfono tiene datos (HU-042). Sin datos no se gastan reintentos.
  bool _online = true;
  StreamSubscription<bool>? _networkWatch;
  Timer? _offlineReminder;

  /// SOS iniciado con el gesto, esperando confirmación o enviándose (HU-042).
  bool _sosByGesture = false;

  /// Estado de la sesión antes del SOS por gesto, para retomarla después.
  LiveStatus _statusBeforeSos = LiveStatus.idle;

  // Detalle interno de orquestación: no forma parte de LiveUiState porque la
  // UI no lo necesita para renderizar.
  int _micChunks = 0; // diagnóstico: chunks de mic enviados
  int _audioInChunks = 0; // diagnóstico: chunks de audio recibidos
  bool _onSpeaker = true; // sin audífonos → altavoz (anti-eco medio-dúplex)
  bool _assistantActive = false; // el asistente está sonando

  /// Lo que el asistente lleva dicho en el turno actual (Gemini lo transcribe por
  /// fragmentos). Se escribe completo en el log al terminar o interrumpirse el
  /// turno: es la evidencia de QA de lo que dijo.
  final StringBuffer _assistantSaid = StringBuffer();
  bool _assistantTurnDone = false; // terminó el turno (audio puede drenar)
  bool _audioDrained = false; // la cola de reproducción ya se vació

  /// Audio del asistente encolado desde que la cola se vació por última vez (ms
  /// estimados). Sirve de red de seguridad: si Android nunca avisa que el audio
  /// terminó, el micrófono se reabre por tiempo para que la app no quede sorda.
  int _queuedAudioMs = 0;
  Timer? _drainFallback;
  _PendingKickoff _pendingKickoff = _PendingKickoff.intro;
  int _retryAttempts = 0; // reintentos de conexión consumidos
  bool _openSettingsOnTap = false; // permisos bloqueados: el toque abre ajustes
  bool _cameraAllowed = true; // false = sin permiso de cámara (solo audio)
  bool _everConnected = false; // hubo setupComplete en esta sesión de uso

  /// Pantalla bloqueada (HU-017): el servicio en primer plano mantiene la
  /// sesión; la cámara se pausa mientras la app no está visible.
  bool _backgroundOn = false;
  bool _visible = true;
  bool _cameraPaused = false;

  /// La sesión actual se abrió con la pantalla bloqueada: no tiene ninguna
  /// imagen y su system prompt lo sabe (HU-017).
  bool _sessionBlind = false;

  /// Cambio de sesión pendiente al bloquear o desbloquear la pantalla.
  Timer? _cameraSwitch;

  /// Modo reunión: lo que se oyó hace poco (para saber si llamaron al asistente
  /// por su nombre) y el audio del turno actual retenido hasta saberlo.
  final List<({DateTime at, String text})> _heard = [];
  final List<String> _heldAudio = [];
  bool _turnAllowed = false; // este turno puede sonar aunque sea modo reunión

  /// Turno en que el asistente entró al modo reunión: su "Entendido" no suena
  /// (aunque lo hayan llamado por su nombre), porque lo confirma el teléfono.
  bool _meetingConfirmTurn = false;

  /// La persona pidió salir del modo reunión llamándolo por su nombre: si el
  /// asistente no llama a `set_meeting_mode`, la app sale igual (LAZA-113).
  bool _leaveMeetingRequested = false;

  /// La persona pidió entrar en modo reunión: si el asistente no llama a
  /// `set_meeting_mode`, la app lo activa al terminar el turno.
  bool _meetingRequested = false;

  /// Lo que dijo la persona en este turno, para la red de seguridad del SOS, y
  /// si el asistente ya llamó a la alerta.
  final StringBuffer _sosHeard = StringBuffer();
  bool _sosCalled = false;

  /// Sonó entera la pregunta "¿Envío la alerta…?" del asistente.
  bool _sosQuestionHeard = false;

  /// La persona consultó la Ruta A y estaba disponible: si se desactiva antes
  /// de Detener, la app se lo avisa sin que pregunte (HU-019, regla 3).
  bool _routeAOffered = false;
  Timer? _routeAWatch;

  /// Perfiles de ruta curados descargados al iniciar (HU-022) y la guía de la
  /// ruta activa, que avanza con el GPS cada [routeCheckInterval].
  List<RouteProfile> _routes = const [];
  RouteGuide? _routeGuide;
  Timer? _routeWatch;

  /// Ya se consultó si el panel pidió los logs en esta sesión (HU-045).
  bool _uploadChecked = false;

  /// TalkBack está hablando: en altavoz el micrófono no se envía (HU-023).
  bool _screenReaderSpeaking = false;

  /// Última vez que habló TalkBack: mientras la persona explora la pantalla,
  /// el asistente no observa.
  DateTime? _screenReaderLastAt;

  /// El micrófono está en pausa porque habla la voz del teléfono (avisos).
  bool _micPausedForNotice = false;
  StreamSubscription<bool>? _screenReaderSpeech;
  Timer? _screenReaderTail;

  /// "Ya pasó el tropel" se pide dos veces: el primer pedido queda aquí y solo
  /// un segundo pedido, con la persona hablando de nuevo, levanta la regla 6.
  ({DateTime at, int heard})? _disturbanceLiftRequest;

  /// Transcripciones de la persona en esta sesión (para la doble confirmación).
  int _heardCount = 0;

  /// Notas de campo dictadas desde el último Detener (HU-024).
  int _notesThisSession = 0;

  /// La persona pidió "silencio total": si el asistente no llama a
  /// `set_microphone`, la app lo aplica igual al terminar su turno (privacidad).
  bool _silenceRequested = false;

  /// Lo que dijo la persona desde la última respuesta del asistente, y si en
  /// ese intercambio se llamó a `add_note`: si el asistente dice "Anotado." sin
  /// llamarla, la nota la guarda la app (Fase 0: se perdieron 4 notas).
  final StringBuffer _userTurnHeard = StringBuffer();
  bool _noteCalled = false;

  /// La persona pidió pausar (`false`) o reanudar (`true`) las descripciones:
  /// si el asistente no llama a `set_descriptions`, la app lo guarda igual.
  bool? _describingRequested;

  /// Acciones que esperan a que suene la próxima respuesta del asistente: la
  /// cuenta de la confirmación SOS arranca cuando termina la pregunta, y una
  /// llamada empieza cuando el asistente terminó de avisarla.
  final List<void Function()> _afterSpeech = [];
  bool _afterSpeechHeard = false; // ya sonó audio de esa respuesta
  Timer? _afterSpeechFallback;

  /// Ciclo de observación (HU-040): Gemini Live no habla si nadie le habla, así
  /// que con todos callados la app le envía `[OBSERVA]` cada pocos segundos para
  /// que mire la imagen y avise de un riesgo.
  Timer? _observeTimer;
  DateTime _lastActivity = DateTime.now(); // última vez que alguien habló
  DateTime? _observeSentAt; // `[OBSERVA]` en curso, esperando respuesta
  bool _observeAnswered = false;

  /// Latencia voz a voz (HU-015): última vez que el micrófono captó voz y si
  /// la persona habló después de la última respuesta del asistente.
  DateTime? _lastVoiceAt;

  /// Última palabra real transcrita de la persona y si hubo alguna desde la
  /// última respuesta: en la calle el ruido mantiene alto el micrófono hasta
  /// que responde el asistente y la latencia salía casi en 0 (Fase 0).
  DateTime? _lastWordAt;
  bool _wordSinceReply = false;

  /// Se espera una respuesta del asistente (a la voz de la persona, al saludo,
  /// a una función o a otro mensaje de la app) y aún no terminó: no se observa,
  /// porque `[OBSERVA]` la cortaría.
  bool _replyPending = false;
  bool _replyStarted = false; // ya empezó a sonar esa respuesta
  DateTime? _replyWaitFrom;
  DateTime? _lastReplyEnd;
  int _loudChunks = 0; // fragmentos seguidos con voz (el ruido es suelto)

  @override
  LiveUiState build() {
    _session = ref.read(liveSessionRepositoryProvider);
    _media = ref.read(mediaRepositoryProvider);
    _settings = ref.read(liveSettingsRepositoryProvider);
    _telemetry = ref.read(sessionTelemetryProvider);
    _background = ref.read(backgroundSessionRepositoryProvider);
    _background.onStopRequested(_stopFromNotification);
    _network = ref.read(networkStatusRepositoryProvider);
    // Sin información de la red, la sesión funciona como antes de HU-042.
    try {
      _network.isOnline().then((online) => _online = online);
      _networkWatch = _network.onlineChanges().listen(
        _onNetworkChanged,
        onError: (Object e) => _log('[Lazarus] red: sin información ($e)'),
      );
    } catch (e) {
      _log('[Lazarus] red: sin información ($e)');
    }
    ref.onDispose(() {
      _networkWatch?.cancel();
      _offlineReminder?.cancel();
    });
    ref.onDispose(_teardown);
    ref.onDispose(_stopBackground);
    ref.onDispose(() => _afterSpeechFallback?.cancel());
    // Español por defecto; si la persona cambió el idioma por voz, se conserva.
    return LiveUiState(language: _settings.getLanguage());
  }

  void _teardown() {
    _routeAWatch?.cancel();
    _routeAWatch = null;
    _stopRouteGuide();
    _cameraSwitch?.cancel();
    _cameraSwitch = null;
    _stopObserving();
    _cameraPaused = false;
    _heldAudio.clear();
    _turnAllowed = false;
    _meetingConfirmTurn = false;
    _leaveMeetingRequested = false;
    _meetingRequested = false;
    _sosHeard.clear();
    _sosCalled = false;
    // Lo que alcanzó a decir en esta sesión se registra aquí: si no, se pegaría
    // al primer turno de la sesión siguiente.
    _logAssistantSaid(' (cortado al cerrar la sesión)');
    _drainFallback?.cancel();
    _screenReaderSpeech?.cancel();
    _screenReaderSpeech = null;
    _screenReaderTail?.cancel();
    _screenReaderTail = null;
    _screenReaderSpeaking = false;
    _screenReaderLastAt = null;
    _media.stopMic();
    _media.stopCamera();
    _media.destroyPlayer();
    _session.disconnect();
  }

  Future<void> connect() async {
    if (state.isLive) return;
    _retryAttempts = 0;
    // Permisos negados de forma permanente: el toque abre los ajustes; al
    // volver, el siguiente toque los pide de nuevo.
    if (_openSettingsOnTap) {
      _openSettingsOnTap = false;
      await _media.openPermissionSettings();
      return;
    }
    final access = await _media.requestPermissions();
    if (!ref.mounted) return;
    // Sin cámara la sesión sigue solo con audio: el asistente lo avisa al saludar.
    _cameraAllowed = access.camera;
    if (!_cameraAllowed) {
      _log('[Lazarus] cámara: sin permiso → modo solo audio');
    }
    switch (access.microphone) {
      case MediaPermission.granted:
        break;
      case MediaPermission.denied:
        state = state.copyWith(status: LiveStatus.error);
        _announce(LiveNotice.permissionDenied);
        return;
      case MediaPermission.blocked:
        _openSettingsOnTap = true;
        state = state.copyWith(status: LiveStatus.error);
        _announce(LiveNotice.permissionBlocked);
        return;
    }
    if (await _ensureBatteryExemption() || !ref.mounted) return;
    unawaited(_settings.setLastSessionStart(ref.read(liveClockProvider)()));
    // La sesión sigue con la pantalla bloqueada (HU-017).
    unawaited(_startBackground());
    // La ubicación acompaña a la sesión; sin permiso la sesión sigue igual.
    unawaited(ref.read(locationControllerProvider.notifier).start());
    // Registro en el panel del piloto (HU-044): la primera vez, en segundo
    // plano; la sesión no lo espera y el token sirve desde la siguiente.
    final deviceAccess = ref.read(deviceAccessRepositoryProvider);
    if (deviceAccess.savedToken == null) unawaited(deviceAccess.token());
    _uploadChecked = false;
    _openSession(state.language);
    // Con TalkBack, el doble toque necesita respuesta mientras llega el saludo.
    _announce(LiveNotice.connecting);
  }

  /// Antes de empezar, pide excluir a Lazarus de la optimización de batería
  /// (si no, Android puede cerrarla con la pantalla bloqueada) y lo explica en
  /// voz alta, con el ajuste extra de Xiaomi. Lo pide la primera vez y, otra
  /// vez, si Android cerró la app en la sesión anterior: la exención se puede
  /// perder (p. ej. al actualizar la app) y el 24 y el 26 de octubre el sistema
  /// cerró la app en dos marcas distintas. Esa vez no se abre la sesión (el
  /// saludo se cruzaría con el aviso y el diálogo): la persona vuelve a tocar la
  /// pantalla. Devuelve `true` si se pidió.
  Future<bool> _ensureBatteryExemption() async {
    final killed = await _previousSessionKilledBySystem();
    final status = await _background.batteryStatus();
    if (!ref.mounted || status.exempt) return false;
    if (_settings.getBatteryExemptionAsked() && !killed) {
      _log('[Lazarus] batería: con optimización (ya se pidió la exención)');
      return false;
    }
    await _settings.setBatteryExemptionAsked();
    _announce(
      status.manufacturer == 'xiaomi'
          ? LiveNotice.batteryExemptionXiaomi
          : LiveNotice.batteryExemption,
    );
    final exempt = await _background.requestBatteryExemption();
    _log(
      '[Lazarus] batería: ${exempt ? "sin restricciones" : "sigue con optimización"}',
    );
    return true;
  }

  static const _exitLabels = {
    'system': 'Android cerró la app',
    'user': 'la app se cerró desde recientes o Ajustes',
    'crash': 'la app falló',
  };

  /// Si la sesión anterior quedó abierta (sin Detener) y el proceso terminó
  /// después, lo registra con el motivo de Android (evidencia de HU-017).
  /// `true` solo si fue el sistema el que la cerró.
  Future<bool> _previousSessionKilledBySystem() async {
    final started = _settings.getLastSessionStart();
    if (started == null) return false;
    await _settings.setLastSessionStart(null);
    final exit = await _background.lastExit();
    if (exit == null || !exit.at.isAfter(started)) return false;
    final detail = exit.description.isEmpty ? '' : ', ${exit.description}';
    _log(
      '[Lazarus] la sesión anterior no terminó con Detener: '
      '${_exitLabels[exit.kind] ?? "el proceso terminó"} a las '
      '${_clockTime(exit.at)} (motivo ${exit.reason}$detail)',
    );
    return exit.kind == 'system';
  }

  static String _clockTime(DateTime t) =>
      [t.hour, t.minute, t.second].map((v) => '$v'.padLeft(2, '0')).join(':');

  Future<void> _startBackground() async {
    if (_backgroundOn) return;
    _backgroundOn = true;
    final started = await _background.start();
    _log(
      started
          ? '[Lazarus] segundo plano: activo (puede bloquear la pantalla)'
          : '[Lazarus] segundo plano: Android no lo permitió',
    );
    if (!started) _backgroundOn = false;
  }

  void _stopBackground() {
    if (!_backgroundOn) return;
    _backgroundOn = false;
    unawaited(_background.stop());
    _log('[Lazarus] segundo plano: detenido');
  }

  /// "Detener" en la notificación: lo mismo que el botón de la pantalla.
  void _stopFromNotification() {
    if (!ref.mounted) return;
    _log('[Lazarus] Detener desde la notificación');
    if (_backgroundOn || state.isLive) {
      disconnect();
    } else {
      _stopBackground();
    }
  }

  /// Cambio de la red de datos del teléfono (HU-042). Al quedarse sin datos
  /// con la sesión activa, lo dice enseguida (criterio 1: menos de 5 s) sin
  /// esperar a que la conexión falle; al volver, se reconecta sola.
  void _onNetworkChanged(bool online) {
    if (!ref.mounted || online == _online) return;
    _online = online;
    _log('[Lazarus] red: ${online ? "con datos" : "sin datos"}');
    _telemetry.event('network', {'online': online});
    if (!online) {
      if (state.status == LiveStatus.connecting ||
          state.status == LiveStatus.connected) {
        _goOffline();
      }
    } else if (state.status == LiveStatus.offline) {
      _backOnline();
    }
  }

  /// Sin datos: cierra la sesión (no puede funcionar), avisa con el teléfono y
  /// queda esperando. El GPS sigue registrando el recorrido.
  void _goOffline() {
    _teardown();
    if (_everConnected) _pendingKickoff = _PendingKickoff.micOn;
    state = state.copyWith(
      status: LiveStatus.offline,
      meetingMode: false,
      micMuted: false,
    );
    _announce(LiveNotice.noData);
    _startOfflineReminder();
  }

  /// Mientras no haya datos, lo recuerda cada cierto tiempo (regla 5).
  void _startOfflineReminder() {
    _offlineReminder?.cancel();
    _offlineReminder = Timer.periodic(ref.read(offlineReminderProvider), (_) {
      if (!ref.mounted || state.status != LiveStatus.offline) return;
      _announce(LiveNotice.noDataReminder);
    });
  }

  /// Volvieron los datos: se reconecta sola, con la confirmación corta del
  /// asistente en lugar del saludo (criterio 3).
  void _backOnline() {
    _offlineReminder?.cancel();
    _offlineReminder = null;
    _retryAttempts = 0;
    state = state.copyWith(status: LiveStatus.connecting);
    _openSession(state.language);
  }

  /// Mantener presionada la pantalla (HU-042): SOS sin el asistente, con y sin
  /// datos. La primera vez pregunta; un segundo gesto la envía ya, un toque la
  /// cancela y, sin respuesta, se envía sola como en HU-012.
  Future<void> onSosGesture() async {
    final sos = ref.read(sosControllerProvider.notifier);
    final pending = ref.read(sosControllerProvider);
    if (_sosByGesture && pending == SosStatus.awaitingConfirmation) {
      final result = await sos.sendNow();
      _finishGestureSos(result);
      return;
    }
    if (pending != SosStatus.idle) return; // ya hay una alerta en curso
    final name = sos.contactName();
    if (name == null) {
      _log('[Lazarus] SOS por gesto: sin contacto; marcador con el 123');
      _announce(LiveNotice.sosNoContact);
      unawaited(sos.placeCall(CallTarget.emergency));
      return;
    }
    _log('[Lazarus] SOS por gesto');
    _telemetry.event('sos_gesture', {'online': _online});
    // El asistente no debe hablar encima de la pregunta: la sesión se pausa y
    // se retoma al terminar.
    _statusBeforeSos = state.status;
    if (state.status == LiveStatus.connecting ||
        state.status == LiveStatus.connected) {
      _teardown();
      if (_everConnected) _pendingKickoff = _PendingKickoff.micOn;
    }
    _sosByGesture = true;
    state = state.copyWith(
      status: LiveStatus.sos,
      meetingMode: false,
      micMuted: false,
    );
    _announceText(
      noticeText(LiveNotice.sosGestureConfirm, state.language, name: name),
    );
    sos.startByGesture(_finishGestureSos);
  }

  void _cancelGestureSos() {
    ref.read(sosControllerProvider.notifier).cancel();
    _announce(LiveNotice.sosCancelled);
    _endGestureSos();
  }

  void _finishGestureSos(String result) {
    if (!ref.mounted) return;
    _announce(
      result.startsWith('sent')
          ? LiveNotice.sosSent
          : result.startsWith('unconfirmed')
          ? LiveNotice.sosUnconfirmed
          : LiveNotice.sosFailed,
    );
    _endGestureSos();
  }

  /// Vuelve a como estaba antes del SOS: sin sesión, sin datos o con la sesión
  /// (tras una pausa, para no tapar el aviso del resultado).
  void _endGestureSos() {
    _sosByGesture = false;
    final before = _statusBeforeSos;
    if (before == LiveStatus.idle || before == LiveStatus.error) {
      state = state.copyWith(status: LiveStatus.idle);
      return;
    }
    if (!_online) {
      state = state.copyWith(status: LiveStatus.offline);
      if (_offlineReminder == null) _startOfflineReminder();
      return;
    }
    _offlineReminder?.cancel();
    _offlineReminder = null;
    state = state.copyWith(status: LiveStatus.connecting);
    Future.delayed(ref.read(sosResumeDelayProvider), () {
      if (!ref.mounted || state.status != LiveStatus.connecting) return;
      _retryAttempts = 0;
      _openSession(state.language);
    });
  }

  /// La app dejó de verse (pantalla bloqueada u otra app encima) o volvió.
  /// Android no deja usar la cámara sin la app visible. Avisarle al asistente
  /// no basta: en la caminata de CP-LAZA-45 siguió describiendo la última imagen
  /// como si fuera lo que la persona tenía delante, y hasta dio indicaciones con
  /// ella. Por eso, al bloquear se abre una sesión nueva sin ninguna imagen, en
  /// modo pantalla bloqueada; al desbloquear, tras una espera por si fue sin
  /// querer, se vuelve a una sesión con cámara (HU-017).
  void onVisibilityChanged(bool visible) {
    if (visible == _visible) return;
    _visible = visible;
    if (!visible) _pauseCamera();
    _syncCameraSession();
  }

  /// El asistente recibe imágenes ahora: hay permiso, la sesión no es de
  /// pantalla bloqueada y la cámara no está en pausa.
  bool get _canSee => _cameraAllowed && !_sessionBlind && !_cameraPaused;

  bool get _sessionUp =>
      _session.connected && state.status == LiveStatus.connected;

  void _pauseCamera() {
    if (!_cameraAllowed || _cameraPaused || !_sessionUp) return;
    _cameraPaused = true;
    _stopObserving();
    unawaited(_media.stopCamera());
    _log('[Lazarus] pantalla bloqueada: cámara en pausa (sigue el audio)');
    _telemetry.event('camera', {'paused': true});
  }

  /// Deja la sesión acorde con la pantalla: sin imágenes si está bloqueada y
  /// con cámara si no. Al bloquear cambia enseguida; al desbloquear, espera.
  void _syncCameraSession() {
    _cameraSwitch?.cancel();
    _cameraSwitch = null;
    if (!_cameraAllowed || !_sessionUp) return;
    final blind = !_visible;
    if (blind == _sessionBlind) {
      // Desbloqueo antes del cambio: la sesión aún tiene cámara, se reanuda.
      if (!blind) _resumeCamera();
      return;
    }
    // En silencio total o en modo reunión no se cambia: el aviso sonaría. Se
    // hace al salir de esos modos.
    if (state.micMuted || state.meetingMode) return;
    _cameraSwitch = Timer(
      blind ? Duration.zero : ref.read(cameraUnlockDelayProvider),
      _switchCameraSession,
    );
  }

  void _switchCameraSession() {
    _cameraSwitch = null;
    if (!ref.mounted || !_sessionUp) return;
    final blind = !_visible;
    if (blind == _sessionBlind) return;
    _log(
      blind
          ? '[Lazarus] pantalla bloqueada: sesión nueva sin imágenes'
          : '[Lazarus] pantalla desbloqueada: sesión nueva con cámara',
    );
    _telemetry.event('camera_session', {'screen_locked': blind});
    _pendingKickoff = blind
        ? _PendingKickoff.cameraOff
        : _PendingKickoff.cameraOn;
    _teardown();
    _openSession(state.language);
  }

  void _resumeCamera() {
    if (!_cameraPaused) return;
    _cameraPaused = false;
    if (!_sessionUp) return;
    unawaited(_startCamera());
    _log('[Lazarus] pantalla desbloqueada: cámara de vuelta');
    _telemetry.event('camera', {'paused': false});
  }

  Future<void> _startCamera() async {
    await _media.startCamera((jpeg) {
      // Silencio total (Modo B): tampoco enviar cámara (privacidad).
      if (state.micMuted) return;
      _session.sendImage(jpeg);
    });
    if (ref.mounted && !_cameraPaused) _startObserving();
  }

  void _openSession(String lang) {
    if (_session.connected) return;
    state = state.copyWith(
      status: LiveStatus.connecting,
      userTranscript: '',
      assistantTranscript: '',
    );

    final voice = _settings.getVoice();
    _sessionBlind = _cameraAllowed && !_visible;
    _session.connect(
      language: lang,
      voice: voice.isEmpty ? null : voice,
      assistantName: _settings.getAssistantName(),
      userName: _settings.getUserName(),
      verbosity: _settings.getVerbosity(),
      describing: _settings.getDescribing(),
      camera: _cameraAllowed,
      screenLocked: _sessionBlind,
      screenReader: ref.read(screenReaderActiveProvider)(),
      deviceToken: ref.read(deviceAccessRepositoryProvider).savedToken,
      onResponse: _handleResponse,
      onClose: (cause) {
        _log('[Lazarus] sesión cerrada: ${cause.name}');
        _telemetry.event('session_closed', {'cause': cause.name});
        if (!ref.mounted) return;
        _teardown();
        _onSessionClosed(cause, lang);
      },
      onError: (e) {
        _log('[Lazarus] error de conexión: $e');
        _telemetry.event('error', {'kind': 'connection'});
        if (!ref.mounted) return;
        _teardown();
        _retryOrFail(lang);
      },
    );
  }

  /// Aviso ya armado (con el nombre del contacto, por ejemplo).
  void _announceText(String text) {
    _log('[Lazarus] aviso: $text');
    ref.read(announcerProvider)(text, state.language);
  }

  void _announce(LiveNotice notice) {
    if (mutableNotices.contains(notice) && _settings.getSystemCuesMuted()) {
      _log('[Lazarus] aviso silenciado: ${notice.name}');
      return;
    }
    if (screenReaderNotices.contains(notice)) {
      ref.read(screenReaderAnnouncerProvider)(
        noticeText(notice, state.language),
      );
      return;
    }
    _log('[Lazarus] aviso: ${notice.name}');
    ref.read(announcerProvider)(
      noticeText(notice, state.language),
      state.language,
    );
  }

  /// La sesión terminó sin que la app la cerrara: decide según la causa.
  void _onSessionClosed(LiveCloseCause cause, String lang) {
    // En silencio total no se reconecta (privacidad): se retoma al tocar.
    if (state.micMuted) {
      state = state.copyWith(status: LiveStatus.idle);
      return;
    }
    if (cause != LiveCloseCause.upstreamError &&
        cause != LiveCloseCause.unknown) {
      _endTelemetry(cause.name);
    }
    switch (cause) {
      case LiveCloseCause.upstreamEnded:
        // Gemini cerró la sesión (p. ej. límite de duración): se retoma cuando la
        // persona vuelve a tocar la pantalla, con una confirmación corta en lugar
        // de la presentación completa.
        if (_everConnected) _pendingKickoff = _PendingKickoff.micOn;
        state = state.copyWith(status: LiveStatus.idle);
        _announce(LiveNotice.sessionPaused);
      case LiveCloseCause.quotaExceeded:
        state = state.copyWith(status: LiveStatus.error);
        _announce(LiveNotice.quotaExceeded);
      case LiveCloseCause.serverMisconfigured:
        state = state.copyWith(status: LiveStatus.error);
        _announce(LiveNotice.serverMisconfigured);
      case LiveCloseCause.billingExhausted:
        // No se reintenta: sin saldo, cada intento falla igual (en la prueba,
        // 8 reintentos seguidos con "Perdí la conexión").
        state = state.copyWith(status: LiveStatus.error);
        _announce(LiveNotice.billingExhausted);
      case LiveCloseCause.servicePaused:
        // No se reintenta: la pausa la levanta quien administra el servidor.
        state = state.copyWith(status: LiveStatus.error);
        _announce(LiveNotice.servicePaused);
      case LiveCloseCause.devicePending:
        state = state.copyWith(status: LiveStatus.error);
        _announce(LiveNotice.devicePending);
      case LiveCloseCause.deviceDisabled:
        state = state.copyWith(status: LiveStatus.error);
        _announce(LiveNotice.deviceDisabled);
      case LiveCloseCause.dailyLimit:
        state = state.copyWith(status: LiveStatus.error);
        _announce(LiveNotice.dailyLimit);
      case LiveCloseCause.closedByAdmin:
        state = state.copyWith(status: LiveStatus.idle);
        _announce(LiveNotice.closedByAdmin);
        // Los logs de esa sesión quedan en el panel, como al tocar Detener.
        unawaited(_uploadLogs('cerrada desde el panel'));
      case LiveCloseCause.protocolError:
        state = state.copyWith(status: LiveStatus.error);
        _announce(LiveNotice.connectionFailed);
      case LiveCloseCause.upstreamError:
      case LiveCloseCause.unknown:
        // Sin código no se sabe la causa: el backend la recuerda (Fase 0: el
        // saldo agotado y el cierre desde el panel llegaron como un corte sin
        // código a través de Render).
        _session
            .lastFailureCause(
              deviceToken: ref.read(deviceAccessRepositoryProvider).savedToken,
            )
            .then((known) {
              if (!ref.mounted) return;
              if (known != null) {
                _log('[Lazarus] causa según el backend: ${known.name}');
                _onSessionClosed(known, lang);
                return;
              }
              _retryOrFail(lang);
            });
    }
  }

  /// Sin conexión con el backend: avisa y reintenta con espera creciente; al
  /// agotar los reintentos deja el estado de error (tocar la pantalla reintenta).
  void _retryOrFail(String lang) {
    // Sin datos no se gastan reintentos: se espera a que vuelvan (HU-042).
    if (!_online) {
      if (state.status != LiveStatus.offline) _goOffline();
      return;
    }
    if (_retryAttempts >= maxConnectionRetries) {
      _endTelemetry('connection_failed');
      state = state.copyWith(status: LiveStatus.error);
      _announce(LiveNotice.connectionFailed);
      return;
    }
    final delay = ref.read(retryDelayProvider)(_retryAttempts);
    // Se avisa solo en el primer reintento: la frase dura más que la espera
    // entre intentos y cada aviso nuevo cortaría el anterior a la mitad.
    if (_retryAttempts == 0) _announce(LiveNotice.retrying);
    _retryAttempts++;
    _telemetry.event('reconnect', {'attempt': _retryAttempts});
    state = state.copyWith(status: LiveStatus.connecting);
    // Si la sesión ya había funcionado, al volver basta una confirmación corta.
    if (_everConnected) _pendingKickoff = _PendingKickoff.micOn;
    Future.delayed(delay, () {
      if (!ref.mounted || state.status != LiveStatus.connecting) return;
      _openSession(lang);
    });
  }

  /// Arranca mic + cámara una vez que el asistente confirma la sesión.
  Future<void> _startMedia() async {
    // El micrófono no debe captar un aviso del teléfono que siga sonando.
    ref.read(announcerStopProvider)();
    try {
      _onSpeaker = !(await _media.isHeadsetConnected());
      _assistantActive = false;
      _assistantTurnDone = false;
      _audioDrained = false;
      if (!ref.mounted) return;
      state = state.copyWith(meetingMode: false, micMuted: false);
      _log(
        '[Lazarus] salida: ${_onSpeaker ? "ALTAVOZ (medio-dúplex anti-eco)" : "AUDÍFONOS (full-duplex)"}',
      );

      await _media.initPlayer(() {
        _audioDrained = true;
        _queuedAudioMs = 0;
        _reopenMicIfTurnOver('fin del audio y turnComplete');
      });

      _micChunks = 0;
      _audioInChunks = 0;
      _listenScreenReaderSpeech();
      await _media.startMic((pcm) {
        // Silencio total (Modo B): no enviar nada hasta reactivar.
        if (state.micMuted) return;
        // En altavoz, no enviar mientras el asistente suena (anti-eco).
        if (_onSpeaker && _assistantActive) return;
        // Ni mientras habla TalkBack: su voz no es la persona (HU-023).
        if (_onSpeaker && _screenReaderSpeaking) return;
        // Ni mientras suena un aviso del teléfono: en la prueba del 21-oct el
        // asistente oyó "Modo reunión. Te escucho en silencio…" como si lo
        // dijera la persona.
        if (_onSpeaker && ref.read(announcerSpeakingProvider).value) {
          if (!_micPausedForNotice) {
            _micPausedForNotice = true;
            _log('[Lazarus] mic: en pausa mientras habla el teléfono');
          }
          return;
        }
        if (_micPausedForNotice) {
          _micPausedForNotice = false;
          _log('[Lazarus] mic: terminó el aviso del teléfono → reabierto');
        }
        _trackVoice(pcm);
        _micChunks++;
        if (_micChunks == 1) _log('[Lazarus] mic: primer chunk enviado');
        if (_micChunks % 50 == 0) _log('[Lazarus] mic: $_micChunks chunks');
        _session.sendAudio(pcm);
      });

      if (!_cameraAllowed) {
        _log('[Lazarus] media activa (solo micrófono: sin permiso de cámara)');
        return;
      }
      if (!_visible || _sessionBlind) {
        // Sesión de pantalla bloqueada: sin imágenes; la cámara vuelve con la
        // sesión que se abre al desbloquear.
        _cameraPaused = true;
        _log('[Lazarus] media activa (solo micrófono: pantalla bloqueada)');
        return;
      }
      await _startCamera();
      _log('[Lazarus] media activa (mic + cámara)');
    } catch (e) {
      _log('[Lazarus] fallo al arrancar media: $e');
    }
  }

  /// Tiempo para confirmar Detener después de que termina la pregunta. El
  /// 26-oct la pregunta tardó 6,8 s en terminar porque el asistente habló
  /// encima: una ventana contada desde el primer toque volvía a preguntar a
  /// quien esperaba a oírla entera.
  static const Duration stopConfirmWindow = Duration(seconds: 4);

  /// Si no se supo cuándo terminó la pregunta (el motor de voz no avisó), se
  /// cuenta desde el primer toque: la pregunta y unos 4 s para reaccionar.
  static const Duration stopConfirmFallback = Duration(seconds: 8);

  /// Tope: aunque la pregunta siga sonando, pasado este tiempo se vuelve a
  /// preguntar.
  static const Duration stopConfirmMax = Duration(seconds: 20);

  DateTime? _stopArmedAt;
  DateTime? _stopQuestionEndedAt;

  /// Tras Detener, el botón desaparece y la pantalla entera vuelve a iniciar:
  /// un toque de más en este tiempo no abre otra sesión (26-oct).
  static const Duration restartGuard = Duration(milliseconds: 1500);
  DateTime? _stoppedByButtonAt;

  /// Si un toque de Detener ahora confirmaría: mientras suena la pregunta y
  /// hasta [stopConfirmWindow] después de que termine.
  bool _stopConfirmOpen(DateTime now) {
    final armed = _stopArmedAt;
    if (armed == null) return false;
    final sinceArmed = now.difference(armed);
    if (sinceArmed > stopConfirmMax) return false;
    if (ref.read(announcerSpeakingProvider).value || _screenReaderSpeaking) {
      return true;
    }
    final ended = _stopQuestionEndedAt;
    return ended != null
        ? now.difference(ended) <= stopConfirmWindow
        : sinceArmed <= stopConfirmFallback;
  }

  /// La voz del teléfono terminó un aviso mientras se espera la confirmación.
  void _onAnnouncerSpeaking() {
    if (_stopArmedAt == null || ref.read(announcerSpeakingProvider).value) {
      return;
    }
    _stopQuestionEndedAt = ref.read(liveClockProvider)();
  }

  void _disarmStop() {
    if (_stopArmedAt == null) return;
    _stopArmedAt = null;
    _stopQuestionEndedAt = null;
    ref.read(announcerSpeakingProvider).removeListener(_onAnnouncerSpeaking);
  }

  /// Botón Detener: el primer toque pregunta y el segundo, mientras suena la
  /// pregunta o poco después, detiene. En la jornada del 24-oct un participante
  /// con TalkBack detuvo la app 11 veces en 40 min sin querer. Mientras se
  /// confirma, el asistente calla para que la pregunta se oiga sola.
  void requestStop() {
    final now = ref.read(liveClockProvider)();
    if (_stopConfirmOpen(now)) {
      _disarmStop();
      _log('[Lazarus] Detener confirmado con el botón');
      disconnect();
      _stoppedByButtonAt = now;
      return;
    }
    _disarmStop();
    _stopArmedAt = now;
    ref.read(announcerSpeakingProvider).addListener(_onAnnouncerSpeaking);
    final talkBack = ref.read(screenReaderActiveProvider)();
    _log(
      '[Lazarus] Detener: primer toque, se pide confirmación '
      '(${talkBack ? "con" : "sin"} TalkBack)',
    );
    _quietAssistantForStop();
    _announce(LiveNotice.stopConfirm);
  }

  /// Corta lo que el asistente esté diciendo; lo que siga llegando mientras se
  /// confirma Detener se descarta y no se envía `[OBSERVA]`.
  void _quietAssistantForStop() {
    _endObserve();
    if (!_assistantActive) return;
    _log('[Lazarus] Detener: el asistente calla mientras se confirma');
    _logAssistantSaid(' (cortado: se pidió Detener)');
    _assistantActive = false;
    _assistantTurnDone = false;
    _drainFallback?.cancel();
    _queuedAudioMs = 0;
    unawaited(_media.interruptPlayback());
  }

  /// Botón Detener: cierra la sesión; la próxima empieza con la presentación.
  /// Botón Detener: cierra la sesión, libera micrófono y cámara y avisa con una
  /// frase corta (sin reconectar).
  void disconnect() {
    _disarmStop();
    // Terminó con Detener: si Android cierra la app después, no es un corte.
    unawaited(_settings.setLastSessionStart(null));
    // Logs de campo al panel (HU-045): lo nuevo desde la última subida.
    unawaited(_uploadLogs('al detener'));
    _offlineReminder?.cancel();
    _offlineReminder = null;
    if (_sosByGesture) {
      _sosByGesture = false;
      ref.read(sosControllerProvider.notifier).cancel();
    }
    _teardown();
    _stopBackground();
    _endTelemetry('stopped');
    _routeAOffered = false;
    _disturbanceLiftRequest = null;
    if (_notesThisSession > 0) {
      final notas = _notesThisSession == 1 ? 'nota' : 'notas';
      _log('[Lazarus] bitácora: $_notesThisSession $notas en esta sesión');
      _notesThisSession = 0;
    }
    ref.read(locationControllerProvider.notifier).stop();
    _everConnected = false;
    _pendingKickoff = _PendingKickoff.intro;
    if (!ref.mounted) return;
    // Los modos de silencio son de sesión: Detener los termina.
    state = state.copyWith(
      status: LiveStatus.idle,
      meetingMode: false,
      micMuted: false,
    );
    _announce(LiveNotice.stopped);
  }

  /// Toque en pantalla: si está en silencio total, reactiva el micrófono; si
  /// no, arranca la sesión cuando aún no está en marcha.
  void onTap() {
    // Un toque cancela el SOS por gesto pendiente (HU-042).
    if (_sosByGesture &&
        ref.read(sosControllerProvider) == SosStatus.awaitingConfirmation) {
      _cancelGestureSos();
      return;
    }
    if (ref.read(sosControllerProvider) == SosStatus.awaitingConfirmation) {
      _cancelVoiceSos();
      return;
    }
    if (state.micMuted) {
      _resumeFromMute();
    } else if (!state.isLive) {
      final stopped = _stoppedByButtonAt;
      if (stopped != null &&
          ref.read(liveClockProvider)().difference(stopped) < restartGuard) {
        _log('[Lazarus] toque justo después de Detener: no inicia');
        return;
      }
      connect();
    }
  }

  /// Sale del silencio total (Modo B): vuelve a enviar mic/cámara y pide al
  /// asistente una confirmación corta de que ya vuelve a escuchar.
  void _resumeFromMute() {
    state = state.copyWith(micMuted: false);
    if (_session.connected && _cameraAllowed && _sessionBlind == _visible) {
      // La pantalla cambió durante el silencio: la sesión nueva confirma.
      _switchCameraSession();
    } else if (_session.connected) {
      // Sesión aún viva: reanuda el envío y pide confirmación, sin reconectar.
      // La confirmación suena aunque siga en modo reunión (LAZA-113).
      _expectReply();
      _allowTurn('reactivado con un toque');
      _session.sendMicResumed();
    } else {
      // La sesión se cerró durante el silencio (el backend la cierra por
      // inactividad al no recibir mic ni cámara). Reconecta con confirmación
      // corta, sin repetir la presentación completa.
      _pendingKickoff = _PendingKickoff.micOn;
      _teardown();
      _openSession(state.language);
    }
  }

  void _handleResponse(LiveResponse message) {
    if (!ref.mounted) return;
    switch (message.type) {
      case LiveResponseType.setupComplete:
        _log('[Lazarus] setupComplete → sesión lista, arrancando media');
        // Lo dicho antes de una sesión nueva (p. ej. al bloquear la pantalla)
        // no se responde en esta: medirlo daba latencias falsas de hasta 56 s.
        _lastVoiceAt = null;
        _lastWordAt = null;
        _wordSinceReply = false;
        // El panel pidió los logs de este teléfono (HU-045): se suben ya.
        if (!_uploadChecked) {
          _uploadChecked = true;
          unawaited(_uploadLogsIfRequested());
          unawaited(_loadRoutes());
        }
        state = state.copyWith(status: LiveStatus.connected);
        _telemetry.event('session_start', {
          'language': state.language,
          'resumed': _pendingKickoff != _PendingKickoff.intro,
          'camera': _cameraAllowed,
          'screen_locked': _sessionBlind,
        });
        _retryAttempts = 0;
        _everConnected = true;
        _routeAWatch?.cancel();
        _routeAWatch = Timer.periodic(
          const Duration(seconds: 30),
          (_) => checkRouteA(),
        );
        switch (_pendingKickoff) {
          case _PendingKickoff.voice:
            _expectReply();
            _session.sendVoiceSample();
          case _PendingKickoff.language:
            _expectReply();
            _session.sendLanguageChanged();
          case _PendingKickoff.micOn:
            _expectReply();
            _session.sendMicResumed();
          case _PendingKickoff.cameraOff:
            _expectReply();
            _session.sendCameraPaused();
          case _PendingKickoff.cameraOn:
            _expectReply();
            _session.sendCameraResumed();
          case _PendingKickoff.intro:
            _expectReply();
            _session.sendKickoff();
        }
        _pendingKickoff = _PendingKickoff.intro;
        _markActivity();
        _startMedia();
        // La pantalla cambió mientras se conectaba.
        _syncCameraSession();
      case LiveResponseType.inputTranscription:
        final t = message.data as LiveTranscription;
        _log('[Lazarus] te escuché (transcripción): "${t.text}"');
        state = state.copyWith(userTranscript: t.text);
        _heardCount++;
        _remember(t.text);
        // La persona habla: el ciclo de observación espera su respuesta. La
        // transcripción respalda al nivel del micrófono, que no capta una voz
        // baja (CP-LAZA-107: preguntas cortadas por [OBSERVA]).
        _observeSentAt = null;
        _expectReply();
        // Latencia voz a voz: cuenta solo una palabra real, no "<noise>" ni el
        // ruido que la transcripción escribe en otros alfabetos.
        if (isSpokenWords(t.text)) {
          _lastWordAt = DateTime.now();
          _wordSinceReply = true;
        }
        // Está respondiendo a "¿Envío la alerta…?": la cuenta espera.
        ref.read(sosControllerProvider.notifier).personSpoke();
        if (asksTotalSilence(_recentHeard())) _silenceRequested = true;
        _userTurnHeard.write(t.text);
        _sosHeard.write(t.text);
        if (!state.meetingMode && asksMeetingMode(_recentHeard())) {
          _meetingRequested = true;
        }
        final describing = asksDescriptions(_recentHeard());
        if (describing != null) _describingRequested = describing;
        if (state.meetingMode &&
            _calledByName() &&
            asksLeaveMeeting(_recentHeard())) {
          _leaveMeetingRequested = true;
        }
        if (_heldAudio.isNotEmpty && !_meetingConfirmTurn && _calledByName()) {
          _allowTurn('lo llamaron por su nombre');
        }
      case LiveResponseType.outputTranscription:
        final t = message.data as LiveTranscription;
        final clean = withoutControlTokens(t.text);
        if (clean.length != t.text.length) {
          _log('[Lazarus] transcripción del asistente con marcas internas');
        }
        _assistantSaid.write(clean);
        // En modo reunión, lo que no va a sonar tampoco se muestra: la persona
        // que mira la pantalla creería que lo dijo en voz alta (LAZA-113).
        state = state.copyWith(
          assistantTranscript: state.meetingMode && !_turnAllowed
              ? ''
              : _assistantSaid.toString(),
        );
      case LiveResponseType.toolCall:
        _markActivity();
        final call = message.data as LiveToolCall;
        _telemetry.event('tool_call', {
          'names': [for (final f in call.functionCalls) f.name],
        });
        _handleToolCall(call);
      case LiveResponseType.audio:
        final pcm = message.data as String;
        // Mientras se confirma Detener, el asistente no habla encima de la
        // pregunta (26-oct).
        if (_stopConfirmOpen(ref.read(liveClockProvider)())) return;
        // Modo reunión: calla salvo que lo llamen por su nombre. El audio se
        // retiene hasta saberlo (la transcripción puede llegar después).
        if (state.meetingMode && !_turnAllowed) {
          if (!_meetingConfirmTurn && _calledByName()) {
            _allowTurn('lo llamaron por su nombre');
          } else {
            if (_heldAudio.isEmpty) {
              _log('[Lazarus] modo reunión: respuesta retenida');
            }
            _heldAudio.add(pcm);
            return;
          }
        }
        _turnAllowed = _turnAllowed || state.meetingMode;
        _releaseHeldAudio();
        _playAssistantAudio(pcm);
      case LiveResponseType.interrupted:
        _logAssistantSaid(
          _endMeetingTurn() ? ' (descartado: modo reunión)' : ' (interrumpido)',
        );
        _log('[Lazarus] INTERRUMPIDO (barge-in: el usuario habló encima)');
        // La pregunta del SOS cortada a medias no cuenta como oída.
        _sosQuestionHeard = false;
        _telemetry.event('interrupted');
        _assistantActive = false;
        _assistantTurnDone = false;
        _drainFallback?.cancel();
        _queuedAudioMs = 0;
        final stopwatch = Stopwatch()..start();
        _media.interruptPlayback().then((_) {
          _log(
            '[Lazarus] reproducción detenida en ${stopwatch.elapsedMilliseconds} ms',
          );
        });
      case LiveResponseType.turnComplete:
        _applyRequestedNote(_assistantSaid.toString());
        _logAssistantSaid(
          _endMeetingTurn() ? ' (descartado: modo reunión)' : '',
        );
        _applyRequestedSilence();
        _applyRequestedDescriptions();
        _applyRequestedMeetingExit();
        _applyRequestedMeeting();
        _applyRequestedSos();
        // El asistente terminó de generar; el audio aún puede estar drenando.
        // El mic se reabrirá cuando la cola se vacíe (onDrained). Si el
        // drenado llegó primero (respuesta corta), reabre ya mismo.
        _log('[Lazarus] turnComplete (asistente terminó su turno)');
        _telemetry.event('turn_complete');
        if (_replyStarted) {
          // Terminó la respuesta esperada; la observación sigue tras una pausa.
          _replyPending = false;
          _replyStarted = false;
          _lastReplyEnd = DateTime.now();
        }
        _endObserve();
        _markActivity();
        _assistantTurnDone = true;
        if (_audioDrained) {
          _reopenMicIfTurnOver('turnComplete tras el fin del audio');
        } else if (_assistantActive) {
          _drainFallback?.cancel();
          _drainFallback = Timer(
            Duration(milliseconds: _queuedAudioMs) +
                ref.read(drainFallbackMarginProvider),
            () => _reopenMicIfTurnOver('por tiempo: no llegó el fin del audio'),
          );
        }
      case LiveResponseType.text:
      case LiveResponseType.unknown:
        break;
    }
  }

  /// Reproduce un fragmento de audio del asistente (en altavoz cierra el mic).
  void _playAssistantAudio(String pcm) {
    _audioInChunks++;
    if (ref.read(sosControllerProvider) == SosStatus.awaitingConfirmation) {
      _sosQuestionHeard = true;
    }
    if (_afterSpeech.isNotEmpty) _afterSpeechHeard = true;
    if (_audioInChunks == 1) {
      _log(
        '[Lazarus] audio del asistente: primer chunk recibido → reproduciendo',
      );
    }
    // El asistente está sonando → en altavoz, cierra el mic (anti-eco).
    if (!_assistantActive) {
      _log('[Lazarus] asistente: INICIA turno de audio');
      if (_replyPending) _replyStarted = true;
      final sent = _observeSentAt;
      if (sent != null && !_observeAnswered) {
        _observeAnswered = true;
        final ms = DateTime.now().difference(sent).inMilliseconds;
        _log('[Lazarus] observa: respondió en $ms ms');
        _telemetry.event('observe', {'answered': true, 'ms': ms});
      } else if (_wordSinceReply && _lastWordAt != null) {
        final ms = DateTime.now()
            .difference(endOfSpeech(_lastVoiceAt, _lastWordAt!))
            .inMilliseconds;
        _log('[Lazarus] latencia voz a voz: $ms ms');
        _telemetry.voiceToVoice(ms);
      }
      _wordSinceReply = false;
      // La voz que ya tuvo respuesta no cuenta para la siguiente.
      _lastVoiceAt = null;
      // Mientras habla, la persona no puede contestar a "¿Envío la alerta…?".
      ref.read(sosControllerProvider.notifier).assistantSpeaking();
    }
    _assistantActive = true;
    _assistantTurnDone = false;
    _audioDrained = false;
    _drainFallback?.cancel();
    // base64 → bytes (×3/4) → muestras de 16 bits (÷2) → ms a 24 kHz (÷24).
    _queuedAudioMs += pcm.length * 3 ~/ 4 ~/ 48;
    _media.playAudio(pcm);
  }

  void _markActivity() => _lastActivity = DateTime.now();

  /// Marca cuándo el micrófono captó voz por última vez (latencia voz a voz).
  void _trackVoice(String base64Pcm) {
    final double level;
    try {
      level = pcm16Level(base64Decode(base64Pcm));
    } on FormatException {
      return; // fragmento ilegible: no cuenta como voz
    }
    if (level < ref.read(voiceLevelThresholdProvider)) {
      _loudChunks = 0;
      return;
    }
    // Voz sostenida (unos 300 ms): pasos o golpes sueltos no cuentan. En la
    // prueba, el ruido al caminar frenó la observación hasta 15 s.
    if (++_loudChunks < 3) return;
    _lastVoiceAt = DateTime.now();
    _expectReply();
  }

  /// La app o la persona dijeron algo que el asistente va a responder.
  void _expectReply() {
    _replyPending = true;
    _replyStarted = false;
    _replyWaitFrom = DateTime.now();
    _markActivity();
  }

  /// Cierra la telemetría de la sesión con la mediana y el percentil 90.
  void _endTelemetry(String reason) {
    final s = _telemetry.endSession(reason);
    if (s.count > 0) {
      _log(
        '[Lazarus] latencia voz a voz: ${s.count} respuestas, mediana ${s.medianMs} ms, p90 ${s.p90Ms} ms',
      );
    }
    _lastVoiceAt = null;
    _lastWordAt = null;
    _wordSinceReply = false;
  }

  void _startObserving() {
    _observeTimer?.cancel();
    _observeSentAt = null;
    _markActivity();
    _observeTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _maybeObserve(),
    );
  }

  void _stopObserving() {
    _observeTimer?.cancel();
    _observeTimer = null;
    _observeSentAt = null;
  }

  /// Envía `[OBSERVA]` solo con todos callados: ni la persona ni el asistente
  /// hablan, no hay una respuesta pendiente, no es modo reunión ni silencio
  /// total y no hay una alerta SOS en curso (criterio 4 de HU-040).
  void _maybeObserve() {
    if (!ref.mounted || !_session.connected) return;
    if (state.status != LiveStatus.connected) return;
    if (state.meetingMode || state.micMuted || !_cameraAllowed) return;
    if (_cameraPaused) return;
    if (_assistantActive) return;
    if (ref.read(sosControllerProvider) != SosStatus.idle) return;
    if (_stopConfirmOpen(ref.read(liveClockProvider)())) return;
    final now = DateTime.now();
    // Con TalkBack hablando o recién callado, la persona está explorando la
    // pantalla: el asistente no le habla encima.
    final screenReaderAt = _screenReaderLastAt;
    if (_screenReaderSpeaking ||
        (screenReaderAt != null &&
            now.difference(screenReaderAt) <
                ref.read(screenReaderObserveQuietProvider))) {
      return;
    }
    // Se espera una respuesta (o un tiempo máximo) antes de observar, para no
    // cortarla; y tras una respuesta, una pausa por si la persona sigue.
    final waitFrom = _replyWaitFrom;
    if (_replyPending &&
        waitFrom != null &&
        now.difference(waitFrom) < ref.read(observeReplyWaitProvider)) {
      return;
    }
    final replyEnd = _lastReplyEnd;
    if (replyEnd != null &&
        now.difference(replyEnd) < ref.read(observeAfterReplyProvider)) {
      return;
    }
    final sent = _observeSentAt;
    if (sent != null) {
      if (now.difference(sent) < ref.read(observeTimeoutProvider)) return;
      _endObserve();
    }
    if (now.difference(_lastActivity) < ref.read(observePeriodProvider)) return;
    _observeSentAt = now;
    _observeAnswered = false;
    _lastActivity = now;
    // En pausa la app lo dice en el propio mensaje: el modelo no siempre
    // recuerda que se pausó a mitad de la sesión (CP-LAZA-107).
    _session.sendObserve(risksOnly: !_settings.getDescribing());
  }

  /// Cierra el `[OBSERVA]` en curso; si el asistente no habló, calló (correcto
  /// cuando no hay riesgo ni nada nuevo).
  void _endObserve() {
    if (_observeSentAt == null) return;
    if (!_observeAnswered) {
      _log('[Lazarus] observa: calló');
      _telemetry.event('observe', {'answered': false});
    }
    _observeSentAt = null;
  }

  /// Guarda lo que se oyó en los últimos segundos (modo reunión).
  void _remember(String text) {
    final now = DateTime.now();
    _heard
      ..removeWhere((h) => now.difference(h.at) > meetingNameWindow)
      ..add((at: now, text: text));
  }

  /// En modo reunión, si alguien dijo el nombre del asistente hace poco.
  bool _calledByName() {
    return mentionsName(_recentHeard(), _settings.getAssistantName());
  }

  /// Lo que se oyó en los últimos segundos, unido.
  String _recentHeard() {
    final now = DateTime.now();
    return _heard
        .where((h) => now.difference(h.at) <= meetingNameWindow)
        .map((h) => h.text)
        .join();
  }

  /// Red de seguridad del silencio total: el asistente dijo que se silenciaba
  /// pero no llamó a la función, así que la app deja de enviar igual.
  /// Red de seguridad de las notas: el asistente dijo "Anotado." sin llamar a
  /// `add_note`, así que la app guarda lo que pidió la persona.
  void _applyRequestedNote(String said) {
    // Turno sin respuesta hablada (p. ej. el de la función): la persona puede
    // seguir hablando y la respuesta llega en el turno siguiente.
    if (said.trim().isEmpty) return;
    final heard = _userTurnHeard.toString();
    final called = _noteCalled;
    _userTurnHeard.clear();
    _noteCalled = false;
    if (called || !saysNoted(said)) return;
    final text = noteRequestText(heard);
    if (text == null) return;
    _log(
      '[Lazarus] nota guardada por la app (el asistente dijo "Anotado" sin llamar a add_note)',
    );
    unawaited(_addFieldNote(text));
  }

  void _applyRequestedSilence() {
    if (!_silenceRequested) return;
    _silenceRequested = false;
    _heard.clear();
    if (state.micMuted) return;
    _log(
      '[Lazarus] silencio total aplicado por la app (el asistente no llamó a set_microphone)',
    );
    state = state.copyWith(micMuted: true);
    _announce(LiveNotice.muted);
  }

  /// Sigue la voz de TalkBack mientras dura la sesión (HU-023).
  void _listenScreenReaderSpeech() {
    _screenReaderSpeech?.cancel();
    _screenReaderSpeech = _media.screenReaderSpeech().listen((speaking) {
      if (speaking) {
        _screenReaderTail?.cancel();
        _screenReaderTail = null;
        if (!_screenReaderSpeaking && _onSpeaker) {
          _log('[Lazarus] mic: en pausa mientras habla TalkBack');
        }
        _screenReaderSpeaking = true;
        _screenReaderLastAt = DateTime.now();
        return;
      }
      _screenReaderTail?.cancel();
      _screenReaderTail = Timer(screenReaderSpeechTail, () {
        if (_screenReaderSpeaking && _onSpeaker) {
          _log('[Lazarus] mic: TalkBack terminó → reabierto');
        }
        _screenReaderSpeaking = false;
        _screenReaderTail = null;
        _screenReaderLastAt = DateTime.now();
        // Con TalkBack, la pregunta de Detener la dice el lector de pantalla.
        if (_stopArmedAt != null) {
          _stopQuestionEndedAt = ref.read(liveClockProvider)();
        }
      });
    });
  }

  Future<void> _uploadLogsIfRequested() async {
    if (await ref.read(deviceAccessRepositoryProvider).uploadRequested()) {
      await _uploadLogs('pedido desde el panel');
    }
  }

  /// Subidas en fila: dos a la vez leen los mismos offsets y mandan lo mismo
  /// (jornada del 24-oct: el .zip de un teléfono traía la evidencia repetida al
  /// tocar Detener seguido con la red lenta).
  Future<void> _uploads = Future<void>.value();

  Future<void> _uploadLogs(String reason) {
    final run = _uploads.then((_) async {
      final files = await ref.read(deviceAccessRepositoryProvider).uploadLogs();
      if (files > 0) {
        _log('[Lazarus] logs subidos al panel ($reason): $files archivos');
      }
    });
    _uploads = run.catchError((Object _) {});
    return run;
  }

  RouteAStatus _routeAStatus() {
    final wall = bogotaWallClock(ref.read(liveClockProvider)());
    return ref
        .read(unicentroScheduleProvider)
        .status(
          wall,
          disturbance: ref.read(disturbanceStoreProvider).isActive(wall),
        );
  }

  /// "Hay tropel en la universidad": la Ruta A queda inhabilitada el resto
  /// del día, a cualquier hora (regla 6). "Ya pasó el tropel" la levanta solo
  /// si la persona lo confirma: la primera vez la app pide confirmación y la
  /// segunda, ya con una nueva respuesta de la persona, la levanta.
  Future<String> _setDisturbance(bool active) async {
    final now = ref.read(liveClockProvider)();
    final wall = bogotaWallClock(now);
    final store = ref.read(disturbanceStoreProvider);
    if (active) {
      _disturbanceLiftRequest = null;
      await store.set(active: true, wall: wall);
      // La persona ya lo sabe: no hace falta el aviso de la regla 3.
      _routeAOffered = false;
      _log('[Lazarus] ruta A: disturbios reportados → inhabilitada hoy');
      return 'ok: Route A (the exit to Pasoancho through Unicentro) is '
          'disabled for the rest of today because of the disturbances. '
          'Confirm it in one short sentence and tell them to look for an '
          'alternate exit (Route B): the Calle 16 gate or the Carrera 86 gate.';
    }
    if (!store.isActive(wall)) {
      _disturbanceLiftRequest = null;
      return 'ok: there was no disturbance report today; the Unicentro '
          'schedule applies. Answer in one short sentence.';
    }
    final request = _disturbanceLiftRequest;
    if (request == null ||
        now.difference(request.at) > disturbanceLiftWindow ||
        _heardCount <= request.heard ||
        now.difference(request.at) < disturbanceLiftMinGap) {
      if (request == null ||
          now.difference(request.at) > disturbanceLiftWindow) {
        _disturbanceLiftRequest = (at: now, heard: _heardCount);
      }
      _log('[Lazarus] ruta A: levantar disturbios → se pide confirmación');
      return 'pending: the disturbance report is still active and Route A '
          'stays disabled. For safety it is lifted only if the person '
          'confirms. Ask once, in one short sentence, whether they are sure '
          'the disturbances are over. Only if the person answers yes or says '
          'it again, call set_route_disturbance with active=false again; '
          'otherwise keep it disabled.';
    }
    _disturbanceLiftRequest = null;
    await store.set(active: false, wall: wall);
    _log('[Lazarus] ruta A: reporte de disturbios levantado (confirmado)');
    return 'ok: the disturbance report was removed; the Unicentro schedule '
        'applies again. Confirm it in one short sentence.';
  }

  /// Respuesta de `get_unicentro_route`: la regla la decide la app con la hora
  /// de Colombia, no el asistente (HU-019, regla 5).
  String _describeRouteAForAssistant() {
    final status = _routeAStatus();
    _routeAOffered = status.available;
    final result = describeRouteA(status);
    _log('[Lazarus] ruta A (Unicentro): ${status.state.name} → $result');
    return result;
  }

  /// Si la persona iba por la Ruta A y se desactivó, el asistente lo avisa
  /// una sola vez y ofrece la ruta alterna (HU-019, regla 3).
  @visibleForTesting
  void checkRouteA() {
    if (!_routeAOffered || !ref.mounted || !_session.connected) return;
    final status = _routeAStatus();
    if (status.available) return;
    _routeAOffered = false;
    final notice = describeRouteA(status);
    _log('[Lazarus] ruta A desactivada durante la sesión → aviso: $notice');
    _expectReply();
    _session.sendRouteNotice(notice);
  }

  /// Descarga los perfiles de ruta (o usa los guardados, sin datos).
  Future<void> _loadRoutes() async {
    final body = await ref.read(deviceAccessRepositoryProvider).routeProfiles();
    if (body == null || !ref.mounted) return;
    try {
      _routes = RouteProfile.listFromJson(body);
    } on Object {
      return;
    }
    _log('[Lazarus] ruta: ${_routes.length} perfiles disponibles');
  }

  /// Respuesta de `start_route` (HU-022): elige el perfil que empieza cerca.
  String _startRoute(String destination) {
    final location = ref.read(locationControllerProvider);
    final fix = location.fix;
    if (fix == null || location.reliability != GpsReliability.reliable) {
      _log('[Lazarus] ruta: no se inicia, GPS no confiable');
      return 'no_gps: the GPS is not reliable right now, so the route cannot '
          'start. Tell the person in one short sentence and suggest trying '
          'again in the open in a moment.';
    }
    final route = pickRoute(_routes, fix, destination);
    if (route == null) {
      _log(
        '[Lazarus] ruta: ningún perfil empieza cerca (${_routes.length} cargados)',
      );
      return 'none: there is no curated route loaded that starts near here. '
          'Tell the person in one sentence and keep NO ROUTES.';
    }
    _stopRouteGuide();
    _routeGuide = RouteGuide(route);
    _routeWatch = Timer.periodic(routeCheckInterval, (_) => checkRoute());
    _log(
      '[Lazarus] ruta: iniciada "${route.slug}" (${route.points.length} puntos, '
      '${route.validatedInField ? "validada" : "sin validar"})',
    );
    final warning = route.validatedInField
        ? ''
        : 'not validated: it is a test route; tell the person it must only be '
              'used with a companion. ';
    return "ok: guiding along '${route.name}', from ${route.origin} to "
        '${route.destination}, ${route.points.length} points. $warning'
        "The app will send '[RUTA]' at each point: do not describe the route "
        'yourself.';
  }

  void _stopRouteGuide() {
    _routeWatch?.cancel();
    _routeWatch = null;
    _routeGuide = null;
  }

  /// Avanza la ruta activa con la última posición y, si llegó o se acerca a un
  /// punto, se lo pasa al asistente (HU-022). En modo reunión solo pasan los
  /// cruces y los riesgos altos.
  @visibleForTesting
  void checkRoute() {
    final guide = _routeGuide;
    if (guide == null || !ref.mounted || !_session.connected) return;
    final location = ref.read(locationControllerProvider);
    final fix = location.fix;
    if (fix == null) return;
    final event = guide.update(fix, location.reliability);
    if (event == null) return;
    final message = describeRouteEvent(
      event,
      fix,
      (p) => ref
          .read(locationControllerProvider.notifier)
          .clockHourTowards(p.latitude, p.longitude),
    );
    if (guide.finished) _stopRouteGuide();
    final point = event.point;
    if (state.meetingMode &&
        point.crossing == null &&
        point.risk != RouteRisk.high) {
      _log('[Lazarus] ruta (en modo reunión, no se dice): $message');
      return;
    }
    _log('[Lazarus] ruta: $message');
    _afterAssistantAudio(() {
      if (!ref.mounted || !_session.connected) return;
      _expectReply();
      _session.sendRouteGuide(message);
    });
  }

  /// Guarda una nota de campo con la hora y la última posición conocida, y
  /// devuelve la respuesta para el asistente (HU-024, criterio 3).
  Future<String> _addFieldNote(String raw) async {
    final text = raw.trim();
    if (text.isEmpty) {
      return 'error: the note is empty. Ask the person what to write down.';
    }
    final location = ref.read(locationControllerProvider);
    final fix = location.fix;
    final at = ref.read(liveClockProvider)();
    final saved = await ref
        .read(noteRecorderProvider)
        .add(
          FieldNote(
            at: at,
            text: text,
            fix: fix,
            reliability: location.reliability,
            heading: location.heading,
          ),
        );
    if (!saved) {
      _log('[Lazarus] nota no guardada: "$text"');
      return 'unavailable: this version of the app does not save notes. Tell '
          'the person, in one sentence, that you could not write it down.';
    }
    _notesThisSession++;
    String two(int n) => n.toString().padLeft(2, '0');
    final time = '${two(at.hour)}:${two(at.minute)}';
    final where = fix == null
        ? 'sin posición'
        : '±${fix.accuracyM.toStringAsFixed(0)} m, ${location.reliability.name}';
    _log('[Lazarus] nota: "$text" ($time, $where)');
    final position = fix == null
        ? 'without position (no GPS yet)'
        : 'with the position';
    if (isPlaceMarkerNote(text)) {
      return 'ok: note saved at $time $position, but it only marks the spot. '
          'Confirm in one word and then ask in one short sentence what is at '
          'this spot.';
    }
    return 'ok: note saved at $time $position. Reply ONLY with one word '
        'confirming it was written down.';
  }

  /// Red de seguridad de "Aria, ya puedes hablar": el asistente respondió sin
  /// llamar a `set_meeting_mode`, así que la app sale del modo reunión igual
  /// (en la prueba de LAZA-113 dijo "Entendido" y siguió callado).
  void _applyRequestedMeetingExit() {
    if (!_leaveMeetingRequested) return;
    _leaveMeetingRequested = false;
    if (!state.meetingMode) return;
    _heard.clear();
    _log(
      '[Lazarus] modo reunión desactivado por la app (el asistente no llamó a set_meeting_mode)',
    );
    state = state.copyWith(meetingMode: false);
    _whenAssistantFinishes(_syncCameraSession);
  }

  /// Red de seguridad de "voy a estar en una reunión": el asistente terminó el
  /// turno sin llamar a `set_meeting_mode`, así que la app entra en el modo
  /// igual y lo confirma con la voz del teléfono.
  void _applyRequestedMeeting() {
    if (!_meetingRequested) return;
    _meetingRequested = false;
    if (state.meetingMode || state.micMuted) return;
    _log(
      '[Lazarus] modo reunión activado por la app (el asistente no llamó a set_meeting_mode)',
    );
    state = state.copyWith(meetingMode: true);
    _turnAllowed = false;
    _afterAssistantAudio(() {
      if (state.meetingMode) _announce(LiveNotice.meetingOn);
    });
  }

  /// Red de seguridad del SOS: la persona dijo "SOS" y el asistente cerró el
  /// turno sin llamar a `trigger_sos` (prueba del 21-oct). La app sigue con el
  /// SOS del gesto: pregunta con la voz del teléfono y, sin respuesta, la envía.
  void _applyRequestedSos() {
    final heard = _sosHeard.toString();
    final called = _sosCalled;
    _sosHeard.clear();
    _sosCalled = false;
    if (called || !asksSos(heard, name: _settings.getAssistantName())) return;
    if (ref.read(sosControllerProvider) != SosStatus.idle) return;
    _log(
      '[Lazarus] SOS iniciado por la app (el asistente no llamó a trigger_sos)',
    );
    _afterAssistantAudio(() {
      if (ref.mounted && ref.read(sosControllerProvider) == SosStatus.idle) {
        unawaited(onSosGesture());
      }
    });
  }

  /// Al terminar el turno: si el audio del asistente sigue sonando, espera a
  /// que termine; si no sonó nada, actúa ya.
  void _afterAssistantAudio(void Function() action) {
    if (_assistantActive) {
      _whenAssistantFinishes(action);
    } else {
      action();
    }
  }

  /// Red de seguridad de "deja de describir" / "vuelve a describir": el
  /// asistente respondió sin llamar a `set_descriptions`, así que la app guarda
  /// el ajuste igual (persiste para la próxima sesión).
  void _applyRequestedDescriptions() {
    final wanted = _describingRequested;
    if (wanted == null) return;
    _describingRequested = null;
    if (_settings.getDescribing() == wanted) return;
    _settings.setDescribing(wanted);
    _log(
      '[Lazarus] descripciones ${wanted ? "reanudadas" : "en pausa"} por la app (el asistente no llamó a set_descriptions)',
    );
  }

  /// Este turno puede sonar en modo reunión: suelta el audio retenido.
  void _allowTurn(String reason) {
    if (_turnAllowed) return;
    _turnAllowed = true;
    _log('[Lazarus] modo reunión: responde ($reason)');
    state = state.copyWith(assistantTranscript: _assistantSaid.toString());
    _releaseHeldAudio();
  }

  void _releaseHeldAudio() {
    if (_heldAudio.isEmpty) return;
    final held = List<String>.of(_heldAudio);
    _heldAudio.clear();
    held.forEach(_playAssistantAudio);
  }

  /// Fin del turno del asistente: lo retenido y no autorizado se descarta.
  /// Devuelve si hubo audio descartado.
  bool _endMeetingTurn() {
    final discarded = _heldAudio.isNotEmpty;
    if (discarded) {
      _log(
        '[Lazarus] modo reunión: respuesta descartada (no lo llamaron por su nombre)',
      );
    }
    _heldAudio.clear();
    _turnAllowed = false;
    _meetingConfirmTurn = false;
    return discarded;
  }

  /// Medio-dúplex: el micrófono se reabre cuando el audio terminó **y** llegó
  /// `turnComplete`, en cualquier orden.
  void _reopenMicIfTurnOver(String reason) {
    if (!_assistantActive || !_assistantTurnDone) return;
    _drainFallback?.cancel();
    _assistantActive = false;
    if (_onSpeaker) _log('[Lazarus] mic: reabierto ($reason)');
    ref.read(sosControllerProvider.notifier).assistantFinished();
    if (_afterSpeechHeard) _runAfterSpeech();
  }

  /// Ejecuta [action] cuando termine de sonar la próxima respuesta del
  /// asistente, o pasado el tiempo de respaldo si no llega a sonar.
  void _whenAssistantFinishes(void Function() action) {
    _afterSpeech.add(action);
    // La respuesta ya está sonando (llegó antes que la función): basta con
    // que termine esta, sin esperar otra que quizá no llegue.
    if (_assistantActive) _afterSpeechHeard = true;
    _afterSpeechFallback?.cancel();
    _afterSpeechFallback = Timer(
      ref.read(sosQuestionFallbackProvider),
      _runAfterSpeech,
    );
  }

  void _runAfterSpeech() {
    _afterSpeechFallback?.cancel();
    _afterSpeechFallback = null;
    _afterSpeechHeard = false;
    final actions = List.of(_afterSpeech);
    _afterSpeech.clear();
    for (final action in actions) {
      action();
    }
  }

  /// La alerta se envió sola (nadie respondió a la confirmación): el asistente
  /// lo dice; si la sesión ya no está, lo dice la voz del teléfono.
  /// La cuenta del SOS por voz arranca cuando la persona oyó la pregunta. En la
  /// prueba del 21-oct un ruido cortó "¿Envío la…" antes de que sonara y la
  /// alerta salió sin que se oyera: si no sonó entera, la pregunta la hace la
  /// voz del teléfono y la cuenta espera a que termine.
  void _startSosCountdown() {
    if (!ref.mounted) return;
    final sos = ref.read(sosControllerProvider.notifier);
    if (ref.read(sosControllerProvider) != SosStatus.awaitingConfirmation) {
      return;
    }
    if (_sosQuestionHeard) {
      sos.startCountdown(_onSosAutoSent);
      return;
    }
    _log('[Lazarus] SOS: la pregunta no sonó; la hace el teléfono');
    _announceText(
      noticeText(
        LiveNotice.sosVoiceConfirm,
        state.language,
        name: sos.contactName() ?? '',
      ),
    );
    Future.delayed(ref.read(sosQuestionRepeatDelayProvider), () {
      if (ref.mounted) sos.startCountdown(_onSosAutoSent);
    });
  }

  /// Un toque cancela la alerta por voz que espera confirmación: el asistente
  /// recibe el resultado para no volver a preguntar.
  void _cancelVoiceSos() {
    final result = ref.read(sosControllerProvider.notifier).cancel();
    _announce(LiveNotice.sosCancelled);
    if (_session.connected) {
      _session.sendSosResult(
        '$result The person cancelled it with a tap and the phone already '
        'said "Alerta cancelada": do not repeat it.',
      );
    }
  }

  void _onSosAutoSent(String result) {
    if (!ref.mounted) return;
    // La respuesta que sigue no es a algo que dijo la persona: no cuenta para
    // la latencia (prueba del 21-oct: midió 26 s, la espera de la alerta).
    _wordSinceReply = false;
    if (_session.connected && state.status == LiveStatus.connected) {
      _turnAllowed = true; // debe sonar aunque esté en modo reunión
      _expectReply();
      _session.sendSosResult(result);
    } else {
      _announce(
        result.startsWith('sent') ? LiveNotice.sosSent : LiveNotice.sosFailed,
      );
    }
  }

  /// Llamada telefónica: el asistente se pausa (libera micrófono y altavoz) y
  /// al volver basta tocar la pantalla para retomar con una confirmación corta.
  void _startCall(CallTarget to) {
    if (!ref.mounted) return;
    _log('[Lazarus] llamada (${to.name}): asistente en pausa');
    _teardown();
    if (_everConnected) _pendingKickoff = _PendingKickoff.micOn;
    state = state.copyWith(
      status: LiveStatus.idle,
      meetingMode: false,
      micMuted: false,
    );
    ref.read(sosControllerProvider.notifier).placeCall(to);
  }

  void _logAssistantSaid([String note = '']) {
    final said = _assistantSaid.toString().trim();
    _assistantSaid.clear();
    if (said.isEmpty) return;
    _log('[Lazarus] asistente dijo$note: "$said"');
  }

  /// Personalización por voz: el asistente pidió ejecutar una o más funciones.
  void _handleToolCall(LiveToolCall toolCall) {
    _log(
      '[Lazarus] toolCall: ${toolCall.functionCalls.map((c) => "${c.name}(${c.args})").join(", ")}',
    );
    String? reconnectLang;
    var reconnectVoice = false;
    bool? meetingMode; // Modo A on/off (si aparece set_meeting_mode)
    bool? micActive; // Modo B: mic activo/apagado (si aparece set_microphone)
    // Funciones que tardan (GPS, SMS, permisos): se responde al terminar todas.
    final waits = <Future<void>>[];
    final sos = ref.read(sosControllerProvider.notifier);
    final results =
        <
          String,
          String
        >{}; // id de la llamada -> resultado si no es un ok simple

    for (final call in toolCall.functionCalls) {
      switch (call.name) {
        case 'set_assistant_name':
          final name = (call.args['name'] ?? '').toString().trim();
          if (name.isNotEmpty) _settings.setAssistantName(name);
        case 'set_user_name':
          final name = (call.args['name'] ?? '').toString().trim();
          if (name.isNotEmpty) _settings.setUserName(name);
        case 'set_voice':
          // Se acepta "aoede" o "AOEDE": se guarda con el nombre exacto de la voz.
          final asked = (call.args['voice'] ?? '')
              .toString()
              .trim()
              .toLowerCase();
          final voice = liveVoices.firstWhere(
            (v) => v.toLowerCase() == asked,
            orElse: () => '',
          );
          if (voice.isEmpty) {
            results[call.id] = unsupportedVoiceResult;
          } else {
            _settings.setVoice(voice);
            reconnectVoice = true;
            results[call.id] = restartResult;
          }
        case 'set_language':
          final lang = (call.args['language'] ?? '').toString();
          if (!liveLanguages.contains(lang)) {
            // Gemini puede pedir un idioma fuera de la lista (p. ej. ruso): no se
            // cambia nada y el asistente se lo explica a la persona.
            results[call.id] = unsupportedLanguageResult;
          } else {
            reconnectLang = lang;
            _settings.setLanguage(lang);
            results[call.id] = restartResult;
          }
        case 'set_verbosity':
          final level = (call.args['level'] ?? '').toString();
          if (level == 'concise' || level == 'detailed') {
            _settings.setVerbosity(level);
          }
        case 'set_descriptions':
          _settings.setDescribing(call.args['enabled'] == true);
          _describingRequested = null;
        case 'set_system_cues':
          // enabled=true => avisos activos => no silenciado.
          _settings.setSystemCuesMuted(call.args['enabled'] != true);
        case 'set_meeting_mode':
          meetingMode = call.args['enabled'] == true;
          _leaveMeetingRequested = false;
          _meetingRequested = false;
        case 'set_microphone':
          micActive = call.args['active'] != false;
          _silenceRequested = false;
        case 'get_location':
          // La dirección se busca en el geocodificador.
          waits.add(
            ref
                .read(locationControllerProvider.notifier)
                .describeForAssistant(canSee: _canSee)
                .then((where) {
                  _log('[Lazarus] ubicación para el asistente: $where');
                  results[call.id] = where;
                }),
          );
        case 'get_heading':
          // Hacia dónde mira la persona, o que pida calibrar (HU-016).
          waits.add(
            ref
                .read(locationControllerProvider.notifier)
                .describeHeadingForAssistant()
                .then((heading) {
                  _log('[Lazarus] rumbo para el asistente: $heading');
                  results[call.id] = heading;
                }),
          );
        case 'add_note':
          _noteCalled = true;
          // "Anota que la rampa está bloqueada" (HU-024).
          waits.add(
            _addFieldNote(
              (call.args['text'] ?? '').toString(),
            ).then((r) => results[call.id] = r),
          );
        case 'get_unicentro_route':
          results[call.id] = _describeRouteAForAssistant();
        case 'set_route_disturbance':
          waits.add(
            _setDisturbance(
              call.args['active'] == true,
            ).then((r) => results[call.id] = r),
          );
        case 'start_route':
          results[call.id] = _startRoute(
            (call.args['destination'] ?? '').toString(),
          );
        case 'stop_route':
          final had = _routeGuide != null;
          _stopRouteGuide();
          if (had) _log('[Lazarus] ruta: detenida a pedido de la persona');
          results[call.id] = had
              ? 'ok: route guidance stopped. Confirm it in one short sentence.'
              : 'ok: there was no active route.';
        case 'get_time':
          final time = describeLocalTime(ref.read(liveClockProvider)());
          _log('[Lazarus] hora para el asistente: $time');
          results[call.id] = time;
        case 'set_emergency_contact':
          waits.add(
            sos
                .setContact(
                  (call.args['name'] ?? '').toString(),
                  (call.args['phone'] ?? '').toString(),
                )
                .then((r) => results[call.id] = r),
          );
        case 'trigger_sos':
          _sosCalled = true;
          _sosQuestionHeard = false;
          // La pregunta de confirmación y el resultado deben sonar siempre.
          _allowTurn('alerta SOS');
          waits.add(
            sos.trigger().then((r) {
              _log('[Lazarus] SOS para el asistente: $r');
              results[call.id] = r;
              if (ref.read(sosControllerProvider) ==
                  SosStatus.awaitingConfirmation) {
                _whenAssistantFinishes(_startSosCountdown);
              }
            }),
          );
        case 'cancel_sos':
          _sosCalled = true;
          results[call.id] = sos.cancel();
        case 'call_phone':
          final to = call.args['to'] == 'emergency'
              ? CallTarget.emergency
              : CallTarget.contact;
          final r = sos.prepareCall(to);
          results[call.id] = r;
          if (r.startsWith('ok')) _whenAssistantFinishes(() => _startCall(to));
      }
    }

    // Aplica los modos de silencio (afectan captura y UI). No persisten.
    if (meetingMode != null || micActive != null) {
      state = state.copyWith(
        meetingMode: meetingMode,
        micMuted: micActive != null ? !micActive : null,
      );
    }
    // Al entrar, la confirmación la dice el teléfono y el "Entendido" del
    // asistente se descarta: no siempre se alcanzaba a oír y la persona no
    // sabía si había entrado (LAZA-113). Al salir, el asistente sí suena.
    if (meetingMode == true) {
      _meetingConfirmTurn = true;
      if (_assistantActive) {
        _whenAssistantFinishes(() => _announce(LiveNotice.meetingOn));
      } else {
        _turnAllowed = false;
        _announce(LiveNotice.meetingOn);
      }
    } else if (meetingMode == false) {
      _allowTurn('sale del modo reunión');
    }
    // También la del silencio total: sin ella, la persona no sabe si el
    // micrófono quedó apagado (LAZA-113).
    if (micActive != null) _allowTurn('silencio total');
    // Con TalkBack se anuncia el estado y cómo salir, después de la
    // confirmación del asistente para no taparla (HU-023, criterio 2).
    if (micActive == false) {
      _whenAssistantFinishes(() {
        if (state.micMuted) _announce(LiveNotice.muted);
      });
    }
    // Si la pantalla cambió durante la reunión, la sesión se ajusta al salir.
    if (meetingMode == false) _whenAssistantFinishes(_syncCameraSession);

    void respond() {
      _expectReply(); // tras la función, el asistente sigue hablando
      _session.sendToolResponse([
        for (final c in toolCall.functionCalls)
          (id: c.id, name: c.name, result: results[c.id] ?? 'ok'),
      ]);
    }

    if (waits.isEmpty) {
      respond();
    } else {
      Future.wait(waits).then((_) {
        if (ref.mounted) respond();
      });
    }

    // Cambiar idioma o voz exige una sesión nueva (ambos se fijan en el setup).
    if (reconnectLang != null || reconnectVoice) {
      final lang = reconnectLang ?? state.language;
      _pendingKickoff = reconnectLang != null
          ? _PendingKickoff.language
          : _PendingKickoff.voice;
      if (reconnectLang != null) {
        state = state.copyWith(language: reconnectLang);
      }
      Future.delayed(const Duration(milliseconds: 600), () {
        if (!ref.mounted) return;
        _teardown();
        _openSession(lang);
      });
    }
  }
}
