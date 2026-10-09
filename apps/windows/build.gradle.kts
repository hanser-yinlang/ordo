// Ordo · Windows 桌面端应用模块(Compose Multiplatform Desktop)
// 依赖一律走根 gradle/libs.versions.toml 的别名或 Compose 插件的 compose.* 访问器,不写死版本号。
// 业务逻辑全部来自冻结的共享核心 :shared:core —— 本模块只做 UI、存储、网络与系统集成。

import org.jetbrains.compose.desktop.application.dsl.TargetFormat

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.compose.multiplatform)
    alias(libs.plugins.compose.compiler)
    alias(libs.plugins.kotlin.serialization)
}

kotlin {
    jvmToolchain(21)
}

dependencies {
    // —— 冻结的共享核心(只调用,不修改)——
    implementation(project(":shared:core"))

    // —— Compose Multiplatform Desktop ——
    // 离屏渲染测试用的 ImageComposeScene 随 desktop.currentOs 一起提供,无需额外的 ui-test 依赖
    implementation(compose.desktop.currentOs)
    implementation(compose.material3)
    implementation(compose.materialIconsExtended)

    // —— 协程(Swing 调度器 = Compose Desktop 的 Main 线程)——
    implementation(libs.kotlinx.coroutines.swing)

    // —— 网络(Ktor CIO,契约 §7.4 / §7.5)——
    implementation(libs.ktor.client.cio)
    implementation(libs.ktor.client.content.negotiation)
    implementation(libs.ktor.client.websockets)
    implementation(libs.ktor.serialization.kotlinx.json)

    // —— 测试 ——
    testImplementation(libs.junit)
}

tasks.withType<Test>().configureEach {
    useJUnit()
    // 离屏渲染:不创建 AWT 窗口,走 Skia 软件后端
    systemProperty("java.awt.headless", "true")
    systemProperty("skiko.renderApi", "SOFTWARE_FAST")
    // 渲染产物输出目录(供 RenderSmokeTest 写 ordo-today.png)
    systemProperty("ordo.reportDir", layout.buildDirectory.dir("reports").get().asFile.absolutePath)
    testLogging {
        events("passed", "failed", "skipped")
        showStandardStreams = true
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}

compose.desktop {
    application {
        mainClass = "com.ordo.desktop.MainKt"

        jvmArgs += listOf(
            "-Dfile.encoding=UTF-8",
            // 部分 Windows 机器上默认渲染后端不可用,显式指定软件后端
            "-Dskiko.renderApi=SOFTWARE_FAST"
        )

        nativeDistributions {
            targetFormats(TargetFormat.Msi, TargetFormat.Exe)
            packageName = "Ordo"
            packageVersion = "1.0.0"
            description = "Ordo(序)—— 把今天理清楚"
            vendor = "Ordo Project"
            copyright = "© 2026 Ordo Project"
            windows {
                menuGroup = "Ordo"
                shortcut = true
                menu = true
                dirChooser = true
                perUserInstall = true
                // 固定 UUID:升级安装时复用同一产品标识
                upgradeUuid = "5B7C1B2E-9A44-4E1D-8C7F-2D6A3E5B9F10"
                // 应用图标(开始菜单/桌面快捷方式/安装包):
                // 多尺寸 ICO(16/24/32/48/64/128/256),由 icons/ 下的 PNG 生成,见 README §13
                iconFile.set(project.file("icons/ordo-ring.ico"))
            }
        }
    }
}
