package online.ebnleadgen.vendokiosk.service

import android.Manifest
import android.annotation.SuppressLint
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.wifi.ScanResult
import android.net.wifi.WifiConfiguration
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log
import online.ebnleadgen.vendokiosk.kiosk.KioskDeviceAdminReceiver
import java.net.Inet4Address
import java.net.Socket

/**
 * Wi-Fi for the administrator screen. In the kiosk the Settings app is never
 * reachable, so the tablet joins the shop Wi-Fi from here.
 *
 * Joining and listing networks use Device Owner privileges: since Android 10
 * only Device Owner, Profile Owner and system apps may add networks directly.
 * Reading the network name and scanning need location permission (granted by
 * the Device Owner) and location turned on.
 */
class WifiAdmin(context: Context) {
    private companion object {
        const val TAG = KioskDeviceAdminReceiver.TAG
    }

    private val ctx = context.applicationContext
    private val wifi = ctx.getSystemService(WifiManager::class.java)
    private val cm = ctx.getSystemService(ConnectivityManager::class.java)
    private val dpm = ctx.getSystemService(DevicePolicyManager::class.java)
    private val admin = KioskDeviceAdminReceiver.component(ctx)

    private fun isDeviceOwner() = dpm.isDeviceOwnerApp(ctx.packageName)

    /** The Wi-Fi network, even when Android prefers mobile data because the Wi-Fi has no internet. */
    @Suppress("DEPRECATION")
    fun wifiNetwork(): Network? = try {
        cm.allNetworks.firstOrNull { cm.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true }
    } catch (e: Exception) {
        null
    }

    /** A socket bound to the Wi-Fi network (falls back to the default network). */
    fun newLocalSocket(): Socket = wifiNetwork()?.socketFactory?.createSocket() ?: Socket()

    /** The tablet's private IPv4 address on the Wi-Fi. */
    fun ownIp(): String? = wifiNetwork()?.let { cm.getLinkProperties(it) }?.let(::ipv4)

    private fun ipv4(lp: LinkProperties): String? =
        lp.linkAddresses.map { it.address }.firstOrNull { it is Inet4Address && it.isSiteLocalAddress }?.hostAddress

    /**
     * Grants this app location permission (Device Owner) and turns location on
     * (Android 11+), which Android requires to show network names and scan.
     */
    private fun ensureLocation(turnOn: Boolean): Boolean {
        if (isDeviceOwner() && ctx.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            try {
                dpm.setPermissionGrantState(admin, ctx.packageName, Manifest.permission.ACCESS_FINE_LOCATION,
                    DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED)
            } catch (e: Exception) {
                Log.w(TAG, "Could not grant location permission: $e")
            }
        }
        val lm = ctx.getSystemService(LocationManager::class.java)
        if (turnOn && !lm.isLocationEnabled && isDeviceOwner() && Build.VERSION.SDK_INT >= 30) {
            try {
                dpm.setLocationEnabled(admin, true)
            } catch (e: Exception) {
                Log.w(TAG, "Could not turn location on: $e")
            }
        }
        return ctx.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED &&
            lm.isLocationEnabled
    }

    private fun cleanSsid(raw: String?): String? =
        raw?.removeSurrounding("\"")?.takeIf { it.isNotEmpty() && it != WifiManager.UNKNOWN_SSID && it != "<unknown ssid>" }

    @Suppress("DEPRECATION")
    fun status(): Map<String, Any?> {
        val located = ensureLocation(turnOn = false)
        val net = wifiNetwork()
        val caps = net?.let { cm.getNetworkCapabilities(it) }
        val lp = net?.let { cm.getLinkProperties(it) }
        val info: WifiInfo? = (if (Build.VERSION.SDK_INT >= 31) caps?.transportInfo as? WifiInfo else null) ?: wifi.connectionInfo
        val defaultIsWifi = cm.getNetworkCapabilities(cm.activeNetwork)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        val gateway = lp?.routes?.firstOrNull { it.isDefaultRoute && it.gateway is Inet4Address }?.gateway?.hostAddress
        return mapOf(
            "enabled" to wifi.isWifiEnabled,
            "connected" to (net != null),
            "ssid" to cleanSsid(info?.ssid),
            "ssidHidden" to (net != null && cleanSsid(info?.ssid) == null),
            "locationReady" to located,
            "ip" to lp?.let(::ipv4),
            "gateway" to gateway,
            "rssi" to info?.rssi?.takeIf { net != null && it > -127 },
            "linkMbps" to info?.linkSpeed?.takeIf { net != null && it > 0 },
            "frequencyMhz" to info?.frequency?.takeIf { net != null && it > 0 },
            "internet" to (caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true),
            // Android sends traffic over mobile data when the Wi-Fi has no internet.
            "defaultIsWifi" to defaultIsWifi,
            "deviceOwner" to isDeviceOwner(),
        )
    }

