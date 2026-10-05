/// HU-012: número del contacto, texto del SMS y qué posición lleva la alerta.
library;

import 'package:app/features/emergency/domain/entities/emergency_contact.dart';
import 'package:app/features/emergency/domain/entities/sos_message.dart';
import 'package:app/features/emergency/presentation/controllers/sos_controller.dart';
import 'package:app/features/location/domain/entities/location_fix.dart';
import 'package:app/features/location/presentation/controllers/location_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('número del contacto', () {
    test('celular y fijo de Colombia de 10 dígitos llevan +57', () {
      expect(normalizePhone('315 123 4567'), '+573151234567');
      expect(normalizePhone('315-123-45-67'), '+573151234567');
      expect(normalizePhone('6023334455'), '+576023334455');
      expect(normalizePhone('57 3151234567'), '+573151234567');
    });

    test('con prefijo internacional se acepta tal cual', () {
      expect(normalizePhone('+1 305 555 0100'), '+13055550100');
    });

    test('lo que no parece un teléfono se rechaza', () {
      expect(normalizePhone('123'), isNull);
      expect(normalizePhone('tres uno cinco'), isNull);
      expect(
        normalizePhone('1234567890'),
        isNull,
      ); // 10 dígitos que no son de Colombia
    });

    test('se lee por grupos', () {
      expect(spokenPhone('+573151234567'), '315 123 4567');
      expect(spokenPhone('+13055550100'), '130 555 501 00');
    });
  });

  group('texto del SMS', () {
    final at = DateTime(2026, 9, 30, 9, 5);

    test('posición actual: nombre, dirección, coordenadas, precisión y '
        'hora, sin enlaces', () {
      final text = buildSosMessage(
        language: 'es',
        userName: 'Andrés',
        position: SosPosition(
          latitude: 3.389270,
          longitude: -76.530190,
          accuracyM: 4.6,
          at: at,
          current: true,
          address: 'Carrera 76 # 14C-101, Comuna 17, Cali',
        ),
      );
      expect(
        text,
        'SOS de Andres: necesito ayuda. Estoy en Carrera 76 # 14C-101, '
        'Comuna 17, Cali. Coordenadas 3.38927,-76.53019 (precision 5 m, '
        '09:05). Enviado por Lazarus.',
      );
      // Los operadores no entregaron ningún SMS con enlace.
      expect(text, isNot(contains('http')));
      expect(text.length, lessThanOrEqualTo(160)); // una sola parte
    });

    test('sin dirección, solo las coordenadas', () {
      final text = buildSosMessage(
        language: 'es',
        userName: '',
        position: SosPosition(
          latitude: 3.38927,
          longitude: -76.53019,
          accuracyM: 5,
          at: at,
          current: true,
        ),
      );
      expect(text, contains('Estoy en Coordenadas 3.38927,-76.53019'));
    });

    test('GPS no confiable: última posición conocida con su hora', () {
      final text = buildSosMessage(
        language: 'es',
        userName: '',
        position: SosPosition(
          latitude: 3.38927,
          longitude: -76.53019,
          accuracyM: 6,
          at: at,
          current: false,
        ),
      );
      expect(text, startsWith('SOS: necesito ayuda.'));
      expect(
        text,
        contains(
          'ultima ubicacion conocida (09:05, precision 6 m): '
          'Coordenadas 3.38927,-76.53019.',
        ),
      );
    });

    test('sin posición lo dice y pide que llamen', () {
      final text = buildSosMessage(
        language: 'en',
        userName: 'Ann',
        position: null,
      );
      expect(
        text,
        'SOS from Ann: I need help. No location available; call me. '
        'Sent by Lazarus.',
      );
    });
  });

  test('cabe en una sola parte de SMS: sin tildes ni símbolos', () {
    final text = buildSosMessage(
      language: 'es',
      userName: 'José Ñúñez',
      position: SosPosition(
        latitude: 3.389270,
        longitude: -76.530190,
        accuracyM: 12,
        at: DateTime(2026, 9, 30, 9, 5),
        current: true,
      ),
    );
    expect(text, contains('SOS de Jose Nunez:'));
    expect(text.codeUnits.every((c) => c < 128), isTrue);
    expect(text.length, lessThanOrEqualTo(160));
  });

  test('la hora del GPS (UTC) se escribe en hora local', () {
    final utc = DateTime.utc(2026, 9, 30, 6, 39);
    expect(clockTime(utc), clockTime(utc.toLocal()));
    final local = utc.toLocal();
    expect(clockTime(utc), '${local.hour.toString().padLeft(2, '0')}:39');
  });

  group('posición de la alerta', () {
    LocationFix fix(double accuracyM, int minute) => LocationFix(
      latitude: 3.38,
      longitude: -76.53,
      accuracyM: accuracyM,
      at: DateTime(2026, 9, 30, 9, minute),
    );

    test('GPS confiable → la actual', () {
      final p = sosPositionFrom(
        LocationState(fix: fix(4, 10), reliability: GpsReliability.reliable),
      )!;
      expect(p.current, isTrue);
      expect(p.at.minute, 10);
    });

    test('GPS no confiable → la última tomada con GPS confiable', () {
      final p = sosPositionFrom(
        LocationState(
          fix: fix(40, 12),
          reliability: GpsReliability.unreliable,
          lastReliableFix: fix(5, 8),
        ),
      )!;
      expect(p.current, isFalse);
      expect(p.at.minute, 8);
      expect(p.accuracyM, 5);
    });

    test('nunca fue confiable → la última que haya; sin GPS → ninguna', () {
      final p = sosPositionFrom(
        LocationState(fix: fix(30, 3), reliability: GpsReliability.unknown),
      )!;
      expect(p.current, isFalse);
      expect(sosPositionFrom(const LocationState()), isNull);
    });
  });
}
