package online.ebnleadgen.vendokiosk.core

import online.ebnleadgen.vendokiosk.core.ControllerProtocol.toHex
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class ControllerProtocolTest {
    private val key = ByteArray(32) { it.toByte() }
    private val nonce = "00112233445566778899aabbccddeeff"
    private fun body(n: String = nonce, device: String = "vk-abc", remaining: Int = 480, station: Int = 2) =
        """{"ok":true,"protocol":2,"device_id":"$device","boot_id":"1a2b3c4d","station":$station,"uptime_ms":60000,"seq":2,"session_no":1,"session":"running","remaining_s":$remaining,"seconds_per_pulse":240,"rate_version":0,"last_added_s":240,"last_pulses":1,"selected_station":2,"selected_ttl_s":75,"held_pulses":5,"resumed":false,"cloud":"ok","nonce":"$n"}"""

    private fun sign(b: String, n: String = nonce, k: ByteArray = key, station: Int = 2) =
        ControllerProtocol.hmacHex(k, ControllerProtocol.statusSignatureInput(station, n, b))

    private fun expectCode(code: String, block: () -> Unit) {
        try {
            block()
            fail("expected $code")
        } catch (e: ProtocolException) {
            assertEquals(code, e.code)
        }
    }

    @Test
    fun `known HMAC-SHA256 vector (RFC 4231 case 2)`() {
        val mac = ControllerProtocol.hmacHex("Jefe".toByteArray(), "what do ya want for nothing?")
        assertEquals("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", mac)
    }

    @Test
    fun `valid signed status is accepted`() {
        val b = body()
        val s = ControllerProtocol.verifyStatus(b, sign(b), nonce, key, "vk-abc", 2)
        assertEquals(480, s.remainingS)
        assertEquals("1a2b3c4d", s.bootId)
        assertEquals(2, s.seq)
        assertTrue(s.running)
        assertEquals(2, s.station)
        assertEquals(2, s.selectedStation)
        assertEquals(5, s.heldPulses)
    }

    @Test
    fun `a response for another tablet is rejected`() {
        // Correctly signed for tablet 3 with tablet 3's own key, presented to tablet 2.
        val b = body(station = 3)
        expectCode("bad_signature") { ControllerProtocol.verifyStatus(b, sign(b, station = 3), nonce, key, null, 2) }
        // Even signed over tablet 2's input, the body must name tablet 2.
        expectCode("wrong_station") { ControllerProtocol.verifyStatus(b, sign(b, station = 2), nonce, key, null, 2) }
    }

    @Test
    fun `protocol 1 firmware is rejected with a clear code`() {
        val b = body().replace("\"protocol\":2", "\"protocol\":1")
        expectCode("protocol") { ControllerProtocol.verifyStatus(b, sign(b), nonce, key, null, 2) }
    }

    @Test
    fun `tampered remaining time is rejected`() {
        val b = body()
        val sig = sign(b)
        expectCode("bad_signature") { ControllerProtocol.verifyStatus(body(remaining = 99_999), sig, nonce, key, "vk-abc", 2) }
    }

    @Test
    fun `wrong key (spoofed controller) is rejected`() {
        val b = body()
        expectCode("bad_signature") { ControllerProtocol.verifyStatus(b, sign(b, k = ByteArray(32)), nonce, key, null, 2) }
    }

    @Test
    fun `missing signature is rejected`() {
        expectCode("unsigned") { ControllerProtocol.verifyStatus(body(), null, nonce, key, null, 2) }
    }

    @Test
    fun `replayed response for an old nonce is rejected`() {
        val old = "ffeeddccbbaa99887766554433221100"
        val b = body(n = old)
        // Signed correctly for the old nonce, but presented for the new request.
        expectCode("bad_signature") { ControllerProtocol.verifyStatus(b, sign(b, n = old), nonce, key, null, 2) }
        // Even if the attacker could sign with the new nonce, the body must echo it.
        expectCode("nonce_mismatch") { ControllerProtocol.verifyStatus(b, sign(b, n = nonce), nonce, key, null, 2) }
    }

    @Test
    fun `different controller id is rejected`() {
        val b = body(device = "vk-other")
        expectCode("wrong_device") { ControllerProtocol.verifyStatus(b, sign(b), nonce, key, "vk-abc", 2) }
    }

    @Test
    fun `command MAC binds name, boot and counter`() {
        val a = ControllerProtocol.commandMac(key, "end_session", 2, "1a2b3c4d", 5)
        assertFalse(a == ControllerProtocol.commandMac(key, "end_session", 2, "1a2b3c4d", 6))
        assertFalse(a == ControllerProtocol.commandMac(key, "unpair", 2, "1a2b3c4d", 5))
        assertFalse(a == ControllerProtocol.commandMac(key, "end_session", 2, "ffffffff", 5))
        assertFalse(a == ControllerProtocol.commandMac(key, "end_session", 3, "1a2b3c4d", 5))
    }

    @Test
    fun `pair response parsing`() {
        val k = ByteArray(32) { 7 }.toHex()
        val p = ControllerProtocol.parsePairResponse("""{"ok":true,"device_id":"vk-abc","boot_id":"1a2b3c4d","station":2,"key":"$k"}""", 2)
        assertEquals("vk-abc", p.deviceId)
        assertEquals(32, p.key.size)
        expectCode("wrong_code") { ControllerProtocol.parsePairResponse("""{"ok":false,"error":"wrong_code"}""", 2) }
        expectCode("bad_key") { ControllerProtocol.parsePairResponse("""{"ok":true,"station":2,"key":"abc"}""", 2) }
    }
}

