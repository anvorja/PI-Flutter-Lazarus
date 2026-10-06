package com.lazarus.app

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.telephony.SmsManager
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    /// Trazas de diagnóstico solo en builds de depuración (HU-015).
    private val debugBuild: Boolean
        get() = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    private fun debugLog(level: Char, tag: String, message: String) {
        if (!debugBuild) return
        when (level) {
            'w' -> Log.w(tag, message)
            'i' -> Log.i(tag, message)
            else -> Log.d(tag, message)
        }
    }

    private val channelName = "lazarus/audio"
    private val emergencyChannelName = "lazarus/emergency"
    private val smsSentAction = "com.lazarus.app.SMS_SENT"
    private var smsRequest = 0

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
                        debugLog('d', "LazarusAudio", "salidas: " + devices.joinToString { it.type.toString() })
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

        // Alerta SOS (HU-012): SMS con confirmación del sistema y llamadas.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, emergencyChannelName)
            .setMethodCallHandler { call, result ->
                val phone = call.argument<String>("phone") ?: ""
                when (call.method) {
                    "sendSms" -> sendSms(phone, call.argument<String>("text") ?: "", result)
                    "call" -> result.success(startCall(phone, direct = true))
                    "dial" -> result.success(startCall(phone, direct = false))
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Envía el SMS (en varias partes si es largo) y responde "sent" cuando el
     * sistema confirma todas, o "error:<código>" con la primera que falle.
     */
    private fun sendSms(phone: String, text: String, result: MethodChannel.Result) {
        if (checkSelfPermission(Manifest.permission.SEND_SMS) != PackageManager.PERMISSION_GRANTED) {
            result.success("error:sin permiso")
            return
        }
        val sms = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            getSystemService(SmsManager::class.java)
        } else {
            @Suppress("DEPRECATION")
            SmsManager.getDefault()
        }
        if (sms == null) {
            result.success("error:sin servicio de SMS")
            return
        }
        val parts = sms.divideMessage(text)
        val startedAt = System.currentTimeMillis()
        val action = "$smsSentAction.${smsRequest++}"
        var pending = parts.size
        var answered = false
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (answered) return
                if (resultCode != Activity.RESULT_OK) {
                    answered = true
                    unregisterReceiver(this)
                    debugLog('w', "LazarusSos", "SMS no enviado: código $resultCode tras ${System.currentTimeMillis() - startedAt} ms")
                    result.success("error:$resultCode")
                    return
                }
                pending--
                if (pending == 0) {
                    answered = true
                    unregisterReceiver(this)
                    // Si llega después de que la app dejó de esperar, queda en el log.
                    debugLog('i', "LazarusSos", "SMS confirmado por la red tras ${System.currentTimeMillis() - startedAt} ms")
                    result.success("sent")
                }
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, IntentFilter(action), Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(receiver, IntentFilter(action))
        }
        val sentIntents = ArrayList<PendingIntent>()
        for (i in parts.indices) {
            val intent = Intent(action).setPackage(packageName)
            sentIntents.add(
                PendingIntent.getBroadcast(this, i, intent, PendingIntent.FLAG_IMMUTABLE),
            )
        }
        try {
            sms.sendMultipartTextMessage(phone, null, parts, sentIntents, null)
            debugLog('i', "LazarusSos", "SMS en envío: ${parts.size} parte(s)")
        } catch (e: Exception) {
            answered = true
            unregisterReceiver(receiver)
            result.success("error:${e.javaClass.simpleName}")
        }
    }

    /** Llamada directa si hay permiso; si no (o con `direct = false`), marcador. */
    private fun startCall(phone: String, direct: Boolean): Boolean {
        val canCall = direct &&
            checkSelfPermission(Manifest.permission.CALL_PHONE) == PackageManager.PERMISSION_GRANTED
        val intent = Intent(
            if (canCall) Intent.ACTION_CALL else Intent.ACTION_DIAL,
            Uri.parse("tel:$phone"),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            startActivity(intent)
            true
        } catch (e: Exception) {
            debugLog('w', "LazarusSos", "no se pudo llamar: ${e.message}")
            false
        }
    }
}
