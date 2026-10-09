package com.ordo.core.platform

import java.util.TimeZone

actual object PlatformTime {
    actual fun nowMillis(): Long = System.currentTimeMillis()

    actual fun utcOffsetMillis(): Long =
        TimeZone.getDefault().getOffset(System.currentTimeMillis()).toLong()
}
