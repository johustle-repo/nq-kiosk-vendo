package online.ebnleadgen.vendokiosk.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionTrackerTest {
    private fun status(
        remaining: Long,
        seq: Long = 1,
        uptime: Long = 10_000,
        boot: String = "aaaaaaaa",
        device: String = "vk-1",
    ) = ControllerStatus(device, boot, uptime, seq, 1, remaining > 0, remaining, 240, 0, 240, 1, false, "ok")

    @Test
    fun `counts down from the verified report using the monotonic clock`() {
        val t = SessionTracker(lossTimeoutMs = 30_000)
        t.onVerifiedStatus(status(240), nowMs = 1_000)
        assertEquals(240_000, t.estimatedRemainingMs(1_000))
        assertEquals(230_000, t.estimatedRemainingMs(11_000))
    }

    @Test
    fun `adding time during countdown is detected via sequence number`() {
        val t = SessionTracker(30_000)
        t.onVerifiedStatus(status(240, seq = 1, uptime = 10_000), 0)
        // 60 s later another coin: controller now reports 180 + 240 = 420 s.
        val r = t.onVerifiedStatus(status(420, seq = 2, uptime = 70_000), 60_000)
        assertEquals(StatusUpdate.CREDIT_ADDED, r)
        assertEquals(420_000, t.estimatedRemainingMs(60_000))
    }

    @Test
    fun `expiration reaches zero and never goes negative`() {
        val t = SessionTracker(30_000)
        t.onVerifiedStatus(status(5), 0)
        assertEquals(0, t.estimatedRemainingMs(5_000))
        assertEquals(0, t.estimatedRemainingMs(50_000))
    }

    @Test
    fun `duplicate or repeated polls never add time`() {
        val t = SessionTracker(30_000)
        t.onVerifiedStatus(status(240, seq = 1, uptime = 10_000), 0)
        // Same report delivered again (retry/replay through a proxy): ignored.
        assertEquals(StatusUpdate.STALE_IGNORED, t.onVerifiedStatus(status(240, seq = 1, uptime = 10_000), 5_000))
        assertEquals(235_000, t.estimatedRemainingMs(5_000))
        // Many polls of a steady state: estimate follows the controller, no growth.
        for (i in 1..10) t.onVerifiedStatus(status(240L - i, seq = 1, uptime = 10_000L + i * 1000), i * 1000L)
        assertEquals(230_000, t.estimatedRemainingMs(10_000))
    }

    @Test
    fun `out of order older report is ignored`() {
        val t = SessionTracker(30_000)
        t.onVerifiedStatus(status(100, uptime = 20_000), 0)
        assertEquals(StatusUpdate.STALE_IGNORED, t.onVerifiedStatus(status(900, uptime = 15_000), 1_000))
        assertEquals(99_000, t.estimatedRemainingMs(1_000))
    }

    @Test
    fun `controller restart with a new boot id replaces the baseline`() {
        val t = SessionTracker(30_000)
        t.onVerifiedStatus(status(600, seq = 4, uptime = 500_000, boot = "aaaaaaaa"), 0)
        // Controller rebooted: lower uptime, seq restarted, restored 0 time.
        val r = t.onVerifiedStatus(status(0, seq = 0, uptime = 3_000, boot = "bbbbbbbb"), 2_000)
        assertEquals(StatusUpdate.BOOT_CHANGED, r)
        assertEquals(0, t.estimatedRemainingMs(2_000))
    }

    @Test
    fun `reconnect after a gap uses only the fresh report`() {
        val t = SessionTracker(30_000)
        t.onVerifiedStatus(status(300, uptime = 10_000), 0)
        repeat(5) { t.onPollFailed("timeout") }
        assertEquals(LinkState.DEGRADED, t.link(10_000))
        assertEquals(5, t.consecutiveFailures)
        t.onVerifiedStatus(status(280, uptime = 30_000), 20_000)
        assertEquals(LinkState.CONNECTED, t.link(20_000))
        assertEquals(0, t.consecutiveFailures)
        assertEquals(280_000, t.estimatedRemainingMs(20_000))
    }

    @Test
    fun `link becomes LOST after the configured loss timeout`() {
        val t = SessionTracker(lossTimeoutMs = 30_000)
        assertEquals(LinkState.NEVER, t.link(0))
        t.onVerifiedStatus(status(3600), 0)
        assertEquals(LinkState.CONNECTED, t.link(1_000))
        assertEquals(LinkState.DEGRADED, t.link(10_000))
        assertEquals(LinkState.DEGRADED, t.link(30_000))
        assertEquals(LinkState.LOST, t.link(30_001))
        t.lossTimeoutMs = 60_000
        assertEquals(LinkState.DEGRADED, t.link(45_000))
    }

    @Test
    fun `reset forgets the controller entirely`() {
        val t = SessionTracker(30_000)
        t.onVerifiedStatus(status(100), 0)
        t.reset()
        assertEquals(LinkState.NEVER, t.link(1))
        assertEquals(0, t.estimatedRemainingMs(1))
        assertTrue(t.last == null)
    }
}
