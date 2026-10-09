# Ordo · Android 端混淆规则（release 构建使用）

# —— 保留 shared:core 的公开 API（KMP 导出面，混淆会破坏序列化字段名）——
-keep class com.ordo.core.** { *; }
-keepclassmembers class com.ordo.core.** { *; }

# —— Kotlin ——
-dontwarn kotlin.**
-keepclassmembers class kotlin.Metadata { *; }
-keepattributes RuntimeVisibleAnnotations,AnnotationDefault,Signature,InnerClasses,EnclosingMethod

# —— kotlinx.serialization（仅用运行时 JsonElement API，保留 Companion 与序列化器）——
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.**
-keepclassmembers class kotlinx.serialization.json.** { *; }
-keepclasseswithmembers class kotlinx.serialization.json.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# —— Ktor / OkHttp ——
-dontwarn org.slf4j.**
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn org.conscrypt.**
-dontwarn kotlinx.coroutines.**
-keep class io.ktor.client.engine.okhttp.** { *; }

# —— 本地存储：原生 SQLiteOpenHelper（无注解处理，无需额外保留规则）——
# 实体以 JSON 快照整行存放，序列化器全部来自 shared:core（已由上面的 -keep com.ordo.core.** 保留）

# —— WorkManager ——
-keep class * extends androidx.work.ListenableWorker { <init>(...); }
-keep class * extends androidx.work.CoroutineWorker { <init>(...); }

# 调试信息保留行号，便于线上问题定位（不打印 token / 口令 / 备注正文，契约 §9）
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
