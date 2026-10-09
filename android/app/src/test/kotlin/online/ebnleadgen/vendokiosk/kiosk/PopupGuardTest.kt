package online.ebnleadgen.vendokiosk.kiosk

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PopupGuardTest {
    @Test
    fun matchesTheBlockedAppBox() {
        assertTrue(PopupGuardService.isBlockedAppBox("com.android.internal.app.BlockedAppActivity", ""))
        assertTrue(
            PopupGuardService.isBlockedAppBox(
                "android.app.Dialog",
                "App is not available Android System is not available right now. OK",
            )
        )
        assertTrue(
            PopupGuardService.isBlockedAppBox(
                "android.app.AlertDialog",
                "App is not available Chrome is not available right now. OK",
            )
        )
    }

    @Test
    fun leavesOtherSystemDialogsAlone() {
        assertFalse(PopupGuardService.isBlockedAppBox("android.app.Dialog", "Allow USB debugging?"))
        assertFalse(PopupGuardService.isBlockedAppBox("com.android.internal.app.ChooserActivity", "Open with"))
        assertFalse(PopupGuardService.isBlockedAppBox(null, "not available"))
    }
}
