import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.konan.target.HostManager

plugins {
    alias(libs.plugins.kotlin.multiplatform)
    alias(libs.plugins.kotlin.serialization)
}

/**
 * Ordo 共享核心(KMP)
 *
 * 目标平台:
 *  - `jvm`   :Windows 桌面端 + 共享核心单元测试(本机即可构建)
 *  - `android`:Android 端;**仅当本机存在 Android SDK 时启用**(无 SDK 环境仍可构建 jvm 与跑测试)
 *  - `ios*`  :iOS 端;**仅 macOS 主机启用**(Kotlin/Native 无法在 Windows 上编译 Apple 目标)
 */
val androidSdkPresent: Boolean = System.getenv("ANDROID_HOME") != null ||
    System.getenv("ANDROID_SDK_ROOT") != null ||
    rootProject.file("local.properties").exists()

if (androidSdkPresent) {
    apply(plugin = "com.android.library")
    extensions.configure<com.android.build.gradle.LibraryExtension>("android") {
        namespace = "com.ordo.core"
        compileSdk = 36
        defaultConfig {
            minSdk = 26
        }
        compileOptions {
            sourceCompatibility = JavaVersion.VERSION_17
            targetCompatibility = JavaVersion.VERSION_17
        }
    }
}

kotlin {
    jvm()

    if (androidSdkPresent) {
        androidTarget {
            compilerOptions {
                jvmTarget.set(JvmTarget.JVM_17)
            }
        }
    }

    if (HostManager.hostIsMac) {
        listOf(iosX64(), iosArm64(), iosSimulatorArm64()).forEach { target ->
            target.binaries.framework {
                baseName = "OrdoCore"
                isStatic = true
            }
        }
    }

    sourceSets {
        commonMain.dependencies {
            api(libs.kotlinx.coroutines.core)
            api(libs.kotlinx.serialization.json)
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
            implementation(libs.kotlinx.coroutines.test)
        }
        jvmTest.dependencies {
            implementation(libs.junit)
        }
    }

    jvmToolchain(21)
}
