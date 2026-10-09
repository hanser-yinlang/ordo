package com.ordo.android

import com.ordo.core.model.EntityType
import com.ordo.core.model.Op
import com.ordo.core.model.OpType
import com.ordo.core.model.Status
import com.ordo.core.store.TodoOptions
import com.ordo.core.model.When
import com.ordo.core.query.ListQuery
import com.ordo.core.store.OrdoEngine
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 契约 §7.3「冲突合并规则」验收：实体级 LWW、完成不可回滚、标签并集、删除墓碑。
 *
 * 远端 op 的构造方式：先本地写入拿到 shared:core 生成的 payload（实体完整 JSON），
 * 再按契约 §2.4 的字段名改写目标字段（title / status / tags），
 * 这样测试不需要自己实现实体编码。
 */
class SyncMergeTest {

    private fun engine(): OrdoEngine = TestSupport.engine()

    private fun OrdoEngine.localOpFor(todoId: String): Op =
        pendingOps().last { it.entityId == todoId }

    private fun payloadOf(op: Op): JsonObject = op.payload as? JsonObject ?: JsonObject(emptyMap())

    private fun mutate(op: Op, vararg changes: Pair<String, JsonElement>): JsonObject =
        JsonObject(payloadOf(op) + changes.toMap())

    private fun remoteOp(
        source: Op,
        payload: JsonElement?,
        clientTs: Long,
        type: OpType = OpType.UPSERT,
    ): Op = Op(
        opId = "remote-01JTEST${clientTs}",
        deviceId = "dev_remote",
        entity = EntityType.TODO,
        entityId = source.entityId,
        type = type,
        payload = payload,
        clientTs = clientTs,
        seq = null,
    )

    /** 固定时钟下的"更新的时间戳" */
    private fun newer(): Long = TestSupport.nowMillis() + 60_000L

    @Test
    fun `更新的远端 op 覆盖本地内容`() {
        val engine = engine()
        val todo = engine.createTodo("本地标题", TodoOptions(`when` = When.TODAY))
        val local = engine.localOpFor(todo.id)

        val applied = engine.applyRemote(
            listOf(remoteOp(local, mutate(local, "title" to JsonPrimitive("远端标题")), newer())),
        )

        assertEquals(1, applied)
        assertEquals("远端标题", engine.todo(todo.id)?.title)
    }

    @Test
    fun `更早的远端 op 因 LWW 被丢弃`() {
        val engine = engine()
        val todo = engine.createTodo("本地标题", TodoOptions(`when` = When.TODAY))
        val local = engine.localOpFor(todo.id)

        val applied = engine.applyRemote(
            listOf(remoteOp(local, mutate(local, "title" to JsonPrimitive("陈旧标题")), clientTs = 1L)),
        )

        assertEquals(0, applied)
        assertEquals("本地标题", engine.todo(todo.id)?.title)
    }

    @Test
    fun `完成状态不会被远端 open 覆盖`() {
        val engine = engine()
        val todo = engine.createTodo("已完成的", TodoOptions(`when` = When.TODAY))
        val beforeDone = engine.localOpFor(todo.id)
        engine.toggleDone(todo.id)

        engine.applyRemote(
            listOf(
                remoteOp(
                    source = beforeDone,
                    payload = mutate(beforeDone, "status" to JsonPrimitive("open")),
                    clientTs = newer(),
                ),
            ),
        )

        assertEquals(Status.DONE, engine.todo(todo.id)?.status)
    }

    @Test
    fun `标签取并集`() {
        val engine = engine()
        val todo = engine.createTodo("打标签的", TodoOptions(`when` = When.TODAY))
        engine.addTag(todo.id, "重要")
        val local = engine.localOpFor(todo.id)

        engine.applyRemote(
            listOf(
                remoteOp(
                    source = local,
                    payload = mutate(
                        local,
                        "tags" to JsonArray(listOf(JsonPrimitive("紧急"))),
                    ),
                    clientTs = newer(),
                ),
            ),
        )

        val tags = engine.todo(todo.id)?.tags.orEmpty()
        assertTrue("本地标签应保留：$tags", tags.contains("重要"))
        assertTrue("远端标签应并入：$tags", tags.contains("紧急"))
    }

    @Test
    fun `删除 op 让实体进入墓碑并不再出现在清单里`() {
        val engine = engine()
        val todo = engine.createTodo("将被删除", TodoOptions(`when` = When.TODAY))

        engine.applyRemote(
            listOf(remoteOp(engine.localOpFor(todo.id), payload = null, clientTs = newer(), type = OpType.DELETE)),
        )

        val stored = engine.snapshot.todos.firstOrNull { it.id == todo.id }
        assertTrue("实体应被软删除", stored == null || stored.deleted)
        assertFalse(engine.list(ListQuery.Today).any { it.id == todo.id })
    }

    @Test
    fun `本地写操作进入 outbox 并可被 ack 清空`() {
        val engine = engine()
        val todo = engine.createTodo("待同步", TodoOptions(`when` = When.ANYTIME))
        val pending = engine.pendingOps()
        assertTrue("createTodo 应产生 outbox op", pending.any { it.entityId == todo.id })

        val opIds = pending.map { it.opId }
        engine.ackOps(opIds)
        assertTrue(engine.pendingOps().isEmpty())
    }

    @Test
    fun `服务端快照可整表替换本地数据`() {
        val engine = engine()
        engine.createTodo("本地独有", TodoOptions(`when` = When.TODAY))

        val remoteSnapshot = com.ordo.core.seed.SeedData.demo(TestSupport.nowMillis(), TestSupport.TODAY)
        engine.replaceWithRemote(remoteSnapshot)

        assertEquals(remoteSnapshot.todos.size, engine.snapshot.todos.size)
        assertFalse(engine.snapshot.todos.any { it.title == "本地独有" })
    }
}
