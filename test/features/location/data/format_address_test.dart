/// HU-013: la dirección que recibe el asistente, sin partes repetidas.
library;

import 'package:app/features/location/data/repositories/location_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart';

void main() {
  test('Colombia: la calle completa viene en street; no se repite', () {
    // Caso real de CP-LAZA-39 (antes: "…, Comuna 9, Cali, …, Comuna 9, Cali").
    final p = Placemark(
      street: 'Cra. 42 # 12B-101, Comuna 9, Cali, Valle del Cauca, Colombia',
      thoroughfare: 'Carrera 42',
      subThoroughfare: '12B-101',
      subLocality: 'Comuna 9',
      locality: 'Cali',
    );
    expect(formatAddress(p), 'Carrera 42 # 12B-101, Comuna 9, Cali');
  });

  test('el número que ya trae "#" no lo duplica', () {
    // Caso real del recorrido: "Carrera 42 # # 12B-101".
    final p = Placemark(
      thoroughfare: 'Carrera 42',
      subThoroughfare: '# 12B-101',
      subLocality: 'Comuna 9',
      locality: 'Cali',
    );
    expect(formatAddress(p), 'Carrera 42 # 12B-101, Comuna 9, Cali');
  });

  test('sin vía separada usa la primera parte de street', () {
    final p = Placemark(
      street: 'Cra. 42 # 12B-101, Comuna 9, Cali',
      subLocality: 'Comuna 9',
      locality: 'Cali',
    );
    expect(formatAddress(p), 'Cra. 42 # 12B-101, Comuna 9, Cali');
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
