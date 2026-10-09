/// Implementación de [BackgroundSessionRepository] sobre el canal nativo
/// `lazarus/session` (servicio en primer plano `LazarusSessionService`).
library;

import 'package:flutter/services.dart';

import '../../domain/repositories/background_session_repository.dart';
import '../../../../core/debug/live_debug.dart';

class BackgroundSessionRepositoryImpl implements BackgroundSessionRepository {
  BackgroundSessionRepositoryImpl([
    this._channel = const MethodChannel('lazarus/session'),
  ]) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'stopRequested') _onStop?.call();
    });
  }

  final MethodChannel _channel;
  void Function()? _onStop;

  @override
  Future<bool> start() async {
    try {
      return await _channel.invokeMethod<bool>('start') ?? false;
    } on PlatformException catch (e) {
      liveLog('[Lazarus] segundo plano: no arrancó (${e.message})');
      return false;
    } on MissingPluginException {
      return false; // fuera de Android
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Fuera de Android: no hay servicio que detener.
    }
  }

  @override
  void onStopRequested(void Function() callback) => _onStop = callback;

  @override
  Future<BatteryStatus> batteryStatus() async {
    try {
      final r = await _channel.invokeMapMethod<String, Object?>(
        'batteryStatus',
      );
      return (
        exempt: r?['exempt'] == true,
        manufacturer: (r?['manufacturer'] as String?) ?? '',
      );
    } on MissingPluginException {
      return (exempt: true, manufacturer: '');
    }
  }

  @override
  Future<bool> requestBatteryExemption() async {
    try {
      return await _channel.invokeMethod<bool>('requestBatteryExemption') ??
          false;
    } on MissingPluginException {
      return true;
    }
  }
}
