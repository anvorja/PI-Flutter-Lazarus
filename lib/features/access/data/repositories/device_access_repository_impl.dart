/// [DeviceAccessRepository] contra el backend: `/api/v1/devices/*`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/config/app_config.dart';
import '../../../../core/debug/field_evidence.dart';
import '../../../../core/debug/live_debug.dart';
import '../../domain/repositories/device_access_repository.dart';
import 'log_chunks.dart';

const String deviceTokenKey = 'device_token';
const String _offsetPrefix = 'log_upload_offset_';
const String routeProfilesKey = 'route_profiles';
const _timeout = Duration(seconds: 6);

class DeviceAccessRepositoryImpl implements DeviceAccessRepository {
  DeviceAccessRepositoryImpl(
    this._prefs, [
    this._channel = const MethodChannel('lazarus/session'),
  ]);

  final SharedPreferences _prefs;
  final MethodChannel _channel;

  @override
  String? get savedToken => _prefs.getString(deviceTokenKey);

  @override
  Future<String?> token() async {
    final saved = _prefs.getString(deviceTokenKey);
    if (saved != null && saved.isNotEmpty) return saved;
    try {
      final info = await _deviceInfo();
      final body = await _send('POST', '/api/v1/devices/register', json: info);
      final token = (jsonDecode(body!) as Map<String, dynamic>)['device_token'];
      if (token is! String) return null;
      await _prefs.setString(deviceTokenKey, token);
      return token;
    } on Object {
      return null; // sin red o backend anterior: la sesión sigue sin token
    }
  }

  @override
  Future<bool> uploadRequested() async {
    final token = _prefs.getString(deviceTokenKey);
    if (token == null) return false;
    try {
      final body = await _send('GET', '/api/v1/devices/me', token: token);
      return (jsonDecode(body!) as Map<String, dynamic>)['upload_requested'] ==
          true;
    } on Object catch (e) {
      await _forgetIfUnknown(e);
      return false;
    }
  }

  @override
  Future<int> uploadLogs() async {
    final token = _prefs.getString(deviceTokenKey);
    if (!kFieldEvidence) return 0;
    if (token == null) {
      liveLog('[Lazarus] logs: el teléfono no está registrado, no se suben');
      return 0;
    }
    try {
      final dir = await evidenceDirectory();
      final offsets = {
        for (final name in uploadableFiles)
          name: _prefs.getInt('$_offsetPrefix$name') ?? 0,
      };
      final chunks = await pendingChunks(dir, offsets);
      if (chunks.isEmpty) return 0;
      await _upload(token, chunks);
      for (final chunk in chunks) {
        await _prefs.setInt('$_offsetPrefix${chunk.name}', chunk.endOffset);
      }
      return chunks.length;
    } on Object catch (e) {
      // Sin la URL ni el token: solo el tipo de fallo (prueba del 21-oct: las
      // subidas no quedaban en el registro y no se sabía por qué).
      final why = e is HttpException ? e.message : e.runtimeType.toString();
      liveLog('[Lazarus] logs: no se subieron ($why); se reintenta después');
      await _forgetIfUnknown(e);
      return 0; // se reintenta en la próxima: los offsets no avanzaron
    }
  }

  @override
  Future<String?> routeProfiles() async {
    final cached = _prefs.getString(routeProfilesKey);
    final token = _prefs.getString(deviceTokenKey);
    if (token == null) return cached;
    try {
      final body = await _send(
        'GET',
        '/api/v1/devices/me/routes',
        token: token,
      );
      if (body == null) return cached;
      await _prefs.setString(routeProfilesKey, body);
      return body;
    } on Object catch (e) {
      // Sin datos en la calle: sirven los que se bajaron antes.
      await _forgetIfUnknown(e);
      return cached;
    }
  }

  /// El backend ya no conoce el token (prueba del 21-oct: HTTP 401 al subir,
  /// p. ej. porque el teléfono se eliminó en el panel). Se olvida, y la próxima
  /// sesión registra el teléfono de nuevo, pendiente de aprobación.
  Future<void> _forgetIfUnknown(Object error) async {
    if (error is! HttpException || error.message != 'HTTP 401') return;
    await _prefs.remove(deviceTokenKey);
    liveLog(
      '[Lazarus] el panel no conoce este teléfono: se registra de nuevo en la próxima sesión',
    );
  }

  Future<Map<String, String>> _deviceInfo() async {
    try {
      final info = await _channel.invokeMapMethod<String, Object?>(
        'deviceInfo',
      );
      return {
        'model': '${info?['model'] ?? ''}',
        'android': '${info?['android'] ?? ''}',
        'app_version': '${info?['appVersion'] ?? ''}',
      };
    } on Object {
      return {'model': '', 'android': '', 'app_version': ''};
    }
  }

  Future<String?> _send(
    String method,
    String path, {
    Map<String, Object?>? json,
    String? token,
  }) async {
    final http = HttpClient()..connectionTimeout = _timeout;
    try {
      final request = await http.openUrl(method, Uri.parse('$backendUrl$path'));
      if (token != null) request.headers.set('X-Device-Token', token);
      if (json != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(json));
      }
      final response = await request.close().timeout(_timeout);
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      return body;
    } finally {
      http.close(force: true);
    }
  }

  Future<void> _upload(String token, List<LogChunk> chunks) async {
    final boundary = 'lazarus${Random().nextInt(1 << 31)}';
    final body = BytesBuilder();
    for (final chunk in chunks) {
      body.add(
        utf8.encode(
          '--$boundary\r\n'
          'Content-Disposition: form-data; name="files"; filename="${chunk.name}"\r\n'
          'Content-Type: application/octet-stream\r\n\r\n',
        ),
      );
      body.add(chunk.bytes);
      body.add(utf8.encode('\r\n'));
    }
    body.add(utf8.encode('--$boundary--\r\n'));
    final http = HttpClient()..connectionTimeout = _timeout;
    try {
      final request = await http.postUrl(
        Uri.parse('$backendUrl/api/v1/devices/me/logs'),
      );
      request.headers
        ..set('X-Device-Token', token)
        ..set(
          HttpHeaders.contentTypeHeader,
          'multipart/form-data; boundary=$boundary',
        );
      request.add(body.takeBytes());
      final response = await request.close().timeout(
        const Duration(seconds: 60),
      );
      await response.drain<void>();
      if (response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}');
      }
    } finally {
      http.close(force: true);
    }
  }
}
