package online.ebnleadgen.vendokiosk.kiosk

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.util.Log
import online.ebnleadgen.vendokiosk.core.KioskMode
import online.ebnleadgen.vendokiosk.data.KioskStore
import online.ebnleadgen.vendokiosk.service.KioskService

/**
 * After reboot (or an app update) restore the SAFE state first — only the
 * kiosk is allowed — then start the service, which re-grants access only after
 * a fresh, verified report from the coin controller. Phone-side credit is never
 * persisted, so nothing stale can be restored.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val store = KioskStore(context)
        if (store.mode == KioskMode.PRODUCTION) {
            val ok = KioskPolicy(context).setPaidAccess(null)
            Log.i(KioskDeviceAdminReceiver.TAG, "Boot: restricted to kiosk (deviceOwner=$ok)")
        }
        if (store.mode != KioskMode.UNCONFIGURED) {
            // BOOT_COMPLETED is an allowed context for starting a foreground service.
            KioskService.start(context)
        }
    }
}

/**
 * Last-resort administrator recovery over USB debugging (PIN and recovery code
 * both lost). Protected by android.permission.DUMP, which the adb shell holds
 * and ordinary apps cannot obtain, so it requires physical USB access, enabled
 * USB debugging and an authorised computer:
 *
 *   adb shell am broadcast -a online.ebnleadgen.vendokiosk.ADB_RECOVERY \
 *       -n online.ebnleadgen.vendokiosk/.kiosk.AdbRecoveryReceiver
 *
 * Releases kiosk policies (leaves lock task) and deletes the PIN so setup asks
 * for a new one. Pairing, enrollment and Device Owner are kept.
 */
class AdbRecoveryReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION) return
        Log.w(KioskDeviceAdminReceiver.TAG, "ADB recovery requested: releasing kiosk and clearing admin PIN")
        val engine = online.ebnleadgen.vendokiosk.service.KioskEngine.get(context)
        engine.adbRecoveryReset()
    }

    companion object {
        const val ACTION = "online.ebnleadgen.vendokiosk.ADB_RECOVERY"
    }
}

/**
 * Fail-safe heartbeat. While the kiosk is in production mode the service
 * re-arms this alarm every minute. If it fires and the service is not alive in
 * this process (e.g. HiOS killed it), access is revoked immediately and the
 * service is restarted (Device Owner apps may start foreground services from
 * the background).
 */
class WatchdogReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val store = KioskStore(context)
        if (store.mode != KioskMode.PRODUCTION) return
        if (!KioskService.isAliveRecently()) {
            Log.w(KioskDeviceAdminReceiver.TAG, "Watchdog: service not running; restricting and restarting")
            KioskPolicy(context).setPaidAccess(null)
            try {
                KioskService.start(context)
            } catch (e: Exception) {
                Log.e(KioskDeviceAdminReceiver.TAG, "Watchdog could not restart service", e)
            }
        }
        schedule(context)
    }

    companion object {
        private const val INTERVAL_MS = 60_000L

        fun schedule(context: Context) {
            val am = context.getSystemService(AlarmManager::class.java)
            val pi = PendingIntent.getBroadcast(
                context, 7, Intent(context, WatchdogReceiver::class.java),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            // Inexact alarm: no SCHEDULE_EXACT_ALARM permission needed. The service
            // itself enforces expiry to the second; this only covers its death.
            am.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, SystemClock.elapsedRealtime() + INTERVAL_MS, pi)
        }
    }
}
