package online.ebnleadgen.vendokiosk.core

import org.json.JSONObject
import java.net.Socket
import java.util.concurrent.Callable
import java.util.concurrent.ExecutorCompletionService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Finds the paired coin box again after its IP changed (new DHCP lease, router
 * restart) by asking every host of the tablet's /24 for GET /api/v1/info and
 * matching the device id saved at pairing.
 *
 * Trust: the result is only an address hint. The poller still accepts nothing
 * from it unless the reply is signed with this tablet's pairing key, so a
 * device that copies the coin box's id gains nothing.
 */
object ControllerDiscovery {
    private const val THREADS = 32

    /**
     * Hosts to try: the tablet's /24 (as "a.b.c.d:port"), starting with the
     * last octet of the previous address (routers often hand it out again),
     * without the tablet itself.
     */
    fun candidates(ownIp: String, previous: String?, port: Int): List<String> {
        val own = LocalHttp.parseLocalAddress(ownIp)?.first ?: return emptyList()
        val prefix = own.substringBeforeLast('.')
        val ownLast = own.substringAfterLast('.').toInt()
        val prevLast = previous?.let { LocalHttp.parseLocalAddress(it)?.first?.substringAfterLast('.')?.toIntOrNull() }
        val order = listOfNotNull(prevLast) + (1..254)
        return order.distinct().filter { it != ownLast }.map { "$prefix.$it:$port" }
    }

    /** The device id in a /api/v1/info reply, or null. */
    fun infoDeviceId(body: String): String? = try {
        JSONObject(body).takeIf { it.optBoolean("ok") }?.optString("device_id")?.takeIf { it.isNotEmpty() }
    } catch (e: Exception) {
        null
    }

    /** A coin box that answered GET /api/v1/info. */
    data class Found(
        val address: String,
        val deviceId: String,
        val fwVersion: String,
        val stations: Int,
        val paired: List<Boolean>,
        /** Null on firmware that does not report it. */
        val pairingOpen: Boolean?,
    )

    fun parseInfo(address: String, body: String): Found? = try {
        val o = JSONObject(body)
        val id = o.optString("device_id")
        if (!o.optBoolean("ok") || id.isEmpty()) {
            null
        } else {
            val paired = o.optJSONArray("paired")
            Found(
                address = address,
                deviceId = id,
                fwVersion = o.optString("fw_version"),
                stations = o.optInt("stations", 1).coerceIn(1, ControllerProtocol.MAX_STATIONS),
                paired = (0 until (paired?.length() ?: 0)).map { paired!!.optBoolean(it) },
                pairingOpen = if (o.has("pairing_open")) o.optBoolean("pairing_open") else null,
            )
        }
    } catch (e: Exception) {
        null
    }

    /** Blocking. Every coin box on the tablet's /24, nearest last octet first; at most ~10 s. */
    fun scanAll(ownIp: String, port: Int = 80, newSocket: () -> Socket = { Socket() }): List<Found> {
        val hosts = candidates(ownIp, null, port)
        if (hosts.isEmpty()) return emptyList()
        val http = LocalHttp(connectTimeoutMs = 700, readTimeoutMs = 1500, maxResponseBytes = 4096, newSocket = newSocket)
        val pool = Executors.newFixedThreadPool(THREADS)
        try {
            val futures = hosts.map { host ->
                pool.submit(Callable {
                    try {
                        val r = http.get(host, "/api/v1/info")
                        if (r.status == 200) parseInfo(host, r.body) else null
                    } catch (e: Exception) {
                        null
                    }
                })
            }
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
            return futures.mapNotNull { f ->
                try {
                    f.get((deadline - System.nanoTime()).coerceAtLeast(1), TimeUnit.NANOSECONDS)
                } catch (e: Exception) {
                    null
                }
            }
        } finally {
            pool.shutdownNow()
        }
    }

    /** Blocking (call off the main thread). The address of the coin box with [deviceId], or null. */
    fun find(ownIp: String, previous: String?, deviceId: String, newSocket: () -> Socket = { Socket() }): String? {
        val port = previous?.let { LocalHttp.parseLocalAddress(it)?.second } ?: 80
        val hosts = candidates(ownIp, previous, port)
        if (hosts.isEmpty()) return null
        val http = LocalHttp(connectTimeoutMs = 700, readTimeoutMs = 1500, maxResponseBytes = 4096, newSocket = newSocket)
        val pool = Executors.newFixedThreadPool(THREADS)
        try {
            val done = ExecutorCompletionService<String?>(pool)
            hosts.forEach { host ->
                done.submit(Callable {
                    try {
                        val r = http.get(host, "/api/v1/info")
                        if (r.status == 200 && infoDeviceId(r.body) == deviceId) host else null
                    } catch (e: Exception) {
                        null
                    }
                })
            }
            repeat(hosts.size) {
                val found = done.poll(10, TimeUnit.SECONDS)?.get() ?: return@repeat
                return found
            }
            return null
        } finally {
            pool.shutdownNow()
        }
    }
}
