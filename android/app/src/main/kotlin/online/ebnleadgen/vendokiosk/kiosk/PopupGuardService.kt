package online.ebnleadgen.vendokiosk.kiosk

import android.accessibilityservice.AccessibilityService
import android.content.ComponentName
import android.content.Context
import android.provider.Settings
import android.util.Log
import android.view.accessibility.AccessibilityEvent

/**
 * Closes Android's "App not available / blocked by your admin" box
 * (BlockedAppActivity). Lock task shows it whenever an approved app tries to
 * open a blocked one, typically an ad opening Chrome, the Play Store or a
 * shopping app. The block itself stays; only the box is dismissed (Back), so
 * the customer is returned to the game.
 *
 * Enabled by [KioskPolicy.applyBaseline] when the app holds
 * WRITE_SECURE_SETTINGS (granted once over adb at provisioning).
 */
class PopupGuardService : AccessibilityService() {
    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        if (event.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) return
        if (event.packageName?.toString() != "android") return
        if (!isBlockedAppBox(event.className?.toString(), event.text.joinToString(" "))) return
        Log.i(KioskDeviceAdminReceiver.TAG, "Popup guard: dismissed the blocked-app box")
        performGlobalAction(GLOBAL_ACTION_BACK)
    }

    override fun onInterrupt() = Unit

    companion object {
        /**
         * The box arrives as the activity or, on many builds, as a plain
         * android.app.Dialog titled "App is not available" / "... is not
         * available right now." (English UI), e.g. "Chrome is not available
         * right now." when a game ad opens a browser.
         */
        fun isBlockedAppBox(className: String?, text: String): Boolean {
            val cls = className.orEmpty()
            if (cls.contains("BlockedAppActivity")) return true
            return cls.endsWith("Dialog") && text.contains("not available", ignoreCase = true)
        }

        fun component(context: Context) = ComponentName(context, PopupGuardService::class.java)

        /** Adds or removes this service in the enabled accessibility services. Needs WRITE_SECURE_SETTINGS. */
        fun setEnabled(context: Context, enabled: Boolean) {
            val me = component(context).flattenToString()
            val cr = context.contentResolver
            val current = Settings.Secure.getString(cr, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
                ?.split(':')?.filter { it.isNotBlank() } ?: emptyList()
            val next = if (enabled) (current.filterNot { it.equals(me, true) } + me) else current.filterNot { it.equals(me, true) }
            if (next == current) return
            Settings.Secure.putString(cr, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, next.joinToString(":"))
            if (enabled) Settings.Secure.putInt(cr, Settings.Secure.ACCESSIBILITY_ENABLED, 1)
        }
    }
}
