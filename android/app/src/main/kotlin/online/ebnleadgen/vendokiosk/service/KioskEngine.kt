package online.ebnleadgen.vendokiosk.service

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import online.ebnleadgen.vendokiosk.BuildConfig
import online.ebnleadgen.vendokiosk.MainActivity
import online.ebnleadgen.vendokiosk.core.AccessDecision
import online.ebnleadgen.vendokiosk.core.AccessInputs
import online.ebnleadgen.vendokiosk.core.AccessPolicy
import online.ebnleadgen.vendokiosk.core.ChargeRule
import online.ebnleadgen.vendokiosk.core.RestrictedApps
import online.ebnleadgen.vendokiosk.core.ControllerDiscovery
import online.ebnleadgen.vendokiosk.core.SoundCues
import online.ebnleadgen.vendokiosk.core.ControllerProtocol
import online.ebnleadgen.vendokiosk.core.ControllerProtocol.toHex
import online.ebnleadgen.vendokiosk.core.ControllerStatus
import online.ebnleadgen.vendokiosk.core.DashboardCredit
import online.ebnleadgen.vendokiosk.core.DemoClock
import online.ebnleadgen.vendokiosk.core.DenyReason
import online.ebnleadgen.vendokiosk.core.KioskMode
import online.ebnleadgen.vendokiosk.core.LinkState
import online.ebnleadgen.vendokiosk.core.LocalHttp
import online.ebnleadgen.vendokiosk.core.PinSecurity
import online.ebnleadgen.vendokiosk.core.ProtocolException
import online.ebnleadgen.vendokiosk.core.Rates
import online.ebnleadgen.vendokiosk.core.SessionTracker
import online.ebnleadgen.vendokiosk.data.KioskStore
import online.ebnleadgen.vendokiosk.kiosk.KioskDeviceAdminReceiver
import online.ebnleadgen.vendokiosk.kiosk.KioskPolicy
import online.ebnleadgen.vendokiosk.kiosk.PopupGuardService
import online.ebnleadgen.vendokiosk.kiosk.WatchdogReceiver
import org.json.JSONArray
import org.json.JSONObject
import java.net.ConnectException
import java.net.Inet4Address
import java.net.SocketTimeoutException
import java.security.SecureRandom
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Process-wide kiosk runtime. All session/access state is owned by one worker
 * thread ([handler]); network I/O runs on separate executors and posts results
 * back, so a slow controller or cloud can never delay expiry enforcement.
 *
 * Runs inside the foreground [KioskService], so it keeps working while a
 * customer app is in the foreground (a Dart timer would not).
 */
class KioskEngine private constructor(context: Context) {
    companion object {
        private const val TAG = KioskDeviceAdminReceiver.TAG
        private const val TICK_MS = 500L
        private const val POLL_INTERVAL_MS = 1_000L
        private const val CLOUD_INTERVAL_MS = 30_000L
        private const val CHARGE_CHECK_MS = 30_000L
        private const val AD_BLOCK_REFRESH_MS = 30 * 60_000L
        private const val AD_BLOCK_RETRY_MS = 60_000L
        private const val CHARGE_RESEND_MS = 10 * 60_000L
        private const val POWER_MENU_MS = 60_000L
        private const val ADMIN_UNLOCK_MS = 5 * 60_000L
        private const val RELOCK_INTERVAL_MS = 3_000L
        // Coin box unreachable this long → look for it on the local network (its IP may have changed).
        private const val DISCOVER_AFTER_MS = 10_000L
        private const val DISCOVER_INTERVAL_MS = 20_000L
        // Google Play for the administrator (install apps), then it is locked out again.
        private const val APP_STORE_WINDOW_MS = 15 * 60_000L
        private const val PLAY_STORE = "com.android.vending"
        private const val PLAY_SERVICES = "com.google.android.gms" // Play sign-in and purchase screens

        @Volatile private var instance: KioskEngine? = null

        fun get(context: Context): KioskEngine =
            instance ?: synchronized(this) { instance ?: KioskEngine(context.applicationContext).also { instance = it } }
    }

    private val ctx = context.applicationContext
    val store = KioskStore(ctx)
    val policy = KioskPolicy(ctx)
    private val tracker = SessionTracker(store.lossTimeoutS * 1000L)
    private val demo = DemoClock()
    // Free time given from the dashboard; worker thread only.
    private val dashboard = DashboardCredit(store.dashboardCreditMs)
    private val dashboardAcks = LinkedHashMap<Long, String>() // applied, not yet confirmed by a heartbeat
    val wifi = WifiAdmin(ctx)
    // Coin box traffic always goes over the Wi-Fi, even when Android prefers mobile data.
    private val http = LocalHttp(newSocket = { wifi.newLocalSocket() })
    private val cloud = CloudClient(BuildConfig.CLOUD_API_BASE)
    private val sounds = SoundPlayer()
    private val random = SecureRandom()
    private val phoneBootId = ByteArray(4).also { random.nextBytes(it) }.toHex()

    private val worker = HandlerThread("vendo-kiosk").apply { start() }
    private val handler = Handler(worker.looper)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pollExecutor = Executors.newSingleThreadExecutor()
    private val cloudExecutor = Executors.newSingleThreadExecutor()
    private val pollInFlight = AtomicBoolean(false)
    private val cloudInFlight = AtomicBoolean(false)
    private val chargeExecutor = Executors.newSingleThreadExecutor()
    private val chargeInFlight = AtomicBoolean(false)
    private val adBlockExecutor = Executors.newSingleThreadExecutor()
    private val adbRestartExecutor = Executors.newSingleThreadExecutor()
    private val adBlockInFlight = AtomicBoolean(false)
    private val discoveryExecutor = Executors.newSingleThreadExecutor()
    private val discoveryInFlight = AtomicBoolean(false)

    private val listeners = CopyOnWriteArrayList<(Map<String, Any?>) -> Unit>()

    // ---- state owned by the worker thread
    private var running = false
    @Volatile private var decision: AccessDecision = AccessDecision.Denied(DenyReason.UNCONFIGURED)
    private var appliedGrant: Boolean? = null
    private var appliedPackages: List<String> = emptyList()
    private var lastExpiryAtMs: Long? = null
    private var lastExpiryReason: String? = null
    private var lastPollAtMs = 0L
    private var pollFailingSinceMs = 0L
    private var lastDiscoveryAtMs = -DISCOVER_INTERVAL_MS
    private var lastCloudAtMs = -CLOUD_INTERVAL_MS
    private var lastWatchdogAtMs = 0L
    private var lastEmitAtMs = 0L
    private var policyProblems: List<String> = emptyList()
    private var cachedOwner: Boolean? = null
    private var cachedOwnerAtMs = 0L
    private var wakeLock: PowerManager.WakeLock? = null
    @Volatile var lastTickAtMs = 0L
    private var lastRelockAtMs = 0L
        private set

