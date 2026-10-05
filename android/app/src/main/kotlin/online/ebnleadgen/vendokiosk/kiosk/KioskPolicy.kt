package online.ebnleadgen.vendokiosk.kiosk

import android.Manifest
import android.app.ActivityManager
import android.app.admin.DeviceAdminReceiver
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.BatteryManager
import android.os.Build
import android.os.UserManager
import android.provider.Settings
import android.util.Log
import online.ebnleadgen.vendokiosk.MainActivity
import online.ebnleadgen.vendokiosk.core.RestrictedApps

/** The Device Policy Controller component. */
class KioskDeviceAdminReceiver : DeviceAdminReceiver() {
    override fun onLockTaskModeEntering(context: Context, intent: Intent, pkg: String) {
        Log.i(TAG, "Lock task entering: $pkg")
    }

    override fun onLockTaskModeExiting(context: Context, intent: Intent) {
        Log.i(TAG, "Lock task exiting")
    }

    companion object {
        const val TAG = "VendoKiosk"
        fun component(context: Context) = ComponentName(context, KioskDeviceAdminReceiver::class.java)
    }
}

/**
 * All Device Owner policy calls live here. Every method is a no-op that reports
 * failure when the app is not Device Owner, so callers can never assume
 * enforcement that is not actually in place.
 */
class KioskPolicy(private val context: Context) {
    private companion object {
        const val GMS = "com.google.android.gms"
    }

    private val dpm = context.getSystemService(DevicePolicyManager::class.java)
    private val admin = KioskDeviceAdminReceiver.component(context)
    private val pkg = context.packageName
    private val homeAlias = ComponentName(context, "$pkg.KioskHome")

    /** Restrictions applied while kiosk mode is active. */
    private val restrictions = buildList {
        add(UserManager.DISALLOW_FACTORY_RESET)
        add(UserManager.DISALLOW_SAFE_BOOT)
        add(UserManager.DISALLOW_ADD_USER)
        add(UserManager.DISALLOW_MOUNT_PHYSICAL_MEDIA)
        add(UserManager.DISALLOW_USB_FILE_TRANSFER)
        add(UserManager.DISALLOW_CREATE_WINDOWS) // blocks overlays/toasts from other apps
        add(UserManager.DISALLOW_SYSTEM_ERROR_DIALOGS)
        add(UserManager.DISALLOW_CONFIG_DATE_TIME)
        add(UserManager.DISALLOW_INSTALL_UNKNOWN_SOURCES)
        add(UserManager.DISALLOW_INSTALL_UNKNOWN_SOURCES_GLOBALLY)
        // A customer's Google (or other) account would stay on the shared kiosk
        // for the next customer, so sign-in is refused with an admin message.
        add(UserManager.DISALLOW_MODIFY_ACCOUNTS)
    }

    fun isDeviceOwner(): Boolean = dpm.isDeviceOwnerApp(pkg)
    fun isAdminActive(): Boolean = dpm.isAdminActive(admin)
    fun isLockTaskPermitted(): Boolean = dpm.isLockTaskPermitted(pkg)

    fun lockTaskState(): String = when (context.getSystemService(ActivityManager::class.java).lockTaskModeState) {
        ActivityManager.LOCK_TASK_MODE_LOCKED -> "locked"
        ActivityManager.LOCK_TASK_MODE_PINNED -> "pinned"
        else -> "none"
    }

    fun currentLockTaskPackages(): List<String> =
        if (isDeviceOwner()) dpm.getLockTaskPackages(admin).toList() else emptyList()

