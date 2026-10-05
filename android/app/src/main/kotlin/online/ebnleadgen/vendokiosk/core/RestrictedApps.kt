package online.ebnleadgen.vendokiosk.core

/**
 * Apps a customer must never get, whatever the administrator or the cloud
 * dashboard approves: they would let customers leave the kiosk (Settings) or
 * install software and sign in accounts that stay on the shared device (app
 * stores, package installers).
 */
object RestrictedApps {
    val NEVER_APPROVABLE: Set<String> = setOf(
        "com.android.settings",
        "com.android.vending",
        "com.android.packageinstaller",
        "com.google.android.packageinstaller",
    )

    fun isRestricted(packageName: String): Boolean = packageName in NEVER_APPROVABLE

    /** [packages] without the restricted ones, order kept. */
    fun filter(packages: List<String>): List<String> = packages.filterNot(::isRestricted)
}
