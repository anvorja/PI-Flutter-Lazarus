#!/usr/bin/env bash
# Ejecuta la app en el EMULADOR de Android.
#
# El emulador llega al backend del PC por la IP especial 10.0.2.2 (= "localhost del
# host" desde dentro del emulador). El backend debe estar corriendo en :8000.
set -e

ADB="${ANDROID_HOME:-$HOME/Android/Sdk}/platform-tools/adb"
AVD="${1:-Medium_Phone_API_36.1}"

# Arranca el emulador si no hay ninguno corriendo.
if ! "$ADB" devices | grep -q "emulator-"; then
  echo "==> Lanzando emulador $AVD ..."
  flutter emulators --launch "$AVD"
  echo "==> Esperando a que arranque..."
  "$ADB" wait-for-device
  # Espera a que el sistema termine de bootear.
  until [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do
    sleep 2
  done
fi

EMU="$("$ADB" devices | grep "emulator-" | head -1 | cut -f1)"
echo "==> Usando $EMU"
flutter run -d "$EMU" --dart-define=BACKEND_URL=http://10.0.2.2:8000
