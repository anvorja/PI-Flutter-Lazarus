# Changelog

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y
[versionado semántico](https://semver.org/lang/es/). Cada versión corresponde a una
release del Release Plan de Lazarus.

## [0.2.0] — 2026-10-29 · R1: piloto técnico listo para campo

Primera versión usada en campo con un usuario ciego real: prueba diurna controlada entre
la estación Buitrera del MIO y la entrada de la Universidad del Valle (27 y 28 de
octubre, sin incidentes). Se distribuye solo a los participantes del piloto por Firebase
App Distribution; el APK no se publica en este repositorio.

### Asistente de voz
- Sesión en tiempo real con Gemini Live a través del backend: audio con interrupción,
  cámara continua y anti-eco (medio-dúplex en altavoz y full-duplex con audífonos).
- Un toque para iniciar ("Iniciar asistente") y botón Detener con confirmación.
- Comandos de voz: personalización, pausa de descripciones, ayuda, repetir, modo reunión,
  silencio total y SOS.
- Alertas de riesgo sin que la persona hable y lateralidad confiable.

### Orientación y rutas
- GPS continuo con indicador de confiabilidad y orientación por brújula en horas de reloj.
- Guía por perfiles de ruta curados:
  - geocercas por punto, según la precisión del GPS;
  - avisos de acercamiento, llegada y cruce;
  - aviso de "fuera de la ruta" y retoma en el punto más cercano;
  - una ruta activa no se reinicia.
- Regla horaria de Unicentro.
- Notas de campo por voz ("anota que…"), con posición y rumbo. La app guarda la nota
  aunque el asistente no lo haga.

### Seguridad y accesibilidad
- Funciona con la pantalla bloqueada (servicio en primer plano); sin cámara pasa a una
  sesión sin imágenes.
- Sin datos móviles: aviso claro, reconexión automática y SOS con un gesto, sin el
  asistente.
- SOS por SMS con ubicación. Si Android restringe el permiso de SMS (app instalada desde
  un .apk), el asistente explica cómo darlo.
- TalkBack completo; Accessibility Scanner sin sugerencias abiertas.

### Piloto
- Registro del teléfono y espera de aprobación en el panel; respeta el horario, el límite
  de minutos y la pausa del servicio.
- En las versiones del piloto (`FIELD_EVIDENCE=true`), el registro, el GPS y las notas
  se suben al panel al tocar Detener, sin números de teléfono.

### Entrega
- Integración continua: formato, análisis, 401 pruebas y build.
- CD: cada rama `release/*` compila el APK firmado y lo envía al grupo `piloto` de
  Firebase App Distribution. El número de compilación queda por encima de 100.
- Configuración de compilación con `.env` y `--dart-define-from-file` (ver
  `.env.example`).

[0.2.0]: https://github.com/anvorja/PI-Flutter-Lazarus/releases/tag/v0.2.0
