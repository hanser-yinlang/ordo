package com.ordo.desktop.data

import com.ordo.core.model.Area
import com.ordo.core.model.EntityType
import com.ordo.core.model.Op
import com.ordo.core.model.OpType
import com.ordo.core.model.OrdoSnapshot
import com.ordo.core.model.Todo
import com.ordo.core.model.Tombstone
import com.ordo.core.model.When
import com.ordo.core.store.OrdoEngine
import com.ordo.core.util.OrdoDate
import com.ordo.core.util.OrdoJson
import kotlinx.serialization.json.JsonNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.charset.StandardCharsets

/**
 * Windows 端本地存储测试(契约 §8)。
 *
 * 覆盖:快照往返、outbox 追加与清理、墓碑往返、kv 读写、损坏文件自动回退 + 备份、
 * 以及与共享核心引擎的真实联调(写操作 → 落盘 → 重启后仍在)。
 */
class JsonFileStorageTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private fun storage(dir: File = tmp.newFolder("ordo")) = JsonFileStorage(dir)

    // ---------------------------------------------------------------- 快照

    @Test
    fun `空目录加载返回 null,由核心写入演示数据`() {
        val s = storage()
        assertNull(s.loadSnapshot())
    }

    @Test
    fun `快照往返保持字段一致`() {
        val s = storage()
        val snapshot = OrdoSnapshot(
            serverSeq = 42,
            areas = listOf(Area(id = "a1", name = "工作", color = "#5B5BD6", updatedAt = 1000)),
            todos = listOf(
                Todo(
                    id = "t1", title = "交季度报告", note = "含 **加粗** 备注",
                    `when` = When.DATE, date = "2026-10-09", reminder = "2026-10-09T18:00",
                    tags = listOf("重要"), order = 3, updatedAt = 2000
                )
            )
        )
        s.saveSnapshot(snapshot)

        val loaded = storage(s.dir).loadSnapshot()
        assertNotNull(loaded)
        assertEquals(42L, loaded!!.serverSeq)
        assertEquals(1, loaded.areas.size)
        assertEquals("工作", loaded.areas.first().name)
        val todo = loaded.todos.first()
        assertEquals("交季度报告", todo.title)
        assertEquals(When.DATE, todo.`when`)
        assertEquals("2026-10-09T18:00", todo.reminder)
        assertEquals(listOf("重要"), todo.tags)
    }

    @Test
    fun `损坏的快照被备份并回退为空,不影响启动`() {
        val dir = tmp.newFolder("corrupt")
        val file = File(dir, JsonFileStorage.FILE_SNAPSHOT)
        file.writeText("{ 这不是合法 JSON", StandardCharsets.UTF_8)

        val s = JsonFileStorage(dir)
        assertNull(s.loadSnapshot())

        val backups = dir.listFiles()?.filter { it.name.startsWith(JsonFileStorage.FILE_SNAPSHOT + ".corrupt-") } ?: emptyList()
        assertTrue("损坏文件应被备份以便排查", backups.isNotEmpty())
    }

    // ---------------------------------------------------------------- outbox / 墓碑 / kv

    @Test
    fun `outbox 追加与清理`() {
        val dir = tmp.newFolder("outbox")
        val s = JsonFileStorage(dir)
        val op1 = op("op-1", "t1")
        val op2 = op("op-2", "t2")
        s.appendOutbox(op1)
        s.appendOutbox(op2)
        assertEquals(2, s.loadOutbox().size)

        s.clearOutbox(listOf("op-1"))
        val rest = s.loadOutbox()
        assertEquals(1, rest.size)
        assertEquals("op-2", rest.first().opId)

        // 重启后仍一致
        assertEquals(1, JsonFileStorage(dir).loadOutbox().size)
    }

    @Test
    fun `重复追加同一 opId 幂等`() {
        val s = storage()
        val op = op("op-dup", "t1")
        s.appendOutbox(op)
        s.appendOutbox(op)
        assertEquals(1, s.loadOutbox().size)
    }

    @Test
    fun `墓碑往返`() {
        val dir = tmp.newFolder("tomb")
        val s = JsonFileStorage(dir)
        s.saveTombstones(
            listOf(
                Tombstone(EntityType.TODO, "t9", deletedAt = 111, clientTs = 222),
                Tombstone(EntityType.PROJECT, "p9", deletedAt = 333, clientTs = 444)
            )
        )
        val loaded = JsonFileStorage(dir).loadTombstones()
        assertEquals(2, loaded.size)
        assertEquals(EntityType.TODO, loaded.first { it.entityId == "t9" }.entity)
        assertEquals(222L, loaded.first { it.entityId == "t9" }.clientTs)
    }

    @Test
    fun `kv 读写与删除`() {
        val dir = tmp.newFolder("kv")
        val s = JsonFileStorage(dir)
        s.kvSet("deviceId", "dev_abc")
        s.kvSet("lastServerSeq", "7")
        assertEquals("dev_abc", JsonFileStorage(dir).kvGet("deviceId"))
        assertEquals("7", s.kvGet("lastServerSeq"))

        s.kvSet("deviceId", null)
        assertNull(s.kvGet("deviceId"))
        assertNull(JsonFileStorage(dir).kvGet("deviceId"))
    }

    // ---------------------------------------------------------------- 与核心引擎联调

    @Test
    fun `引擎写操作落盘并在重启后仍然可见`() {
        val dir = tmp.newFolder("engine")
        val engine = OrdoEngine(JsonFileStorage(dir))
        engine.seedDemoData(force = true)
        val before = engine.snapshot.todos.size
        val created = engine.createTodo("明天 18:00 交季度报告 #重要")
        engine.toggleDone(created.id)

        // 重启:新建引擎读同一目录
        val reopened = OrdoEngine(JsonFileStorage(dir))
        assertEquals(before + 1, reopened.snapshot.todos.size)
        val restored = reopened.todo(created.id)
        assertNotNull(restored)
        assertEquals("交季度报告", restored!!.title)
        assertTrue("完成状态应持久化", restored.status.isClosed)
        // 「明天」是相对词,期望值同样按"今天 +1 天"计算,避免测试与日期耦合
        assertEquals(
            OrdoDate.dateTime(OrdoDate.plusDays(OrdoDate.todayISO(), 1), "18:00"),
            restored.reminder
        )
    }

    @Test
    fun `未推送的 op 在重启后仍在 outbox 中`() {
        val dir = tmp.newFolder("pending")
        val engine = OrdoEngine(JsonFileStorage(dir))
        engine.createTodo("离线时新增的待办")
        assertTrue(engine.pendingOpCount() > 0)

        val reopened = OrdoEngine(JsonFileStorage(dir))
        assertTrue("outbox 必须持久化,否则离线改动会丢失", reopened.pendingOpCount() > 0)
    }

    @Test
    fun `快照文件使用原子替换,不残留 tmp 文件`() {
        val dir = tmp.newFolder("atomic")
        val s = JsonFileStorage(dir)
        s.saveSnapshot(OrdoSnapshot(serverSeq = 1, areas = listOf(Area("a", "测试"))))
        val leftovers = dir.listFiles()?.filter { it.name.endsWith(".tmp") } ?: emptyList()
        assertTrue("不应残留临时文件", leftovers.isEmpty())
        assertFalse(File(dir, JsonFileStorage.FILE_SNAPSHOT).length() == 0L)
    }

    private fun op(opId: String, entityId: String) = Op(
        opId = opId,
        deviceId = "dev-test",
        entity = EntityType.TODO,
        entityId = entityId,
        type = OpType.UPSERT,
        payload = OrdoJson.instance.encodeToJsonElement(
            Todo.serializer(),
            Todo(id = entityId, title = "测试待办", `when` = When.TODAY, updatedAt = 1000)
        ),
        clientTs = 1000
    )
}