class LocalHttpTest {
    @Test
    fun `only private IPv4 literals are accepted`() {
        assertEquals("192.168.1.50" to 80, LocalHttp.parseLocalAddress("192.168.1.50"))
        assertEquals("10.0.0.7" to 8080, LocalHttp.parseLocalAddress("http://10.0.0.7:8080/"))
        assertNotNull(LocalHttp.parseLocalAddress("172.20.1.2"))
        assertNotNull(LocalHttp.parseLocalAddress("169.254.10.10"))
        assertNull(LocalHttp.parseLocalAddress("8.8.8.8"))
        assertNull(LocalHttp.parseLocalAddress("172.32.0.1"))
        assertNull(LocalHttp.parseLocalAddress("vendo.example.com"))
        assertNull(LocalHttp.parseLocalAddress("192.168.1.256"))
        assertNull(LocalHttp.parseLocalAddress("192.168.01.5"))
        assertNull(LocalHttp.parseLocalAddress("192.168.1.255"))
        assertNull(LocalHttp.parseLocalAddress("192.168.1.5:0"))
        assertNull(LocalHttp.parseLocalAddress("192.168.1.5:abc"))
    }

    @Test
    fun `parses response headers and content length`() {
        val raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-VK-Signature: ab12\r\nContent-Length: 7\r\n\r\n{\"a\":1}".toByteArray()
        val r = LocalHttp().parseResponse(raw)
        assertEquals(200, r.status)
        assertEquals("ab12", r.headers["x-vk-signature"])
        assertEquals("{\"a\":1}", r.body)
    }

    @Test
    fun `detects a complete response without waiting for the socket to close`() {
        val http = LocalHttp()
        assertFalse(http.isComplete("HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\n{\"a\"".toByteArray()))
        assertTrue(http.isComplete("HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\n{\"a\":1}".toByteArray()))
        assertFalse(http.isComplete("HTTP/1.1 200 OK\r\nContent-Type: x".toByteArray()))
    }

    @Test(expected = LocalHttpException::class)
    fun `truncated response is rejected`() {
        LocalHttp().parseResponse("HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\n{}".toByteArray())
    }
}

class PinSecurityTest {
    @Test
    fun `weak PINs are rejected`() {
        assertNotNull(PinSecurity.validateNewPin("12345"))
        assertNotNull(PinSecurity.validateNewPin("111111"))
        assertNotNull(PinSecurity.validateNewPin("123456"))
        assertNotNull(PinSecurity.validateNewPin("987654"))
        assertNotNull(PinSecurity.validateNewPin("12a456"))
        assertNull(PinSecurity.validateNewPin("482915"))
    }

    @Test
    fun `hash verifies only the right PIN`() {
        val salt = PinSecurity.newSalt()
        val h = PinSecurity.hash("482915", salt, iterations = 1000)
        assertTrue(PinSecurity.verify("482915", salt, h, iterations = 1000))
        assertFalse(PinSecurity.verify("482916", salt, h, iterations = 1000))
        assertFalse(PinSecurity.verify("482915", PinSecurity.newSalt(), h, iterations = 1000))
    }

    @Test
    fun `recovery code format and normalisation`() {
        val c = PinSecurity.newRecoveryCode()
        assertTrue(c.matches(Regex("^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$")))
        assertEquals(c.replace("-", ""), PinSecurity.normaliseRecoveryCode(c.lowercase().replace("-", " ")))
    }

    @Test
    fun `lockout grows after free attempts and survives reboot`() {
        val l = PinLockout()
        repeat(3) { l.onFailure(0) }
        assertEquals(0, l.remainingLockMs(0))
        l.onFailure(0) // 4th failure
        assertEquals(30_000, l.remainingLockMs(0))
        l.onFailure(30_000) // 5th
        assertEquals(60_000, l.remainingLockMs(30_000))
        // Reboot resets the monotonic clock to ~0: the lock restarts in full.
        l.onReboot(5_000)
        assertEquals(60_000, l.remainingLockMs(5_000))
        repeat(20) { l.onFailure(0) }
        assertEquals(PinLockout.MAX_LOCK_MS, l.remainingLockMs(0))
        l.onSuccess()
        assertEquals(0, l.remainingLockMs(0))
        assertEquals(0, l.failures)
    }
}
