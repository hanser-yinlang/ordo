package com.ordo.core.platform

import platform.Foundation.NSDate
import platform.Foundation.NSTimeZone
import platform.Foundation.localTimeZone
import platform.Foundation.secondsFromGMT
import platform.Foundation.timeIntervalSince1970

/** iOS 实现(Framework 由 macOS 构建;Windows 上不编译该目标) */
actual object PlatformTime {
    actual fun nowMillis(): Long = (NSDate().timeIntervalSince1970 * 1000.0).toLong()

    actual fun utcOffsetMillis(): Long =
        (NSTimeZone.localTimeZone.secondsFromGMT * 1000L)
}
