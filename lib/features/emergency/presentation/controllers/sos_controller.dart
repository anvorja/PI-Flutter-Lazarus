/// Alerta SOS (HU-012): configura el contacto, lleva la confirmación ("¿Envío
/// la alerta a…?") y envía el SMS con la ubicación. Cada método devuelve el
/// texto que recibe el asistente como resultado de su función; el asistente
/// solo dice lo que ese resultado le indica (regla: detenerse y esperar apoyo
/// humano, sin improvisar).
///
/// La cuenta de 5 s la arranca [LiveController] cuando termina de sonar la
/// pregunta: sin respuesta, la alerta se envía sola (regla 2).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../live/presentation/providers/live_providers.dart';
import '../../../location/domain/entities/location_fix.dart';
import '../../../location/presentation/controllers/location_controller.dart';
import '../../../location/domain/repositories/location_repository.dart';
import '../../../location/presentation/providers/location_providers.dart';
import '../../domain/entities/emergency_contact.dart';
import '../../domain/entities/sos_message.dart';
import '../../domain/repositories/emergency_repository.dart';
import '../providers/emergency_providers.dart';
import '../../../../core/debug/live_debug.dart';

void _log(String message) => liveLog(message);

/// Línea oficial de emergencias de Colombia.
const String emergencyLineNumber = '123';

enum SosStatus {
  idle,

  /// Se preguntó "¿Envío la alerta a…?" y se espera respuesta.
  awaitingConfirmation,
  sending,
}

class SosController extends Notifier<SosStatus> {
  late final EmergencyRepository _repo;
  Timer? _countdown;
  DateTime? _countdownStarted;
  void Function(String result)? _onAutoSent;

  /// La cuenta está en pausa porque el asistente habla (en altavoz el
  /// micrófono está cerrado y la persona no puede contestar).
  bool _paused = false;

  /// Si esta alerta pendiente se envía sola al vencer la cuenta. No, cuando ya
  /// se envió otra hace poco: entonces solo se envía si la persona lo confirma.
  bool _autoSend = true;
  DateTime? _lastSentAt;

  @override
  SosStatus build() {
    _repo = ref.read(emergencyRepositoryProvider);
    ref.onDispose(() => _countdown?.cancel());
    return SosStatus.idle;
  }

  /// `set_emergency_contact`: valida y guarda el número y pide los permisos.
  Future<String> setContact(String name, String rawPhone) async {
    final phone = normalizePhone(rawPhone);
    if (phone == null) {
      // En la prueba el reconocimiento de voz añadía o perdía el primer
      // dígito: se le dice a la persona qué se oyó, por grupos, para que vea
      // dónde está el error.
      final digits = rawPhone.replaceAll(RegExp(r'[^0-9]'), '');
      _log('[Lazarus] SOS: número inválido (${digits.length} dígitos)');
      return 'error: invalid number, nothing was saved. You heard '
          '${digits.length} digits: ${spokenPhone(digits)}. A Colombian mobile '
          'number has 10 digits and starts with 3 (a landline starts with 60). '
          'Read those groups back to the person, tell them how many digits a '
          'number must have, and ask them to say it again slowly in groups of '
          'three, three and four digits (for example: "tres uno cinco, uno dos '
          'tres, cuatro cinco seis siete").';
    }
    final contact = EmergencyContact(name: name.trim(), phone: phone);
    await _repo.setContact(contact);
    _log('[Lazarus] SOS: contacto guardado (${contact.name})');
    var canSms = false;
    try {
      canSms = await _repo.requestPermissions();
    } catch (e) {
      _log('[Lazarus] SOS: no se pudieron pedir los permisos ($e)');
    }
    final saved =
        'ok: emergency contact saved: ${_nameOf(contact)}, '
        '${spokenPhone(phone)}. Repeat the name and the number in groups of '
        'digits so the person can confirm it.';
    if (canSms) return saved;
    return '$saved The SMS permission was not granted: also tell them that '
        'the alert cannot be sent until they allow SMS for Lazarus in the '
        'phone settings.';
  }

