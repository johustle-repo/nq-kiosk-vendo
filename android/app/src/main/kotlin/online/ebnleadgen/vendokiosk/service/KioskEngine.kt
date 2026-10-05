package online.ebnleadgen.vendokiosk.service

import android.content.Context
import android.content.Intent
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
import online.ebnleadgen.vendokiosk.core.ControllerProtocol
import online.ebnleadgen.vendokiosk.core.ControllerProtocol.toHex
import online.ebnleadgen.vendokiosk.core.ControllerStatus
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
import online.ebnleadgen.vendokiosk.kiosk.WatchdogReceiver
import org.json.JSONArray
import org.json.JSONObject
import java.net.ConnectException
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
        private const val ADMIN_UNLOCK_MS = 5 * 60_000L
        private const val RELOCK_INTERVAL_MS = 3_000L

        @Volatile private var instance: KioskEngine? = null

        fun get(context: Context): KioskEngine =
            instance ?: synchronized(this) { instance ?: KioskEngine(context.applicationContext).also { instance = it } }
    }

    private val ctx = context.applicationContext
    val store = KioskStore(ctx)
    val policy = KioskPolicy(ctx)
    private val tracker = SessionTracker(store.lossTimeoutS * 1000L)
    private val demo = DemoClock()
    private val http = LocalHttp()
    private val cloud = CloudClient(BuildConfig.CLOUD_API_BASE)
    private val random = SecureRandom()
    private val phoneBootId = ByteArray(4).also { random.nextBytes(it) }.toHex()

    private val worker = HandlerThread("vendo-kiosk").apply { start() }
    private val handler = Handler(worker.looper)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pollExecutor = Executors.newSingleThreadExecutor()
    private val cloudExecutor = Executors.newSingleThreadExecutor()
    private val pollInFlight = AtomicBoolean(false)
    private val cloudInFlight = AtomicBoolean(false)

    private val listeners = CopyOnWriteArrayList<(Map<String, Any?>) -> Unit>()

    // ---- state owned by the worker thread
    private var running = false
    @Volatile private var decision: AccessDecision = AccessDecision.Denied(DenyReason.UNCONFIGURED)
    private var appliedGrant: Boolean? = null
    private var appliedPackages: List<String> = emptyList()
    private var lastExpiryAtMs: Long? = null
    private var lastExpiryReason: String? = null
    private var lastPollAtMs = 0L
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

    private fun now() = SystemClock.elapsedRealtime()

    // ================================================================ lifecycle

    fun start() = handler.post {
        if (running) return@post
        running = true
        // Fail-safe default: until a verified report arrives, customers get nothing.
        if (store.mode == KioskMode.PRODUCTION) {
            policyProblems = policy.applyBaseline(store.lockAdbInProduction)
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
        val inputs = AccessInputs(
            mode = mode,
            isDeviceOwner = isDeviceOwner(),
            controllerPaired = controllerKey != null && store.controllerAddress != null,
            link = tracker.link(t),
            controllerRemainingMs = tracker.estimatedRemainingMs(t),
            demoRemainingMs = demo.remainingMs(t),
        )
        val prev = decision
        val next = AccessPolicy.decide(inputs)
        decision = next
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

    /** Applies the decision to Device Owner policy only when it changes. */
    private fun enforce(granted: Boolean) {
        val packages = if (granted) store.allowedPackages else emptyList()
        if (appliedGrant == granted && appliedPackages == packages) return
        val ok = policy.setPaidAccess(if (granted) packages else null)
        appliedGrant = if (ok) granted else null
        appliedPackages = packages
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
        if (!pollInFlight.compareAndSet(false, true)) return
        pollExecutor.execute {
            val result = try {
                val nonce = ByteArray(16).also { random.nextBytes(it) }.toHex()
                val r = http.get(address, "/api/v1/status?nonce=$nonce")
                if (r.status != 200) throw ProtocolException("http_${r.status}", "Controller returned ${r.status}")
                Result.success(ControllerProtocol.verifyStatus(r.body, r.headers["x-vk-signature"], nonce, key, expectedId))
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
            }
        )
        evaluate()
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

    private fun heartbeatPayload(): JSONObject {
        val t = now()
        val s = tracker.last
        return JSONObject()
            .put("boot_id", phoneBootId)
            .put("uptime_ms", t)
            .put("app_version", BuildConfig.VERSION_NAME)
            .put("mode", store.mode.wire)
            .put("device_owner", isDeviceOwner())
            .put("lock_task", policy.lockTaskState())
            .put("access", decision.let { if (it is AccessDecision.Denied) it.reason.wire else "granted" })
            .put(
                "controller", JSONObject()
                    .put("paired", controllerKey != null)
                    .put("link", tracker.link(t).name.lowercase())
                    .put("last_ok_age_s", tracker.ageMs(t)?.div(1000) ?: -1)
                    .put("remaining_s", s?.let { tracker.estimatedRemainingMs(t) / 1000 } ?: 0)
            )
            .put("allowed_packages", JSONArray(store.allowedPackages))
            .put("config_version_applied", store.cloudConfigVersion)
            .put("model", "${Build.MANUFACTURER} ${Build.MODEL}")
            .put("android_sdk", Build.VERSION.SDK_INT)
    }

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
                "screenLockSecure" to isScreenLockSecure(),
            ),
            "admin" to mapOf(
                "hasPin" to (store.pinRecord != null),
                "unlocked" to isAdminUnlocked(),
                "lockoutMs" to lockout.remainingLockMs(t),
            ),
            "demoRemainingMs" to demo.remainingMs(t),
        )
    }

    // ================================================================ admin gate + PIN

    fun isAdminUnlocked(): Boolean = now() < adminUnlockedUntilMs

    /** Throws if no administrator is unlocked; extends the unlock window otherwise. */
    fun requireAdmin() {
        if (!isAdminUnlocked()) throw SecurityException("admin_locked")
        adminUnlockedUntilMs = now() + ADMIN_UNLOCK_MS
    }

    fun lockAdmin() {
        adminUnlockedUntilMs = 0
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
                policyProblems = policy.applyBaseline(store.lockAdbInProduction)
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
        store.allowedPackages = packages.filter { it.matches(Regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$")) && it != ctx.packageName }
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

    fun setLockAdb(lock: Boolean) {
        store.lockAdbInProduction = lock
        handler.post {
            if (store.mode == KioskMode.PRODUCTION) policyProblems = policy.applyBaseline(lock).also { appliedGrant = null }
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
    fun pairController(address: String, code: String): Result<String> = try {
        val parsed = LocalHttp.parseLocalAddress(address) ?: throw IllegalArgumentException("bad_address")
        val normalized = "${parsed.first}:${parsed.second}"
        val r = http.postForm(normalized, "/api/v1/pair", mapOf("code" to code.trim(), "phone_id" to store.phoneId))
        if (r.status != 200) {
            val err = try { JSONObject(r.body).optString("error", "http_${r.status}") } catch (e: Exception) { "http_${r.status}" }
            throw ProtocolException(err, "Pairing failed: $err")
        }
        val pair = ControllerProtocol.parsePairResponse(r.body)
        store.controllerAddress = normalized
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

    private fun sendCommand(name: String): Result<Unit> = try {
        val address = store.controllerAddress ?: throw IllegalStateException("not_paired")
        val key = controllerKey ?: throw IllegalStateException("not_paired")
        val boot = tracker.last?.bootId ?: throw IllegalStateException("controller_not_connected")
        val ctr = store.nextCommandCounter()
        val r = http.postForm(
            address, "/api/v1/${if (name == "end_session") "session/end" else name}",
            mapOf("boot_id" to boot, "ctr" to ctr.toString(), "mac" to ControllerProtocol.commandMac(key, name, boot, ctr))
        )
        if (r.status != 200) throw ProtocolException("http_${r.status}", r.body.take(100))
        Result.success(Unit)
    } catch (e: Exception) {
        Result.failure(e)
    }

    /** Blocking. Ends the current paid session on the controller (admin action). */
    fun endSession(): Result<Unit> = sendCommand("end_session").also { handler.post { demo.clear(); evaluate(); emit() } }

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
        decision.granted && packageName in store.allowedPackages

    fun diagnostics(): Map<String, Any?> = policy.diagnostics() + mapOf(
        "appVersion" to BuildConfig.VERSION_NAME,
        "applicationId" to BuildConfig.APPLICATION_ID,
        "cloudApiBase" to BuildConfig.CLOUD_API_BASE,
        "phoneBootId" to phoneBootId,
        "policyProblems" to policyProblems,
        "serviceTickAgoMs" to (now() - lastTickAtMs),
    )
}
