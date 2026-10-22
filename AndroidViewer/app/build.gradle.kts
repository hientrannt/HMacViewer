plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// CI passes the version; local builds use the defaults.
val appVersion = (System.getenv("HMACVIEWER_VERSION") ?: "0.0.0").ifEmpty { "0.0.0" }
val appBuild = (System.getenv("HMACVIEWER_BUILD_NUMBER") ?: "1").toIntOrNull() ?: 1

android {
    namespace = "io.github.hientrannt.hmacviewer"
    compileSdk = 35

    defaultConfig {
        applicationId = "io.github.hientrannt.hmacviewer"
        minSdk = 24
        targetSdk = 35
        versionCode = appBuild
        versionName = appVersion
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64") }
    }

    // A release keystore from the environment keeps updates installable over
    // each other; without one the release APK is signed with the debug key.
    val keystore = System.getenv("ANDROID_KEYSTORE_FILE")?.let { file(it) }?.takeIf { it.exists() }
    signingConfigs {
        if (keystore != null) {
            create("release") {
                storeFile = keystore
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}
