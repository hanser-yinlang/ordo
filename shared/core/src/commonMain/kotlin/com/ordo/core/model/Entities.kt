package com.ordo.core.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/* ============================================================================
 * Ordo 数据模型 —— 与《03-数据模型与同步协议》§2 逐字段一致。
 * 字段名即 JSON 传输字段名,也是各端本地库字段名;修改必须同步改契约文档并升 schemaVersion。
 * ========================================================================== */

@Serializable
enum class When {
    @SerialName("inbox") INBOX,
    @SerialName("today") TODAY,
    @SerialName("evening") EVENING,
    @SerialName("anytime") ANYTIME,
    @SerialName("someday") SOMEDAY,
    @SerialName("date") DATE;

    val wire: String
        get() = when (this) {
            INBOX -> "inbox"; TODAY -> "today"; EVENING -> "evening"
            ANYTIME -> "anytime"; SOMEDAY -> "someday"; DATE -> "date"
        }

    /** 是否使用 date 字段 */
    val usesDate: Boolean get() = this == DATE

    companion object {
        fun fromWire(value: String?): When = when (value?.lowercase()) {
            "today" -> TODAY
            "evening" -> EVENING
            "anytime" -> ANYTIME
            "someday" -> SOMEDAY
            "date" -> DATE
            else -> INBOX
        }
    }
}

@Serializable
enum class Status {
    @SerialName("open") OPEN,
    @SerialName("done") DONE,
    @SerialName("canceled") CANCELED;

    val wire: String
        get() = when (this) {
            OPEN -> "open"; DONE -> "done"; CANCELED -> "canceled"
        }

    val isClosed: Boolean get() = this != OPEN

    companion object {
        fun fromWire(value: String?): Status = when (value?.lowercase()) {
            "done" -> DONE
            "canceled" -> CANCELED
            else -> OPEN
        }
    }
}

@Serializable
enum class RepeatFreq {
    @SerialName("daily") DAILY,
    @SerialName("weekly") WEEKLY,
    @SerialName("monthly") MONTHLY,
    @SerialName("yearly") YEARLY;

    val wire: String
        get() = when (this) {
            DAILY -> "daily"; WEEKLY -> "weekly"; MONTHLY -> "monthly"; YEARLY -> "yearly"
        }

    companion object {
        fun fromWire(value: String?): RepeatFreq = when (value?.lowercase()) {
            "weekly" -> WEEKLY
            "monthly" -> MONTHLY
            "yearly" -> YEARLY
            else -> DAILY
        }
    }
}

@Serializable
enum class RepeatMode {
    @SerialName("fixed") FIXED,
    @SerialName("afterCompletion") AFTER_COMPLETION;

    val wire: String
        get() = if (this == FIXED) "fixed" else "afterCompletion"

    companion object {
        fun fromWire(value: String?): RepeatMode =
            if (value?.lowercase() == "aftercompletion") AFTER_COMPLETION else FIXED
    }
}

@Serializable
data class RepeatRule(
    val freq: RepeatFreq,
    val interval: Int = 1,
    val mode: RepeatMode = RepeatMode.FIXED
)

@Serializable
data class ChecklistItem(
    val id: String,
    val title: String,
    val done: Boolean = false
)

@Serializable
data class Area(
    val id: String,
    val name: String,
    val color: String? = null,
    val order: Int = 0,
    val archived: Boolean = false,
    val updatedAt: Long = 0L,
    val deleted: Boolean = false
)

@Serializable
data class Heading(
    val id: String,
    val projectId: String,
    val name: String,
    val order: Int = 0,
    val archived: Boolean = false,
    /** 仅本地 UI 状态,不参与同步(推送前置 false) */
    val collapsed: Boolean = false,
    val updatedAt: Long = 0L,
    val deleted: Boolean = false
)

@Serializable
data class Project(
    val id: String,
    val name: String,
    val areaId: String? = null,
    val note: String = "",
    val `when`: When = When.ANYTIME,
    val date: String? = null,
    val deadline: String? = null,
    val tags: List<String> = emptyList(),
    val order: Int = 0,
    val status: Status = Status.OPEN,
    val completedAt: Long? = null,
    val repeat: RepeatRule? = null,
    val createdAt: Long = 0L,
    val updatedAt: Long = 0L,
    val deleted: Boolean = false
)

@Serializable
data class Todo(
    val id: String,
    val title: String,
    val note: String = "",
    val `when`: When = When.INBOX,
    val date: String? = null,
    val reminder: String? = null,
    val deadline: String? = null,
    val tags: List<String> = emptyList(),
    val checklist: List<ChecklistItem> = emptyList(),
    val projectId: String? = null,
    val areaId: String? = null,
    val headingId: String? = null,
    val repeat: RepeatRule? = null,
    val order: Int = 0,
    val status: Status = Status.OPEN,
    val createdAt: Long = 0L,
    val updatedAt: Long = 0L,
    val completedAt: Long? = null,
    val deleted: Boolean = false
) {
    val isOpen: Boolean get() = status == Status.OPEN
    val checklistDone: Int get() = checklist.count { it.done }
    val checklistLabel: String? get() = if (checklist.isEmpty()) null else "$checklistDone/${checklist.size}"
}

@Serializable
data class Tag(
    val id: String,
    val name: String,
    val color: String = "#6B6860",
    val updatedAt: Long = 0L,
    val deleted: Boolean = false
)

/** 日历事件:仅本地读取,不上传(契约 §2.8) */
@Serializable
data class CalendarEvent(
    val id: String,
    val title: String,
    val start: String,
    val end: String,
    val calendar: String = "",
    val allDay: Boolean = false
)

/** 全量快照:本地库与同步快照的统一结构 */
@Serializable
data class OrdoSnapshot(
    val schemaVersion: Int = ORDO_SCHEMA_VERSION,
    val serverSeq: Long = 0L,
    val areas: List<Area> = emptyList(),
    val projects: List<Project> = emptyList(),
    val headings: List<Heading> = emptyList(),
    val todos: List<Todo> = emptyList(),
    val tags: List<Tag> = emptyList()
)

const val ORDO_SCHEMA_VERSION: Int = 1
