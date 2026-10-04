package online.ebnleadgen.vendokiosk.core

/** Coin rate arithmetic. The ESP8266 applies the same rule authoritatively. */
object Rates {
    const val DEFAULT_SECONDS_PER_PULSE = 240

    fun secondsFor(pulses: Int, secondsPerPulse: Int = DEFAULT_SECONDS_PER_PULSE): Long {
        require(pulses >= 0) { "pulses must be >= 0" }
        require(secondsPerPulse > 0) { "secondsPerPulse must be > 0" }
        return pulses.toLong() * secondsPerPulse
    }

    fun formatHms(totalSeconds: Long): String {
        val s = totalSeconds.coerceAtLeast(0)
        return "%02d:%02d:%02d".format(s / 3600, (s % 3600) / 60, s % 60)
    }
}
