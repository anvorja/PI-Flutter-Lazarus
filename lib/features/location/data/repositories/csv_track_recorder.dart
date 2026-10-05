/// [TrackRecorder] que escribe el recorrido en un CSV dentro de la carpeta
/// privada de la app. En un build de depuración se lee sin root:
///
///   adb exec-out run-as com.lazarus.app cat files/gps_track.csv
///
/// Cada línea se escribe y se vuelca al disco en el momento (una cada ~2 s):
/// si la app se cierra de golpe en la calle, el recorrido hasta ahí queda.
/// Cada tramo (inicio del GPS) lleva su identificador para separar recorridos.
library;

import 'dart:io';

import '../../domain/entities/location_fix.dart';
import '../../domain/repositories/track_recorder.dart';

const String gpsTrackFileName = 'gps_track.csv';
const String gpsTrackHeader = 'tramo,hora,latitud,longitud,precision_m,estado';

class CsvTrackRecorder implements TrackRecorder {
  CsvTrackRecorder(this._directory);

  /// Carpeta donde vive el archivo (en la app: `getApplicationSupportDirectory`).
  final Future<Directory> Function() _directory;

  File? _file;
  String _segment = '';

  @override
  Future<void> begin() async {
    final dir = await _directory();
    final file = File('${dir.path}/$gpsTrackFileName');
    if (!file.existsSync()) _append(file, gpsTrackHeader);
    _segment = DateTime.now().toIso8601String();
    _file = file;
  }

  @override
  void record(LocationFix fix, GpsReliability reliability) {
    final file = _file;
    if (file == null) return;
    _append(
      file,
      [
        _segment,
        fix.at.toIso8601String(),
        fix.latitude.toStringAsFixed(6),
        fix.longitude.toStringAsFixed(6),
        fix.accuracyM.toStringAsFixed(1),
        reliability.name,
      ].join(','),
    );
  }

  @override
  Future<void> end() async => _file = null;

  void _append(File file, String line) {
    try {
      file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // Sin espacio o sin acceso: el recorrido no debe tumbar la app.
    }
  }
}
