package online.ebnleadgen.vendokiosk.core

enum class LinkState { NEVER, CONNECTED, DEGRADED, LOST }

/** What happened when a verified status was offered to the tracker. */
enum class StatusUpdate { FIRST, UPDATED, CREDIT_ADDED, BOOT_CHANGED, STALE_IGNORED }

/**
 * Mirrors the coin controller's authoritative remaining time.
 *
 * Time base: a monotonic clock in milliseconds (SystemClock.elapsedRealtime on
 * Android) supplied by the caller. Wall-clock changes therefore have no effect.
 *
 * The phone never adds time itself. Between polls it only counts DOWN from the
 * last verified report, so repeated polls, retries and reconnects cannot
 * duplicate credit. A report is applied only if it is newer than the previous
 * one from the same controller boot (higher uptime). A new boot id means the
 * controller restarted: its fresh report replaces the old baseline outright.
 */
class SessionTracker(
    lossTimeoutMs: Long,
    private val degradedAfterMs: Long = 4_000,
) {
    var lossTimeoutMs: Long = lossTimeoutMs
        set(value) {
            require(value > 0)
            field = value
        }

    var last: ControllerStatus? = null
        private set
    private var verifiedAtMs: Long = 0
    var lastCreditDetectedAtMs: Long? = null
        private set
    var consecutiveFailures: Int = 0
        private set
    var lastError: String? = null
        private set

    fun onVerifiedStatus(status: ControllerStatus, nowMs: Long): StatusUpdate {
        val prev = last
        val result = when {
            prev == null -> StatusUpdate.FIRST
            prev.deviceId != status.deviceId || prev.bootId != status.bootId -> StatusUpdate.BOOT_CHANGED
            status.uptimeMs <= prev.uptimeMs -> return StatusUpdate.STALE_IGNORED.also {
                // Out-of-order / duplicated report: does not refresh the link either.
            }
            status.seq > prev.seq -> StatusUpdate.CREDIT_ADDED
            else -> StatusUpdate.UPDATED
        }
        if (result == StatusUpdate.CREDIT_ADDED) lastCreditDetectedAtMs = nowMs
        last = status
        verifiedAtMs = nowMs
        consecutiveFailures = 0
        lastError = null
        return result
    }

    fun onPollFailed(error: String) {
        consecutiveFailures++
        lastError = error
    }

    /** Forget everything (unpaired or controller replaced). */
    fun reset() {
        last = null
        verifiedAtMs = 0
        consecutiveFailures = 0
        lastError = null
        lastCreditDetectedAtMs = null
    }

    fun ageMs(nowMs: Long): Long? = if (last == null) null else (nowMs - verifiedAtMs).coerceAtLeast(0)

    fun link(nowMs: Long): LinkState {
        val age = ageMs(nowMs) ?: return LinkState.NEVER
        return when {
            age > lossTimeoutMs -> LinkState.LOST
            age > degradedAfterMs -> LinkState.DEGRADED
            else -> LinkState.CONNECTED
        }
    }

    /** Remaining time estimated from the last verified report (never increases between reports). */
    fun estimatedRemainingMs(nowMs: Long): Long {
        val s = last ?: return 0
        val age = ageMs(nowMs) ?: return 0
        return (s.remainingS * 1000 - age).coerceAtLeast(0)
    }
}
