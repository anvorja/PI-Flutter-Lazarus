package com.lazarus.app

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "lazarus/audio"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // ¿Hay audífonos/auriculares de salida conectados (cable/BT/USB)?
                    // Se usa para decidir full-duplex (con audífonos) vs medio-dúplex
                    // (altavoz: silenciar el mic mientras el asistente habla, anti-eco).
                    "isHeadsetConnected" -> {
                        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        val devices = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                        Log.d("LazarusAudio", "salidas: " + devices.joinToString { it.type.toString() })
                        val connected = devices.any { d ->
                            when (d.type) {
                                AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                                AudioDeviceInfo.TYPE_WIRED_HEADSET,
                                AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                                AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                                // Audífonos médicos (Android 9+) y audífonos BLE Audio
                                // (Android 12+): en versiones anteriores estas
                                // constantes nunca aparecen, así que no afectan.
                                AudioDeviceInfo.TYPE_HEARING_AID,
                                AudioDeviceInfo.TYPE_BLE_HEADSET,
                                AudioDeviceInfo.TYPE_USB_HEADSET -> true
                                // TYPE_USB_DEVICE no cuenta: el cable de depuración
                                // lo simula y daría un falso positivo.
                                else -> false
                            }
                        }
                        result.success(connected)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
