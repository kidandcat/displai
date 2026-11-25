import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.kidandcat.minerva"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.kidandcat.minerva"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }
    }

    packaging {
        jniLibs {
            // On the phone Minerva is only a remote: speech recognition and the voice run on the
            // desktop, so the local voice engine (sherpa-onnx) stays out of the APK.
            excludes += listOf("**/libonnxruntime.so", "**/libsherpa-onnx-*.so")
        }
    }

    // Release signing: android/key.properties (storeFile, storePassword, keyAlias, keyPassword) or
    // the MINERVA_KEYSTORE* environment variables (CI). Without either, the release build is signed
    // with the debug keys, so `flutter run --release` and forks' CI builds still work.
    val keyProperties = Properties().apply {
        val file = rootProject.file("key.properties")
        if (file.exists()) file.inputStream().use { load(it) }
    }
    fun signingValue(property: String, env: String): String? =
        keyProperties.getProperty(property) ?: System.getenv(env)?.takeIf { it.isNotEmpty() }
    val releaseStoreFile = signingValue("storeFile", "MINERVA_KEYSTORE_FILE")

    signingConfigs {
        if (releaseStoreFile != null) {
            create("release") {
                storeFile = rootProject.file(releaseStoreFile)
                storePassword = signingValue("storePassword", "MINERVA_KEYSTORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "MINERVA_KEY_ALIAS")
                keyPassword = signingValue("keyPassword", "MINERVA_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (releaseStoreFile != null) "release" else "debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
