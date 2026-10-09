package com.ordo.core.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

/** 参与同步的实体类型(契约 §7.2) */
@Serializable
enum class EntityType {
    @SerialName("area") AREA,
    @SerialName("project") PROJECT,
    @SerialName("heading") HEADING,
    @SerialName("todo") TODO,
    @SerialName("tag") TAG;

    val wire: String
        get() = when (this) {
            AREA -> "area"; PROJECT -> "project"; HEADING -> "heading"; TODO -> "todo"; TAG -> "tag"
        }

    companion object {
        fun fromWire(value: String?): EntityType? = when (value?.lowercase()) {
            "area" -> AREA
            "project" -> PROJECT
            "heading" -> HEADING
            "todo" -> TODO
            "tag" -> TAG
            else -> null
        }
    }
}

@Serializable
enum class OpType {
    @SerialName("upsert") UPSERT,
    @SerialName("delete") DELETE;

    val wire: String get() = if (this == UPSERT) "upsert" else "delete"

    companion object {
        fun fromWire(value: String?): OpType = if (value?.lowercase() == "delete") DELETE else UPSERT
    }
}

/**
 * 同步操作(契约 §7.2)。
 * `opId` 为 ULID 幂等键;`payload` 为实体完整 JSON 快照;delete 时为 null。
 */
@Serializable
data class Op(
    val opId: String,
    val deviceId: String,
    val entity: EntityType,
    val entityId: String,
    val type: OpType,
    val payload: JsonElement? = null,
    val clientTs: Long,
    val seq: Long? = null
)

/** 删除墓碑,防止旧 op 让实体复活(契约 §7.3.5) */
@Serializable
data class Tombstone(
    val entity: EntityType,
    val entityId: String,
    val deletedAt: Long,
    val clientTs: Long
)

/** 应用一条 op 的结果 */
data class ApplyResult(
    val applied: Boolean,
    val reason: String? = null
) {
    companion object {
        val APPLIED = ApplyResult(true)
        fun skipped(reason: String) = ApplyResult(false, reason)
    }
}
