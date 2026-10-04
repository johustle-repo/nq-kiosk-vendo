package online.ebnleadgen.vendokiosk.bridge

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.os.Build
import java.io.ByteArrayOutputStream

/** Lists launchable apps (visible via the scoped <queries> LAUNCHER intent) with icons. */
class AppCatalog(private val context: Context) {
    private val pm = context.packageManager
    private val iconCache = HashMap<String, ByteArray>()

    fun launchableApps(includeIcons: Boolean, only: Set<String>? = null): List<Map<String, Any?>> {
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val seen = HashSet<String>()
        val resolved = if (Build.VERSION.SDK_INT >= 33) {
            pm.queryIntentActivities(intent, PackageManager.ResolveInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            pm.queryIntentActivities(intent, 0)
        }
        return resolved
            .mapNotNull { ri ->
                val pkg = ri.activityInfo.packageName
                if (pkg == context.packageName || !seen.add(pkg)) return@mapNotNull null
                if (only != null && pkg !in only) return@mapNotNull null
                mapOf(
                    "packageName" to pkg,
                    "label" to ri.loadLabel(pm).toString(),
                    "icon" to if (includeIcons) iconPng(pkg) { ri.loadIcon(pm) } else null,
                )
            }
            .sortedBy { (it["label"] as String).lowercase() }
    }

    private fun iconPng(pkg: String, load: () -> Drawable): ByteArray? = iconCache.getOrPut(pkg) {
        try {
            val d = load()
            val size = 144
            val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val c = Canvas(bmp)
            d.setBounds(0, 0, size, size)
            d.draw(c)
            ByteArrayOutputStream().use { out ->
                bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
                out.toByteArray()
            }
        } catch (e: Exception) {
            return null
        }
    }

    fun launchIntent(pkg: String): Intent? = pm.getLaunchIntentForPackage(pkg)
}
