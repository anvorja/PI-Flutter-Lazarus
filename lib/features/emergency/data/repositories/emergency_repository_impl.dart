/// Implementación de [EmergencyRepository]: el contacto vive en
/// `SharedPreferences` y el SMS y las llamadas van por el canal nativo.
library;

import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entities/emergency_contact.dart';
import '../../domain/repositories/emergency_repository.dart';
import '../datasources/emergency_phone_datasource.dart' as phone_channel;
import '../../../../core/debug/live_debug.dart';

const String _nameKey = 'lazarus_emergency_contact_name';
const String _phoneKey = 'lazarus_emergency_contact_phone';

/// Máximo que se espera la confirmación del SMS (criterio 1: menos de 10 s en
/// total; si el operador tarda más, se informa y se ofrece llamar).
const Duration smsConfirmationTimeout = Duration(seconds: 9);

class EmergencyRepositoryImpl implements EmergencyRepository {
  EmergencyRepositoryImpl(this._prefs);

  final SharedPreferences _prefs;

  @override
  EmergencyContact? getContact() {
    final name = _prefs.getString(_nameKey)?.trim() ?? '';
    final phone = _prefs.getString(_phoneKey)?.trim() ?? '';
    if (phone.isEmpty) return null;
    return EmergencyContact(name: name, phone: phone);
  }

  @override
  Future<void> setContact(EmergencyContact contact) async {
    await _prefs.setString(_nameKey, contact.name.trim());
    await _prefs.setString(_phoneKey, contact.phone);
  }

  @override
  Future<bool> requestPermissions() async {
    final statuses = await [Permission.sms, Permission.phone].request();
    return statuses[Permission.sms]?.isGranted ?? false;
  }

  @override
  Future<SmsResult> sendSms(String phone, String text) async {
    if (!await Permission.sms.isGranted &&
        !(await Permission.sms.request()).isGranted) {
      return SmsResult.noPermission;
    }
    final result = await phone_channel
        .sendSms(phone, text)
        .timeout(smsConfirmationTimeout, onTimeout: () => 'timeout');
    if (result != 'sent') liveLog('[Lazarus] SOS: SMS no enviado ($result)');
    return switch (result) {
      'sent' => SmsResult.sent,
      'timeout' => SmsResult.timeout,
      _ => SmsResult.failed,
    };
  }

  @override
  Future<bool> call(String phone) => phone_channel.call(phone);

  @override
  Future<bool> dial(String number) => phone_channel.dial(number);
}
