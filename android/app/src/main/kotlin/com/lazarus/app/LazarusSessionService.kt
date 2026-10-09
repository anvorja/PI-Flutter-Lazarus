package com.lazarus.app

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Servicio en primer plano de la sesión (HU-017): con la pantalla bloqueada,
 * Android no suspende la app mientras el servicio esté activo, así que siguen el
 * micrófono, el audio, el GPS y la conexión con el asistente. Muestra la
 * notificación persistente "Lazarus está activo" con la acción "Detener".
 *
 * Lo arranca y detiene la app desde Dart (canal `lazarus/session`); la acción
 * "Detener" de la notificación avisa a Dart, que cierra la sesión igual que el
 * botón de la pantalla.
 */
class LazarusSessionService : Service() {
    companion object {
        const val ACTION_START = "com.lazarus.app.SESSION_START"
        const val ACTION_STOP = "com.lazarus.app.SESSION_STOP"
        const val ACTION_STOP_FROM_NOTIFICATION = "com.lazarus.app.SESSION_STOP_FROM_NOTIFICATION"
        private const val CHANNEL_ID = "lazarus_session"
        private const val NOTIFICATION_ID = 17

        /** Lo registra la actividad: lleva el "Detener" de la notificación a Dart. */
        var onStopRequested: (() -> Unit)? = null

        fun start(context: Context) {
            val intent = Intent(context, LazarusSessionService::class.java).setAction(ACTION_START)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, LazarusSessionService::class.java))
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP_FROM_NOTIFICATION) {
            val listener = onStopRequested
            if (listener != null) {
                // Dart cierra la sesión y luego detiene este servicio.
                listener()
            } else {
                // Sin la app para cerrar la sesión: al menos se libera el servicio.
                stopSelf()
            }
            return START_NOT_STICKY
        }
        startInForeground()
        acquireWakeLock()
        // Si Android mata el proceso, la sesión no se puede retomar sola: no se
        // recrea el servicio (la persona vuelve a tocar la pantalla).
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    private fun startInForeground() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, foregroundTypes())
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    /**
     * Solo los tipos con permiso concedido: en Android 14 declarar un tipo sin su
     * permiso (p. ej. cámara negada) hace fallar el arranque del servicio.
     */
    private fun foregroundTypes(): Int {
        var types = 0
        if (granted(Manifest.permission.RECORD_AUDIO) && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        }
        if (granted(Manifest.permission.ACCESS_FINE_LOCATION) ||
            granted(Manifest.permission.ACCESS_COARSE_LOCATION)
        ) {
            types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
        }
        if (granted(Manifest.permission.CAMERA) && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
        }
        return types
    }

    private fun granted(permission: String) =
        checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        // Mantiene la CPU despierta (no la pantalla) para que el audio y la
        // conexión no se congelen con la pantalla apagada.
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Lazarus:session").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Sesión activa",
                NotificationManager.IMPORTANCE_LOW,
            ).apply { description = "Lazarus sigue contigo con la pantalla bloqueada." }
            manager.createNotificationChannel(channel)
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, LazarusSessionService::class.java).setAction(ACTION_STOP_FROM_NOTIFICATION),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            // Silueta blanca: Android pinta los íconos de notificación como máscara.
            .setSmallIcon(R.drawable.ic_stat_lazarus)
            .setColor(0xFF1DC9BE.toInt())
            .setContentTitle("Lazarus está activo")
            .setContentText("Sigue contigo con la pantalla bloqueada.")
            .setOngoing(true)
            .setContentIntent(open)
            .addAction(
                @Suppress("DEPRECATION")
                Notification.Action.Builder(0, "Detener", stop).build(),
            )
            .build()
    }
}