  /// `trigger_sos`: la primera vez pide confirmación; si ya se preguntó, la
  /// persona confirmó y se envía.
  Future<String> trigger() async {
    final contact = _repo.getContact();
    if (contact == null) {
      _log('[Lazarus] SOS: sin contacto de emergencia');
      return 'no_contact: there is no emergency contact, so no alert was sent. '
          'Offer to call the emergency line 123 now (call_phone with '
          'to="emergency") and ask them to set a contact by saying "my '
          'emergency contact is" with the name and number.';
    }
    switch (state) {
      case SosStatus.idle:
        state = SosStatus.awaitingConfirmation;
        final name = _nameOf(contact);
        final last = _lastSentAt;
        final since = last == null ? null : DateTime.now().difference(last);
        // En la prueba, un "Ah! So." dicho mientras salía la alerta abrió otra y
        // se envió un segundo SMS sin que la persona lo quisiera.
        if (since != null && since < ref.read(sosResendGuardProvider)) {
          _autoSend = false;
          _log(
            '[Lazarus] SOS: ya se envió hace ${since.inSeconds} s; otra solo '
            'si la persona la confirma',
          );
          return 'pending: an alert was already sent to $name '
              '${since.inSeconds} seconds ago. Ask the person ONLY this, in '
              'their language: "Ya envié la alerta a $name. ¿Envío otra?". If '
              'they say yes, call trigger_sos again; if they say no, call '
              'cancel_sos. If they say nothing, do not send it.';
        }
        _autoSend = true;
        _log('[Lazarus] SOS: pedido; esperando confirmación');
        return 'pending: ask the person ONLY this, in their language: "¿Envío '
            'la alerta a $name?". If they say yes or SOS again, call '
            'trigger_sos again; if they say no, call cancel_sos. If they say '
            'nothing, the app sends it on its own in a few seconds.';
      case SosStatus.awaitingConfirmation:
        _log('[Lazarus] SOS: confirmado por la persona');
        return _send(contact);
      case SosStatus.sending:
        return 'pending: the alert is being sent right now. Tell the person to '
            'wait a moment.';
    }
  }

  /// Arranca la cuenta de la confirmación (cuando ya sonó la pregunta). Al
  /// vencer, envía la alerta y entrega el resultado a [onAutoSent].
  void startCountdown(void Function(String result) onAutoSent) {
    if (state != SosStatus.awaitingConfirmation || _countdown != null) return;
    if (!_autoSend) return; // ya se envió una hace poco: solo con confirmación
    _onAutoSent = onAutoSent;
    _countdownStarted = DateTime.now();
    final window = ref.read(sosConfirmationWindowProvider);
    _log('[Lazarus] SOS: cuenta de ${window.inSeconds} s para enviar sola');
    _armCountdown();
  }

  /// La persona está hablando durante la cuenta: su respuesta tarda en llegar
  /// al asistente (en la prueba, hasta 9 s entre "Sí, envía." y la función),
  /// así que se espera su decisión un poco más. Con un tope total, para que el
  /// ruido no retrase la alerta sin fin.
  void personSpoke() {
    final started = _countdownStarted;
    if (_countdown == null || started == null) return;
    if (DateTime.now().difference(started) >= ref.read(sosMaxWaitProvider)) {
      return;
    }
    _log('[Lazarus] SOS: la persona habla; se espera su respuesta');
    _armCountdown(ref.read(sosAnswerWindowProvider));
  }

  /// El asistente empezó a hablar: la cuenta se detiene.
  void assistantSpeaking() {
    if (_countdown == null) return;
    _countdown?.cancel();
    _countdown = null;
    _paused = true;
    _log('[Lazarus] SOS: cuenta en pausa mientras habla el asistente');
  }

  /// El asistente terminó y el micrófono se reabrió: la cuenta vuelve a
  /// empezar completa.
  void assistantFinished() {
    if (!_paused) return;
    _paused = false;
    if (state != SosStatus.awaitingConfirmation) return;
    _countdownStarted = DateTime.now();
    _log('[Lazarus] SOS: el asistente terminó; la cuenta vuelve a empezar');
    _armCountdown();
  }

  void _armCountdown([Duration? window]) {
    _countdown?.cancel();
    _countdown = Timer(
      window ?? ref.read(sosConfirmationWindowProvider),
      () async {
        _countdown = null;
        _countdownStarted = null;
        final contact = _repo.getContact();
        if (state != SosStatus.awaitingConfirmation || contact == null) return;
        _log('[Lazarus] SOS: sin respuesta; se envía sola');
        final result = await _send(contact);
        _onAutoSent?.call(result);
      },
    );
  }

  /// `cancel_sos`.
  String cancel() {
    if (state != SosStatus.awaitingConfirmation) {
      return 'ok: there was no alert waiting to be sent.';
    }
    _countdown?.cancel();
    _countdown = null;
    _countdownStarted = null;
    _paused = false;
    state = SosStatus.idle;
    _log('[Lazarus] SOS: cancelado por la persona');
    return 'cancelled: no alert was sent. Confirm it in a few words.';
  }

  /// `call_phone`: comprueba a quién se puede llamar. La llamada la hace
  /// [placeCall] cuando el asistente termina de hablar.
  String prepareCall(CallTarget to) {
    if (to == CallTarget.emergency) {
      return 'ok: the phone dialer opens now with 123. Tell the person in one '
          'short sentence to press the call button at the bottom center of '
          'the screen. You will be paused.';
    }
    final contact = _repo.getContact();
    if (contact == null) {
      return 'no_contact: there is no emergency contact to call. Offer to call '
          'the emergency line 123 instead.';
    }
    return 'ok: calling ${_nameOf(contact)} now. Say only a very short sentence '
        'such as "Llamando a ${_nameOf(contact)}." You will be paused during '
        'the call.';
  }

