package online.ebnleadgen.vendokiosk.core

import java.io.ByteArrayOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URLEncoder

data class LocalHttpResponse(val status: Int, val headers: Map<String, String>, val body: String)

class LocalHttpException(message: String) : Exception(message)

/**
 * Minimal HTTP/1.1 client for the coin controller on the local network.
 *
 * Deliberately restricted to private/link-local IPv4 literals (no DNS, no
 * public addresses), so it cannot be used to send cleartext traffic to the
 * internet. The app's network security config keeps cleartext disabled for
 * everything else. Integrity/authenticity comes from the HMAC protocol in
 * [ControllerProtocol]; this transport provides no confidentiality.
 */
class LocalHttp(
    private val connectTimeoutMs: Int = 1500,
    private val readTimeoutMs: Int = 2500,
    private val maxResponseBytes: Int = 16 * 1024,
) {
    companion object {
        /** Accepts "a.b.c.d" or "a.b.c.d:port" in 10/8, 172.16/12, 192.168/16 or 169.254/16. */
        fun parseLocalAddress(input: String): Pair<String, Int>? {
            val trimmed = input.trim().removePrefix("http://").trimEnd('/')
            val parts = trimmed.split(":")
            if (parts.size > 2) return null
            val port = if (parts.size == 2) parts[1].toIntOrNull() ?: return null else 80
            if (port !in 1..65535) return null
            val octets = parts[0].split(".")
            if (octets.size != 4) return null
            val o = octets.map { s ->
                if (s.isEmpty() || s.length > 3 || !s.all(Char::isDigit) || (s.length > 1 && s[0] == '0')) return null
                s.toInt().takeIf { it in 0..255 } ?: return null
            }
            val private = o[0] == 10 ||
                (o[0] == 172 && o[1] in 16..31) ||
                (o[0] == 192 && o[1] == 168) ||
                (o[0] == 169 && o[1] == 254)
            if (!private || o[3] == 0 || o[3] == 255) return null
            return o.joinToString(".") to port
        }

        fun formEncode(form: Map<String, String>): String =
            form.entries.joinToString("&") { (k, v) -> URLEncoder.encode(k, "UTF-8") + "=" + URLEncoder.encode(v, "UTF-8") }
    }

    fun get(address: String, path: String): LocalHttpResponse = request(address, "GET", path, null)

    fun postForm(address: String, path: String, form: Map<String, String>): LocalHttpResponse =
        request(address, "POST", path, formEncode(form))

    private fun request(address: String, method: String, path: String, formBody: String?): LocalHttpResponse {
        val (host, port) = parseLocalAddress(address) ?: throw LocalHttpException("Controller address must be a private IPv4 address")
        require(path.startsWith("/") && path.none { it == '\r' || it == '\n' || it == ' ' })
        val bodyBytes = formBody?.toByteArray(Charsets.UTF_8)
        val req = buildString {
            append("$method $path HTTP/1.1\r\n")
            append("Host: $host\r\n")
            append("Connection: close\r\n")
            append("Accept: application/json\r\n")
            if (bodyBytes != null) {
                append("Content-Type: application/x-www-form-urlencoded\r\n")
                append("Content-Length: ${bodyBytes.size}\r\n")
            }
            append("\r\n")
        }
        Socket().use { s ->
            s.connect(InetSocketAddress(host, port), connectTimeoutMs)
            s.soTimeout = readTimeoutMs
            val out = s.getOutputStream()
            out.write(req.toByteArray(Charsets.US_ASCII))
            if (bodyBytes != null) out.write(bodyBytes)
            out.flush()
            val buf = ByteArrayOutputStream()
            val chunk = ByteArray(2048)
            val input = s.getInputStream()
            while (true) {
                val n = input.read(chunk)
                if (n < 0) break
                buf.write(chunk, 0, n)
                if (buf.size() > maxResponseBytes) throw LocalHttpException("Response too large")
                // Stop as soon as the declared body has arrived, even if the server keeps the socket open.
                if (isComplete(buf.toByteArray())) break
            }
            return parseResponse(buf.toByteArray())
        }
    }

    internal fun isComplete(raw: ByteArray): Boolean {
        val text = String(raw, Charsets.ISO_8859_1)
        val split = text.indexOf("\r\n\r\n")
        if (split < 0) return false
        val len = Regex("(?im)^content-length:\\s*(\\d+)\\s*$").find(text.substring(0, split))?.groupValues?.get(1)?.toIntOrNull()
            ?: return false
        return raw.size - (split + 4) >= len
    }

    internal fun parseResponse(raw: ByteArray): LocalHttpResponse {
        val text = String(raw, Charsets.UTF_8)
        val split = text.indexOf("\r\n\r\n")
        if (split < 0) throw LocalHttpException("Malformed HTTP response")
        val headLines = text.substring(0, split).split("\r\n")
        val statusParts = headLines.first().split(" ")
        val status = statusParts.getOrNull(1)?.toIntOrNull() ?: throw LocalHttpException("Bad status line")
        val headers = headLines.drop(1).mapNotNull { line ->
            val i = line.indexOf(':')
            if (i <= 0) null else line.substring(0, i).trim().lowercase() to line.substring(i + 1).trim()
        }.toMap()
        var body = text.substring(split + 4)
        headers["content-length"]?.toIntOrNull()?.let { len ->
            val bytes = body.toByteArray(Charsets.UTF_8)
            if (bytes.size < len) throw LocalHttpException("Truncated response")
            body = String(bytes, 0, len, Charsets.UTF_8)
        }
        return LocalHttpResponse(status, headers, body)
    }
}
