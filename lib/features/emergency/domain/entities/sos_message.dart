/// Texto del SMS de la alerta SOS (HU-012): quién pide ayuda, dirección
/// aproximada, coordenadas, precisión y hora. Si el GPS no es confiable, se
/// envía la última posición conocida con su hora (regla 4).
///
/// Sin enlaces: en la prueba los operadores no entregaron ningún SMS con un
/// enlace (ni desde Lazarus ni desde la app de Mensajes), y sí los de solo
/// texto. Las coordenadas se pueden pegar en cualquier app de mapas.
library;

import 'package:flutter/foundation.dart';

/// Posición que lleva la alerta.
@immutable
class SosPosition {
  const SosPosition({
    required this.latitude,
    required this.longitude,
    required this.accuracyM,
    required this.at,
    required this.current,
    this.address,
  });

  final double latitude;
  final double longitude;
  final double accuracyM;
  final DateTime at;

  /// `true` = posición actual con GPS confiable; `false` = última conocida.
  final bool current;

  /// Dirección aproximada ("Carrera 76 # 14C-101, Comuna 17, Cali"), si el
  /// geocodificador respondió a tiempo.
  final String? address;

  SosPosition withAddress(String? address) => SosPosition(
    latitude: latitude,
    longitude: longitude,
    accuracyM: accuracyM,
    at: at,
    current: current,
    address: address,
  );

  /// "3.38927,-76.53019": 5 decimales, alrededor de un metro.
  String get coordinates =>
      '${latitude.toStringAsFixed(5)},${longitude.toStringAsFixed(5)}';
}

/// Hora local "HH:MM" (el GPS entrega la hora en UTC).
String clockTime(DateTime at) {
  final local = at.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

/// Solo caracteres del alfabeto básico de SMS: con una tilde o un "±" el
/// mensaje pasa a otra codificación de 70 caracteres por parte y sale en 3
/// partes; sin ellos cabe en una (más rápido y más fiable).
String smsSafe(String text) {
  const from = 'áàâäãÁÀÂÄÃéèêëÉÈÊËíìîïÍÌÎÏóòôöõÓÒÔÖÕúùûüÚÙÛÜñÑçÇ';
  const to = 'aaaaaAAAAAeeeeEEEEiiiiIIIIoooooOOOOOuuuuUUUUnNcC';
  final out = StringBuffer();
  for (final ch in text.split('')) {
    final i = from.indexOf(ch);
    if (i >= 0) {
      out.write(to[i]);
    } else if (ch.codeUnitAt(0) < 128) {
      out.write(ch);
    }
  }
  return out.toString();
}

typedef _Texts = ({
  String who,
  String nobody,
  String current,
  String last,
  String coords,
  String none,
  String by,
});

const Map<String, _Texts> _texts = {
  'es': (
    who: 'SOS de {name}: necesito ayuda.',
    nobody: 'SOS: necesito ayuda.',
    current: 'Estoy en {place} (precision {m} m, {time}).',
    last:
        'GPS no confiable; ultima ubicacion conocida ({time}, precision {m} m): {place}.',
    coords: 'Coordenadas',
    none: 'No hay ubicacion disponible; llamame.',
    by: 'Enviado por Lazarus.',
  ),
  'en': (
    who: 'SOS from {name}: I need help.',
    nobody: 'SOS: I need help.',
    current: 'I am at {place} (accuracy {m} m, {time}).',
    last:
        'GPS not reliable; last known location ({time}, accuracy {m} m): {place}.',
    coords: 'Coordinates',
    none: 'No location available; call me.',
    by: 'Sent by Lazarus.',
  ),
  'fr': (
    who: 'SOS de {name} : j\'ai besoin d\'aide.',
    nobody: 'SOS : j\'ai besoin d\'aide.',
    current: 'Je suis a {place} (precision {m} m, {time}).',
    last:
        'GPS pas fiable ; derniere position connue ({time}, precision {m} m) : {place}.',
    coords: 'Coordonnees',
    none: 'Aucune position disponible ; appelle-moi.',
    by: 'Envoye par Lazarus.',
  ),
  'pt': (
    who: 'SOS de {name}: preciso de ajuda.',
    nobody: 'SOS: preciso de ajuda.',
    current: 'Estou em {place} (precisao {m} m, {time}).',
    last:
        'GPS nao confiavel; ultima localizacao conhecida ({time}, precisao {m} m): {place}.',
    coords: 'Coordenadas',
    none: 'Sem localizacao disponivel; me ligue.',
    by: 'Enviado pelo Lazarus.',
  ),
  'it': (
    who: 'SOS da {name}: ho bisogno di aiuto.',
    nobody: 'SOS: ho bisogno di aiuto.',
    current: 'Sono a {place} (precisione {m} m, {time}).',
    last:
        'GPS non affidabile; ultima posizione nota ({time}, precisione {m} m): {place}.',
    coords: 'Coordinate',
    none: 'Nessuna posizione disponibile; chiamami.',
    by: 'Inviato da Lazarus.',
  ),
};

/// Arma el SMS en el idioma de la persona (español si no está disponible),
/// sin tildes ni enlaces.
String buildSosMessage({
  required String language,
  required String userName,
  required SosPosition? position,
}) {
  final t = _texts[language] ?? _texts['es']!;
  final name = userName.trim();
  final who = name.isEmpty ? t.nobody : t.who.replaceAll('{name}', name);
  final String where;
  if (position == null) {
    where = t.none;
  } else {
    final address = position.address?.trim() ?? '';
    final coords = '${t.coords} ${position.coordinates}';
    final place = address.isEmpty ? coords : '$address. $coords';
    where = (position.current ? t.current : t.last)
        .replaceAll('{place}', place)
        .replaceAll('{m}', position.accuracyM.toStringAsFixed(0))
        .replaceAll('{time}', clockTime(position.at));
  }
  return smsSafe('$who $where ${t.by}');
}
