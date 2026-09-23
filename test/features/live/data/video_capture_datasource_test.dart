import 'dart:async';

import 'package:app/features/live/data/datasources/video_capture_datasource.dart';
import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'detener mientras se buscan las cámaras no enciende la cámara',
    () async {
      final cameras = Completer<List<CameraDescription>>();
      final streamer = VideoStreamer((_) {}, listCameras: () => cameras.future);

      final starting = streamer.start();
      await streamer.stop(); // la sesión se cierra antes de que arranque
      cameras.complete(const [
        CameraDescription(
          name: '0',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
      ]);
      await starting;

      expect(streamer.controller, isNull);
    },
  );
}
