package com.ordo.core.platform

import java.util.TimeZone

/** Android 目标与 JVM 目标实现相同(android 源集独立于 jvm 源集,故单独提供) */
actual object PlatformTime {
    actual fun nowMillis(): Long = System.currentTimeMillis()

    actual fun utcOffsetMillis(): Long =
        TimeZone.getDefault().getOffset(System.currentTimeMillis()).toLong()
}
