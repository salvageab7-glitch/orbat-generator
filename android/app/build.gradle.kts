plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigningValues = listOf(
    System.getenv("ORBAT_RELEASE_KEYSTORE"),
    System.getenv("ORBAT_RELEASE_STORE_PASSWORD"),
    System.getenv("ORBAT_RELEASE_KEY_ALIAS"),
    System.getenv("ORBAT_RELEASE_KEY_PASSWORD"),
)
val releaseSigningConfigured = releaseSigningValues.all { !it.isNullOrBlank() }
if (releaseSigningValues.any { !it.isNullOrBlank() } && !releaseSigningConfigured) {
    throw GradleException(
        "Release signing requires ORBAT_RELEASE_KEYSTORE, ORBAT_RELEASE_STORE_PASSWORD, " +
            "ORBAT_RELEASE_KEY_ALIAS, and ORBAT_RELEASE_KEY_PASSWORD."
    )
}

android {
    namespace = "com.orbat.orbat_core"
    // 固定 36：file_picker 等插件要求 compileSdk >= 36（flutter 默认值偏低）
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.orbat.orbat_core"
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

    if (releaseSigningConfigured) {
        signingConfigs.create("release") {
            storeFile = file(requireNotNull(releaseSigningValues[0]))
            storePassword = requireNotNull(releaseSigningValues[1])
            keyAlias = requireNotNull(releaseSigningValues[2])
            keyPassword = requireNotNull(releaseSigningValues[3])
        }
    }

    // lint 在分析 webview_flutter_android 生成的 Kotlin 文件时自身崩溃（lint 内部缺陷），
    // 会阻断 release 构建；这里关闭 release 的 lint 检查，不影响编译与打包。
    lint {
        checkReleaseBuilds = false
    }

    buildTypes {
        release {
            // 正式签名：配置了 ORBAT_RELEASE_* 时使用正式 keystore。
            // 测试/侧载期（未配置正式签名）沿用 debug 证书签名，便于覆盖安装。
            if (!releaseSigningConfigured) {
                logger.warn(
                    "ORBAT_RELEASE_* not set: release APK will use DEBUG signing. " +
                        "Sideload/testing only; do not publish this package as a production release."
                )
            }
            signingConfig = if (releaseSigningConfigured) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
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
