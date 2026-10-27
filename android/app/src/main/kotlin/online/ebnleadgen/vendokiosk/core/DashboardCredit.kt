package online.ebnleadgen.vendokiosk.core

/**
 * Free time given from the dashboard (heartbeat command, audited there), kept
 * on the tablet (monotonic clock). It only counts down while it is in use:
 * while the coin box has paid time for this tablet, that time runs on the box
 * and this credit waits, so both add up instead of draining together.
 */
class DashboardCredit(initialMs: Long = 0) {
    private var leftMs = initialMs.coerceIn(0, MAX_MS)
    private var runningSinceMs: Long? = null

    fun remainingMs(nowMs: Long): Long = runningSinceMs?.let { (leftMs - (nowMs - it)).coerceAtLeast(0) } ?: leftMs

    val running get() = runningSinceMs != null

    fun setRunning(run: Boolean, nowMs: Long) {
        if (run == running) return
        leftMs = remainingMs(nowMs)
        runningSinceMs = if (run) nowMs else null
    }

    fun add(seconds: Int, nowMs: Long) {
        require(seconds in 1..MAX_ADD_S) { "bad_seconds" }
        leftMs = (remainingMs(nowMs) + seconds * 1000L).coerceAtMost(MAX_MS)
        if (running) runningSinceMs = nowMs
    }

    fun clear() {
        leftMs = 0
        runningSinceMs = null
    }

    companion object {
        const val MAX_ADD_S = 24 * 3600
        const val MAX_MS = 7 * 24 * 3600 * 1000L
    }
}
