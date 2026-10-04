package online.ebnleadgen.vendokiosk

import android.Manifest
import android.app.ActivityOptions
import android.app.KeyguardManager
import android.app.role.RoleManager
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import online.ebnleadgen.vendokiosk.bridge.AppCatalog
import online.ebnleadgen.vendokiosk.core.KioskMode
import online.ebnleadgen.vendokiosk.kiosk.KioskDeviceAdminReceiver
import online.ebnleadgen.vendokiosk.service.KioskEngine
import online.ebnleadgen.vendokiosk.service.KioskService
import java.util.concurrent.Executors

/**
 * Hosts the Flutter UI and the platform channels:
 *  - MethodChannel "vendo_kiosk/native": commands (see docs/ARCHITECTURE.md)
 *  - EventChannel  "vendo_kiosk/state":  state snapshots from [KioskEngine]
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val REQUEST_HOME_ROLE = 31
    }

    private lateinit var engine: KioskEngine
    private lateinit var catalog: AppCatalog
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var stateListener: ((Map<String, Any?>) -> Unit)? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        engine = KioskEngine.get(this)
        catalog = AppCatalog(this)
        super.onCreate(savedInstanceState)
        // The kiosk may appear over the lock screen and turn the display on
        // (used when a coin wakes a sleeping screen).
        setShowWhenLocked(true)
        setTurnScreenOn(true)
    }

    /**
     * Full screen: hides the status and navigation bars. Re-applied on every
     * focus change because Android shows them again after dialogs, other apps
     * or the notification shade. A swipe from an edge reveals them briefly.
     */
    @Suppress("DEPRECATION")
    private fun hideSystemBars() {
        window.attributes = window.attributes.apply {
            layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let {
                it.hide(WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars())
                it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            window.decorView.systemUiVisibility = (
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or View.SYSTEM_UI_FLAG_FULLSCREEN or
                    View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                    View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                )
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemBars()
    }

    /** Removes a swipe-only lock screen; a PIN/pattern lock still asks for the credential. */
    private fun dismissNonSecureKeyguard() {
        val km = getSystemService(KeyguardManager::class.java) ?: return
        if (km.isKeyguardLocked && !km.isDeviceSecure) km.requestDismissKeyguard(this, null)
    }

    /**
     * Screen saver for an idle kiosk: asleep = minimum backlight and no
     * keep-screen-on (Android may then switch the display fully off).
     * Awake = normal brightness and the display stays on.
     */
    private fun setScreenAwake(awake: Boolean) {
        val lp = window.attributes
        lp.screenBrightness = if (awake) WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE else 0.01f
        window.attributes = lp
        if (awake) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            dismissNonSecureKeyguard()
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    override fun onResume() {
        super.onResume()
        val mode = engine.store.mode
        if (mode != KioskMode.UNCONFIGURED) {
            try {
                KioskService.start(this)
            } catch (e: Exception) {
                Log.e(KioskDeviceAdminReceiver.TAG, "Could not start kiosk service", e)
            }
        }
        dismissNonSecureKeyguard()
        hideSystemBars()
        if (mode == KioskMode.PRODUCTION) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            enterLockTaskIfPermitted()
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    private fun enterLockTaskIfPermitted() {
        if (engine.policy.isDeviceOwner() && engine.policy.isLockTaskPermitted() && engine.policy.lockTaskState() == "none") {
            try {
                startLockTask()
            } catch (e: Exception) {
                Log.e(KioskDeviceAdminReceiver.TAG, "startLockTask failed", e)
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        EventChannel(messenger, "vendo_kiosk/state").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                val l: (Map<String, Any?>) -> Unit = { events.success(it) }
                stateListener = l
                engine.addListener(l)
            }

            override fun onCancel(arguments: Any?) {
                stateListener?.let { engine.removeListener(it) }
                stateListener = null
            }
        })

        MethodChannel(messenger, "vendo_kiosk/native").setMethodCallHandler { call, result ->
            try {
                handle(call, result)
            } catch (e: CodedException) {
                result.error(e.code, e.message, null)
            } catch (e: SecurityException) {
                result.error(e.message ?: "forbidden", "Administrator PIN required", null)
            } catch (e: IllegalArgumentException) {
                result.error("invalid_argument", e.message, null)
            } catch (e: Exception) {
                Log.e(KioskDeviceAdminReceiver.TAG, "Method ${call.method} failed", e)
                result.error("error", e.message ?: e.javaClass.simpleName, null)
            }
        }
    }

    /** Runs blocking work off the UI thread and replies on it. */
    private fun background(result: MethodChannel.Result, work: () -> Any?) {
        io.execute {
            val outcome = runCatching(work)
            main.post {
                outcome.fold(
                    onSuccess = { result.success(it) },
                    onFailure = { e ->
                        val code = when (e) {
                            is CodedException -> e.code
                            is SecurityException -> e.message ?: "forbidden"
                            is IllegalArgumentException -> "invalid_argument"
                            else -> "error"
                        }
                        result.error(code, e.message ?: e.javaClass.simpleName, null)
                    }
                )
            }
        }
    }

    /** Carries a machine-readable error code to Flutter. */
    class CodedException(val code: String, cause: Throwable?) : RuntimeException(code, cause)

    private fun <T> Result<T>.orThrowCode(): T = getOrElse { e ->
        throw CodedException(
            (e as? online.ebnleadgen.vendokiosk.core.ProtocolException)?.code
                ?: (e as? online.ebnleadgen.vendokiosk.core.LocalHttpException)?.let { "unreachable" }
                ?: (e as? java.net.SocketTimeoutException)?.let { "timeout" }
                ?: (e as? java.net.ConnectException)?.let { "unreachable" }
                ?: (e as? online.ebnleadgen.vendokiosk.service.CloudHttpException)?.code
                ?: e.message ?: e.javaClass.simpleName,
            e
        )
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getState" -> engine.requestState { result.success(it) }

            "listApps" -> {
                val onlyAllowed = call.argument<Boolean>("onlyAllowed") ?: false
                val icons = call.argument<Boolean>("includeIcons") ?: true
                if (!onlyAllowed) engine.requireAdmin() // the full app list is an admin view
                background(result) {
                    catalog.launchableApps(icons, if (onlyAllowed) engine.store.allowedPackages.toSet() else null)
                }
            }

            "launchApp" -> {
                val pkg = call.argument<String>("packageName") ?: throw IllegalArgumentException("packageName")
                if (!engine.canLaunch(pkg)) {
                    result.error("not_allowed", "No paid time or app not approved", null)
                    return
                }
                // Production enforcement relies on lock task mode; never launch outside it.
                if (engine.store.mode == KioskMode.PRODUCTION && engine.policy.lockTaskState() != "locked") {
                    enterLockTaskIfPermitted()
                    result.error("lock_task_inactive", "Kiosk lock is not active; try again", null)
                    return
                }
                val intent = catalog.launchIntent(pkg)
                if (intent == null) {
                    result.error("not_launchable", "App is not installed or has no launcher activity", null)
                    return
                }
                val options = if (engine.store.mode == KioskMode.PRODUCTION && engine.policy.isDeviceOwner()) {
                    ActivityOptions.makeBasic().setLockTaskEnabled(true).toBundle()
                } else null
                startActivity(intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK), options)
                result.success(true)
            }

            // ---- administrator PIN
            "createPin" -> {
                val pin = call.argument<String>("pin") ?: ""
                background(result) { engine.createPin(pin) }
            }
            "verifyPin" -> {
                val pin = call.argument<String>("pin") ?: ""
                background(result) {
                    val r = engine.verifyPin(pin)
                    mapOf("ok" to r.ok, "lockoutMs" to r.lockoutMs, "failures" to r.failures)
                }
            }
            "recoverWithCode" -> {
                val code = call.argument<String>("code") ?: ""
                val newPin = call.argument<String>("newPin") ?: ""
                background(result) {
                    val r = engine.verifyRecoveryCode(code)
                    if (!r.ok) mapOf("ok" to false, "lockoutMs" to r.lockoutMs, "failures" to r.failures)
                    else mapOf("ok" to true, "recoveryCode" to engine.changePin(newPin))
                }
            }
            "changePin" -> {
                val pin = call.argument<String>("pin") ?: ""
                background(result) { engine.changePin(pin) }
            }
            "lockAdmin" -> {
                engine.lockAdmin()
                result.success(null)
            }

            // ---- admin settings
            "setMode" -> {
                engine.requireAdmin()
                val mode = KioskMode.fromWire(call.argument<String>("mode"))
                engine.setMode(mode).orThrowCode()
                KioskService.start(this)
                if (mode == KioskMode.PRODUCTION) enterLockTaskIfPermitted()
                result.success(true)
            }
            "setAllowedPackages" -> {
                engine.requireAdmin()
                engine.setAllowedPackages(call.argument<List<String>>("packages") ?: emptyList())
                result.success(true)
            }
            "setLossTimeout" -> {
                engine.requireAdmin()
                engine.setLossTimeout(call.argument<Int>("seconds") ?: 30)
                result.success(true)
            }
            "setLockAdb" -> {
                engine.requireAdmin()
                engine.setLockAdb(call.argument<Boolean>("lock") ?: false)
                result.success(true)
            }
            "pairController" -> {
                engine.requireAdmin()
                val address = call.argument<String>("address") ?: ""
                val code = call.argument<String>("code") ?: ""
                background(result) { engine.pairController(address, code).orThrowCode() }
            }
            "setControllerAddress" -> {
                engine.requireAdmin()
                engine.setControllerAddress(call.argument<String>("address") ?: "").orThrowCode()
                result.success(true)
            }
            "unpairController" -> {
                engine.requireAdmin()
                background(result) { engine.unpairController().orThrowCode(); true }
            }
            "endSession" -> {
                engine.requireAdmin()
                background(result) { engine.endSession().orThrowCode(); true }
            }
            "enrollCloud" -> {
                engine.requireAdmin()
                val code = call.argument<String>("code") ?: ""
                background(result) { engine.enrollCloud(code).orThrowCode() }
            }
            "unenrollCloud" -> {
                engine.requireAdmin()
                engine.unenrollCloud()
                result.success(true)
            }
            "simulateCoin" -> {
                val pulses = call.argument<Int>("pulses") ?: 1
                val r = engine.simulateCoin(pulses)
                if (r.isSuccess) result.success(r.getOrNull())
                else result.error(r.exceptionOrNull()?.message ?: "rejected", "Simulated credits are disabled in production mode", null)
            }
            "exitKiosk" -> {
                engine.requireAdmin()
                try {
                    stopLockTask()
                } catch (e: Exception) {
                    Log.w(KioskDeviceAdminReceiver.TAG, "stopLockTask: ${e.message}")
                }
                result.success(engine.releaseKiosk())
            }
            "removeDeviceOwner" -> {
                engine.requireAdmin()
                try {
                    stopLockTask()
                } catch (e: Exception) {
                    Log.w(KioskDeviceAdminReceiver.TAG, "stopLockTask: ${e.message}")
                }
                result.success(engine.clearDeviceOwner())
            }
            "diagnostics" -> {
                engine.requireAdmin()
                result.success(engine.diagnostics())
            }
            // Demo convenience: make Home return to the kiosk. Android shows its own
            // confirmation; production sets the home screen via Device Owner policy instead.
            "useAsHomeApp" -> {
                engine.requireAdmin()
                engine.policy.setHomeEntryEnabled(true)
                val roles = getSystemService(RoleManager::class.java)
                if (roles != null && roles.isRoleAvailable(RoleManager.ROLE_HOME) && !roles.isRoleHeld(RoleManager.ROLE_HOME)) {
                    @Suppress("DEPRECATION")
                    startActivityForResult(roles.createRequestRoleIntent(RoleManager.ROLE_HOME), REQUEST_HOME_ROLE)
                } else if (!engine.policy.isDefaultHome()) {
                    startActivity(Intent(Settings.ACTION_HOME_SETTINGS))
                }
                result.success(true)
            }
            "setScreenAwake" -> {
                setScreenAwake(call.argument<Boolean>("awake") ?: true)
                result.success(true)
            }
            "setIdleSleep" -> {
                engine.requireAdmin()
                engine.setIdleSleep(call.argument<Int>("seconds") ?: 60)
                result.success(true)
            }
            "openLockScreenSettings" -> {
                engine.requireAdmin()
                startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                result.success(true)
            }
            "restoreNormalHome" -> {
                engine.requireAdmin()
                if (engine.store.mode == KioskMode.PRODUCTION) {
                    result.error("production_mode", "In production the kiosk must stay the Home app. Exit kiosk first.", null)
                    return
                }
                // Hiding the HOME entry makes Android fall back to the phone's own launcher.
                engine.policy.setHomeEntryEnabled(false)
                result.success(true)
            }
            "requestNotificationPermission" -> {
                if (Build.VERSION.SDK_INT >= 33 &&
                    checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                ) {
                    requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
                }
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    override fun onDestroy() {
        stateListener?.let { engine.removeListener(it) }
        stateListener = null
        super.onDestroy()
    }
}
