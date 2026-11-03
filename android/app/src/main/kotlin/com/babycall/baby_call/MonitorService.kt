package com.babycall.baby_call

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Servicio en primer plano: mantiene vivo el proceso de la app (y con él los
 * reproductores y la vigilancia) cuando la pantalla se apaga o la app pasa a
 * segundo plano. Android mata con facilidad a las apps sin un servicio así.
 */
class MonitorService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Vigilando las cámaras"
        val alarm = intent?.getBooleanExtra(EXTRA_ALARM, false) ?: false
        val notification = buildNotification(text, alarm)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        // Si el sistema mata el servicio, no lo reinicia solo: sin la app
        // en memoria no habría nada que vigilar.
        return START_NOT_STICKY
    }

    private fun buildNotification(text: String, alarm: Boolean): Notification {
        ensureChannel()
        val launch = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pending = PendingIntent.getActivity(
            this, 0, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(if (alarm) "¡Cámara Desconectada!" else "Baby Call")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setContentIntent(pending)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
        if (alarm) {
            builder.setColor(0xFFE53935.toInt()).setColorized(true)
        }
        return builder.build()
    }

    private fun ensureChannel() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Monitor de cámaras",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Muestra que Baby Call sigue vigilando las cámaras"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    companion object {
        const val CHANNEL_ID = "baby_call_monitor"
        const val NOTIFICATION_ID = 1001
        const val EXTRA_TEXT = "text"
        const val EXTRA_ALARM = "alarm"

        fun start(context: Context, text: String, alarm: Boolean) {
            val intent = Intent(context, MonitorService::class.java)
                .putExtra(EXTRA_TEXT, text)
                .putExtra(EXTRA_ALARM, alarm)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, MonitorService::class.java))
        }
    }
}
