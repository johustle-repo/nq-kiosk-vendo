package online.ebnleadgen.vendokiosk.core

enum class KioskMode(val wire: String) {
    UNCONFIGURED("unconfigured"), DEMO("demo"), PRODUCTION("production");

    companion object {
        fun fromWire(s: String?): KioskMode = entries.firstOrNull { it.wire == s } ?: UNCONFIGURED
    }
}

enum class DenyReason(val wire: String) {
    UNCONFIGURED("unconfigured"),
    NOT_DEVICE_OWNER("not_device_owner"),
    NOT_PAIRED("controller_not_paired"),
    CONTROLLER_LOST("controller_lost"),
    NO_TIME("no_time"),
}

sealed class AccessDecision {
    data class Granted(val remainingMs: Long, val source: String) : AccessDecision()
    data class Denied(val reason: DenyReason) : AccessDecision()

    val granted get() = this is Granted
}

data class AccessInputs(
    val mode: KioskMode,
    val isDeviceOwner: Boolean,
    val controllerPaired: Boolean,
    val link: LinkState,
    val controllerRemainingMs: Long,
    val demoRemainingMs: Long,
    val dashboardRemainingMs: Long = 0,
)

/**
 * Single place that decides whether customer apps may be used.
 *
 * Production: verified controller time, plus free time given from the
 * dashboard (authenticated heartbeat). No Device Owner denies everything; with
 * no dashboard time, no paired controller or a coin box never heard from deny
 * access. A paid session survives the coin box dropping off the network: the
 * tablet keeps counting down the last verified report (it never adds time) and
 * the next report replaces the estimate. Simulated credit is ignored and there
 * is no fallback to demo behaviour.
 *
 * Demo: simulated credit plus dashboard and (if paired) controller time;
 * nothing is enforced.
 */
object AccessPolicy {
    fun decide(i: AccessInputs): AccessDecision = when (i.mode) {
        KioskMode.UNCONFIGURED -> AccessDecision.Denied(DenyReason.UNCONFIGURED)
        KioskMode.PRODUCTION -> {
            val ctl = controllerMs(i)
            val dash = i.dashboardRemainingMs
            when {
                !i.isDeviceOwner -> AccessDecision.Denied(DenyReason.NOT_DEVICE_OWNER)
                ctl > 0 -> AccessDecision.Granted(ctl + dash, "controller")
                dash > 0 -> AccessDecision.Granted(dash, "dashboard")
                !i.controllerPaired -> AccessDecision.Denied(DenyReason.NOT_PAIRED)
                i.link == LinkState.NEVER || i.link == LinkState.LOST -> AccessDecision.Denied(DenyReason.CONTROLLER_LOST)
                else -> AccessDecision.Denied(DenyReason.NO_TIME)
            }
        }
        KioskMode.DEMO -> {
            val ctl = controllerMs(i)
            val total = ctl + i.dashboardRemainingMs + i.demoRemainingMs
            val source = when {
                ctl > 0 -> "controller"
                i.dashboardRemainingMs > 0 -> "dashboard"
                else -> "simulated"
            }
            if (total > 0) AccessDecision.Granted(total, source) else AccessDecision.Denied(DenyReason.NO_TIME)
        }
    }

    /**
     * Controller time that counts: paired and verified at least once. A lost
     * link keeps counting down so a Wi-Fi or internet drop does not interrupt play.
     */
    fun controllerMs(i: AccessInputs): Long =
        if (i.controllerPaired && i.link != LinkState.NEVER) i.controllerRemainingMs.coerceAtLeast(0) else 0
}

/**
 * Demo-only simulated coin credits (monotonic clock). Refuses to operate in
 * production mode so simulated time can never unlock a production kiosk.
 */
class DemoClock {
    private var endMs: Long = 0

    fun addPulses(mode: KioskMode, pulses: Int, secondsPerPulse: Int, nowMs: Long): Result<Long> {
        if (mode != KioskMode.DEMO) return Result.failure(IllegalStateException("simulated_credit_rejected"))
        if (pulses !in 1..100) return Result.failure(IllegalArgumentException("bad_pulses"))
        val base = maxOf(endMs, nowMs)
        endMs = base + Rates.secondsFor(pulses, secondsPerPulse) * 1000
        return Result.success(remainingMs(nowMs))
    }

    fun remainingMs(nowMs: Long): Long = (endMs - nowMs).coerceAtLeast(0)

    fun clear() {
        endMs = 0
    }
}
