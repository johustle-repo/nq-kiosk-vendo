package online.ebnleadgen.vendokiosk.core

/** Sounds the kiosk plays for the customer. */
enum class SoundCue { COIN, FIVE_MINUTES, ONE_MINUTE, TIME_UP }

/**
 * Picks the cue for a change of the customer's remaining time between two
 * engine ticks (0 = no access). Pure, so it can be unit-tested.
 */
object SoundCues {
    /** Smaller increases are clock corrections from the coin box, not coins. */
    const val COIN_MIN_INCREASE_MS = 30_000L
    const val FIVE_MINUTES_MS = 5 * 60_000L
    const val ONE_MINUTE_MS = 60_000L

    fun cueFor(prevMs: Long, nextMs: Long): SoundCue? = when {
        nextMs - prevMs >= COIN_MIN_INCREASE_MS -> SoundCue.COIN
        prevMs > 0 && nextMs <= 0 -> SoundCue.TIME_UP
        prevMs > ONE_MINUTE_MS && nextMs in 1..ONE_MINUTE_MS -> SoundCue.ONE_MINUTE
        prevMs > FIVE_MINUTES_MS && nextMs in (ONE_MINUTE_MS + 1)..FIVE_MINUTES_MS -> SoundCue.FIVE_MINUTES
        else -> null
    }
}
