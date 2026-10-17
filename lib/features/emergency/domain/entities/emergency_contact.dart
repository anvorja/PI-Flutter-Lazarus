/// Contacto de emergencia (HU-012): quién recibe la alerta SOS. Se configura
/// por voz ("mi contacto de emergencia es…") y persiste en el teléfono.
library;

import 'package:flutter/foundation.dart';

@immutable
class EmergencyContact {
  const EmergencyContact({required this.name, required this.phone});

  final String name;

  /// Número normalizado (ver [normalizePhone]), p. ej. `+573151234567`.
  final String phone;
}

/// Normaliza el número que dictó la persona. En Colombia los celulares (3…) y
/// los fijos (60…) tienen 10 dígitos y se les antepone el +57; un número con
/// prefijo internacional se acepta tal cual. Devuelve `null` si no parece un
/// número de teléfono.
String? normalizePhone(String raw) {
  final compact = raw.replaceAll(RegExp(r'[^0-9+]'), '');
  final international = compact.startsWith('+');
  final digits = compact.replaceAll('+', '');
  if (international) {
    return digits.length >= 8 && digits.length <= 15 ? '+$digits' : null;
  }
  if (digits.length == 10 &&
      (digits.startsWith('3') || digits.startsWith('60'))) {
    return '+57$digits';
  }
  if (digits.length == 12 && digits.startsWith('57')) return '+$digits';
  return null;
}

/// El número para leerlo en voz alta por grupos: "315 123 4567" (sin el +57
/// de Colombia) o de a tres dígitos si es de otro país.
String spokenPhone(String phone) {
  final national = phone.startsWith('+57') && phone.length == 13
      ? phone.substring(3)
      : phone.replaceAll('+', '');
  if (national.length == 10) {
    return '${national.substring(0, 3)} ${national.substring(3, 6)} '
        '${national.substring(6)}';
  }
  final groups = <String>[];
  for (var i = 0; i < national.length; i += 3) {
    groups.add(
      national.substring(i, i + 3 > national.length ? national.length : i + 3),
    );
  }
  return groups.join(' ');
}
