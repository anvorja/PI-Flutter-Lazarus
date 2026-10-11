/// La dirección se dice sin el bloque "# 12B-80", que el asistente repetía.
library;

import 'package:app/features/location/domain/entities/spoken_address.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('separa la letra, quita el numeral y el guion', () {
    expect(
      spokenAddress('Carrera 42 # 12B-80, Comuna 9, Cali'),
      'Carrera 42 número 12 B 80, Comuna 9, Cali',
    );
    expect(
      spokenAddress('Calle 12b # 41-25, Comuna 9, Cali'),
      'Calle 12 B número 41 25, Comuna 9, Cali',
    );
    expect(
      spokenAddress('Carrera 42 # 12B-101, Comuna 9, Cali'),
      'Carrera 42 número 12 B 101, Comuna 9, Cali',
    );
  });

  test('placa sin guion del geocodificador', () {
    expect(
      spokenAddress('Calle 12b # 4315, Comuna 9, Cali'),
      'Calle 12 B número 43 15, Comuna 9, Cali',
    );
  });

  test('cruce de vías', () {
    expect(
      spokenAddress('Carrera 43 # Calle 13, Comuna 9, Cali'),
      'Carrera 43 con Calle 13, Comuna 9, Cali',
    );
  });

  test('sin placa queda igual', () {
    expect(
      spokenAddress('Calle 13, Meléndez, Cali'),
      'Calle 13, Meléndez, Cali',
    );
  });
}
