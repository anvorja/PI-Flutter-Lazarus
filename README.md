# Lazarus — App móvil (Flutter)

App **voz-first** de Lazarus, copiloto conversacional de movilidad asistida para
personas con discapacidad visual. Captura micrófono, cámara y sensores, habla con el
backend de Lazarus por WebSocket (`/ws/live`) y reproduce la voz del asistente en
tiempo real. La app nunca contiene la API key de Gemini.

Proyecto gestionado en Jira (proyecto **LAZA**). Cada cambio entra por una rama
`feature/LAZA-<n>-…` y un Pull Request hacia `develop`.

## Stack

| Capa | Tecnología |
| --- | --- |
| Framework | Flutter (Dart), Android como plataforma del piloto |
| Arquitectura | Capas `data` / `domain` / `presentation` con Riverpod |
| Audio | `record` (captura PCM 16 kHz), `flutter_pcm_sound` (reproducción PCM 24 kHz) |
| Cámara | `camera` (JPEG ~1 fps) |
| Persistencia de ajustes | `shared_preferences` |

## Ejecutar

```bash
flutter pub get
# Emulador Android (el backend del PC se ve como 10.0.2.2)
./scripts/run-emulator.sh
# Teléfono por USB (adb reverse hacia el backend local)
./scripts/run-phone.sh
# O indicando la URL del backend
flutter run --dart-define=BACKEND_URL=http://<ip-del-backend>:8000
```

## Calidad

```bash
dart format --set-exit-if-changed .
flutter analyze
flutter test
```

## Flujo de trabajo (GitFlow)

- `main`: versiones publicadas (etiquetas `vX.Y.Z`).
- `develop`: integración del sprint.
- `feature/LAZA-<n>-<descripcion>`: una rama por historia de usuario o tarea de Jira.
- `release/vX.Y.Z` y `hotfix/LAZA-<n>-…` según la estrategia GitFlow del proyecto.

Commits: `LAZA-<n> <verbo en presente> <qué>`.
