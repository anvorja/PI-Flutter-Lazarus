/// [TrackRecorder] que escribe el recorrido en un CSV en la carpeta de la
/// evidencia de campo (ver `field_evidence.dart`):
///
///   adb pull /sdcard/Android/data/com.lazarus.app/files/gps_track.csv
///
/// Cada línea se escribe y se vuelca al disco en el momento (una cada ~2 s):
/// si la app se cierra de golpe en la calle, el recorrido hasta ahí queda.
/// Cada tramo (inicio del GPS) lleva su identificador para separar recorridos.
library;

import 'dart:io';

import '../../domain/entities/heading.dart';
import '../../domain/entities/location_fix.dart';
import '../../domain/repositories/track_recorder.dart';

const String gpsTrackFileName = 'gps_track.csv';
const String gpsTrackHeader =
    'tramo,hora,latitud,longitud,precision_m,estado,velocidad_ms,rumbo,'
    'fuente_rumbo,calibrar_brujula';

/// Recorridos con el encabezado anterior (sin rumbo, antes de HU-016): se
/// conservan aparte para no mezclar columnas.
const String gpsTrackPreviousFileName = 'gps_track_anterior.csv';

class CsvTrackRecorder implements TrackRecorder {
  CsvTrackRecorder(this._directory);

  /// Carpeta donde vive el archivo (en la app: `evidenceDirectory`).
  final Future<Directory> Function() _directory;

  File? _file;
  String _segment = '';

  @override
  Future<void> begin() async {
    final dir = await _directory();
    final file = File('${dir.path}/$gpsTrackFileName');
    if (file.existsSync() && !_hasCurrentHeader(file)) {
      try {
        file.renameSync('${dir.path}/$gpsTrackPreviousFileName');
      } catch (_) {
        // Si no se puede mover, se sigue en el mismo archivo.
      }
    }
    if (!file.existsSync()) _append(file, gpsTrackHeader);
    _segment = DateTime.now().toIso8601String();
    _file = file;
  }

  @override
  void record(LocationFix fix, GpsReliability reliability, [Heading? heading]) {
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
        fix.speedMps?.toStringAsFixed(2) ?? '',
        heading?.degrees.toStringAsFixed(0) ?? '',
        heading?.source.name ?? '',
        heading == null ? '' : (heading.needsCalibration ? 'si' : 'no'),
      ].join(','),
    );
  }

  @override
  Future<void> end() async => _file = null;

  bool _hasCurrentHeader(File file) {
    try {
      final lines = file.readAsLinesSync();
      return lines.isNotEmpty && lines.first == gpsTrackHeader;
    } catch (_) {
      return true;
    }
  }

  void _append(File file, String line) {
    try {
      file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // Sin espacio o sin acceso: el recorrido no debe tumbar la app.
    }
  }
}
