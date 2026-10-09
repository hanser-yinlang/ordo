package com.ordo.android.data

import com.ordo.core.model.CalendarEvent
import com.ordo.core.model.OrdoSnapshot
import com.ordo.core.seed.SeedData as CoreSeed
import com.ordo.core.util.OrdoDate

/**
 * 示例数据入口（与 Web 原型同规模：4 区域 / 5 项目 / 3 标题 / 7 标签 / 30+ 待办 / 3 日历事件）。
 *
 * 内容由共享核心统一提供（`com.ordo.core.seed.SeedData`），Android 端不再复制一份，
 * 避免四端出现"两份示例数据"；写入时机由 `OrdoEngine.seedDemoData()` 负责（契约 §8）。
 */
object SeedData {

    /** 全量演示快照（首次启动写入本地库用） */
    fun snapshot(
        now: Long = System.currentTimeMillis(),
        today: String = OrdoDate.todayISO(),
    ): OrdoSnapshot = CoreSeed.demo(now, today)

    /** 设备本地只读日历事件（契约 §2.8：仅本地读取，不上传、不同步） */
    fun events(today: String = OrdoDate.todayISO()): List<CalendarEvent> = CoreSeed.events(today)
}
