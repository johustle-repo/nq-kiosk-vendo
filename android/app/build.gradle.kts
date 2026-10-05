import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing key, kept outside the repo (android/key.properties is gitignored).
// Device Owner apps are tied to their signing key: changing the key later
// requires re-provisioning (factory reset) the kiosk phone. Back the key up.
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "online.ebnleadgen.vendokiosk"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    buildFeatures {
        buildConfig = true
    }

    defaultConfig {
        applicationId = "online.ebnleadgen.vendokiosk"
        // API 29+: typed foreground services (startForeground with a type) and lock task features.
        minSdk = maxOf(29, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Cloud API base. HTTPS only; certificates are verified by the platform.
        buildConfigField("String", "CLOUD_API_BASE", "\"https://vendo-kiosk.ebnleadgen.online/api/v1\"")
    }

    signingConfigs {
        if (keystoreProperties.containsKey("storeFile")) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // No silent fallback to the debug key: a release build without
            // android/key.properties fails instead of producing an APK that
            // would lock the Device Owner phone to the wrong key.
            val release = signingConfigs.findByName("release")
            if (release == null && gradle.startParameter.taskNames.any { it.contains("Release") }) {
                throw GradleException("android/key.properties missing: release signing key not configured")
            }
            signingConfig = release
        }
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    // org.json is part of Android but stubbed in local JVM unit tests.
    testImplementation("org.json:json:20240303")
}

flutter {
    source = "../.."
}
