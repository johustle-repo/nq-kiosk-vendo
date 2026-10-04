package online.ebnleadgen.vendokiosk.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.os.SystemClock
import android.util.Log
import online.ebnleadgen.vendokiosk.MainActivity
import online.ebnleadgen.vendokiosk.R
import online.ebnleadgen.vendokiosk.kiosk.KioskDeviceAdminReceiver

/**
 * Foreground service (type connectedDevice) that keeps the kiosk engine
 * running while customer apps are in the foreground: it polls the coin
 * controller over the LAN, enforces expiry, and reports to the cloud.
 */
class KioskService : Service() {
    companion object {
        private const val CHANNEL_STATUS = "kiosk_status"
        private const val CHANNEL_ALERTS = "kiosk_alerts"
        private const val NOTIFICATION_ID = 41
        private const val EXPIRED_NOTIFICATION_ID = 42

        @Volatile private var running = false

        fun isAliveRecently(): Boolean {
            if (!running) return false
            val engine = instanceEngine ?: return false
            return SystemClock.elapsedRealtime() - engine.lastTickAtMs < 30_000
        }

        @Volatile private var instanceEngine: KioskEngine? = null

        /** Allowed from an activity, BOOT_COMPLETED, or (Device Owner) the background. */
        fun start(context: Context) {
            context.startForegroundService(Intent(context, KioskService::class.java))
        }

        private fun ensureChannels(context: Context) {
            val nm = context.getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(NotificationChannel(CHANNEL_STATUS, "Kiosk status", NotificationManager.IMPORTANCE_LOW))
            nm.createNotificationChannel(NotificationChannel(CHANNEL_ALERTS, "Session alerts", NotificationManager.IMPORTANCE_HIGH))
        }

        private fun openKioskIntent(context: Context) = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
            PendingIntent.FLAG_IMMUTABLE
        )

        /** Demo mode cannot force the kiosk to the front; tell the user instead. */
        fun notifyDemoExpired(context: Context) {
            ensureChannels(context)
            val n = Notification.Builder(context, CHANNEL_ALERTS)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle("Vendo demo: time expired")
                .setContentText("Demo mode does not restrict other apps. Tap to return to the kiosk.")
                .setContentIntent(openKioskIntent(context))
                .setAutoCancel(true)
                .build()
            try {
                context.getSystemService(NotificationManager::class.java).notify(EXPIRED_NOTIFICATION_ID, n)
            } catch (e: SecurityException) {
                Log.w(KioskDeviceAdminReceiver.TAG, "Notification permission not granted")
            }
        }
    }

    private lateinit var engine: KioskEngine

    override fun onCreate() {
        super.onCreate()
        ensureChannels(this)
        val notification = Notification.Builder(this, CHANNEL_STATUS)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Vendo kiosk is running")
            .setContentText("Communicating with the coin controller")
            .setContentIntent(openKioskIntent(this))
            .setOngoing(true)
            .build()
        startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        engine = KioskEngine.get(this)
        instanceEngine = engine
        running = true
        engine.start()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        running = false
        // Without the service nothing enforces expiry, so fail closed.
        if (engine.store.mode == online.ebnleadgen.vendokiosk.core.KioskMode.PRODUCTION) {
            engine.policy.setPaidAccess(null)
        }
        engine.stop()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
