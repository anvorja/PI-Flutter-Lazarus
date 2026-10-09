/// La dirección se dice sin el bloque "# 14C-80", que el asistente repetía.
library;

import 'package:app/features/location/domain/entities/spoken_address.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('separa la letra, quita el numeral y el guion', () {
    expect(
      spokenAddress('Carrera 76 # 14C-80, Comuna 17, Cali'),
      'Carrera 76 número 14 C 80, Comuna 17, Cali',
    );
    expect(
      spokenAddress('Calle 14c # 75-25, Comuna 17, Cali'),
      'Calle 14 C número 75 25, Comuna 17, Cali',
    );
    expect(
      spokenAddress('Carrera 76 # 14C-101, Comuna 17, Cali'),
      'Carrera 76 número 14 C 101, Comuna 17, Cali',
    );
  });

  test('placa sin guion del geocodificador', () {
    expect(
      spokenAddress('Calle 14c # 7615, Comuna 17, Cali'),
      'Calle 14 C número 76 15, Comuna 17, Cali',
    );
  });

  test('cruce de vías', () {
    expect(
      spokenAddress('Carrera 77 # Calle 15, Comuna 17, Cali'),
      'Carrera 77 con Calle 15, Comuna 17, Cali',
    );
  });

  test('sin placa queda igual', () {
    expect(
      spokenAddress('Calle 13, Meléndez, Cali'),
      'Calle 13, Meléndez, Cali',
    );
  });
}
