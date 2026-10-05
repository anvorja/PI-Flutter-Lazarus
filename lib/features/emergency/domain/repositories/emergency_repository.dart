/// Contrato de la alerta SOS (HU-012): guardar el contacto de emergencia,
/// pedir los permisos, enviar el SMS y hacer llamadas. No dice nada de
/// `SharedPreferences`, `SmsManager` ni intents: eso es de la implementación.
library;

import '../entities/emergency_contact.dart';

/// Resultado del envío del SMS, ya confirmado por el sistema.
enum SmsResult {
  sent,

  /// La persona no dio el permiso de SMS.
  noPermission,

  /// Sin señal, sin SIM o error del operador.
  failed,

  /// El sistema no confirmó el envío a tiempo.
  timeout,
}

/// A quién llamar con `call_phone`.
enum CallTarget { contact, emergency }

abstract class EmergencyRepository {
  /// `null` si la persona aún no configuró su contacto.
  EmergencyContact? getContact();
  Future<void> setContact(EmergencyContact contact);

  /// Pide los permisos de SMS y de llamadas. Devuelve si se puede enviar SMS.
  Future<bool> requestPermissions();

  /// Envía el SMS y espera la confirmación del sistema.
  Future<SmsResult> sendSms(String phone, String text);

  /// Llama directo al número (si no hay permiso, abre el marcador con él).
  Future<bool> call(String phone);

  /// Abre el marcador con el número: Android no deja que una app llame sola a
  /// una línea de emergencias.
  Future<bool> dial(String number);
}
