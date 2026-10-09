// Ordo · Android 端应用模块
// 依赖版本一律走根 gradle/libs.versions.toml 的别名，本文件不写死版本号。
// 本模块需要的全部别名清单见 apps/android/README.md「接口与别名对齐清单」。

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.compose.compiler)
}

android {
    namespace = "com.ordo.android"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.ordo.android"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "1.0.0"
        // 契约 §7.4：客户端标识头 X-Ordo-Client: android/1.0.0
        buildConfigField("String", "ORDO_SCHEMA", "\"1\"")
        buildConfigField("String", "ORDO_CLIENT", "\"android/1.0.0\"")
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
            excludes += "/META-INF/versions/9/OSGI-INF/MANIFEST.MF"
        }
    }

    // 单元测试（NlpParsingTest / QueryRulesTest / RepeatEngineTest / SyncMergeTest）
    // 只依赖 shared:core 与 JVM 测试库，不依赖 Android 框架。
    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

// 说明:本地存储使用原生 SQLiteOpenHelper(见 data/SqliteStorage.kt),
// 刻意不引入 Room/KSP —— 注解处理器版本与 Kotlin 版本强耦合,会带来构建风险(架构 ADR-005)。

dependencies {
    // —— 冻结的共享核心（只调用，不修改）——
    implementation(project(":shared:core"))

    // —— 目录中已列出的别名 ——
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.navigation.compose)
    implementation(libs.androidx.work.runtime.ktx)
    implementation(libs.androidx.datastore.preferences)
    implementation(libs.ktor.client.okhttp)
    implementation(libs.ktor.client.content.negotiation)
    implementation(libs.ktor.client.websockets)
    implementation(libs.ktor.serialization.kotlinx.json)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.datetime)
    implementation(libs.kotlinx.coroutines.android)

    // —— Compose 基础：需在根 libs.versions.toml 中存在（见 README 对齐清单）——
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.ui.tooling.preview)
    debugImplementation(libs.androidx.compose.ui.tooling)

    // —— 测试：JUnit4 + kotlin.test ——
    testImplementation(libs.junit)
    testImplementation(libs.kotlin.test)
    testImplementation(libs.kotlinx.coroutines.test)
}
