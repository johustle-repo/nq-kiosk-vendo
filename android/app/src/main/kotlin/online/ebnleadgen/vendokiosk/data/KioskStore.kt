package online.ebnleadgen.vendokiosk.data

import android.content.Context
import android.content.SharedPreferences
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import online.ebnleadgen.vendokiosk.core.KioskMode
import online.ebnleadgen.vendokiosk.core.PinLockout
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Encrypts small secrets with an AES-256-GCM key that lives in the Android
 * Keystore (hardware-backed where available) and never leaves it.
 */
class SecretBox {
    private val alias = "vendo_kiosk_secrets_v1"

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    fun encrypt(plain: ByteArray): String {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key())
        val ct = c.doFinal(plain)
        return Base64.encodeToString(c.iv, Base64.NO_WRAP) + ":" + Base64.encodeToString(ct, Base64.NO_WRAP)
    }

    fun decrypt(stored: String): ByteArray? = try {
        val (ivB64, ctB64) = stored.split(":", limit = 2)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(ivB64, Base64.NO_WRAP)))
        c.doFinal(Base64.decode(ctB64, Base64.NO_WRAP))
    } catch (e: Exception) {
        null // key lost (e.g. data restored elsewhere) or tampered value: treat as absent
    }
}

/** Persistent kiosk settings. Secrets are stored only in encrypted form. */
class KioskStore(context: Context) {
    private val appContext = context.applicationContext
    private val prefs: SharedPreferences = appContext.getSharedPreferences("vendo_kiosk", Context.MODE_PRIVATE)
    private val box = SecretBox()

    // ---- plain settings
    var mode: KioskMode
        get() = KioskMode.fromWire(prefs.getString("mode", null))
        set(v) = prefs.edit().putString("mode", v.wire).apply()

    var controllerAddress: String?
        get() = prefs.getString("controller_address", null)
        set(v) = prefs.edit().putString("controller_address", v).apply()

    var controllerDeviceId: String?
        get() = prefs.getString("controller_device_id", null)
        set(v) = prefs.edit().putString("controller_device_id", v).apply()

    /** This tablet's number on the shared coin box (1-4). Earlier single-tablet pairings are tablet 1. */
    var controllerStation: Int
        get() = prefs.getInt("controller_station", 1).takeIf { it in 1..4 } ?: 1
        set(v) = prefs.edit().putInt("controller_station", v).apply()

    var allowedPackages: List<String>
        get() = prefs.getString("allowed_packages", "")!!.split(",").filter { it.isNotBlank() }
        set(v) = prefs.edit().putString("allowed_packages", v.distinct().joinToString(",")).apply()

    var lossTimeoutS: Int
        get() = prefs.getInt("loss_timeout_s", 30)
        set(v) = prefs.edit().putInt("loss_timeout_s", v.coerceIn(5, 600)).apply()

    var cloudConfigVersion: Int
        get() = prefs.getInt("cloud_config_version", 0)
        set(v) = prefs.edit().putInt("cloud_config_version", v).apply()

    var cloudDeviceId: String?
        get() = prefs.getString("cloud_device_id", null)
        set(v) = prefs.edit().putString("cloud_device_id", v).apply()

    /** Random per-install id sent to the controller when pairing (not a secret). */
    val phoneId: String
        get() = prefs.getString("phone_id", null) ?: java.util.UUID.randomUUID().toString().also {
            prefs.edit().putString("phone_id", it).apply()
        }

    /** Strictly increasing counter for authenticated controller commands (anti-replay). */
    @Synchronized
    fun nextCommandCounter(): Long {
        val next = prefs.getLong("cmd_counter", 0) + 1
        prefs.edit().putLong("cmd_counter", next).commit()
        return next
    }

    /** Seconds without paid time and without touches before the screen sleeps (0 = never). */
    var idleSleepS: Int
        get() = prefs.getInt("idle_sleep_s", 60)
        set(v) = prefs.edit().putInt("idle_sleep_s", v.coerceIn(0, 3600)).apply()

    var lockAdbInProduction: Boolean
        get() = prefs.getBoolean("lock_adb", false)
        set(v) = prefs.edit().putBoolean("lock_adb", v).apply()

    // ---- secrets (Keystore-encrypted)
    private fun putSecret(name: String, value: ByteArray?) {
        prefs.edit().apply { if (value == null) remove(name) else putString(name, box.encrypt(value)) }.apply()
    }

    private fun getSecret(name: String): ByteArray? = prefs.getString(name, null)?.let { box.decrypt(it) }

    var controllerKey: ByteArray?
        get() = getSecret("s_controller_key")
        set(v) = putSecret("s_controller_key", v)

    var cloudToken: String?
        get() = getSecret("s_cloud_token")?.toString(Charsets.UTF_8)
        set(v) = putSecret("s_cloud_token", v?.toByteArray(Charsets.UTF_8))

    data class PinRecord(val salt: ByteArray, val hash: ByteArray, val recoverySalt: ByteArray, val recoveryHash: ByteArray)

    var pinRecord: PinRecord?
        get() {
            val raw = getSecret("s_pin") ?: return null
            val parts = raw.toString(Charsets.UTF_8).split(":")
            if (parts.size != 4) return null
            val d = parts.map { Base64.decode(it, Base64.NO_WRAP) }
            return PinRecord(d[0], d[1], d[2], d[3])
        }
        set(v) = putSecret(
            "s_pin",
            v?.let {
                listOf(it.salt, it.hash, it.recoverySalt, it.recoveryHash)
                    .joinToString(":") { b -> Base64.encodeToString(b, Base64.NO_WRAP) }
                    .toByteArray(Charsets.UTF_8)
            }
        )

    // ---- PIN lockout (persisted so killing the app does not reset it)
    fun loadLockout(nowElapsedMs: Long): PinLockout {
        val l = PinLockout(prefs.getInt("pin_failures", 0), prefs.getLong("pin_locked_until", 0))
        val bootCount = currentBootCount()
        if (bootCount != prefs.getInt("pin_lock_boot", bootCount)) {
            l.onReboot(nowElapsedMs)
            saveLockout(l)
        }
        return l
    }

    fun saveLockout(l: PinLockout) {
        prefs.edit()
            .putInt("pin_failures", l.failures)
            .putLong("pin_locked_until", l.lockedUntilMs)
            .putInt("pin_lock_boot", currentBootCount())
            .apply()
    }

    private fun currentBootCount(): Int =
        Settings.Global.getInt(appContext.contentResolver, Settings.Global.BOOT_COUNT, -1)
}
