package online.ebnleadgen.vendokiosk.core

/**
 * When the tablet asks the coin box to switch on the charger relay (D6).
 * Starts below [startPct] (after [LOW_READINGS_TO_START] low readings in a row,
 * so one bad battery reading cannot switch it on), stops at [stopPct]. In
 * between it keeps charging only while the tablet is actually charging, so a
 * relay that is not wired (or a charger that is unplugged) is released.
 */
object ChargeRule {
    const val DEFAULT_START_PCT = 20
    const val DEFAULT_STOP_PCT = 90
    const val LOW_READINGS_TO_START = 2
    val START_RANGE = 5..50
    val STOP_RANGE = 30..100

    fun wantsCharge(
        enabled: Boolean,
        batteryPct: Int,
        startPct: Int,
        stopPct: Int,
        previous: Boolean,
        charging: Boolean,
        lowReadings: Int,
    ): Boolean = when {
        !enabled -> false
        batteryPct !in 0..100 -> previous // level unknown: keep what the coin box has
        batteryPct >= stopPct -> false
        batteryPct < startPct -> previous || lowReadings >= LOW_READINGS_TO_START
        else -> previous && charging
    }

    /** Valid (start, stop) pair: stop at least 10 points above start. */
    fun normalize(startPct: Int, stopPct: Int): Pair<Int, Int> {
        val start = startPct.coerceIn(START_RANGE)
        return start to stopPct.coerceIn(maxOf(STOP_RANGE.first, start + 10), STOP_RANGE.last)
    }
}
