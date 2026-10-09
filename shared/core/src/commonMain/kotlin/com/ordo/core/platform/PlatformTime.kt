package com.ordo.core.platform

/**
 * 平台时间抽象。
 *
 * 共享核心刻意**不依赖 kotlinx-datetime**(避免多端 API 漂移),只向平台要两样东西:
 * 当前 epoch 毫秒 与 本地时区相对 UTC 的偏移。其余日期计算由 [com.ordo.core.util.OrdoDate] 纯 Kotlin 实现,
 * 保证 Android / iOS / Windows 三端结果完全一致,并可注入固定时钟做确定性测试。
 */
expect object PlatformTime {
    /** 当前时间,epoch 毫秒 */
    fun nowMillis(): Long

    /** 本地时区相对 UTC 的偏移(毫秒),东八区为 8*3600*1000 */
    fun utcOffsetMillis(): Long
}

/** 可注入时钟:生产用 [SystemOrdoClock],测试用 [FixedOrdoClock] */
fun interface OrdoClock {
    fun nowMillis(): Long
}

object SystemOrdoClock : OrdoClock {
    override fun nowMillis(): Long = PlatformTime.nowMillis()
}

class FixedOrdoClock(private var millis: Long) : OrdoClock {
    override fun nowMillis(): Long = millis
    fun advanceTo(newMillis: Long) { millis = newMillis }
    fun advanceBy(deltaMillis: Long) { millis += deltaMillis }
}
