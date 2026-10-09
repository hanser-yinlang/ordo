package com.ordo.android

import com.ordo.core.platform.FixedOrdoClock
import com.ordo.core.platform.PlatformTime
import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.store.OrdoEngine
import com.ordo.core.util.OrdoDate

/**
 * 测试公共设施。
 *
 * 说明：Android 端最初自建的内存仓储已由共享核心的
 * `com.ordo.core.storage.InMemoryStorage` 取代（同一 `OrdoStorage` 接口、同一行为），
 * 因此本文件只保留"固定时钟 + 引擎工厂"，让所有断言完全确定、与真实时间无关。
 */
object TestSupport {

    /** 契约 §5 的示例基准日：2026-10-08（周四） */
    const val TODAY = "2026-10-08"

    /** 默认的"现在"：本地时间 09:00 */
    const val NOW_HHMM = "09:00"

    private const val MS_PER_DAY = 86_400_000L

    /** 把某个本地日期时刻转成"让引擎认为今天是该日期"的时钟 */
    fun clock(date: String = TODAY, hour: Int = 9, minute: Int = 0): FixedOrdoClock {
        val parts = OrdoDate.parseISO(date) ?: error("非法日期：$date")
        val localMillis = OrdoDate.epochDayOf(parts[0], parts[1], parts[2]) * MS_PER_DAY +
            hour * 3_600_000L + minute * 60_000L
        return FixedOrdoClock(localMillis - PlatformTime.utcOffsetMillis())
    }

    /** 固定时钟下的"当前毫秒"，用于构造"更新的远端 op" */
    fun nowMillis(date: String = TODAY, hour: Int = 9): Long = clock(date, hour).nowMillis()

    fun engine(date: String = TODAY): OrdoEngine = OrdoEngine(
        storage = InMemoryStorage(),
        clock = clock(date),
        uuid = { "test-" + idSeq++ },
    )

    private var idSeq = 0

    /** 相对基准日的日期字符串 */
    fun day(offset: Int, from: String = TODAY): String = OrdoDate.plusDays(from, offset)
}
