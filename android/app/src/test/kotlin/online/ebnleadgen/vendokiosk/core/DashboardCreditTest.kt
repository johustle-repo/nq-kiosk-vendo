package online.ebnleadgen.vendokiosk.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DashboardCreditTest {
    private val min = 60_000L

    @Test
    fun waitsUntilRunning() {
        val c = DashboardCredit()
        c.add(600, 0)
        assertEquals(10 * min, c.remainingMs(5 * min))
        c.setRunning(true, 5 * min)
        assertEquals(7 * min, c.remainingMs(8 * min))
    }

    @Test
    fun pausesWhileCoinTimeRuns() {
        val c = DashboardCredit()
        c.add(600, 0)
        c.setRunning(true, 0)
        c.setRunning(false, 4 * min)
        assertEquals(6 * min, c.remainingMs(30 * min))
        assertFalse(c.running)
    }

    @Test
    fun addingWhileRunningExtendsWhatIsLeft() {
        val c = DashboardCredit()
        c.add(600, 0)
        c.setRunning(true, 0)
        c.add(300, 8 * min)
        assertEquals(7 * min, c.remainingMs(8 * min))
        assertEquals(0, c.remainingMs(20 * min))
        assertTrue(c.running)
    }

    @Test
    fun clearEndsIt() {
        val c = DashboardCredit(5 * min)
        c.setRunning(true, 0)
        c.clear()
        assertEquals(0, c.remainingMs(1))
        assertFalse(c.running)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsBadAmounts() {
        DashboardCredit().add(0, 0)
    }
}
