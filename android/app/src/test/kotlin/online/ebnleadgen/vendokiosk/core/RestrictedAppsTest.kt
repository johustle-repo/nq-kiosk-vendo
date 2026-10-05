package online.ebnleadgen.vendokiosk.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RestrictedAppsTest {
    @Test
    fun settingsAndPlayStoreAreNeverApprovable() {
        assertTrue(RestrictedApps.isRestricted("com.android.settings"))
        assertTrue(RestrictedApps.isRestricted("com.android.vending"))
        assertTrue(RestrictedApps.isRestricted("com.google.android.packageinstaller"))
        assertFalse(RestrictedApps.isRestricted("com.google.android.youtube"))
    }

    @Test
    fun filterDropsRestrictedAndKeepsOrder() {
        val approved = listOf("com.android.chrome", "com.android.vending", "com.google.android.youtube", "com.android.settings")
        assertEquals(listOf("com.android.chrome", "com.google.android.youtube"), RestrictedApps.filter(approved))
    }
}
