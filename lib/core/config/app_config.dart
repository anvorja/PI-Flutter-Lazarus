/// Configuración de la app (endpoints del backend).
///
/// El backend expone el proxy `/ws/live`: la API key de Gemini vive solo en el
/// servidor (ver ADR-0003). Por ahora apunta a
/// desarrollo local; se puede sobreescribir en tiempo de compilación con:
///   flutter run --dart-define=BACKEND_URL=http://192.168.x.x:8000
library;

/// URL base del backend (HTTP). En un emulador Android, `localhost` del host es
/// `10.0.2.2`; en un teléfono físico usa la IP de tu máquina en la LAN.
const String backendUrl = String.fromEnvironment(
  'BACKEND_URL',
  defaultValue: 'http://localhost:8000',
);

/// URL del WebSocket del proxy Live, derivada de [backendUrl].
String get liveWsUrl =>
    '${backendUrl.replaceFirst(RegExp(r'^http'), 'ws')}/ws/live';

/// FPS de envío de frames de cámara.
const int videoFps = 1;
