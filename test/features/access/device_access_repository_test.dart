import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/features/access/data/repositories/device_access_repository_impl.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Backend falso: `/devices/me` responde según los tokens que conoce y
/// `/devices/register` entrega un token nuevo.
class _Backend {
  late final HttpServer server;
  final known = <String>{'token-conocido'};
  int registrations = 0;

  String get url => 'http://${server.address.host}:${server.port}';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final res = request.response;
      if (request.uri.path == '/api/v1/devices/register') {
        registrations++;
        // Llega en paralelo con otro pedido: se nota si hay dos registros.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final token = 'token-nuevo-$registrations';
        known.add(token);
        res.statusCode = 201;
        res.write(jsonEncode({'device_token': token, 'status': 'pending'}));
      } else if (request.uri.path == '/api/v1/devices/me') {
        final token = request.headers.value('X-Device-Token');
        if (known.contains(token)) {
          res.write(
            jsonEncode({
              'status': 'pending',
              'name': '',
              'upload_requested': false,
            }),
          );
        } else {
          res.statusCode = 401;
        }
      } else {
        res.statusCode = 404;
      }
      await res.close();
    });
  }
}

void main() {
  late _Backend backend;

  setUp(() async {
    backend = _Backend();
    await backend.start();
  });

  tearDown(() => backend.server.close(force: true));

  Future<(DeviceAccessRepositoryImpl, SharedPreferences)> repo(
    String? token,
  ) async {
    SharedPreferences.setMockInitialValues({deviceTokenKey: ?token});
    final prefs = await SharedPreferences.getInstance();
    return (
      DeviceAccessRepositoryImpl(
        prefs,
        const MethodChannel('lazarus/session'),
        backend.url,
      ),
      prefs,
    );
  }

  test('token que el panel ya no conoce: lo olvida y registra el teléfono '
      'de nuevo (27-oct)', () async {
    final (access, prefs) = await repo('token-borrado');
    await access.registerAgainIfUnknown();
    expect(backend.registrations, 1);
    expect(prefs.getString(deviceTokenKey), 'token-nuevo-1');
  });

  test(
    'token conocido: de verdad está pendiente, no se registra otra vez',
    () async {
      final (access, prefs) = await repo('token-conocido');
      await access.registerAgainIfUnknown();
      expect(backend.registrations, 0);
      expect(prefs.getString(deviceTokenKey), 'token-conocido');
    },
  );

  test('sin red: deja el token como está', () async {
    final (access, prefs) = await repo('token-borrado');
    await backend.server.close(force: true);
    await access.registerAgainIfUnknown();
    expect(prefs.getString(deviceTokenKey), 'token-borrado');
  });

  test('sin token y con el registro de la sesión en curso: una sola fila '
      'en el panel', () async {
    final (access, prefs) = await repo(null);
    await Future.wait([access.token(), access.registerAgainIfUnknown()]);
    expect(backend.registrations, 1);
    expect(prefs.getString(deviceTokenKey), 'token-nuevo-1');
  });
}
