plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
    namespace = "com.v2rayag.v2rayag"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.v2rayag.v2rayag"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // v10.1.2: a stable release keystore, so releases update
    // over each other instead of failing with "package
    // conflicts". The keystore itself lives only in the repo's
    // GitHub secrets (KEYSTORE_BASE64); CI decodes it and
    // passes its path + passwords through the environment.
    // Local builds without those variables keep the old
    // debug-signing fallback, so `flutter run --release`
    // still works on a dev machine.
    signingConfigs {
        create("release") {
            val ksFile = System.getenv("KEYSTORE_FILE")
            if (ksFile != null) {
                storeFile = file(ksFile)
                storePassword = System.getenv("KEYSTORE_PASSWORD")
                keyAlias = System.getenv("KEY_ALIAS")
                keyPassword = System.getenv("KEY_PASSWORD")
                storeType = "PKCS12"
            }
        }
    }

    buildTypes {
        release {
            if (System.getenv("V2RAYAG_RELEASE_SIGNING") == "true") {
                val ksFile = System.getenv("KEYSTORE_FILE")
                if (ksFile == null || !file(ksFile).exists()) {
                    throw org.gradle.api.GradleException("V2RAYAG_RELEASE_SIGNING=true but the release keystore is missing — refusing to ship a debug-signed release")
                }
                signingConfig = signingConfigs.getByName("release")
            } else {
                signingConfig = signingConfigs.getByName("debug")
            }
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

repositories {
    maven { url = uri("https://raw.github.com/Psiphon-Labs/psiphon-tunnel-core-Android-library/master") }
}

dependencies {
    implementation("ca.psiphon:psiphontunnel:2.0.41")
}
