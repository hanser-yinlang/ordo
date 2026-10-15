// Ordo · Windows 桌面端应用模块(Compose Multiplatform Desktop)
// 依赖一律走根 gradle/libs.versions.toml 的别名或 Compose 插件的 compose.* 访问器,不写死版本号。
// 业务逻辑全部来自冻结的共享核心 :shared:core —— 本模块只做 UI、本地存储与系统集成。
//
// **纯本地应用(2026-10-13 产品决策:云同步彻底删除)**:这里**没有任何网络依赖** ——
// Ktor / WebSocket / 序列化 HTTP 客户端全部移除,类路径上不存在 HTTP 客户端(见 NoNetworkTest 的断言)。

import org.jetbrains.compose.desktop.application.dsl.TargetFormat

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.compose.multiplatform)
    alias(libs.plugins.compose.compiler)
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

// —— NSIS 安装包(每用户安装,不需要管理员)——
//
// 用 **Tauri bundler 下载的那份 NSIS 3.11** 编译(`%LOCALAPPDATA%\tauri\NSIS\makensis.exe`),
// 脚本在 `installer/Ordo.nsi`。注意这里并没有引入 Tauri 外壳:本端是 Compose Multiplatform(JVM)
// 桌面应用,Tauri 的 WebView 外壳对它没有意义(理由见 README §2「为什么不是 Tauri 应用」),
// 要的只是 Tauri 已经在机器上备好的这个 NSIS 打包器。
//
// 产物:build/compose/binaries/main/nsis/Ordo_1.0.0_x64-setup.exe
// 依赖 createDistributable 且把 app-image 声明为输入,所以源码变了会重新打(踩过坑:
// jpackage 那套在 app-image 陈旧时可能仍然 UP-TO-DATE,打出来的安装包是旧代码)。
val packageNsis by tasks.registering(Exec::class) {
    group = "compose desktop"
    description = "用 NSIS 打每用户安装包(不需要管理员;与 Tauri bundler 共用同一份 NSIS)"

    dependsOn("createDistributable")

    val imageDir = layout.buildDirectory.dir("compose/binaries/main/app/Ordo")
    val outFile = layout.buildDirectory.file("compose/binaries/main/nsis/Ordo_1.0.0_x64-setup.exe")
    val scriptFile = project.file("installer/Ordo.nsi")
    val iconFile = project.file("icons/ordo-ring.ico")

    inputs.dir(imageDir)
    inputs.file(scriptFile)
    inputs.file(iconFile)
    outputs.file(outFile)

    doFirst {
        val makensis = listOf(
            System.getenv("LOCALAPPDATA")?.let { File(it, "tauri/NSIS/makensis.exe") },
            File("C:/Program Files (x86)/NSIS/makensis.exe"),
            File("C:/Program Files/NSIS/makensis.exe"),
        ).filterNotNull().firstOrNull { it.isFile }
            ?: throw GradleException(
                "找不到 makensis.exe。装一个 NSIS 3.x,或先让 Tauri CLI 下载一份" +
                    "(会落在 %LOCALAPPDATA%\\tauri\\NSIS),见 apps/windows/README.md §2。"
            )

        val out = outFile.get().asFile
        out.parentFile.mkdirs()
        // 脚本是 UTF-8(无 BOM),必须显式告诉 makensis,否则它按 GBK 读会报 Bad text encoding
        commandLine(
            makensis.absolutePath,
            "/INPUTCHARSET", "UTF8",
            "/DSRC_DIR=${imageDir.get().asFile.absolutePath}",
            "/DOUT_FILE=${out.absolutePath}",
            "/DAPP_ICON=${iconFile.absolutePath}",
            scriptFile.absolutePath,
        )
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
