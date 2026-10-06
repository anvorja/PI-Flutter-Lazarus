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
| Ubicación | `geolocator` (posición cada 2 s con estado de confiabilidad), `geocoding` (dirección aproximada) |
| Pantalla | `wakelock_plus` (encendida mientras el GPS sigue a la persona) |
| Emergencias | Canal nativo `lazarus/emergency`: SMS con confirmación de la red (`SmsManager`) y llamadas (`CALL_PHONE`, marcador para el 123) |
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

## Pruebas en el teléfono físico (QA)

Así se preparan las pruebas de los casos de QA (CP-LAZA-n) en el teléfono del piloto.
Las pruebas de campo se hacen con **datos móviles**, como las usará la persona: el
backend se expone con un túnel temporal de ngrok y el Wi-Fi del teléfono queda apagado
desde antes de abrir la app. La app guarda la evidencia en el teléfono; al volver, el
teléfono se conecta al Wi-Fi de la casa y la evidencia se baja al PC por depuración
inalámbrica.

### Flujo general (leer primero)

La **depuración inalámbrica solo sirve para dos cosas**: instalar el APK y sacar la
evidencia. **Durante la prueba la app no depende de adb**: habla con el backend por la
URL de ngrok (`BACKEND_URL`, fijada al compilar) usando los datos móviles.

La depuración inalámbrica exige que teléfono y PC estén en la misma red Wi-Fi, y
mientras el teléfono tenga Wi-Fi, Android usa el Wi-Fi para internet y no los datos
móviles. Por eso, para probar con datos hay que apagar el Wi-Fi, y al apagarlo se cae
la sesión de adb. El orden es:

1. **Con Wi-Fi**: levantar backend y ngrok, compilar con la URL de ngrok, conectar
   por depuración inalámbrica e instalar el APK (secciones 1 y 2).
2. **Apagar el Wi-Fi del teléfono** y salir a hacer la prueba con datos móviles. La
   app llega al backend por ngrok; adb ya no está conectado y no hace falta.
3. **Durante la prueba** la app guarda su propia evidencia en el teléfono (sección 3),
   porque es un build de depuración.
4. **Al volver**: encender el Wi-Fi, reconectar adb (el puerto casi seguro cambió, ver
   la pantalla de Depuración inalámbrica) y bajar la evidencia al PC.

### 1. Conectar el teléfono por depuración inalámbrica

En el teléfono: *Opciones de desarrollador* → **Depuración inalámbrica** (activar). La
pantalla muestra `IP:puerto`; **el puerto cambia cada vez** que se activa.

```bash
adb connect <IP>:<PUERTO>                    # p. ej. 192.168.1.10:41083
adb devices                                  # debe decir "device"
```

Si `connect` falla, hay que vincular primero: en el teléfono, *Vincular dispositivo con
código de sincronización* (muestra otro puerto y un código de 6 dígitos):

```bash
adb pair <IP>:<PUERTO-DE-VINCULACIÓN> <CÓDIGO>
adb connect <IP>:<PUERTO>                    # el de la pantalla principal, no el de vincular
```

Si sale `Unable to start pairing client`: `adb kill-server && adb start-server` y
repetir.

### 2. Tres terminales

**Terminal 1: backend** (en la rama de la HU que se prueba)

```bash
cd ../PI-Backend-Lazarus
uv run uvicorn app.main:app --host 0.0.0.0 --port 8000
```

**Terminal 2: túnel** (solo para pruebas con datos móviles)

```bash
ngrok http 8000      # copiar la URL de "Forwarding": https://<id>.ngrok-free.app
```

La URL cambia cada vez que se reinicia ngrok. **Nunca se escribe en el código ni se
sube al repositorio**: solo se pasa al compilar. El túnel no tiene autenticación: se
cierra (Ctrl+C) al terminar la prueba.

**Terminal 3: compilar, instalar y ver los logs**

```bash
# Con datos móviles (ngrok):
flutter build apk --debug --dart-define=BACKEND_URL=<URL-NGROK>
# Solo en casa, por la LAN: --dart-define=BACKEND_URL=http://<IP-DEL-PC>:8000

adb -s <IP>:<PUERTO> install -r build/app/outputs/flutter-apk/app-debug.apk

# Logs de la app (trazas [Lazarus] y del SMS nativo), guardados como evidencia:
adb -s <IP>:<PUERTO> logcat -v time flutter:I LazarusSos:V *:S | tee ~/prueba-<caso>.log
```

### 3. Evidencia que queda en el teléfono

En los builds de depuración la app guarda su propia evidencia, que no depende de que
el teléfono siga conectado al PC (pruebas en la calle):

```bash
# Trazas [Lazarus] de la app con la hora (5 MB; el anterior queda en lazarus.log.1)
adb exec-out run-as com.lazarus.app cat files/lazarus.log > ~/lazarus.log

# Telemetría sin contenido de la persona (también en distribución): eventos de
# sesión y latencia voz a voz (mediana y percentil 90 al cerrar cada sesión)
adb exec-out run-as com.lazarus.app cat files/telemetry.jsonl > ~/telemetria.jsonl

# Recorrido del GPS: una fila cada ~2 s con precisión y estado
adb exec-out run-as com.lazarus.app cat files/gps_track.csv > ~/recorrido.csv

# Fotos que recibió el asistente en los últimos 10 minutos, con la hora en el nombre
adb exec-out run-as com.lazarus.app tar c files/frames > ~/fotos.tar

# Registro completo del sistema (p. ej. el envío de SMS), sin captura previa:
adb logcat -d -v time > ~/sistema.log
```

En producción no se guarda nada de esto, y la cámara borra cada foto después de
enviarla.

### 4. Lista de verificación del teléfono (MIUI / HyperOS)

| Ajuste | Cómo debe estar | Por qué |
| --- | --- | --- |
| *Opciones de desarrollador* → **Verificar apps por USB** | Desactivado | Con él, `adb install` falla con `INSTALL_FAILED_USER_RESTRICTED` |
| *Wi-Fi* → **Cambiar entre redes / aceleración de red** | Desactivado | Al cambiar de red, MIUI corta la depuración inalámbrica ("Disabling adbwifi") |
| *SIM* → **Llamadas por Wi-Fi (VoWiFi)** de la SIM de SMS | Desactivado en pruebas de SOS | Con VoWiFi cada SMS tardó 1-2 min y quedaron en fila; sin él, 1,8 s |
| SIM predeterminada para SMS | La que tenga plan de SMS | La alerta SOS sale por esa SIM |
| Permisos de Lazarus | Micrófono, cámara, ubicación, SMS y teléfono | Se piden en uso; si se negaron, darlos en *Ajustes → Apps* |
| Saldo del proyecto de Gemini (AI Studio) | Con créditos | Sin saldo, Gemini cierra cada sesión; la app lo dice ("se quedó sin saldo") y no reintenta |
| Wi-Fi en pruebas de campo | Apagado antes de abrir la app; encenderlo solo al terminar, para bajar la evidencia | Cambiar de red con la sesión activa corta la conexión; la app se recupera sola, pero se pierden de 9 a 35 s |

> Antes de una prueba larga, agrandar el búfer de logcat: `adb logcat -G 64M` (en la
> prueba de CP-LAZA-39 el búfer por defecto guardó solo los últimos 5 minutos). Reinicia
> el servicio de logs y corta una captura en curso: hacerlo antes de empezar.

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