  Future<bool> placeCall(CallTarget to) async {
    if (to == CallTarget.emergency) {
      _log('[Lazarus] SOS: marcador con el $emergencyLineNumber');
      return _repo.dial(emergencyLineNumber);
    }
    final contact = _repo.getContact();
    if (contact == null) return false;
    _log('[Lazarus] SOS: llamando al contacto de emergencia');
    return _repo.call(contact.phone);
  }

  Future<SosPosition?> _withAddress(SosPosition? position) =>
      _withAddressFrom(ref.read(locationRepositoryProvider), position);

  Future<String> _send(EmergencyContact contact) async {
    _countdown?.cancel();
    _countdown = null;
    _countdownStarted = null;
    _paused = false;
    state = SosStatus.sending;
    final name = _nameOf(contact);
    final watch = Stopwatch()..start();
    final position = await _withAddress(
      sosPositionFrom(ref.read(locationControllerProvider)),
    );
    final text = buildSosMessage(
      language: ref.read(liveSettingsRepositoryProvider).getLanguage(),
      userName: ref.read(liveSettingsRepositoryProvider).getUserName(),
      position: position,
    );
    SmsResult sent;
    try {
      sent = await _repo.sendSms(contact.phone, text);
    } catch (e) {
      _log('[Lazarus] SOS: error al enviar ($e)');
      sent = SmsResult.failed;
    }
    if (sent == SmsResult.sent || sent == SmsResult.timeout) {
      _lastSentAt = DateTime.now();
    }
    if (ref.mounted) state = SosStatus.idle;
    final where = position == null
        ? 'sin ubicación'
        : position.current
        ? 'ubicación actual ±${position.accuracyM.toStringAsFixed(0)} m'
        : 'última ubicación conocida de las ${clockTime(position.at)}';
    _log(
      '[Lazarus] SOS: ${sent.name} en ${watch.elapsedMilliseconds} ms '
      '($where)',
    );
    if (sent == SmsResult.timeout) {
      // En la prueba la red (SMS por VoLTE) no confirmó el envío: no se sabe
      // si llegó, así que no se puede decir que no se envió.
      return 'unconfirmed: the SMS was handed to the phone network, but the '
          'network did not confirm it in time, so it may or may not arrive. '
          'Tell the person you cannot confirm that $name got the alert and '
          'offer to call $name now (call_phone with to="contact").';
    }
    if (sent != SmsResult.sent) {
      final reason = switch (sent) {
        SmsResult.noPermission => 'the SMS permission was not granted',
        _ => 'no signal or the operator rejected it',
      };
      return 'failed: the SMS could not be sent ($reason). Tell the person the '
          'alert was NOT sent and offer to call $name (call_phone with '
          'to="contact") or the emergency line 123 (call_phone with '
          'to="emergency").';
    }
    final withWhat = position == null
        ? 'without a location, because there is no GPS position'
        : position.current
        ? 'with their current location'
        : 'with their last known location from ${clockTime(position.at)}, '
              'because the GPS is not reliable now';
    return 'sent: the SMS was sent to $name $withWhat. Tell the person that '
        '$name has the alert, to stop in a safe place and wait, and offer to '
        'call $name (call_phone with to="contact").';
  }
}

/// Añade la dirección aproximada, sin pasar de [sosAddressTimeout]: la alerta
/// no espera al geocodificador más de eso (criterio 1: menos de 10 s).
Future<SosPosition?> _withAddressFrom(
  LocationRepository repo,
  SosPosition? position,
) async {
  if (position == null) return null;
  try {
    final address = await repo
        .addressOf(
          LocationFix(
            latitude: position.latitude,
            longitude: position.longitude,
            accuracyM: position.accuracyM,
            at: position.at,
          ),
        )
        .timeout(sosAddressTimeout, onTimeout: () => null);
    return position.withAddress(address);
  } catch (_) {
    return position;
  }
}

/// Máximo que se espera la dirección antes de enviar solo las coordenadas.
const Duration sosAddressTimeout = Duration(seconds: 3);

String _nameOf(EmergencyContact contact) =>
    contact.name.isEmpty ? 'your emergency contact' : contact.name;

/// Qué posición lleva la alerta: la actual si el GPS es confiable; si no, la
/// última tomada con GPS confiable; si nunca lo fue, la última que haya.
SosPosition? sosPositionFrom(LocationState location) {
  final fix = location.fix;
  if (fix != null && location.reliability == GpsReliability.reliable) {
    return _position(fix, current: true);
  }
  final last = location.lastReliableFix ?? fix;
  return last == null ? null : _position(last, current: false);
}

SosPosition _position(LocationFix fix, {required bool current}) => SosPosition(
  latitude: fix.latitude,
  longitude: fix.longitude,
  accuracyM: fix.accuracyM,
  at: fix.at,
  current: current,
);