    /**
     * Baseline kiosk policies (idempotent). Returns human-readable problems;
     * an empty list means everything was applied.
     */
    fun applyBaseline(lockAdb: Boolean): List<String> {
        if (!isDeviceOwner()) return listOf("App is not Device Owner")
        val problems = mutableListOf<String>()
        fun attempt(label: String, block: () -> Unit) = try {
            block()
        } catch (e: Exception) {
            Log.w(KioskDeviceAdminReceiver.TAG, "$label failed", e)
            problems += "$label: ${e.javaClass.simpleName}"
        }

        // Start from the safe state: only the kiosk itself may run in lock task.
        attempt("Lock task allowlist") { setPaidAccess(null) }

        // Home: our activity-alias becomes the persistent home screen.
        attempt("Home activity") {
            context.packageManager.setComponentEnabledSetting(
                homeAlias, PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP
            )
            val filter = IntentFilter(Intent.ACTION_MAIN).apply {
                addCategory(Intent.CATEGORY_HOME)
                addCategory(Intent.CATEGORY_DEFAULT)
            }
            dpm.clearPackagePersistentPreferredActivities(admin, pkg)
            dpm.addPersistentPreferredActivity(admin, filter, homeAlias)
        }
        attempt("User restrictions") {
            restrictions.forEach { dpm.addUserRestriction(admin, it) }
            if (lockAdb) dpm.addUserRestriction(admin, UserManager.DISALLOW_DEBUGGING_FEATURES)
            else dpm.clearUserRestriction(admin, UserManager.DISALLOW_DEBUGGING_FEATURES)
        }
        attempt("Keyguard") {
            // Fails (returns false) when a secure screen lock is set.
            if (!dpm.setKeyguardDisabled(admin, true)) problems += "Keyguard: remove the screen lock (PIN/pattern) so the kiosk can start unattended after reboot"
        }
        attempt("Status bar") {
            if (!dpm.setStatusBarDisabled(admin, true)) problems += "Status bar could not be disabled"
        }
        attempt("Stay awake while charging") {
            val all = BatteryManager.BATTERY_PLUGGED_AC or BatteryManager.BATTERY_PLUGGED_USB or BatteryManager.BATTERY_PLUGGED_WIRELESS
            dpm.setGlobalSetting(admin, Settings.Global.STAY_ON_WHILE_PLUGGED_IN, all.toString())
        }
        if (Build.VERSION.SDK_INT >= 33) attempt("Notification permission") {
            dpm.setPermissionGrantState(admin, pkg, Manifest.permission.POST_NOTIFICATIONS, DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED)
        }
        return problems
    }

    /**
     * Grants (packages != null) or revokes (null) customer app access.
     *
     * Revoking removes customer apps from the lock task allowlist; Android then
     * finishes their tasks and returns to the kiosk task. That is the
     * enforcement at expiry — it works even while a customer app is in front.
     */
    fun setPaidAccess(packages: List<String>?): Boolean {
        if (!isDeviceOwner()) return false
        val allowed = buildList {
            add(pkg)
            packages?.let(RestrictedApps::filter)?.filter { it != pkg && isInstalled(it) }?.let { addAll(it) }
            // The Recents button and the gesture-navigation Home swipe are served by
            // the system launcher's recents activity even though this app is Home.
            // Without it on the allowlist both land on "App is not available".
            if (packages != null) recentsProviderPackage()?.let { add(it) }
            // Runtime permission prompts (camera, microphone, notifications...) are
            // shown by the system permission controller; without it approved apps
            // get "App is not available" when they ask for a permission.
            if (packages != null) permissionControllerPackage()?.let { add(it) }
            // Google Play services hosts sign-in and consent screens that approved
            // apps open; account sign-in itself is blocked by DISALLOW_MODIFY_ACCOUNTS.
            if (packages != null && isInstalled(GMS)) add(GMS)
        }.distinct()
        dpm.setLockTaskPackages(admin, allowed.toTypedArray())
        var features = DevicePolicyManager.LOCK_TASK_FEATURE_HOME or DevicePolicyManager.LOCK_TASK_FEATURE_SYSTEM_INFO
        if (packages != null) features = features or DevicePolicyManager.LOCK_TASK_FEATURE_OVERVIEW
        // Stop allowlisted apps from opening non-allowlisted activities (e.g. Settings
        // screens) inside their own task. Android 11+.
        if (Build.VERSION.SDK_INT >= 30) features = features or DevicePolicyManager.LOCK_TASK_FEATURE_BLOCK_ACTIVITY_START_IN_TASK
        dpm.setLockTaskFeatures(admin, features)
        return true
    }

    /**
     * Package of the platform's recents component (config_recentsComponentName,
     * e.g. Pixel/AOSP Launcher3 Quickstep or the HiOS launcher). Never the
     * Settings app, so allowlisting it cannot open Settings.
     */
    private fun recentsProviderPackage(): String? {
        val id = context.resources.getIdentifier("config_recentsComponentName", "string", "android")
        if (id == 0) return null
        val recents = ComponentName.unflattenFromString(context.resources.getString(id))?.packageName ?: return null
        val settings = context.packageManager.resolveActivity(Intent(Settings.ACTION_SETTINGS), 0)?.activityInfo?.packageName
        return recents.takeIf { it != pkg && it != settings && isInstalled(it) }
    }

