package online.ebnleadgen.vendokiosk.service

import org.json.JSONObject
import java.io.IOException
import java.net.URL
import javax.net.ssl.HttpsURLConnection

class CloudHttpException(val status: Int, val code: String) : IOException("HTTP $status $code")

/**
 * Outbound HTTPS to the Hostinger API. Uses the platform trust store, so the
 * server certificate and host name are always verified. The device token is
 * never logged.
 */
class CloudClient(private val apiBase: String) {
    init {
        require(apiBase.startsWith("https://")) { "Cloud API must use HTTPS" }
    }

    fun postJson(path: String, body: JSONObject, token: String?): JSONObject {
        val conn = URL(apiBase + path).openConnection() as HttpsURLConnection
        try {
            conn.requestMethod = "POST"
            conn.connectTimeout = 10_000
            conn.readTimeout = 15_000
            conn.doOutput = true
            conn.useCaches = false
            conn.setRequestProperty("Content-Type", "application/json")
            conn.setRequestProperty("Accept", "application/json")
            if (token != null) conn.setRequestProperty("Authorization", "Bearer $token")
            conn.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
            val status = conn.responseCode
            val stream = if (status in 200..299) conn.inputStream else conn.errorStream
            val text = stream?.bufferedReader()?.use { it.readText().take(64 * 1024) } ?: ""
            val json = try {
                JSONObject(text)
            } catch (e: Exception) {
                JSONObject()
            }
            if (status !in 200..299) {
                throw CloudHttpException(status, json.optJSONObject("error")?.optString("code") ?: "http_$status")
            }
            return json
        } finally {
            conn.disconnect()
        }
    }

    /** Redeems a one-time enrollment code; returns (public device id, token). */
    fun enrollPhone(code: String, name: String, hardwareId: String): Pair<String, String> {
        val res = postJson(
            "/devices/enroll",
            JSONObject().put("device_type", "phone").put("enrollment_code", code).put("name", name).put("hardware_id", hardwareId),
            null
        )
        val token = res.optString("device_token")
        if (!token.startsWith("vkd_")) throw IOException("Enrollment response missing token")
        return res.optString("device_id") to token
    }

    fun heartbeat(token: String, payload: JSONObject): JSONObject = postJson("/phone/heartbeat", payload, token)
}
