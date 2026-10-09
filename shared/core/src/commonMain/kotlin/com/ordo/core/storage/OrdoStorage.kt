package com.ordo.core.storage

import com.ordo.core.model.Op
import com.ordo.core.model.OrdoSnapshot
import com.ordo.core.model.Tombstone
import com.ordo.core.util.OrdoJson
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonElement

/**
 * 本地存储抽象(契约 §8)。
 *
 * 四端各自实现:Android = SQLiteOpenHelper / iOS = SwiftData / 鸿蒙 = RelationalStore / Windows = JSON 文件。
 * 表(或键)字段名必须与契约 §2 一致;另需 outbox / tombstones / kv 三块。
 */
interface OrdoStorage {

    fun loadSnapshot(): OrdoSnapshot?

    fun saveSnapshot(snapshot: OrdoSnapshot)

    fun loadOutbox(): List<Op>

    fun appendOutbox(op: Op)

    fun clearOutbox(opIds: List<String>)

    fun loadTombstones(): List<Tombstone>

    fun saveTombstones(list: List<Tombstone>)

    fun kvGet(key: String): String?

    fun kvSet(key: String, value: String?)
}

/** 内存实现:单元测试与桌面端首启动使用 */
class InMemoryStorage(
    private var snapshot: OrdoSnapshot? = null,
    private val outbox: MutableList<Op> = mutableListOf(),
    private var tombstones: List<Tombstone> = emptyList(),
    private val kv: MutableMap<String, String> = mutableMapOf()
) : OrdoStorage {

    override fun loadSnapshot(): OrdoSnapshot? = snapshot

    override fun saveSnapshot(snapshot: OrdoSnapshot) {
        this.snapshot = snapshot
    }

    override fun loadOutbox(): List<Op> = outbox.toList()

    override fun appendOutbox(op: Op) {
        outbox.add(op)
    }

    override fun clearOutbox(opIds: List<String>) {
        outbox.removeAll { opIds.contains(it.opId) }
    }

    override fun loadTombstones(): List<Tombstone> = tombstones

    override fun saveTombstones(list: List<Tombstone>) {
        tombstones = list
    }

    override fun kvGet(key: String): String? = kv[key]

    override fun kvSet(key: String, value: String?) {
        if (value == null) kv.remove(key) else kv[key] = value
    }
}

/** 供各端实现复用的 JSON 序列化辅助 */
object OpCodec {
    private val opListSerializer = ListSerializer(Op.serializer())
    private val tombstoneListSerializer = ListSerializer(Tombstone.serializer())

    fun encodeOps(ops: List<Op>): String = OrdoJson.instance.encodeToString(opListSerializer, ops)

    fun decodeOps(raw: String?): List<Op> =
        if (raw.isNullOrBlank()) emptyList() else OrdoJson.instance.decodeFromString(opListSerializer, raw)

    fun encodeTombstones(list: List<Tombstone>): String =
        OrdoJson.instance.encodeToString(tombstoneListSerializer, list)

    fun decodeTombstones(raw: String?): List<Tombstone> =
        if (raw.isNullOrBlank()) emptyList() else OrdoJson.instance.decodeFromString(tombstoneListSerializer, raw)

    fun encodeSnapshot(snapshot: OrdoSnapshot): String =
        OrdoJson.instance.encodeToString(OrdoSnapshot.serializer(), snapshot)

    fun decodeSnapshot(raw: String?): OrdoSnapshot? =
        if (raw.isNullOrBlank()) null else runCatching { OrdoJson.instance.decodeFromString(OrdoSnapshot.serializer(), raw) }.getOrNull()

    fun emptyPayload(): JsonElement = kotlinx.serialization.json.JsonNull
}
