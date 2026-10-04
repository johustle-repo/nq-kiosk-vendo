package online.ebnleadgen.vendokiosk.core

import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.PBEKeySpec

/** Administrator PIN rules and hashing (PBKDF2-HMAC-SHA256 with a random salt). */
object PinSecurity {
    const val MIN_LENGTH = 6
    const val MAX_LENGTH = 12
    const val ITERATIONS = 60_000
    private val random = SecureRandom()

    /** Returns null when acceptable, otherwise a user-facing reason. */
    fun validateNewPin(pin: String): String? = when {
        !pin.all { it in '0'..'9' } -> "PIN must contain digits only."
        pin.length < MIN_LENGTH -> "PIN must be at least $MIN_LENGTH digits."
        pin.length > MAX_LENGTH -> "PIN must be at most $MAX_LENGTH digits."
        pin.toSet().size == 1 -> "PIN cannot repeat a single digit."
        isSequential(pin) -> "PIN cannot be a simple sequence."
        else -> null
    }

    private fun isSequential(pin: String): Boolean {
        val up = pin.zipWithNext().all { (a, b) -> b - a == 1 }
        val down = pin.zipWithNext().all { (a, b) -> a - b == 1 }
        return up || down
    }

    fun newSalt(): ByteArray = ByteArray(16).also { random.nextBytes(it) }

    fun hash(secret: String, salt: ByteArray, iterations: Int = ITERATIONS): ByteArray {
        val spec = PBEKeySpec(secret.toCharArray(), salt, iterations, 256)
        try {
            return SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
        } finally {
            spec.clearPassword()
        }
    }

    fun verify(secret: String, salt: ByteArray, expected: ByteArray, iterations: Int = ITERATIONS): Boolean =
        MessageDigest.isEqual(hash(secret, salt, iterations), expected)

    /** 16-character recovery code from an unambiguous alphabet, grouped 4-4-4-4. */
    fun newRecoveryCode(): String {
        val alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
        val raw = (1..16).map { alphabet[random.nextInt(alphabet.length)] }.joinToString("")
        return raw.chunked(4).joinToString("-")
    }

    fun normaliseRecoveryCode(code: String): String = code.uppercase().filter { it.isLetterOrDigit() }
}

/**
 * Failed-attempt throttling. The first [FREE_ATTEMPTS] failures are free; after
 * that each failure locks entry for an exponentially growing time (30 s, 60 s,
 * 120 s … capped at 1 h). Time is monotonic (elapsedRealtime); after a reboot an
 * active lockout restarts in full, so rebooting never shortens it.
 */
class PinLockout(var failures: Int = 0, var lockedUntilMs: Long = 0) {
    companion object {
        const val FREE_ATTEMPTS = 4
        const val BASE_LOCK_MS = 30_000L
        const val MAX_LOCK_MS = 3_600_000L

        fun lockDurationMs(failures: Int): Long {
            if (failures < FREE_ATTEMPTS) return 0
            val exp = (failures - FREE_ATTEMPTS).coerceAtMost(16)
            return (BASE_LOCK_MS shl exp).coerceAtMost(MAX_LOCK_MS)
        }
    }

    fun remainingLockMs(nowMs: Long): Long = (lockedUntilMs - nowMs).coerceAtLeast(0)

    fun onFailure(nowMs: Long) {
        failures++
        val d = lockDurationMs(failures)
        if (d > 0) lockedUntilMs = nowMs + d
    }

    fun onSuccess() {
        failures = 0
        lockedUntilMs = 0
    }

    /** Called when the monotonic clock was reset by a reboot. */
    fun onReboot(nowMs: Long) {
        val d = lockDurationMs(failures)
        if (d > 0) lockedUntilMs = nowMs + d
    }
}
