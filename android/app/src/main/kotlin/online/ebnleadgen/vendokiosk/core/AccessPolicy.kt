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
)

/**
 * Single place that decides whether customer apps may be used.
 *
 * Production: only fresh, verified controller time counts. No Device Owner,
 * no paired controller, or a lost local link (older than the configured
 * timeout) all deny access. Simulated credit is ignored and there is no
 * fallback to demo behaviour.
 *
 * Demo: simulated credit plus (if paired) controller time; nothing is enforced.
 */
object AccessPolicy {
    fun decide(i: AccessInputs): AccessDecision = when (i.mode) {
        KioskMode.UNCONFIGURED -> AccessDecision.Denied(DenyReason.UNCONFIGURED)
        KioskMode.PRODUCTION -> when {
            !i.isDeviceOwner -> AccessDecision.Denied(DenyReason.NOT_DEVICE_OWNER)
            !i.controllerPaired -> AccessDecision.Denied(DenyReason.NOT_PAIRED)
            i.link == LinkState.NEVER || i.link == LinkState.LOST -> AccessDecision.Denied(DenyReason.CONTROLLER_LOST)
            i.controllerRemainingMs <= 0 -> AccessDecision.Denied(DenyReason.NO_TIME)
            else -> AccessDecision.Granted(i.controllerRemainingMs, "controller")
        }
        KioskMode.DEMO -> {
            val ctl = if (i.controllerPaired && i.link != LinkState.LOST && i.link != LinkState.NEVER) i.controllerRemainingMs else 0
            val total = ctl + i.demoRemainingMs
            if (total > 0) AccessDecision.Granted(total, if (ctl > 0) "controller" else "simulated")
            else AccessDecision.Denied(DenyReason.NO_TIME)
        }
    }
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
