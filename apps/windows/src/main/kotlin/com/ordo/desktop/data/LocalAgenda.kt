package com.ordo.desktop.data

import com.ordo.core.model.CalendarEvent
import com.ordo.core.storage.OrdoStorage
import com.ordo.core.util.OrdoDate
import com.ordo.core.util.OrdoJson
import kotlinx.serialization.builtins.ListSerializer

/**
 * 日历事件仅本地读取、不上传(契约 §2.8)。
 *
 * 桌面端没有系统日历接入,这里维护一份**设备本地**的日程:
 * 首次启动写入当天示例事件(便于还原"今天"视图版式),之后按日缓存复用。
 * 存储在 `kv.json` 的 `ordo.agenda.<日期>` 键下。
 */
object LocalAgenda {

    private const val KEY_PREFIX = "ordo.agenda."

    fun eventsFor(storage: OrdoStorage, today: String = OrdoDate.todayISO()): List<CalendarEvent> {
        val key = KEY_PREFIX + today
        val raw = storage.kvGet(key)
        if (!raw.isNullOrBlank()) {
            val parsed = runCatching {
                OrdoJson.instance.decodeFromString(ListSerializer(CalendarEvent.serializer()), raw)
            }.getOrNull()
            if (parsed != null) return parsed
        }
        val seeded = demoEvents(today)
        storage.kvSet(key, OrdoJson.instance.encodeToString(ListSerializer(CalendarEvent.serializer()), seeded))
        return seeded
    }

    /** 三条示例日程:与设计稿「今天」基线图一致 */
    fun demoEvents(today: String): List<CalendarEvent> = listOf(
        CalendarEvent(
            id = "local-agenda-1",
            title = "产品评审会",
            start = OrdoDate.dateTime(today, "10:00"),
            end = OrdoDate.dateTime(today, "11:00"),
            calendar = "工作"
        ),
        CalendarEvent(
            id = "local-agenda-2",
            title = "与设计师 1:1",
            start = OrdoDate.dateTime(today, "14:30"),
            end = OrdoDate.dateTime(today, "15:00"),
            calendar = "工作"
        ),
        CalendarEvent(
            id = "local-agenda-3",
            title = "健身",
            start = OrdoDate.dateTime(today, "19:00"),
            end = OrdoDate.dateTime(today, "20:00"),
            calendar = "个人"
        )
    )
}
