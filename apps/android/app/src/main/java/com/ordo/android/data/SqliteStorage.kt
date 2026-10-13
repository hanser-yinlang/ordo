package com.ordo.android.data

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import com.ordo.core.model.Area
import com.ordo.core.model.EntityType
import com.ordo.core.model.Heading
import com.ordo.core.model.Op
import com.ordo.core.model.OrdoSnapshot
import com.ordo.core.model.Project
import com.ordo.core.model.Tag
import com.ordo.core.model.Todo
import com.ordo.core.model.Tombstone
import com.ordo.core.storage.OrdoStorage
import com.ordo.core.util.OrdoJson
import java.io.File

/**
 * Android 本地存储实现(契约 §8)。
 *
 * 设计:**实体以 JSON 快照整行存放**(`entities(entity, id, payload, updated_at, deleted)`),
 * 与服务端 `entities` 表同构(见架构文档 ADR-004),好处是:
 *  1. 字段名与契约 §2 永远一致,**不需要任何"实体 ↔ 数据类"映射代码**;
 *  2. 契约新增字段时无需数据库迁移;
 *  3. 零注解处理(Room/KSP 会引入与 Kotlin 版本强耦合的构建风险)。
 *
 * 表结构:
 *  - `entities`   实体快照(area/project/heading/todo/tag 共用一张表)
 *  - `outbox`     待推送的 Op(主键 op_id 即幂等键)
 *  - `tombstones` 删除墓碑(契约 §7.3.5)
 *  - `kv`         键值:deviceId / lastServerSeq / 令牌 / 服务器地址
 *
 * 说明:shared:core 的 [OrdoStorage] 是**同步接口**(引擎构造与写操作中直接调用),
 * 这里用 SQLite 同步 API 直接满足;单设备本地库整表读写为毫秒级。
 */
