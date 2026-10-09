package online.ebnleadgen.vendokiosk.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ChargeRuleTest {
    private fun wants(
        pct: Int,
        previous: Boolean,
        charging: Boolean = previous,
        lowReadings: Int = 2,
        enabled: Boolean = true,
    ) = ChargeRule.wantsCharge(enabled, pct, 20, 90, previous, charging, lowReadings)

    @Test
    fun startsBelowTheStartLevelAfterTwoReadings() {
        assertFalse(wants(19, previous = false, lowReadings = 1))
        assertTrue(wants(19, previous = false, lowReadings = 2))
        assertFalse(wants(20, previous = false))
    }

    @Test
    fun oneBadReadingDoesNotStartCharging() {
        assertFalse(wants(0, previous = false, lowReadings = 1))
    }

    @Test
    fun keepsChargingUntilTheStopLevelWhileCharging() {
        assertTrue(wants(20, previous = true, charging = true))
        assertTrue(wants(89, previous = true, charging = true))
        assertFalse(wants(90, previous = true, charging = true))
    }

    @Test
    fun releasesTheRelayWhenTheTabletIsNotCharging() {
        // Relay on but no power reaches the tablet (not wired / charger unplugged).
        assertFalse(wants(40, previous = true, charging = false))
        // Still low: keep asking.
        assertTrue(wants(15, previous = true, charging = false))
    }

    @Test
    fun offWhenDisabled() {
        assertFalse(wants(5, previous = true, enabled = false))
    }

    @Test
    fun unknownLevelKeepsTheLastDecision() {
        assertTrue(wants(-1, previous = true))
        assertFalse(wants(-1, previous = false))
    }

    @Test
    fun normalizeKeepsStopAboveStart() {
        assertEquals(20 to 90, ChargeRule.normalize(20, 90))
        assertEquals(50 to 60, ChargeRule.normalize(80, 40))
        assertEquals(5 to 30, ChargeRule.normalize(0, 0))
        assertEquals(20 to 100, ChargeRule.normalize(20, 150))
    }
}
