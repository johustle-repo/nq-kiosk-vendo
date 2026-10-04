package online.ebnleadgen.vendokiosk.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AccessPolicyTest {
    private fun inputs(
        mode: KioskMode = KioskMode.PRODUCTION,
        owner: Boolean = true,
        paired: Boolean = true,
        link: LinkState = LinkState.CONNECTED,
        ctl: Long = 60_000,
        demo: Long = 0,
    ) = AccessInputs(mode, owner, paired, link, ctl, demo)

    private fun reason(d: AccessDecision) = (d as AccessDecision.Denied).reason

    @Test
    fun `production grants verified controller time`() {
        val d = AccessPolicy.decide(inputs())
        assertTrue(d is AccessDecision.Granted)
        assertEquals("controller", (d as AccessDecision.Granted).source)
    }

    @Test
    fun `production without Device Owner is denied and never falls back to demo`() {
        val d = AccessPolicy.decide(inputs(owner = false, demo = 600_000))
        assertEquals(DenyReason.NOT_DEVICE_OWNER, reason(d))
    }

    @Test
    fun `production ignores simulated credit`() {
        val d = AccessPolicy.decide(inputs(ctl = 0, demo = 600_000))
        assertEquals(DenyReason.NO_TIME, reason(d))
    }

    @Test
    fun `production denies when controller is not paired`() {
        assertEquals(DenyReason.NOT_PAIRED, reason(AccessPolicy.decide(inputs(paired = false))))
    }

    @Test
    fun `local controller loss denies access even with time remaining`() {
        assertEquals(DenyReason.CONTROLLER_LOST, reason(AccessPolicy.decide(inputs(link = LinkState.LOST, ctl = 3_600_000))))
        assertEquals(DenyReason.CONTROLLER_LOST, reason(AccessPolicy.decide(inputs(link = LinkState.NEVER))))
    }

    @Test
    fun `degraded link inside the loss timeout keeps access (cloud outage is irrelevant)`() {
        // Cloud state is not an input at all: an internet outage cannot affect access.
        assertTrue(AccessPolicy.decide(inputs(link = LinkState.DEGRADED)).granted)
    }

    @Test
    fun `expired time denies`() {
        assertEquals(DenyReason.NO_TIME, reason(AccessPolicy.decide(inputs(ctl = 0))))
    }

    @Test
    fun `unconfigured denies`() {
        assertEquals(DenyReason.UNCONFIGURED, reason(AccessPolicy.decide(inputs(mode = KioskMode.UNCONFIGURED))))
    }

    @Test
    fun `demo grants simulated time without Device Owner`() {
        val d = AccessPolicy.decide(inputs(mode = KioskMode.DEMO, owner = false, paired = false, link = LinkState.NEVER, ctl = 0, demo = 1_000))
        assertTrue(d.granted)
        assertEquals("simulated", (d as AccessDecision.Granted).source)
    }

    @Test
    fun `demo ignores controller time when link is lost`() {
        val d = AccessPolicy.decide(inputs(mode = KioskMode.DEMO, link = LinkState.LOST, ctl = 60_000, demo = 0))
        assertFalse(d.granted)
    }
}

class DemoClockTest {
    @Test
    fun `rates for 1, 5, 10 and 20 pulses`() {
        assertEquals(240, Rates.secondsFor(1))
        assertEquals(1_200, Rates.secondsFor(5))
        assertEquals(2_400, Rates.secondsFor(10))
        assertEquals(4_800, Rates.secondsFor(20))
        assertEquals("00:04:00", Rates.formatHms(Rates.secondsFor(1)))
        assertEquals("01:20:00", Rates.formatHms(Rates.secondsFor(20)))
    }

    @Test
    fun `simulated coins extend the current demo session`() {
        val c = DemoClock()
        c.addPulses(KioskMode.DEMO, 1, 240, nowMs = 0)
        assertEquals(240_000, c.remainingMs(0))
        c.addPulses(KioskMode.DEMO, 5, 240, nowMs = 60_000)
        assertEquals(180_000 + 1_200_000, c.remainingMs(60_000))
    }

    @Test
    fun `simulated coins after expiry start from now`() {
        val c = DemoClock()
        c.addPulses(KioskMode.DEMO, 1, 240, 0)
        c.addPulses(KioskMode.DEMO, 1, 240, 1_000_000)
        assertEquals(240_000, c.remainingMs(1_000_000))
    }

    @Test
    fun `production rejects simulated credits`() {
        val c = DemoClock()
        val r = c.addPulses(KioskMode.PRODUCTION, 10, 240, 0)
        assertTrue(r.isFailure)
        assertEquals("simulated_credit_rejected", r.exceptionOrNull()?.message)
        assertEquals(0, c.remainingMs(0))
        assertTrue(c.addPulses(KioskMode.UNCONFIGURED, 1, 240, 0).isFailure)
    }
}
