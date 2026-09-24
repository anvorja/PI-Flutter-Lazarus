/// Captura la cámara y emite frames JPEG en base64 a ~1 fps.
///
/// Usa el plugin `camera`:
/// inicializa la cámara trasera y, con un Timer, toma una foto por segundo, la
/// codifica a base64 y la entrega. A 1 fps `takePicture` es suficiente; el stream
/// de imágenes crudas (YUV→JPEG) queda como optimización futura.
library;

import 'dart:async';
import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

class VideoStreamer {
  VideoStreamer(
    this._onFrame, {
    Future<List<CameraDescription>> Function()? listCameras,
  }) : _listCameras = listCameras ?? availableCameras;

  final void Function(String base64Jpeg) _onFrame;
  final Future<List<CameraDescription>> Function() _listCameras;

  CameraController? _controller;
  Timer? _timer;
  Future<void>? _initFuture; // init en curso, para no soltar a mitad
  bool _busy = false;
  bool _streaming = false;

  /// La sesión se cerró: un `start` que aún no termina no debe dejar la cámara
  /// encendida.
  bool _stopped = false;

  /// Controlador inicializado, por si la UI quiere mostrar la vista previa.
  CameraController? get controller => _controller;

  Future<void> start({int fps = 1}) async {
    _stopped = false;
    final cameras = await _listCameras();
    if (_stopped || cameras.isEmpty) return;

    final back = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    final controller = CameraController(
      back,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    _controller = controller;
    _initFuture = _initialize(controller);
    await _initFuture;
    if (_stopped) return; // stop() ya liberó el controlador

    _streaming = true;
    _timer = Timer.periodic(
      Duration(milliseconds: (1000 / fps).round()),
      (_) => _captureFrame(),
    );
  }

  Future<void> _captureFrame() async {
    final controller = _controller;
    if (!_streaming || _busy || controller == null) return;
    if (!controller.value.isInitialized || controller.value.isTakingPicture) {
      return;
    }
    _busy = true;
    try {
      final file = await controller.takePicture();
      final bytes = await file.readAsBytes();
      if (_streaming && bytes.isNotEmpty) _onFrame(base64Encode(bytes));
    } catch (_) {
      // Frame perdido: lo ignoramos y seguimos con el siguiente.
    } finally {
      _busy = false;
    }
  }

  /// Inicializa la cámara aislando los eventos tardíos del plugin: al cerrar la
  /// sesión, la cámara puede emitir un error sobre un controlador ya liberado
  /// ("used after being disposed"); se registra en lugar de quedar sin manejar.
  Future<void> _initialize(CameraController controller) {
    final done = Completer<void>();
    runZonedGuarded(() async {
      try {
        await controller.initialize();
        done.complete();
      } catch (e, st) {
        done.completeError(e, st);
      }
    }, (e, _) => debugPrint('[Lazarus] cámara tras el cierre: $e'));
    return done.future;
  }

  Future<void> stop() async {
    _stopped = true;
    _streaming = false;
    _timer?.cancel();
    _timer = null;
    try {
      // Espera a que termine una init en vuelo antes de soltar, para no disponer
      // el controlador a mitad de inicialización (evita el "used after disposed").
      await _initFuture;
      await _controller?.dispose();
    } catch (_) {
      // Carrera de teardown de la cámara: la ignoramos para no romper el cierre.
    }
    _controller = null;
  }
}
