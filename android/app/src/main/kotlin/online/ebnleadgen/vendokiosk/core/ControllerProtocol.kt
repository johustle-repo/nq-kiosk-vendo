package online.ebnleadgen.vendokiosk.core

import org.json.JSONObject
import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** A status report from the coin controller that passed signature verification. */
data class ControllerStatus(
    val deviceId: String,
    val bootId: String,
    val uptimeMs: Long,
    val seq: Long,
    val sessionNo: Long,
    val running: Boolean,
    val remainingS: Long,
    val secondsPerPulse: Int,
    val rateVersion: Long,
    val lastAddedS: Long,
    val lastPulses: Long,
    val resumed: Boolean,
    val cloud: String,
)

class ProtocolException(val code: String, message: String) : Exception(message)

/**
 * Local controller protocol v1 (see docs/API.md, "Local controller API").
 *
 * The phone sends a fresh random nonce with every status request; the ESP8266
 * signs `VK1|status|<nonce>|<body>` with the shared pairing key. A response is
 * only trusted when the signature, nonce, protocol and device id all match, so
 * a spoofed or replayed response on the LAN cannot grant paid time.
 */
object ControllerProtocol {
    const val PROTOCOL_VERSION = 1

    fun hmacHex(key: ByteArray, message: String): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(message.toByteArray(Charsets.UTF_8)).toHex()
    }

    fun statusSignatureInput(nonce: String, body: String) = "VK1|status|$nonce|$body"

    fun commandMac(key: ByteArray, name: String, bootId: String, counter: Long): String =
        hmacHex(key, "VK1|cmd|$name|$bootId|$counter")

    /**
     * Verifies and parses a status response.
     * @param expectedDeviceId the controller id recorded at pairing, or null to skip.
     */
    fun verifyStatus(
        body: String,
        signatureHeader: String?,
        nonce: String,
        key: ByteArray,
        expectedDeviceId: String?,
    ): ControllerStatus {
        if (signatureHeader.isNullOrEmpty()) throw ProtocolException("unsigned", "Response is not signed")
        val expected = hmacHex(key, statusSignatureInput(nonce, body))
        // Constant-time comparison.
        if (!MessageDigest.isEqual(expected.toByteArray(), signatureHeader.lowercase().toByteArray())) {
            throw ProtocolException("bad_signature", "Signature mismatch (wrong key or tampered response)")
        }
        val j = try {
            JSONObject(body)
        } catch (e: Exception) {
            throw ProtocolException("bad_json", "Malformed status JSON")
        }
        if (j.optString("nonce") != nonce) throw ProtocolException("nonce_mismatch", "Replayed or mismatched response")
        if (j.optInt("protocol", -1) != PROTOCOL_VERSION) throw ProtocolException("protocol", "Unsupported controller protocol")
        val deviceId = j.optString("device_id")
        if (expectedDeviceId != null && deviceId != expectedDeviceId) {
            throw ProtocolException("wrong_device", "Response from a different controller")
        }
        val bootId = j.optString("boot_id")
        if (!bootId.matches(Regex("^[0-9a-f]{8,16}$"))) throw ProtocolException("bad_boot_id", "Invalid boot id")
        val remaining = j.optLong("remaining_s", -1)
        if (remaining < 0) throw ProtocolException("bad_remaining", "Missing remaining_s")
        return ControllerStatus(
            deviceId = deviceId,
            bootId = bootId,
            uptimeMs = j.optLong("uptime_ms", 0),
            seq = j.optLong("seq", 0),
            sessionNo = j.optLong("session_no", 0),
            running = j.optString("session") == "running",
            remainingS = remaining,
            secondsPerPulse = j.optInt("seconds_per_pulse", Rates.DEFAULT_SECONDS_PER_PULSE),
            rateVersion = j.optLong("rate_version", 0),
            lastAddedS = j.optLong("last_added_s", 0),
            lastPulses = j.optLong("last_pulses", 0),
            resumed = j.optBoolean("resumed", false),
            cloud = j.optString("cloud", "unknown"),
        )
    }

    data class PairResult(val deviceId: String, val key: ByteArray, val bootId: String)

    fun parsePairResponse(body: String): PairResult {
        val j = try {
            JSONObject(body)
        } catch (e: Exception) {
            throw ProtocolException("bad_json", "Malformed pairing response")
        }
        if (!j.optBoolean("ok")) throw ProtocolException(j.optString("error", "pair_failed"), "Pairing rejected")
        val keyHex = j.optString("key")
        if (!keyHex.matches(Regex("^[0-9a-f]{64}$"))) throw ProtocolException("bad_key", "Invalid key in pairing response")
        return PairResult(j.optString("device_id"), keyHex.hexToBytes(), j.optString("boot_id"))
    }

    fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

    fun String.hexToBytes(): ByteArray {
        require(length % 2 == 0) { "odd hex length" }
        return ByteArray(length / 2) { i -> substring(2 * i, 2 * i + 2).toInt(16).toByte() }
    }
}
