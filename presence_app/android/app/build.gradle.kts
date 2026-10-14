import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing with the upload key (Google Play re-signs uploads with
// its own app signing key), from either:
//   - the environment: ANDROID_KEYSTORE_PATH, ANDROID_KEYSTORE_PASSWORD,
//     ANDROID_KEY_ALIAS (default "upload") and ANDROID_KEY_PASSWORD (default
//     the keystore's password), as the release workflow sets them; or
//   - android/key.properties (ignored by git): storeFile (absolute, or
//     relative to android/), storePassword, keyAlias, keyPassword.
// The environment wins when ANDROID_KEYSTORE_PATH is set. With neither,
// release builds are signed with the debug key, so `flutter run --release`
// and scripts/android-install.sh keep working, but a release App Bundle
// (`flutter build appbundle`: the store build) fails instead of producing
// a bundle Play would reject. scripts/android-upload-key.sh creates the key.
val keyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

fun nonBlank(value: String?): String? = value?.takeIf { it.isNotBlank() }

val signingFromEnv = nonBlank(System.getenv("ANDROID_KEYSTORE_PATH")) != null
val signingSource = if (signingFromEnv) "ANDROID_KEYSTORE_PATH" else "android/key.properties"

fun signingSetting(property: String, env: String): String? =
    if (signingFromEnv) nonBlank(System.getenv(env)) else nonBlank(keyProperties.getProperty(property))

val uploadStoreFile = signingSetting("storeFile", "ANDROID_KEYSTORE_PATH")?.let { rootProject.file(it) }
val uploadStorePassword = signingSetting("storePassword", "ANDROID_KEYSTORE_PASSWORD")
val uploadKeyAlias = signingSetting("keyAlias", "ANDROID_KEY_ALIAS") ?: "upload"
val uploadKeyPassword = signingSetting("keyPassword", "ANDROID_KEY_PASSWORD") ?: uploadStorePassword
val hasUploadKey = uploadStoreFile != null

// A key that's named but unusable is an error, never a quiet debug build.
if (uploadStoreFile != null) {
    if (!uploadStoreFile.isFile) {
        throw GradleException("Release signing: the keystore $uploadStoreFile (from $signingSource) doesn't exist")
    }
    if (uploadStorePassword == null) {
        throw GradleException("Release signing: $signingSource names a keystore but no password")
    }
}

// An App Bundle is only ever built for Google Play: never sign one with
// the debug key.
val buildsReleaseBundle = gradle.startParameter.taskNames.any {
    val task = it.substringAfterLast(':')
    task.startsWith("bundle") && task.endsWith("Release")
}
if (buildsReleaseBundle && !hasUploadKey) {
    throw GradleException(
        "A release App Bundle needs the upload key: set ANDROID_KEYSTORE_PATH and " +
            "ANDROID_KEYSTORE_PASSWORD, or write android/key.properties " +
            "(see scripts/android-upload-key.sh). Refusing to sign it with the debug key.",
    )
}

android {
    namespace = "com.nu01.presence"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.nu01.presence"
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
    }

    signingConfigs {
        if (hasUploadKey) {
            create("upload") {
                storeFile = uploadStoreFile
                storePassword = uploadStorePassword
                keyAlias = uploadKeyAlias
                keyPassword = uploadKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // The upload key when there is one (above), else the debug key.
            signingConfig = signingConfigs.getByName(if (hasUploadKey) "upload" else "debug")
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

dependencies {
    // Play services' sign-in, for the silent re-sign-in of the remembered
    // account (GoogleSilentSignIn). google_sign_in_android uses the same
    // version, but doesn't expose it to the app.
    implementation("com.google.android.gms:play-services-auth:21.6.0")
}
