package online.ebnleadgen.vendokiosk.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SoundCuesTest {
    private val min = 60_000L

    @Test
    fun coinWhenTimeIsAdded() {
        assertEquals(SoundCue.COIN, SoundCues.cueFor(0, 4 * min))
        assertEquals(SoundCue.COIN, SoundCues.cueFor(10 * min, 30 * min))
    }

    @Test
    fun noCoinForSmallClockCorrections() {
        assertNull(SoundCues.cueFor(10 * min, 10 * min + 5_000))
        assertNull(SoundCues.cueFor(10 * min, 10 * min - 500))
    }

    @Test
    fun warnsOnceWhenCrossingFiveAndOneMinute() {
        assertEquals(SoundCue.FIVE_MINUTES, SoundCues.cueFor(5 * min + 400, 5 * min - 100))
        assertNull(SoundCues.cueFor(5 * min - 100, 5 * min - 600))
        assertEquals(SoundCue.ONE_MINUTE, SoundCues.cueFor(min + 300, min - 200))
        assertNull(SoundCues.cueFor(min - 200, min - 700))
    }

    @Test
    fun timeUpWhenAccessEnds() {
        assertEquals(SoundCue.TIME_UP, SoundCues.cueFor(400, 0))
        assertNull(SoundCues.cueFor(0, 0))
    }

    @Test
    fun aBigDropSkipsStraightToTheLowestWarning() {
        // e.g. the coin box corrected a long gap: one cue, the most urgent.
        assertEquals(SoundCue.ONE_MINUTE, SoundCues.cueFor(20 * min, 30_000))
    }
}