    fun setEnabled(on: Boolean) {
        requireOwner()
        @Suppress("DEPRECATION")
        if (!wifi.setWifiEnabled(on)) throw CodedError("wifi_toggle_failed")
    }

    /** Networks in range, strongest first, one entry per name. Starts a new scan (Android limits how often). */
    @SuppressLint("MissingPermission")
    fun scan(): List<Map<String, Any?>> {
        requireOwner()
        if (!wifi.isWifiEnabled) throw CodedError("wifi_off")
        if (!ensureLocation(turnOn = true)) throw CodedError("location_off")
        @Suppress("DEPRECATION")
        wifi.startScan() // may be throttled; the last results are still returned
        Thread.sleep(2500)
        val current = cleanSsid(status()["ssid"] as String?)
        return wifi.scanResults
            .mapNotNull { r -> ssidOf(r)?.let { it to r } }
            .groupBy({ it.first }, { it.second })
            .map { (ssid, rs) ->
                val best = rs.maxBy { it.level }
                mapOf(
                    "ssid" to ssid,
                    "rssi" to best.level,
                    "frequencyMhz" to best.frequency,
                    "security" to securityOf(best),
                    "connected" to (ssid == current),
                )
            }
            .sortedWith(compareByDescending<Map<String, Any?>> { it["connected"] == true }.thenByDescending { it["rssi"] as Int })
    }

    @Suppress("DEPRECATION")
    private fun ssidOf(r: ScanResult): String? =
        (if (Build.VERSION.SDK_INT >= 33) r.wifiSsid?.toString() else r.SSID).let(::cleanSsid)

    private fun securityOf(r: ScanResult): String {
        val c = r.capabilities
        return when {
            c.contains("SAE") && !c.contains("PSK") -> "wpa3"
            c.contains("PSK") || c.contains("SAE") -> "wpa2"
            c.contains("EAP") -> "enterprise"
            c.contains("WEP") -> "wep"
            else -> "open"
        }
    }

    /**
     * Joins [ssid] (and remembers it). [security] is "open", "wpa2" or "wpa3".
     * Returns when Android accepted the network; the connection itself takes a
     * few seconds and shows up in [status].
     */
    @SuppressLint("MissingPermission")
    @Suppress("DEPRECATION")
    fun connect(ssid: String, password: String, security: String) {
        requireOwner()
        val name = ssid.trim()
        if (name.isEmpty() || name.length > 32) throw CodedError("bad_ssid")
        when (security) {
            "open" -> Unit
            "wpa2", "wpa3" -> if (password.length !in 8..63) throw CodedError("bad_wifi_password")
            else -> throw CodedError("unsupported_security")
        }
        if (!wifi.isWifiEnabled && !wifi.setWifiEnabled(true)) throw CodedError("wifi_off")
        ensureLocation(turnOn = false)
        val quoted = "\"$name\""
        // Replace an older saved entry for the same name (e.g. a changed password).
        try {
            wifi.configuredNetworks?.filter { it.SSID == quoted }?.forEach { wifi.removeNetwork(it.networkId) }
        } catch (e: SecurityException) {
            Log.w(TAG, "Could not read saved networks: $e")
        }
        val conf = WifiConfiguration().apply {
            SSID = quoted
            if (security != "open") preSharedKey = "\"$password\""
            if (Build.VERSION.SDK_INT >= 30) {
                setSecurityParams(when (security) {
                    "open" -> WifiConfiguration.SECURITY_TYPE_OPEN
                    "wpa3" -> WifiConfiguration.SECURITY_TYPE_SAE
                    else -> WifiConfiguration.SECURITY_TYPE_PSK
                })
            } else {
                allowedKeyManagement.set(when (security) {
                    "open" -> WifiConfiguration.KeyMgmt.NONE
                    "wpa3" -> WifiConfiguration.KeyMgmt.SAE
                    else -> WifiConfiguration.KeyMgmt.WPA_PSK
                })
            }
        }
        val id = wifi.addNetwork(conf)
        if (id == -1) throw CodedError("wifi_add_failed")
        if (!wifi.enableNetwork(id, true)) throw CodedError("wifi_connect_failed")
        wifi.reconnect()
        Log.i(TAG, "Joining Wi-Fi network (id $id)")
    }

    private fun requireOwner() {
        if (!isDeviceOwner()) throw CodedError("not_device_owner")
    }

    /** Carries a machine-readable code to Flutter. */
    class CodedError(val code: String) : Exception(code)
}