    // ---- cloud state (written by cloud executor, read when emitting)
    @Volatile private var cloudLink = "disabled"
    @Volatile private var cloudLastOkAtMs: Long? = null
    @Volatile private var cloudLastError: String? = null

    // ---- secrets cached in memory (never logged)
    @Volatile private var controllerKey: ByteArray? = store.controllerKey
    @Volatile private var adminUnlockedUntilMs = 0L
    @Volatile private var appStoreUntilMs = 0L
    private var appliedAppStore = false

    // ---- charger relay on the coin box (written by the charge executor)
    @Volatile private var chargeConfirmed: Boolean? = null // what the coin box last accepted
    @Volatile private var chargeConfirmedBoot: String? = null
    @Volatile private var chargeConfirmedAtMs = 0L
    @Volatile private var chargeRelayOn: Boolean? = null
    @Volatile private var chargeLastError: String? = null
    private var lastChargeCheckAtMs = -CHARGE_CHECK_MS
    private var chargeLowReadings = 0

    // ---- ad blocking (Private DNS)
    @Volatile private var adBlockProblem: String? = null
    private var lastAdBlockAtMs = -AD_BLOCK_REFRESH_MS

    /** Bumped when the dashboard asks to open admin; Flutter opens the admin screen on a change. */
    @Volatile private var adminOpenSeq = 0

    private fun now() = SystemClock.elapsedRealtime()

    // ================================================================ lifecycle

    fun start() = handler.post {
        if (running) return@post
        running = true
        // Fail-safe default: until a verified report arrives, customers get nothing.
        if (store.mode == KioskMode.PRODUCTION) {
            policyProblems = applyBaseline()
            appliedGrant = false
            appliedPackages = emptyList()
        }
        handler.post(tickRunnable)
    }

    /**
     * Fail-safe reset for receivers (boot, app update, watchdog): only the kiosk
     * is allowed until the next evaluation re-grants from a verified report.
     * The restriction applies immediately on the caller's thread (the engine
     * thread may be the thing that is stuck); the applied-policy cache is then
     * cleared on the engine thread, so a session [enforce] already granted is
     * re-applied instead of being left with an empty allowlist.
     */
    fun restrictToKiosk(): Boolean {
        if (store.mode != KioskMode.PRODUCTION) return false
        val ok = policy.setPaidAccess(null)
        handler.post {
            appliedGrant = null
            if (running) evaluate()
        }
        return ok
    }

    fun stop() = handler.post {
        running = false
        handler.removeCallbacks(tickRunnable)
        releaseWakeLock()
    }

    private val tickRunnable = object : Runnable {
        override fun run() {
            if (!running) return
            try {
                tick()
            } catch (e: Exception) {
                Log.e(TAG, "tick failed", e)
            }
            handler.postDelayed(this, TICK_MS)
        }
    }

    private fun tick() {
        val t = now()
        lastTickAtMs = t
        if (t - lastPollAtMs >= POLL_INTERVAL_MS) {
            lastPollAtMs = t
            schedulePoll()
        }
        if (t - lastCloudAtMs >= CLOUD_INTERVAL_MS) {
            lastCloudAtMs = t
            scheduleCloud()
        }
        val adBlockEvery = if (adBlockProblem == null) AD_BLOCK_REFRESH_MS else AD_BLOCK_RETRY_MS
        if (store.mode == KioskMode.PRODUCTION && t - lastAdBlockAtMs >= adBlockEvery) {
            lastAdBlockAtMs = t
            applyAdBlock()
        }
        if (t - lastChargeCheckAtMs >= CHARGE_CHECK_MS) {
            lastChargeCheckAtMs = t
            if (store.keepWirelessAdb && !(store.mode == KioskMode.PRODUCTION && store.lockAdbInProduction)) {
                policy.ensureWirelessAdb()
            }
            checkCharge()
        }
        evaluate()
        if (store.mode == KioskMode.PRODUCTION && t - lastWatchdogAtMs >= 50_000) {
            lastWatchdogAtMs = t
            WatchdogReceiver.schedule(ctx)
        }
        // Self-heal: production must always run in lock task. An app update or a
        // crash kills the kiosk task and Android resumes whatever was below it
        // (e.g. the stock launcher). Skipped while an administrator is unlocked,
        // because "Exit kiosk" stops lock task on purpose.
        if (store.mode == KioskMode.PRODUCTION && !isAdminUnlocked() &&
            t - lastRelockAtMs >= RELOCK_INTERVAL_MS && policy.lockTaskState() == "none" && isDeviceOwner()
        ) {
            lastRelockAtMs = t
            Log.w(TAG, "Self-heal: not in lock task; bringing the kiosk back")
            bringKioskToFront()
        }
        if (appStoreUntilMs != 0L && t >= appStoreUntilMs) {
            Log.i(TAG, "Google Play window ended")
            appStoreUntilMs = 0L
            evaluate()
            if (store.mode == KioskMode.PRODUCTION) bringKioskToFront()
            emit()
        }
        if (t - lastEmitAtMs >= 1_000) emit()
    }

    private fun isDeviceOwner(): Boolean {
        val t = now()
        val c = cachedOwner
        if (c != null && t - cachedOwnerAtMs < 5_000) return c
        return policy.isDeviceOwner().also {
            cachedOwner = it
            cachedOwnerAtMs = t
        }
    }

    // ================================================================ access decision + enforcement

    private fun evaluate() {
        val t = now()
        val mode = store.mode
        val base = AccessInputs(
            mode = mode,
            isDeviceOwner = isDeviceOwner(),
            controllerPaired = controllerKey != null && store.controllerAddress != null,
            link = tracker.link(t),
            controllerRemainingMs = tracker.estimatedRemainingMs(t),
            demoRemainingMs = demo.remainingMs(t),
        )
        // Dashboard time is used only while there is no paid coin time to use.
        val usable = mode == KioskMode.DEMO || (mode == KioskMode.PRODUCTION && base.isDeviceOwner)
        dashboard.setRunning(usable && AccessPolicy.controllerMs(base) == 0L, t)
        val inputs = base.copy(dashboardRemainingMs = dashboard.remainingMs(t))
        val prev = decision
        val next = AccessPolicy.decide(inputs)
        decision = next
        if (store.sounds && mode != KioskMode.UNCONFIGURED) {
            SoundCues.cueFor(remainingOf(prev), remainingOf(next))?.let(sounds::play)
        }
        if (prev.granted && !next.granted) {
            lastExpiryAtMs = t
            lastExpiryReason = (next as AccessDecision.Denied).reason.wire
            Log.i(TAG, "Access ended: $lastExpiryReason")
            onAccessEnded(mode)
            emit()
        } else if (!prev.granted && next.granted) {
            lastExpiryAtMs = null
            // A coin was inserted: turn the screen on if it was asleep or off.
            wakeScreen()
            emit()
        }
        if (mode == KioskMode.PRODUCTION) enforce(next.granted)
    }

    private fun remainingOf(d: AccessDecision) = (d as? AccessDecision.Granted)?.remainingMs ?: 0L