    /** Package that shows runtime permission prompts. Never the Settings app. */
    private fun permissionControllerPackage(): String? {
        val pm = context.packageManager
        val pc = pm.resolveActivity(Intent("android.content.pm.action.REQUEST_PERMISSIONS"), 0)
            ?.activityInfo?.packageName ?: return null
        val settings = pm.resolveActivity(Intent(Settings.ACTION_SETTINGS), 0)?.activityInfo?.packageName
        return pc.takeIf { it != pkg && it != settings }
    }

    private fun isInstalled(p: String) = try {
        context.packageManager.getApplicationInfo(p, 0).enabled
    } catch (e: PackageManager.NameNotFoundException) {
        false
    }

    /**
     * Authenticated administrator exit: undoes kiosk policies so the phone can
     * be used normally. The app stays Device Owner (re-entering kiosk mode does
     * not need re-provisioning). Call Activity.stopLockTask() as well.
     */
    fun releaseKiosk(): List<String> {
        if (!isDeviceOwner()) return listOf("App is not Device Owner")
        val problems = mutableListOf<String>()
        fun attempt(label: String, block: () -> Unit) = try {
            block()
        } catch (e: Exception) {
            problems += "$label: ${e.javaClass.simpleName}"
        }
        attempt("Lock task allowlist") { dpm.setLockTaskPackages(admin, emptyArray()) }
        attempt("Home activity") {
            dpm.clearPackagePersistentPreferredActivities(admin, pkg)
            context.packageManager.setComponentEnabledSetting(
                homeAlias, PackageManager.COMPONENT_ENABLED_STATE_DISABLED, PackageManager.DONT_KILL_APP
            )
        }
        attempt("User restrictions") {
            (restrictions + UserManager.DISALLOW_DEBUGGING_FEATURES).forEach { dpm.clearUserRestriction(admin, it) }
        }
        attempt("Keyguard") { dpm.setKeyguardDisabled(admin, false) }
        attempt("Status bar") { dpm.setStatusBarDisabled(admin, false) }
        return problems
    }

    /** Permanently gives up Device Owner. Irreversible without re-provisioning. */
    fun clearDeviceOwner(): Boolean {
        if (!isDeviceOwner()) return false
        releaseKiosk()
        @Suppress("DEPRECATION")
        dpm.clearDeviceOwnerApp(pkg)
        return !isDeviceOwner()
    }

    // ---- Home app (demo convenience; production sets this via Device Owner policy)

    /** True when pressing Home currently opens this app. */
    fun isDefaultHome(): Boolean {
        val home = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        val resolved = if (Build.VERSION.SDK_INT >= 33) {
            context.packageManager.resolveActivity(home, PackageManager.ResolveInfoFlags.of(PackageManager.MATCH_DEFAULT_ONLY.toLong()))
        } else {
            @Suppress("DEPRECATION")
            context.packageManager.resolveActivity(home, PackageManager.MATCH_DEFAULT_ONLY)
        }
        return resolved?.activityInfo?.packageName == pkg
    }

    /** Makes the HOME entry point (activity-alias) available or hides it again. */
    fun setHomeEntryEnabled(enabled: Boolean) {
        context.packageManager.setComponentEnabledSetting(
            homeAlias,
            if (enabled) PackageManager.COMPONENT_ENABLED_STATE_ENABLED else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.DONT_KILL_APP
        )
    }

    fun diagnostics(): Map<String, Any?> = mapOf(
        "isDeviceOwner" to isDeviceOwner(),
        "isAdminActive" to isAdminActive(),
        "lockTaskPermitted" to isLockTaskPermitted(),
        "lockTaskState" to lockTaskState(),
        "lockTaskPackages" to currentLockTaskPackages(),
        "homeAliasEnabled" to (context.packageManager.getComponentEnabledSetting(homeAlias) == PackageManager.COMPONENT_ENABLED_STATE_ENABLED),
        "sdkInt" to Build.VERSION.SDK_INT,
        "manufacturer" to Build.MANUFACTURER,
        "model" to Build.MODEL,
        "release" to Build.VERSION.RELEASE,
        "activity" to MainActivity::class.java.name,
    )
}
