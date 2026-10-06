/// HU-013: la dirección que recibe el asistente, sin partes repetidas.
library;

import 'package:app/features/location/data/repositories/location_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart';

void main() {
  test('Colombia: la calle completa viene en street; no se repite', () {
    // Caso real de CP-LAZA-39 (antes: "…, Comuna 17, Cali, …, Comuna 17, Cali").
    final p = Placemark(
      street: 'Cra. 76 # 14C-101, Comuna 17, Cali, Valle del Cauca, Colombia',
      thoroughfare: 'Carrera 76',
      subThoroughfare: '14C-101',
      subLocality: 'Comuna 17',
      locality: 'Cali',
    );
    expect(formatAddress(p), 'Carrera 76 # 14C-101, Comuna 17, Cali');
  });

  test('el número que ya trae "#" no lo duplica', () {
    // Caso real del recorrido: "Carrera 76 # # 14C-101".
    final p = Placemark(
      thoroughfare: 'Carrera 76',
      subThoroughfare: '# 14C-101',
      subLocality: 'Comuna 17',
      locality: 'Cali',
    );
    expect(formatAddress(p), 'Carrera 76 # 14C-101, Comuna 17, Cali');
  });

  test('sin vía separada usa la primera parte de street', () {
    final p = Placemark(
      street: 'Cra. 76 # 14C-101, Comuna 17, Cali',
      subLocality: 'Comuna 17',
      locality: 'Cali',
    );
    expect(formatAddress(p), 'Cra. 76 # 14C-101, Comuna 17, Cali');
  });

  test('quita lo pegado antes de la vía y el "#" repetido', () {
    // Sótano de un centro comercial (CP-LAZA-39, 5-oct).
    final p = Placemark(
      street: '18:00Cra. 100 # #5-169, Las Vegas, Cali',
      subLocality: 'Las Vegas',
      locality: 'Cali',
    );
    expect(formatAddress(p), 'Cra. 100 # 5-169, Las Vegas, Cali');
  });

  test('sin datos: null', () {
    expect(formatAddress(Placemark()), isNull);
  });
}
