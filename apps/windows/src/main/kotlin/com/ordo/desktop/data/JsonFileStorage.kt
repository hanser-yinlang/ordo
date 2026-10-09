package com.ordo.desktop.data

import com.ordo.core.model.Op
import com.ordo.core.model.OrdoSnapshot
import com.ordo.core.model.Tombstone
import com.ordo.core.storage.OpCodec
import com.ordo.core.storage.OrdoStorage
import com.ordo.core.util.OrdoJson
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import java.io.File
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * Windows 端本地存储(契约 §8):JSON 文件仓储。
 *
 * 目录内容:`snapshot.json` / `outbox.json` / `tombstones.json` / `kv.json`,
 * 全部走"临时文件 + 原子替换",写入过程掉电不会产生半截文件;
 * 文件损坏时备份为 `<名字>.corrupt-<时间戳>` 并回退为空,保证 App 仍能启动。
 */
class JsonFileStorage(val dir: File) : OrdoStorage {

    private val lock = Any()
    private val snapshotFile = File(dir, FILE_SNAPSHOT)
    private val outboxFile = File(dir, FILE_OUTBOX)
    private val tombstonesFile = File(dir, FILE_TOMBSTONES)
    private val kvFile = File(dir, FILE_KV)

    private val mapSerializer = MapSerializer(String.serializer(), String.serializer())

    @Volatile
    private var kvCache: MutableMap<String, String>? = null

    init {
        if (!dir.exists()) dir.mkdirs()
    }

    // ------------------------------------------------------------ 快照

    override fun loadSnapshot(): OrdoSnapshot? = synchronized(lock) {
        val raw = readOrNull(snapshotFile) ?: return null
        if (raw.isBlank()) return null
        val parsed = runCatching {
            OrdoJson.instance.decodeFromString(OrdoSnapshot.serializer(), raw)
        }.getOrNull()
        if (parsed == null) {
            backupCorrupt(snapshotFile)
            return null
        }
        parsed
    }

    override fun saveSnapshot(snapshot: OrdoSnapshot) = synchronized(lock) {
        writeAtomic(snapshotFile, OpCodec.encodeSnapshot(snapshot))
    }

    // ------------------------------------------------------------ outbox

    override fun loadOutbox(): List<Op> = synchronized(lock) {
        val raw = readOrNull(outboxFile) ?: return emptyList()
        if (raw.isBlank()) return emptyList()
        val parsed = runCatching { OpCodec.decodeOps(raw) }.getOrNull()
        if (parsed == null) {
            backupCorrupt(outboxFile)
            return emptyList()
        }
        parsed
    }

    override fun appendOutbox(op: Op) = synchronized(lock) {
        val current = loadOutbox().toMutableList()
        // 幂等:同一 opId 只保留一条(重试/重放时不会把队列撑大,契约 §7.2)
        val existing = current.indexOfFirst { it.opId == op.opId }
        if (existing >= 0) current[existing] = op else current.add(op)
        writeAtomic(outboxFile, OpCodec.encodeOps(current))
    }

    override fun clearOutbox(opIds: List<String>) = synchronized(lock) {
        if (opIds.isEmpty()) return
        val kept = loadOutbox().filterNot { opIds.contains(it.opId) }
        writeAtomic(outboxFile, OpCodec.encodeOps(kept))
    }

    // ------------------------------------------------------------ 墓碑

    override fun loadTombstones(): List<Tombstone> = synchronized(lock) {
        val raw = readOrNull(tombstonesFile) ?: return emptyList()
        if (raw.isBlank()) return emptyList()
        runCatching { OpCodec.decodeTombstones(raw) }.getOrElse {
            backupCorrupt(tombstonesFile)
            emptyList()
        }
    }

    override fun saveTombstones(list: List<Tombstone>) = synchronized(lock) {
        writeAtomic(tombstonesFile, OpCodec.encodeTombstones(list))
    }

    // ------------------------------------------------------------ kv

    override fun kvGet(key: String): String? = synchronized(lock) { kv().get(key) }

    override fun kvSet(key: String, value: String?) = synchronized(lock) {
        val map = kv()
        if (value == null) map.remove(key) else map[key] = value
        writeAtomic(kvFile, OrdoJson.instance.encodeToString(mapSerializer, map))
    }

    private fun kv(): MutableMap<String, String> {
        kvCache?.let { return it }
        val raw = readOrNull(kvFile)
        val loaded = if (raw.isNullOrBlank()) {
            mutableMapOf()
        } else {
            runCatching {
                OrdoJson.instance.decodeFromString(mapSerializer, raw).toMutableMap()
            }.getOrElse {
                backupCorrupt(kvFile)
                mutableMapOf()
            }
        }
        kvCache = loaded
        return loaded
    }

    // ------------------------------------------------------------ 底层 IO

    private fun readOrNull(file: File): String? =
        if (!file.exists()) null else runCatching { file.readText(StandardCharsets.UTF_8) }.getOrNull()

    /** 先写 `.tmp`,再原子替换目标文件 */
    private fun writeAtomic(target: File, content: String) {
        if (!target.parentFile.exists()) target.parentFile.mkdirs()
        val tmp = File(target.parentFile, target.name + ".tmp")
        tmp.writeText(content, StandardCharsets.UTF_8)
        val moved = runCatching {
            Files.move(
                tmp.toPath(), target.toPath(),
                StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE
            )
        }.isSuccess
        if (!moved) {
            runCatching {
                Files.move(tmp.toPath(), target.toPath(), StandardCopyOption.REPLACE_EXISTING)
            }.onFailure { tmp.delete() }
        }
    }

    /** 损坏文件备份,便于事后排查;不阻断启动 */
    private fun backupCorrupt(file: File) {
        if (!file.exists()) return
        val stamp = System.currentTimeMillis()
        runCatching { file.renameTo(File(file.parentFile, "${file.name}.corrupt-$stamp")) }
    }

    companion object {
        const val FILE_SNAPSHOT = "snapshot.json"
        const val FILE_OUTBOX = "outbox.json"
        const val FILE_TOMBSTONES = "tombstones.json"
        const val FILE_KV = "kv.json"

        /** `%APPDATA%\Ordo`(无 APPDATA 时退回用户目录) */
        fun defaultDir(): File {
            val appData = System.getenv("APPDATA")
            val base = if (!appData.isNullOrBlank()) File(appData) else File(System.getProperty("user.home"))
            return File(base, "Ordo")
        }
    }
}