class SqliteStorage(
    context: Context,
    /**
     * 数据库文件（契约 §7.6.3）：
     *  根目录 `filesDir/ordo-bootstrap.db` = 引导库（会话 / 服务器地址，登录前就要能读）；
     *  `filesDir/<userId>/ordo.db` = 该账号的数据目录，**绝不允许两个账号共用**。
     * 省略时退回旧路径 `filesDir/ordo.db`（仅用于兼容与测试）。
     */
    dbFile: File? = null,
) : OrdoStorage {

    private val helper = OrdoDbHelper(context.applicationContext, dbFile)

    private val reader: SQLiteDatabase get() = helper.readableDatabase
    private val writer: SQLiteDatabase get() = helper.writableDatabase

    // ---------------------------------------------------------------- 快照

    override fun loadSnapshot(): OrdoSnapshot? {
        val db = reader
        val areas = queryEntities(db, EntityType.AREA) { p -> OrdoJson.instance.decodeFromString(Area.serializer(), p) }
        val projects = queryEntities(db, EntityType.PROJECT) { p -> OrdoJson.instance.decodeFromString(Project.serializer(), p) }
        val headings = queryEntities(db, EntityType.HEADING) { p -> OrdoJson.instance.decodeFromString(Heading.serializer(), p) }
        val todos = queryEntities(db, EntityType.TODO) { p -> OrdoJson.instance.decodeFromString(Todo.serializer(), p) }
        val tags = queryEntities(db, EntityType.TAG) { p -> OrdoJson.instance.decodeFromString(Tag.serializer(), p) }
        if (areas.isEmpty() && projects.isEmpty() && headings.isEmpty() && todos.isEmpty() && tags.isEmpty()) {
            return null // 首次启动:交由 core 的 seedDemoData 写入演示数据
        }
        return OrdoSnapshot(
            schemaVersion = kvGet(KEY_SCHEMA_VERSION)?.toIntOrNull() ?: OrdoSnapshot().schemaVersion,
            serverSeq = kvGet(KEY_SERVER_SEQ)?.toLongOrNull() ?: 0L,
            areas = areas,
            projects = projects,
            headings = headings,
            todos = todos,
            tags = tags
        )
    }

    override fun saveSnapshot(snapshot: OrdoSnapshot) {
        val db = writer
        db.beginTransaction()
        try {
            db.delete("entities", null, null)
            insertEntities(db, EntityType.AREA, snapshot.areas.map { it.id to encode(Area.serializer(), it) })
            insertEntities(db, EntityType.PROJECT, snapshot.projects.map { it.id to encode(Project.serializer(), it) })
            insertEntities(db, EntityType.HEADING, snapshot.headings.map { it.id to encode(Heading.serializer(), it) })
            insertEntities(db, EntityType.TODO, snapshot.todos.map { it.id to encode(Todo.serializer(), it) })
            insertEntities(db, EntityType.TAG, snapshot.tags.map { it.id to encode(Tag.serializer(), it) })
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    private fun <T> encode(serializer: kotlinx.serialization.KSerializer<T>, value: T): String =
        OrdoJson.instance.encodeToString(serializer, value)

    private fun <T> queryEntities(
        db: SQLiteDatabase,
        entity: EntityType,
        decode: (String) -> T
    ): List<T> {
        val out = ArrayList<T>()
        db.query(
            "entities", arrayOf("payload"), "entity = ?", arrayOf(entity.wire),
            null, null, "rowid ASC"
        ).use { cursor ->
            while (cursor.moveToNext()) {
                val payload = cursor.getString(0) ?: continue
                runCatching { decode(payload) }.getOrNull()?.let { out.add(it) }
            }
        }
        return out
    }

    private fun insertEntities(db: SQLiteDatabase, entity: EntityType, rows: List<Pair<String, String>>) {
        rows.forEach { (id, payload) ->
            val values = ContentValues().apply {
                put("entity", entity.wire)
                put("id", id)
                put("payload", payload)
                put("updated_at", System.currentTimeMillis())
                put("deleted", 0)
            }
            db.insertWithOnConflict("entities", null, values, SQLiteDatabase.CONFLICT_REPLACE)
        }
    }

    // ---------------------------------------------------------------- outbox

    override fun loadOutbox(): List<Op> {
        val out = ArrayList<Op>()
        reader.query("outbox", arrayOf("payload"), null, null, null, null, "created_at ASC, rowid ASC").use { cursor ->
            while (cursor.moveToNext()) {
                val payload = cursor.getString(0) ?: continue
                runCatching { OrdoJson.instance.decodeFromString(Op.serializer(), payload) }.getOrNull()?.let { out.add(it) }
            }
        }
        return out
    }

    override fun appendOutbox(op: Op) {
        val values = ContentValues().apply {
            put("op_id", op.opId)
            put("payload", OrdoJson.instance.encodeToString(Op.serializer(), op))
            put("created_at", op.clientTs)
        }
        writer.insertWithOnConflict("outbox", null, values, SQLiteDatabase.CONFLICT_REPLACE)
    }

    override fun clearOutbox(opIds: List<String>) {
        if (opIds.isEmpty()) return
        val placeholders = opIds.joinToString(",") { "?" }
        writer.delete("outbox", "op_id IN ($placeholders)", opIds.toTypedArray())
    }

    /** 待推送条数(同步状态条展示) */
    fun outboxCount(): Int =
        reader.rawQuery("SELECT COUNT(*) FROM outbox", null).use { c -> if (c.moveToFirst()) c.getInt(0) else 0 }

    /**
     * 到点提醒扫描用:未完成且 reminder 非空的待办。
     *
     * WorkManager 的 [com.ordo.android.notify.ReminderWorker] 在引擎之外运行(可能进程刚被拉起),
     * 因此这里直接查本地库,不经过引擎的内存快照。
     */
    fun reminderTodos(): List<Todo> =
        queryEntities(reader, EntityType.TODO) { p ->
            OrdoJson.instance.decodeFromString(Todo.serializer(), p)
        }.filter { it.isOpen && !it.reminder.isNullOrBlank() }

    // ---------------------------------------------------------------- 墓碑

    override fun loadTombstones(): List<Tombstone> {
        val out = ArrayList<Tombstone>()
        reader.query(
            "tombstones", arrayOf("entity", "entity_id", "deleted_at", "client_ts"),
            null, null, null, null, "client_ts DESC"
        ).use { cursor ->
            while (cursor.moveToNext()) {
                val entity = EntityType.fromWire(cursor.getString(0)) ?: continue
                out.add(
                    Tombstone(
                        entity = entity,
                        entityId = cursor.getString(1),
                        deletedAt = cursor.getLong(2),
                        clientTs = cursor.getLong(3)
                    )
                )
            }
        }
        return out
    }

    override fun saveTombstones(list: List<Tombstone>) {
        val db = writer
        db.beginTransaction()
        try {
            db.delete("tombstones", null, null)
            list.forEach { tombstone ->
                val values = ContentValues().apply {
                    put("entity", tombstone.entity.wire)
                    put("entity_id", tombstone.entityId)
                    put("deleted_at", tombstone.deletedAt)
                    put("client_ts", tombstone.clientTs)
                }
                db.insertWithOnConflict("tombstones", null, values, SQLiteDatabase.CONFLICT_REPLACE)
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    // ---------------------------------------------------------------- kv

    override fun kvGet(key: String): String? =
        reader.query("kv", arrayOf("v"), "k = ?", arrayOf(key), null, null, null).use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }

    override fun kvSet(key: String, value: String?) {
        if (value == null) {
            writer.delete("kv", "k = ?", arrayOf(key))
        } else {
            val values = ContentValues().apply {
                put("k", key)
                put("v", value)
            }
            writer.insertWithOnConflict("kv", null, values, SQLiteDatabase.CONFLICT_REPLACE)
        }
    }

    fun close() = helper.close()

    companion object {
        const val DB_NAME = "ordo.db"
        const val DB_VERSION = 1

        /**
         * kv 键。v1.4（纯本地）后只剩**本地**用得到的键：
         * schemaVersion / serverSeq（本地游标）/ deviceId（本地生成，用于 Op 记录）。
         * 会话、令牌、服务器地址等键已随云同步一起删除。
         */
        const val KEY_SCHEMA_VERSION = "schemaVersion"
        const val KEY_SERVER_SEQ = "serverSeq"
    }
}

/** SQLite 建表:字段名与契约 §8 一致 */
private class OrdoDbHelper(
    context: Context,
    dbFile: File?,
) : SQLiteOpenHelper(context, resolvePath(context, dbFile), null, SqliteStorage.DB_VERSION) {

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """
            CREATE TABLE entities (
                entity     TEXT    NOT NULL,
                id         TEXT    NOT NULL,
                payload    TEXT    NOT NULL,
                updated_at INTEGER NOT NULL,
                deleted    INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (entity, id)
            )
            """.trimIndent()
        )
        db.execSQL(
            """
            CREATE TABLE outbox (
                op_id      TEXT    PRIMARY KEY,
                payload    TEXT    NOT NULL,
                created_at INTEGER NOT NULL
            )
            """.trimIndent()
        )
        db.execSQL(
            """
            CREATE TABLE tombstones (
                entity    TEXT    NOT NULL,
                entity_id TEXT    NOT NULL,
                deleted_at INTEGER NOT NULL,
                client_ts  INTEGER NOT NULL,
                PRIMARY KEY (entity, entity_id)
            )
            """.trimIndent()
        )
        db.execSQL("CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        // v1 无历史版本;后续升级在此按版本号顺序执行迁移(契约 §8 迁移策略)
    }

    private companion object {
        /**
         * 数据库路径解析：`SQLiteOpenHelper` 只接受**名字**，但当名字是绝对路径时
         * `Context.getDatabasePath()` 会原样使用它 —— 这正是"按用户分目录"需要的语义：
         *   `filesDir/ordo-bootstrap.db`（会话）· `filesDir/<userId>/ordo.db`（该账号数据）。
         * 父目录必须先存在，否则 SQLite 打不开文件。
         */
        fun resolvePath(context: Context, dbFile: File?): String {
            val file = dbFile ?: File(context.filesDir, SqliteStorage.DB_NAME)
            file.parentFile?.takeIf { !it.exists() }?.mkdirs()
            return file.absolutePath
        }
    }
}