    /** Applies the decision to Device Owner policy only when it changes. */
    private fun enforce(granted: Boolean) {
        val packages = if (granted) store.allowedPackages else emptyList()
        val appStore = appStoreOpen()
        if (appliedGrant == granted && appliedPackages == packages && appliedAppStore == appStore) return
        val ok = policy.setPaidAccess(if (granted) packages else null, if (appStore) listOf(PLAY_STORE, PLAY_SERVICES) else emptyList())
        appliedGrant = if (ok) granted else null
        appliedPackages = packages
        appliedAppStore = appStore
        if (granted) acquireWakeLock() else releaseWakeLock()
    }

    private fun onAccessEnded(mode: KioskMode) {
        if (mode == KioskMode.PRODUCTION) {
            // enforce(false) removes customer apps from the lock task allowlist; Android
            // finishes their tasks and the kiosk task returns to the front.
            enforce(false)
            bringKioskToFront()
        } else if (mode == KioskMode.DEMO) {
            KioskService.notifyDemoExpired(ctx)
            bringKioskToFront() // may be blocked by Android's background-launch rules in demo mode
        }
    }

    private fun bringKioskToFront() {
        try {
            ctx.startActivity(
                Intent(ctx, MainActivity::class.java).addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP
                )
            )
        } catch (e: Exception) {
            Log.w(TAG, "Could not bring kiosk to front: ${e.message}")
        }
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        wakeLock = ctx.getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "vendo:session").apply {
                setReferenceCounted(false)
                acquire(8 * 60 * 60_000L) // safety timeout; released at expiry
            }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    // ================================================================ controller polling

    private fun schedulePoll() {
        val address = store.controllerAddress ?: return
        val key = controllerKey ?: return
        val expectedId = store.controllerDeviceId
        val station = store.controllerStation
        if (!pollInFlight.compareAndSet(false, true)) return
        pollExecutor.execute {
            val result = try {
                val nonce = ByteArray(16).also { random.nextBytes(it) }.toHex()
                val r = http.get(address, "/api/v1/status?station=$station&nonce=$nonce")
                if (r.status != 200) throw ProtocolException("http_${r.status}", "Controller returned ${r.status}")
                Result.success(ControllerProtocol.verifyStatus(r.body, r.headers["x-vk-signature"], nonce, key, expectedId, station))
            } catch (e: Exception) {
                Result.failure<ControllerStatus>(e)
            } finally {
                pollInFlight.set(false)
            }
            handler.post { onPollResult(result) }
        }
    }

    private fun onPollResult(result: Result<ControllerStatus>) {
        result.fold(
            onSuccess = { status ->
                pollFailingSinceMs = 0L
                val update = tracker.onVerifiedStatus(status, now())
                if (update.name != "UPDATED" && update.name != "STALE_IGNORED") Log.i(TAG, "Controller: $update")
            },
            onFailure = { e ->
                tracker.onPollFailed(
                    when (e) {
                        is ProtocolException -> e.code
                        is SocketTimeoutException -> "timeout"
                        is ConnectException -> "unreachable"
                        else -> e.javaClass.simpleName
                    }
                )
                if (pollFailingSinceMs == 0L) pollFailingSinceMs = now()
                maybeDiscoverController()
            }
        )
        evaluate()
    }

    /** The coin box stopped answering: its IP may have changed, so look for it by its device id. */
    private fun maybeDiscoverController() {
        val deviceId = store.controllerDeviceId ?: return
        val t = now()
        if (t - pollFailingSinceMs < DISCOVER_AFTER_MS || t - lastDiscoveryAtMs < DISCOVER_INTERVAL_MS) return
        val ownIp = ownLocalIp() ?: return
        if (!discoveryInFlight.compareAndSet(false, true)) return
        lastDiscoveryAtMs = t
        val previous = store.controllerAddress
        discoveryExecutor.execute {
            val found = try {
                ControllerDiscovery.find(ownIp, previous, deviceId) { wifi.newLocalSocket() }
            } catch (e: Exception) {
                null
            } finally {
                discoveryInFlight.set(false)
            }
            handler.post {
                if (found != null && found != store.controllerAddress && store.controllerDeviceId == deviceId) {
                    Log.i(TAG, "Coin box found at a new address: $found (was $previous)")
                    store.controllerAddress = found
                    pollFailingSinceMs = 0L
                    emit()
                }
            }
        }
    }

    private fun ownLocalIp(): String? = wifi.ownIp() ?: try {
        val cm = ctx.getSystemService(ConnectivityManager::class.java)
        cm.getLinkProperties(cm.activeNetwork)?.linkAddresses
            ?.map { it.address }?.firstOrNull { it is Inet4Address && it.isSiteLocalAddress }?.hostAddress
    } catch (e: Exception) {
        null
    }

    // ================================================================ cloud heartbeat (independent of local access)

    private fun scheduleCloud() {
        val token = store.cloudToken
        if (token == null) {
            cloudLink = "disabled"
            return
        }
        if (!cloudInFlight.compareAndSet(false, true)) return
        val payload = heartbeatPayload()
        cloudExecutor.execute {
            try {
                val res = cloud.heartbeat(token, payload)
                cloudLink = "ok"
                cloudLastOkAtMs = now()
                cloudLastError = null
                res.optJSONObject("config")?.let { cfg -> handler.post { applyCloudConfig(cfg) } }
                // One-shot request from a signed-in dashboard administrator (audited there).
                if (res.optJSONObject("admin_unlock") != null) handler.post { remoteAdminUnlock() }
                if (res.optBoolean("tap_admin", false)) handler.post { enableTapAdmin() }
                val sentAcks = payload.optJSONArray("acks")
                val commands = res.optJSONArray("commands")
                handler.post { onDashboardCommands(sentAcks, commands) }
            } catch (e: CloudHttpException) {
                cloudLink = if (e.status == 401) "unauthorized" else "error"
                cloudLastError = e.code
            } catch (e: Exception) {
                // Internet/cloud outage. Local controller access is unaffected.
                cloudLink = "offline"
                cloudLastError = e.javaClass.simpleName
            } finally {
                cloudInFlight.set(false)
            }
        }
    }

    /**
     * Commands from the dashboard (add_time, end_session) carried in the
     * heartbeat reply. Each is applied once by id and acknowledged on the next
     * heartbeat; the dashboard re-sends it until then.
     */
    private fun onDashboardCommands(sentAcks: JSONArray?, commands: JSONArray?) {
        if (sentAcks != null) for (i in 0 until sentAcks.length()) dashboardAcks.remove(sentAcks.getJSONObject(i).optLong("id"))
        if (commands == null || commands.length() == 0) return
        val t = now()
        val done = store.dashboardCommandIds.toMutableList()
        for (i in 0 until commands.length()) {
            val c = commands.optJSONObject(i) ?: continue
            val id = c.optLong("id", 0)
            if (id <= 0) continue
            if (id in done) {
                dashboardAcks.putIfAbsent(id, "ok")
                continue
            }
            val result = when (c.optString("type")) {
                "add_time" -> try {
                    dashboard.add(c.optInt("seconds", 0), t)
                    Log.i(TAG, "Dashboard added ${c.optInt("seconds")} s")
                    "ok"
                } catch (e: IllegalArgumentException) {
                    "bad_seconds"
                }
                "end_session" -> {
                    dashboard.clear()
                    demo.clear()
                    Log.i(TAG, "Dashboard ended the session")
                    "ok"
                }
                else -> "unsupported"
            }
            done += id
            dashboardAcks[id] = result
        }
        store.dashboardCommandIds = done
        store.dashboardCreditMs = dashboard.remainingMs(t)
        evaluate()
        emit()
        // Acknowledge now rather than in 30 s, so the dashboard shows it quickly.
        lastCloudAtMs = 0
    }

    private fun heartbeatPayload(): JSONObject {
        val t = now()
        val s = tracker.last
        store.dashboardCreditMs = dashboard.remainingMs(t)
        return JSONObject()
            .put("features", JSONArray(listOf("dashboard_time")))
            .put(
                "dashboard_time", JSONObject()
                    .put("remaining_s", dashboard.remainingMs(t) / 1000)
                    .put("running", dashboard.running)
            )
            .put("acks", JSONArray(dashboardAcks.map { (id, r) -> JSONObject().put("id", id).put("result", r) }))
            .put("boot_id", phoneBootId)
            .put("uptime_ms", t)
            .put("app_version", BuildConfig.VERSION_NAME)
            .put("mode", store.mode.wire)
            .put("device_owner", isDeviceOwner())
            .put("lock_task", policy.lockTaskState())
            .put("tap_admin", store.cloudToken == null || store.tapAdminEnabled)
            .put("access", decision.let { if (it is AccessDecision.Denied) it.reason.wire else "granted" })
            .put(
                "controller", JSONObject()
                    .put("paired", controllerKey != null)
                    .put("station", store.controllerStation)
                    .put("link", tracker.link(t).name.lowercase())
                    .put("last_ok_age_s", tracker.ageMs(t)?.div(1000) ?: -1)
                    .put("remaining_s", s?.let { tracker.estimatedRemainingMs(t) / 1000 } ?: 0)
            )
            .put("allowed_packages", JSONArray(store.allowedPackages))
            .put("config_version_applied", store.cloudConfigVersion)
            .put("model", "${Build.MANUFACTURER} ${Build.MODEL}")
            .put("android_sdk", Build.VERSION.SDK_INT)
            .put("battery", batteryStatus())
    }

    /** Battery level (0-100, -1 if unknown) and whether it is charging, for the dashboard. */
    private fun batteryStatus(): JSONObject = JSONObject()
        .put("pct", batteryPct())
        .put("charging", isCharging())
        .put("charge_requested", store.chargeRequested)
        .put("charge_relay", chargeRelayOn ?: JSONObject.NULL)

    /** Last battery broadcast (sticky; no receiver is registered). */
    private fun batteryIntent(): Intent? = try {
        ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
    } catch (e: Exception) {
        null
    }

    /** Level from the battery broadcast (what Settings shows); -1 if unknown. */
    private fun batteryPct(): Int {
        val i = batteryIntent()
        val level = i?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = i?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val pct = if (level >= 0 && scale > 0) level * 100 / scale
        else ctx.getSystemService(BatteryManager::class.java)?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1
        return if (pct in 0..100) pct else -1
    }

    /** Power connected (charging, or full while plugged in). */
    private fun isCharging(): Boolean =
        (batteryIntent()?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0 ||
            ctx.getSystemService(BatteryManager::class.java)?.isCharging == true

    // ================================================================ charger relay (coin box D6)

    /**
     * Asks the coin box to switch its charger relay on below the start level and
     * off at the stop level (admin settings). Sent when the decision changes, when
     * the coin box restarts, and every few minutes as a refresh; failures retry
     * on the next check.
     */
    private fun checkCharge() {
        if (controllerKey == null || store.controllerAddress == null) return
        val boot = tracker.last?.bootId ?: return
        val pct = batteryPct()
        val charging = isCharging()
        chargeLowReadings = if (pct in 0 until store.chargeStartPct) chargeLowReadings + 1 else 0
        if (store.manualCharge && pct >= 100) {
            store.manualCharge = false
            Log.i(TAG, "Battery full: manual charging ended")
        }
        val want = ChargeRule.wantsCharge(
            store.autoChargeEnabled, pct, store.chargeStartPct, store.chargeStopPct, store.chargeRequested,
            charging, chargeLowReadings, store.manualCharge,
        )
        if (want != store.chargeRequested) {
            store.chargeRequested = want
            Log.i(TAG, "Battery $pct%${if (charging) " charging" else ""}: charger relay ${if (want) "on" else "off"}")
        }
        val fresh = chargeConfirmed == want && chargeConfirmedBoot == boot && now() - chargeConfirmedAtMs < CHARGE_RESEND_MS
        if (fresh || !chargeInFlight.compareAndSet(false, true)) return
        chargeExecutor.execute {
            try {
                sendCommandForBody(if (want) "charge_on" else "charge_off").fold(
                    onSuccess = { body ->
                        chargeConfirmed = want
                        chargeConfirmedBoot = boot
                        chargeConfirmedAtMs = now()
                        chargeRelayOn = body.contains("\"relay\":true")
                        chargeLastError = null
                    },
                    onFailure = { e ->
                        chargeConfirmed = null
                        chargeLastError = (e as? ProtocolException)?.code ?: e.javaClass.simpleName
                    },
                )
            } finally {
                chargeInFlight.set(false)
            }
            handler.post { emit() }
        }
    }

    /** Applies the ad-blocking setting off the engine thread (the check uses the network). */
    private fun applyAdBlock() {
        if (!adBlockInFlight.compareAndSet(false, true)) return
        val enabled = store.blockAds && store.mode == KioskMode.PRODUCTION
        adBlockExecutor.execute {
            try {
                val problem = policy.applyAdBlock(enabled)
                if (problem != adBlockProblem) Log.i(TAG, problem ?: "Ad blocking ${if (enabled) "on" else "off"}")
                adBlockProblem = problem
            } finally {
                adBlockInFlight.set(false)
            }
            handler.post { emit() }
        }
    }

    fun setAllowAccounts(allow: Boolean) {
        store.allowAccounts = allow
        handler.post {
            if (store.mode == KioskMode.PRODUCTION) policyProblems = applyBaseline().also { appliedGrant = null }
            evaluate()
            emit()
        }
    }

    fun setKeepWirelessAdb(enabled: Boolean) {
        store.keepWirelessAdb = enabled
        handler.post {
            if (enabled) policy.ensureWirelessAdb()
            emit()
        }
    }

    fun setSounds(enabled: Boolean) {
        store.sounds = enabled
        handler.post { emit() }
    }

    fun setBlockAds(enabled: Boolean) {
        store.blockAds = enabled
        handler.post {
            lastAdBlockAtMs = now()
            applyAdBlock()
            emit()
        }
    }

    fun setAutoCharge(enabled: Boolean, startPct: Int, stopPct: Int) {
        val (start, stop) = ChargeRule.normalize(startPct, stopPct)
        store.autoChargeEnabled = enabled
        store.chargeStartPct = start
        store.chargeStopPct = stop
        handler.post {
            lastChargeCheckAtMs = now()
            checkCharge()
            emit()
        }
    }

    /**
     * Administrator's "Charge now" / "Stop charging": switches the coin box relay
     * on until the battery is full, or off now. Stopping hands control back to
     * the automatic levels, which may switch it on again when the battery is low.
     */
    fun setManualCharge(on: Boolean) {
        if (on && (controllerKey == null || store.controllerAddress == null)) {
            throw ProtocolException("not_paired", "Pair the coin box first")
        }
        store.manualCharge = on
        if (!on) store.chargeRequested = false
        handler.post {
            lastChargeCheckAtMs = now()
            checkCharge()
            emit()
        }
    }

    /**
     * Opens Android's power menu (Power off / Restart) for the administrator. No
     * app may power the tablet off itself, so the menu does it. Lock task blocks
     * the menu; it is allowed for [POWER_MENU_MS] and then blocked again. False
     * when the popup guard (accessibility) is not running: the administrator
     * then holds the power button within that time instead.
     */
    fun showPowerMenu(): Boolean {
        policy.allowPowerMenu(true)
        handler.removeCallbacks(blockPowerMenu)
        handler.postDelayed(blockPowerMenu, POWER_MENU_MS)
        if (!PopupGuardService.isRunning()) return false
        // Give the system UI a moment to apply the new lock task features first.
        handler.postDelayed({ PopupGuardService.showPowerMenu() }, 300)
        return true
    }

    private val blockPowerMenu = Runnable { policy.allowPowerMenu(false) }

    /** Applies a newer cloud configuration version (allowed apps, loss timeout). */
    private fun applyCloudConfig(cfg: JSONObject) {
        val version = cfg.optInt("version", 0)
        if (version <= store.cloudConfigVersion) return
        cfg.optJSONArray("allowed_packages")?.let { arr ->
            store.allowedPackages = (0 until arr.length()).map { arr.getString(it) }
        }
        val loss = cfg.optInt("local_loss_timeout_s", store.lossTimeoutS)
        store.lossTimeoutS = loss
        tracker.lossTimeoutMs = store.lossTimeoutS * 1000L
        store.cloudConfigVersion = version
        Log.i(TAG, "Applied cloud config v$version")
        evaluate()
        emit()
    }

    // ================================================================ state for Flutter

    fun addListener(l: (Map<String, Any?>) -> Unit) {
        listeners += l
        handler.post { emit() }
    }

    fun removeListener(l: (Map<String, Any?>) -> Unit) {
        listeners -= l
    }

    /** Must run on the worker thread. */
    private fun emit() {
        lastEmitAtMs = now()
        val snapshot = snapshot()
        mainHandler.post { listeners.forEach { it(snapshot) } }
    }

    fun requestState(callback: (Map<String, Any?>) -> Unit) = handler.post {
        val s = snapshot()
        mainHandler.post { callback(s) }
    }

    private fun snapshot(): Map<String, Any?> {
        val t = now()
        val s = tracker.last
        val d = decision
        val lockout = store.loadLockout(t)
        return mapOf(
            "mode" to store.mode.wire,
            "deviceOwner" to isDeviceOwner(),
            "lockTask" to policy.lockTaskState(),
            "policyProblems" to policyProblems,
            "serviceRunning" to running,
            "access" to mapOf(
                "granted" to d.granted,
                "remainingMs" to ((d as? AccessDecision.Granted)?.remainingMs ?: 0L),
                "source" to (d as? AccessDecision.Granted)?.source,
                "reason" to (d as? AccessDecision.Denied)?.reason?.wire,
            ),
            "expiredAgoMs" to lastExpiryAtMs?.let { t - it },
            "expiredReason" to lastExpiryReason,
            "controller" to mapOf(
                "paired" to (controllerKey != null && store.controllerAddress != null),
                "address" to store.controllerAddress,
                "deviceId" to store.controllerDeviceId,
                "station" to store.controllerStation,
                "selectedStation" to s?.selectedStation,
                "selectedTtlS" to s?.selectedTtlS,
                "heldPulses" to s?.heldPulses,
                "link" to tracker.link(t).name.lowercase(),
                "lastOkAgoMs" to tracker.ageMs(t),
                "lastError" to tracker.lastError,
                "failures" to tracker.consecutiveFailures,
                "bootId" to s?.bootId,
                "seq" to s?.seq,
                "remainingS" to s?.remainingS,
                "estimatedRemainingMs" to tracker.estimatedRemainingMs(t),
                "secondsPerPulse" to (s?.secondsPerPulse ?: Rates.DEFAULT_SECONDS_PER_PULSE),
                "lastAddedS" to s?.lastAddedS,
                "lastPulses" to s?.lastPulses,
                "lastCreditAgoMs" to tracker.lastCreditDetectedAtMs?.let { t - it },
                "resumed" to s?.resumed,
                "controllerCloud" to s?.cloud,
            ),
            "cloud" to mapOf(
                "enrolled" to (store.cloudToken != null),
                "link" to cloudLink,
                "lastOkAgoMs" to cloudLastOkAtMs?.let { t - it },
                "lastError" to cloudLastError,
                "configVersion" to store.cloudConfigVersion,
                "deviceId" to store.cloudDeviceId,
            ),
            "settings" to mapOf(
                "allowedPackages" to store.allowedPackages,
                "lossTimeoutS" to store.lossTimeoutS,
                "lockAdb" to store.lockAdbInProduction,
                "isDefaultHome" to policy.isDefaultHome(),
                "idleSleepS" to store.idleSleepS,
                "screenOffS" to store.screenOffS,
                "blockAds" to store.blockAds,
                "sounds" to store.sounds,
                "brightnessPct" to policy.brightness().first,
                "brightnessAuto" to policy.brightness().second,
                "appStoreOpenS" to (if (appStoreOpen()) (appStoreUntilMs - now()) / 1000 else 0L),
                "keepWirelessAdb" to store.keepWirelessAdb,
                "tapAdmin" to store.tapAdminEnabled,
                "allowAccounts" to store.allowAccounts,
                "wirelessAdbOn" to policy.wirelessAdbOn(),
                "adBlockActive" to policy.adBlockActive(),
                "adBlockProblem" to adBlockProblem,
                "autoCharge" to store.autoChargeEnabled,
                "chargeStartPct" to store.chargeStartPct,
                "chargeStopPct" to store.chargeStopPct,
                "screenLockSecure" to isScreenLockSecure(),
            ),
            "charge" to mapOf(
                "batteryPct" to batteryPct(),
                "charging" to isCharging(),
                "requested" to store.chargeRequested,
                "manual" to store.manualCharge,
                "relayOn" to chargeRelayOn,
                "lastError" to chargeLastError,
            ),
            "admin" to mapOf(
                "hasPin" to (store.pinRecord != null),
                "unlocked" to isAdminUnlocked(),
                "openSeq" to adminOpenSeq,
                "lockoutMs" to lockout.remainingLockMs(t),
            ),
            "demoRemainingMs" to demo.remainingMs(t),
            "dashboardRemainingMs" to dashboard.remainingMs(t),
        )
    }

    // ================================================================ admin gate + PIN

    fun isAdminUnlocked(): Boolean = now() < adminUnlockedUntilMs

    /** Throws if no administrator is unlocked; extends the unlock window otherwise. */
    fun requireAdmin() {
        if (!isAdminUnlocked()) throw SecurityException("admin_locked")
        adminUnlockedUntilMs = now() + ADMIN_UNLOCK_MS
    }

    /**
     * The dashboard asked to open admin on this tablet: unlock without the PIN
     * (the dashboard login is the proof) for the normal unlock window, bring the
     * kiosk to the front and let Flutter open the admin screen.
     */
    private fun remoteAdminUnlock() {
        if (store.mode == KioskMode.UNCONFIGURED) return
        Log.i(TAG, "Admin unlocked from the dashboard")
        adminUnlockedUntilMs = now() + ADMIN_UNLOCK_MS
        adminOpenSeq++
        bringKioskToFront()
        emit()
    }

    /** The dashboard turned the 10-tap admin gesture on (until admin is locked). */
    private fun enableTapAdmin() {
        if (store.tapAdminEnabled) return
        Log.i(TAG, "10-tap admin turned on from the dashboard")
        store.tapAdminEnabled = true
        emit()
    }

    private fun appStoreOpen() = appStoreUntilMs != 0L && now() < appStoreUntilMs

    /**
     * Opens Google Play for the administrator to install apps. In production it
     * is let into the kiosk lock for [APP_STORE_WINDOW_MS] (or until admin is
     * locked); customers can never get it (RestrictedApps). New apps still need
     * to be approved on the Apps page.
     */
    fun openAppStore() {
        requireAdmin()
        if (!policy.isPackageInstalled(PLAY_STORE)) throw ProtocolException("play_store_missing", "Google Play is not installed")
        appStoreUntilMs = now() + APP_STORE_WINDOW_MS
        // Admin stays unlocked while away in Play, so returning lands on the admin screen.
        adminUnlockedUntilMs = maxOf(adminUnlockedUntilMs, appStoreUntilMs)
        handler.post {
            evaluate() // production: adds Play to the lock task allowlist first
            try {
                val launch = ctx.packageManager.getLaunchIntentForPackage(PLAY_STORE)
                    ?: Intent(Intent.ACTION_VIEW, android.net.Uri.parse("market://search?q=")).setPackage(PLAY_STORE)
                ctx.startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                Log.i(TAG, "Google Play opened for the administrator")
            } catch (e: Exception) {
                Log.w(TAG, "Could not open Google Play: $e")
            }
            emit()
        }
    }

    /** Tablet-wide screen brightness (percentage) or automatic brightness. Needs Device Owner. */
    fun setBrightness(percent: Int, auto: Boolean) {
        requireAdmin()
        if (percent !in 1..100) throw ProtocolException("bad_brightness", "Brightness must be 1-100%")
        if (!policy.setBrightness(percent, auto)) throw ProtocolException("not_device_owner", "Brightness needs Device Owner")
        handler.post { emit() }
    }

    /** Ends the Google Play window and returns to the kiosk. */
    fun closeAppStore() {
        if (appStoreUntilMs == 0L) return
        appStoreUntilMs = 0L
        handler.post {
            evaluate()
            if (store.mode == KioskMode.PRODUCTION) bringKioskToFront()
            emit()
        }
    }

    fun lockAdmin() {
        closeAppStore()
        adminUnlockedUntilMs = 0
        // Locking admin also turns the dashboard-enabled 10-tap gesture off again.
        store.tapAdminEnabled = false
        handler.post { emit() }
    }

    /** First-time PIN creation. Returns the one-time recovery code. */
    @Synchronized
    fun createPin(pin: String): String {
        if (store.pinRecord != null) throw SecurityException("pin_exists")
        return setPinInternal(pin)
    }

    @Synchronized
    fun changePin(pin: String): String {
        requireAdmin()
        return setPinInternal(pin)
    }

    private fun setPinInternal(pin: String): String {
        PinSecurity.validateNewPin(pin)?.let { throw IllegalArgumentException(it) }
        val recovery = PinSecurity.newRecoveryCode()
        val salt = PinSecurity.newSalt()
        val rsalt = PinSecurity.newSalt()
        store.pinRecord = KioskStore.PinRecord(
            salt, PinSecurity.hash(pin, salt), rsalt, PinSecurity.hash(PinSecurity.normaliseRecoveryCode(recovery), rsalt)
        )
        store.saveLockout(online.ebnleadgen.vendokiosk.core.PinLockout())
        adminUnlockedUntilMs = now() + ADMIN_UNLOCK_MS
        handler.post { emit() }
        return recovery
    }

    data class PinCheck(val ok: Boolean, val lockoutMs: Long, val failures: Int)

    @Synchronized
    fun verifyPin(pin: String): PinCheck = checkSecret { rec -> PinSecurity.verify(pin, rec.salt, rec.hash) }

    /** Recovery code path: on success the caller must set a new PIN immediately. */
    @Synchronized
    fun verifyRecoveryCode(code: String): PinCheck =
        checkSecret { rec -> PinSecurity.verify(PinSecurity.normaliseRecoveryCode(code), rec.recoverySalt, rec.recoveryHash) }

    private fun checkSecret(check: (KioskStore.PinRecord) -> Boolean): PinCheck {
        val t = now()
        val rec = store.pinRecord ?: throw SecurityException("no_pin")
        val lockout = store.loadLockout(t)
        val remaining = lockout.remainingLockMs(t)
        if (remaining > 0) return PinCheck(false, remaining, lockout.failures)
        return if (check(rec)) {
            lockout.onSuccess()
            store.saveLockout(lockout)
            adminUnlockedUntilMs = t + ADMIN_UNLOCK_MS
            handler.post { emit() }
            PinCheck(true, 0, 0)
        } else {
            lockout.onFailure(t)
            store.saveLockout(lockout)
            handler.post { emit() }
            PinCheck(false, lockout.remainingLockMs(t), lockout.failures)
        }
    }

    // ================================================================ admin actions

    /** Production requires verified Device Owner; never silently falls back to demo. */
    fun setMode(mode: KioskMode): Result<Unit> {
        if (mode == KioskMode.UNCONFIGURED) return Result.failure(IllegalArgumentException("bad_mode"))
        if (mode == KioskMode.PRODUCTION && !policy.isDeviceOwner()) {
            return Result.failure(IllegalStateException("not_device_owner"))
        }
        store.mode = mode
        handler.post {
            cachedOwner = null
            if (mode == KioskMode.PRODUCTION) {
                demo.clear()
                policyProblems = applyBaseline()
                appliedGrant = null
            } else {
                policyProblems = emptyList()
            }
            evaluate()
            emit()
        }
        return Result.success(Unit)
    }

    fun setAllowedPackages(packages: List<String>) {
        store.allowedPackages = RestrictedApps.filter(packages).filter { it.matches(Regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$")) && it != ctx.packageName }
        handler.post { evaluate(); emit() }
    }

    fun setLossTimeout(seconds: Int) {
        store.lossTimeoutS = seconds
        handler.post {
            tracker.lossTimeoutMs = store.lossTimeoutS * 1000L
            evaluate()
            emit()
        }
    }

    fun setIdleSleep(seconds: Int) {
        store.idleSleepS = seconds
        handler.post { emit() }
    }

    fun setScreenOff(seconds: Int) {
        store.screenOffS = seconds
        handler.post { emit() }
    }

    private fun isScreenLockSecure(): Boolean =
        ctx.getSystemService(android.app.KeyguardManager::class.java)?.isDeviceSecure == true

    /**
     * Turns the display on (even if it is fully off) and brings the kiosk to the
     * front. The activity is marked turnScreenOn/showWhenLocked, so it appears
     * without going through a non-secure lock screen.
     */
    @Suppress("DEPRECATION")
    private fun wakeScreen() {
        val pm = ctx.getSystemService(PowerManager::class.java)
        if (!pm.isInteractive) {
            pm.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP or PowerManager.ON_AFTER_RELEASE,
                "vendo:coin-wake"
            ).acquire(5_000)
        }
        bringKioskToFront()
    }

    /** Kiosk policies; brings debugging back if a restriction change stopped it. */
    private fun applyBaseline(): List<String> {
        val problems = policy.applyBaseline(store.lockAdbInProduction, store.allowAccounts)
        if (policy.restrictionsChanged && store.keepWirelessAdb && !store.lockAdbInProduction) {
            adbRestartExecutor.execute { policy.restartAdb() }
        }
        return problems
    }

    fun setLockAdb(lock: Boolean) {
        store.lockAdbInProduction = lock
        handler.post {
            if (store.mode == KioskMode.PRODUCTION) policyProblems = applyBaseline().also { appliedGrant = null }
            evaluate()
            emit()
        }
    }

    fun simulateCoin(pulses: Int): Result<Long> {
        val r = demo.addPulses(store.mode, pulses, tracker.last?.secondsPerPulse ?: Rates.DEFAULT_SECONDS_PER_PULSE, now())
        handler.post { evaluate(); emit() }
        return r
    }

    /** Blocking (call off the main thread). */
    /**
     * Reaches the coin box at [address] over the Wi-Fi: how long it took and
     * what it reported, or why it failed. Never throws.
     */
    fun testCoinBox(address: String?): Map<String, Any?> {
        val target = address?.takeIf { it.isNotBlank() } ?: store.controllerAddress
        val parsed = target?.let { LocalHttp.parseLocalAddress(it) }
        val ownIp = ownLocalIp()
        val base = mapOf(
            "address" to parsed?.let { "${it.first}:${it.second}" },
            "ownIp" to ownIp,
            "sameNetwork" to (parsed != null && ownIp != null && parsed.first.substringBeforeLast('.') == ownIp.substringBeforeLast('.')),
            "viaWifi" to (wifi.wifiNetwork() != null),
        )
        if (parsed == null) return base + mapOf("ok" to false, "error" to "bad_address")
        val started = System.nanoTime()
        return try {
            val r = pairingHttp.get("${parsed.first}:${parsed.second}", "/api/v1/info")
            val ms = (System.nanoTime() - started) / 1_000_000
            val info = ControllerDiscovery.parseInfo("${parsed.first}:${parsed.second}", r.body)
            if (r.status != 200 || info == null) {
                base + mapOf("ok" to false, "ms" to ms, "error" to "not_a_coin_box")
            } else {
                base + mapOf(
                    "ok" to true, "ms" to ms, "deviceId" to info.deviceId, "fwVersion" to info.fwVersion,
                    "stations" to info.stations, "paired" to info.paired, "pairingOpen" to info.pairingOpen,
                )
            }
        } catch (e: Exception) {
            base + mapOf("ok" to false, "ms" to (System.nanoTime() - started) / 1_000_000, "error" to networkError(e))
        }
    }

    /** Every coin box on this tablet's Wi-Fi (blocking, up to ~10 s). */
    fun findCoinBoxes(): List<Map<String, Any?>> {
        val ownIp = ownLocalIp() ?: throw ProtocolException("no_wifi", "The tablet is not on a Wi-Fi network")
        return ControllerDiscovery.scanAll(ownIp) { wifi.newLocalSocket() }.map {
            mapOf(
                "address" to it.address, "deviceId" to it.deviceId, "fwVersion" to it.fwVersion,
                "stations" to it.stations, "paired" to it.paired, "pairingOpen" to it.pairingOpen,
                "mine" to (it.deviceId == store.controllerDeviceId),
            )
        }
    }

    private fun networkError(e: Exception): String = when (e) {
        is SocketTimeoutException -> "timeout"
        is ConnectException -> "unreachable"
        is ProtocolException -> e.code
        else -> e.javaClass.simpleName
    }

    // Pairing and tests wait longer than the 1 s poll: a coin box that is busy with
    // its cloud connection can take a few seconds to answer.
    private val pairingHttp = LocalHttp(connectTimeoutMs = 4000, readTimeoutMs = 6000, newSocket = { wifi.newLocalSocket() })

    fun pairController(address: String, code: String, station: Int): Result<String> = try {
        if (!ControllerProtocol.isValidStation(station)) throw IllegalArgumentException("bad_station")
        val parsed = LocalHttp.parseLocalAddress(address) ?: throw IllegalArgumentException("bad_address")
        val normalized = "${parsed.first}:${parsed.second}"
        // Reach the box first (two tries): a wrong address or Wi-Fi then fails here
        // without using up one of the box's 5 code attempts.
        val info = (1..2).firstNotNullOfOrNull { attempt ->
            try {
                pairingHttp.get(normalized, "/api/v1/info").let { ControllerDiscovery.parseInfo(normalized, it.body) }
            } catch (e: Exception) {
                if (attempt == 2) throw e
                null
            }
        } ?: throw ProtocolException("not_a_coin_box", "No coin box answers at $normalized")
        if (station > info.stations) throw ProtocolException("bad_station", "This coin box serves ${info.stations} tablet(s)")
        if (info.pairingOpen == false) throw ProtocolException("pairing_closed", "Pairing is not open on the coin box")
        val r = pairingHttp.postForm(
            normalized, "/api/v1/pair",
            mapOf("code" to code.trim(), "phone_id" to store.phoneId, "station" to station.toString())
        )
        if (r.status != 200) {
            val err = try { JSONObject(r.body).optString("error", "http_${r.status}") } catch (e: Exception) { "http_${r.status}" }
            throw ProtocolException(err, "Pairing failed: $err")
        }
        val pair = ControllerProtocol.parsePairResponse(r.body, station)
        store.controllerAddress = normalized
        store.controllerStation = station
        store.controllerDeviceId = pair.deviceId
        store.controllerKey = pair.key
        controllerKey = pair.key
        handler.post { tracker.reset(); evaluate(); emit() }
        Result.success(pair.deviceId)
    } catch (e: Exception) {
        Result.failure(e)
    }

    /** Changes the controller's IP (e.g. new DHCP lease) without re-pairing. */
    fun setControllerAddress(address: String): Result<Unit> {
        val parsed = LocalHttp.parseLocalAddress(address) ?: return Result.failure(IllegalArgumentException("bad_address"))
        store.controllerAddress = "${parsed.first}:${parsed.second}"
        handler.post { emit() }
        return Result.success(Unit)
    }

    private fun sendCommand(name: String): Result<Unit> = sendCommandForBody(name).map { }

    /** Signed tablet command; returns the response body on HTTP 200. */
    private fun sendCommandForBody(name: String): Result<String> = try {
        val address = store.controllerAddress ?: throw IllegalStateException("not_paired")
        val key = controllerKey ?: throw IllegalStateException("not_paired")
        val boot = tracker.last?.bootId ?: throw IllegalStateException("controller_not_connected")
        val ctr = store.nextCommandCounter()
        val station = store.controllerStation
        val r = http.postForm(
            address, "/api/v1/${commandPath(name)}",
            mapOf(
                "station" to station.toString(), "boot_id" to boot, "ctr" to ctr.toString(),
                "mac" to ControllerProtocol.commandMac(key, name, station, boot, ctr),
            )
        )
        if (r.status == 409 && r.body.contains("\"busy\"")) {
            val other = Regex("\"selected_station\":(\\d+)").find(r.body)?.groupValues?.get(1) ?: "0"
            val ttl = Regex("\"ttl_s\":(\\d+)").find(r.body)?.groupValues?.get(1) ?: "0"
            throw ProtocolException("busy:$other:$ttl", "The coin box is in use by tablet $other")
        }
        if (r.status == 404) throw ProtocolException("coin_box_outdated", "Coin box firmware does not support this")
        if (r.status != 200) throw ProtocolException("http_${r.status}", r.body.take(100))
        Result.success(r.body)
    } catch (e: Exception) {
        Result.failure(e)
    }

    private fun commandPath(name: String) = when (name) {
        "end_session" -> "session/end"
        "charge_on" -> "charge/on"
        "charge_off" -> "charge/off"
        else -> name
    }

    /**
     * Blocking. A player tapped "Insert coin": ask the coin box to send its next
     * coins to this tablet. Returns how long the claim lasts (seconds); fails
     * with "busy:<tablet>:<seconds>" while another tablet is inserting coins.
     */
    fun claimCoinBox(): Result<Int> = sendCommandForBody("select").map { body ->
        Regex("\"ttl_s\":(\\d+)").find(body)?.groupValues?.get(1)?.toIntOrNull() ?: 0
    }.also { if (it.isSuccess) handler.post { lastPollAtMs = now(); schedulePoll() } }

    /** Blocking. Ends the current session: dashboard time here, paid time on the controller (admin action). */
    fun endSession(): Result<Unit> {
        handler.post {
            dashboard.clear()
            store.dashboardCreditMs = 0
            demo.clear()
            evaluate()
            emit()
        }
        return if (controllerKey != null && store.controllerAddress != null) sendCommand("end_session") else Result.success(Unit)
    }

    /** Blocking. Best-effort unpair on the controller, then forget the key locally. */
    fun unpairController(): Result<Unit> {
        val remote = sendCommand("unpair")
        store.controllerKey = null
        store.controllerDeviceId = null
        controllerKey = null
        handler.post { tracker.reset(); evaluate(); emit() }
        return if (remote.isSuccess) remote else Result.success(Unit)
    }

    /** Blocking. */
    fun enrollCloud(code: String): Result<String> = try {
        val (deviceId, token) = cloud.enrollPhone(code.trim(), "Kiosk phone ${Build.MODEL}", store.phoneId.take(32))
        store.cloudToken = token
        store.cloudDeviceId = deviceId
        store.cloudConfigVersion = 0 // take the dashboard configuration on first heartbeat
        cloudLink = "ok"
        lastCloudAtMs = -CLOUD_INTERVAL_MS
        handler.post { emit() }
        Result.success(deviceId)
    } catch (e: Exception) {
        Result.failure(e)
    }

    fun unenrollCloud() {
        store.cloudToken = null
        store.cloudDeviceId = null
        cloudLink = "disabled"
        handler.post { emit() }
    }

    /** Admin exit: release policies so the phone can be used normally. */
    fun releaseKiosk(): List<String> {
        val problems = policy.releaseKiosk()
        store.mode = KioskMode.DEMO
        handler.post {
            adBlockProblem = null
            lastAdBlockAtMs = -AD_BLOCK_REFRESH_MS // re-applied when production is turned on again
            appliedGrant = null
            policyProblems = emptyList()
            releaseWakeLock()
            evaluate()
            emit()
        }
        return problems
    }

    /** See AdbRecoveryReceiver. */
    fun adbRecoveryReset() {
        policy.releaseKiosk()
        store.pinRecord = null
        store.saveLockout(online.ebnleadgen.vendokiosk.core.PinLockout())
        store.mode = KioskMode.UNCONFIGURED
        adminUnlockedUntilMs = 0
        handler.post {
            appliedGrant = null
            policyProblems = emptyList()
            releaseWakeLock()
            evaluate()
            emit()
        }
    }

    fun clearDeviceOwner(): Boolean {
        val ok = policy.clearDeviceOwner()
        if (ok) store.mode = KioskMode.DEMO
        handler.post { cachedOwner = null; evaluate(); emit() }
        return ok
    }

    /** Whether a customer app may be launched right now. */
    fun canLaunch(packageName: String): Boolean =
        decision.granted && packageName in store.allowedPackages && !RestrictedApps.isRestricted(packageName)

    fun diagnostics(): Map<String, Any?> = policy.diagnostics() + mapOf(
        "appVersion" to BuildConfig.VERSION_NAME,
        "applicationId" to BuildConfig.APPLICATION_ID,
        "cloudApiBase" to BuildConfig.CLOUD_API_BASE,
        "phoneBootId" to phoneBootId,
        "policyProblems" to policyProblems,
        "serviceTickAgoMs" to (now() - lastTickAtMs),
    )
}
