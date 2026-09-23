#!/usr/bin/env bash
# Ejecuta la app en un TELÉFONO ANDROID FÍSICO conectado por USB.
#
# Requisitos (una sola vez, en el teléfono):
#   1. Ajustes → Acerca del teléfono → toca "Número de compilación" 7 veces.
#   2. Ajustes → Sistema → Opciones de desarrollador → activa "Depuración USB".
#   3. Conecta el teléfono por USB y acepta el aviso "¿Permitir depuración USB?"
#      (marca "Permitir siempre").
#
# Backend: este script usa `adb reverse` para que el `localhost:8000` del teléfono
# apunte al backend que corre en tu PC (vía el cable USB). Así no dependes de la WiFi.
set -e

ADB="${ANDROID_HOME:-$HOME/Android/Sdk}/platform-tools/adb"

echo "==> Dispositivos:"
"$ADB" devices

# Redirige el puerto 8000 del teléfono hacia el PC (backend).
"$ADB" reverse tcp:8000 tcp:8000
echo "==> adb reverse activo: el teléfono verá el backend en localhost:8000"

# Lanza la app. Si hay varios dispositivos, Flutter te preguntará cuál usar.
flutter run --dart-define=BACKEND_URL=http://localhost:8000
