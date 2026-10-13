// Ordo(序)—— 多端待办应用 · Gradle 根设置
// 共享核心 :shared:core 被 Windows / Android 消费;鸿蒙端为 ArkTS 独立实现(见 apps/harmony)
// iOS 端已于 2026-10-13 整体移除(apps/ios 与核心的 Apple 目标一并删除)。
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "ordo"

// —— 共享核心(KMP)——
include(":shared:core")

// —— Windows 桌面端(Compose Multiplatform)——
if (file("apps/windows/build.gradle.kts").exists()) {
    include(":apps:windows")
}

// —— Android 端:仅在检测到 Android SDK 时纳入构建 ——
// 这样在没有 SDK 的环境(如本仓库的 Windows 开发机)也能正常配置并运行共享核心的单元测试。
val androidSdkPresent = System.getenv("ANDROID_HOME") != null ||
    System.getenv("ANDROID_SDK_ROOT") != null ||
    file("local.properties").exists()
if (androidSdkPresent && file("apps/android/app/build.gradle.kts").exists()) {
    include(":apps:android:app")
}
