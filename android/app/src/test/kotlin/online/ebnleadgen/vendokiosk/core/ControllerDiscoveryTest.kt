package online.ebnleadgen.vendokiosk.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ControllerDiscoveryTest {
    @Test
    fun scansTheTabletsSubnetPreviousHostFirstWithoutItself() {
        val hosts = ControllerDiscovery.candidates("192.168.0.42", "192.168.1.105:80", 80)
        assertEquals("192.168.0.105:80", hosts.first())
        assertEquals(253, hosts.size)
        assertFalse(hosts.contains("192.168.0.42:80"))
        assertTrue(hosts.all { it.startsWith("192.168.0.") })
    }

    @Test
    fun scansWithoutAPreviousAddressAndRejectsPublicIps() {
        assertEquals("10.0.5.1:8080", ControllerDiscovery.candidates("10.0.5.9", null, 8080).first())
        assertTrue(ControllerDiscovery.candidates("8.8.8.8", null, 80).isEmpty())
    }

    @Test
    fun readsTheDeviceIdFromInfo() {
        assertEquals("vk-f6e705", ControllerDiscovery.infoDeviceId("""{"ok":true,"protocol":2,"device_id":"vk-f6e705"}"""))
        assertNull(ControllerDiscovery.infoDeviceId("""{"ok":false,"device_id":"vk-f6e705"}"""))
        assertNull(ControllerDiscovery.infoDeviceId("<html>router</html>"))
    }

    @Test
    fun parsesWhatACoinBoxReports() {
        val box = ControllerDiscovery.parseInfo(
            "192.168.0.106:80",
            """{"ok":true,"protocol":2,"device_id":"vk-f6e705","fw_version":"2.4.0","stations":1,"paired":[true],"pairing_open":true}""",
        )!!
        assertEquals("vk-f6e705", box.deviceId)
        assertEquals("2.4.0", box.fwVersion)
        assertEquals(1, box.stations)
        assertEquals(listOf(true), box.paired)
        assertEquals(true, box.pairingOpen)
        // Older firmware does not report pairing; unknown, not "closed".
        assertNull(ControllerDiscovery.parseInfo("10.0.0.2:80", """{"ok":true,"device_id":"vk-1"}""")!!.pairingOpen)
        assertNull(ControllerDiscovery.parseInfo("10.0.0.2:80", "<html>router</html>"))
    }
}
