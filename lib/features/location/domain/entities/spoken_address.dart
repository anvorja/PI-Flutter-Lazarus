/// Dirección colombiana lista para decir en voz alta.
///
/// Con "Carrera 76 # 14C-80" el asistente a veces decía "catorce ce" dos veces:
/// el bloque "# 14C-80" (numeral, letra pegada y guion) es ambiguo al hablar.
/// Aquí se separa: "Carrera 76 número 14 C 80" (CP-LAZA-45).
library;

final _letter = RegExp(r'\b(\d+)([A-Za-z])\b');
final _crossing = RegExp(
  r'#\s*(Calle|Carrera|Avenida|Diagonal|Transversal)\b',
  caseSensitive: false,
);
final _dash = RegExp(r'([0-9A-Z])\s*-\s*(\d)');
// Placa sin guion ("# 7615"): con 4 cifras, son 76 y 15.
final _joined = RegExp(r'#\s*(\d{2})(\d{2})\b');

String spokenAddress(String address) {
  var s = address
      .replaceAllMapped(_letter, (m) => '${m[1]} ${m[2]!.toUpperCase()}')
      .replaceAllMapped(_crossing, (m) => 'con ${m[1]}')
      .replaceAllMapped(_joined, (m) => 'número ${m[1]} ${m[2]}')
      .replaceAllMapped(_dash, (m) => '${m[1]} ${m[2]}')
      .replaceAll(RegExp(r'#\s*'), 'número ');
  s = s.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  return s;
}
