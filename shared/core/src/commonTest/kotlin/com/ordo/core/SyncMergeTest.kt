package com.ordo.core

import com.ordo.core.model.ChecklistItem
import com.ordo.core.model.EntityType
import com.ordo.core.model.Op
import com.ordo.core.model.OpType
import com.ordo.core.model.Status
import com.ordo.core.model.Todo
import com.ordo.core.model.Tombstone
import com.ordo.core.model.When
import com.ordo.core.platform.FixedOrdoClock
import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.store.OrdoEngine
import com.ordo.core.sync.PullResponse
import com.ordo.core.sync.PushRequest
import com.ordo.core.sync.PushResponse
import com.ordo.core.sync.SnapshotResponse
import com.ordo.core.sync.SyncApi
import com.ordo.core.sync.SyncEngine
import com.ordo.core.util.OrdoDate
import com.ordo.core.util.OrdoJson
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonElement
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** 同步合并规则测试 —— 覆盖契约 §7.3 与 §7.4 */
class SyncMergeTest {

    private val baseTs = OrdoDate.nowMillis()

    private fun engine(device: String = "dev-test"): OrdoEngine =
        OrdoEngine(InMemoryStorage(), FixedOrdoClock(baseTs), deviceId = device)

    private fun todoPayload(todo: Todo): JsonElement =
        OrdoJson.instance.encodeToJsonElement(Todo.serializer(), todo)

    private fun upsertOp(
        id: String,
        todo: Todo,
        clientTs: Long,
        opId: String = "op-$id-$clientTs",
        seq: Long? = null
    ) = Op(
        opId = opId,
        deviceId = "dev-remote",
        entity = EntityType.TODO,
        entityId = id,
        type = OpType.UPSERT,
        payload = todoPayload(todo),
        clientTs = clientTs,
        seq = seq
    )

    @Test
    fun remoteUpsertCreatesTodo() {
        val engine = engine()
        val remote = Todo(id = "r1", title = "远端新增", `when` = When.TODAY, updatedAt = baseTs + 1000)
        val applied = engine.applyRemote(listOf(upsertOp("r1", remote, baseTs + 1000, seq = 5)))
        assertEquals(1, applied)
        assertEquals("远端新增", engine.todo("r1")!!.title)
        assertEquals(5, engine.lastServerSeq())
    }

    @Test
    fun lastWriteWinsByClientTs() {
        val engine = engine()
        val local = engine.createTodo("本地版本")
        val localTs = engine.todo(local.id)!!.updatedAt

        // 更早的远端 op → 丢弃
        val stale = engine.todo(local.id)!!.copy(title = "过期远端", updatedAt = localTs - 5000)
        assertEquals(0, engine.applyRemote(listOf(upsertOp(local.id, stale, localTs - 5000))))
        assertEquals("本地版本", engine.todo(local.id)!!.title)

        // 更新的远端 op → 覆盖
        val fresh = engine.todo(local.id)!!.copy(title = "新远端", updatedAt = localTs + 5000)
        assertEquals(1, engine.applyRemote(listOf(upsertOp(local.id, fresh, localTs + 5000))))
        assertEquals("新远端", engine.todo(local.id)!!.title)
    }

    @Test
    fun completionIsNotReverted() {
        val engine = engine()
        val todo = engine.createTodo("完成后不应被回滚")
        engine.complete(todo.id)
        val done = engine.todo(todo.id)!!
        assertEquals(Status.DONE, done.status)

        // 远端带一条更晚时间戳的 open 版本(模拟另一设备的旧意图)
        val openCopy = done.copy(status = Status.OPEN, completedAt = null, updatedAt = done.updatedAt + 10_000)
        engine.applyRemote(listOf(upsertOp(todo.id, openCopy, done.updatedAt + 10_000)))

        assertEquals(Status.DONE, engine.todo(todo.id)!!.status, "完成不可被回滚(契约 §7.3.2)")

        // 显式 reopen 仍然允许
        engine.reopen(todo.id)
        assertEquals(Status.OPEN, engine.todo(todo.id)!!.status)
    }

    @Test
    fun tagsAreMergedAsUnion() {
        val engine = engine()
        val todo = engine.createTodo("打标签")
        engine.addTag(todo.id, "本地标签")
        val merged = engine.todo(todo.id)!!

        val remote = merged.copy(tags = listOf("远端标签"), updatedAt = merged.updatedAt + 1000)
        engine.applyRemote(listOf(upsertOp(todo.id, remote, merged.updatedAt + 1000)))

        val result = engine.todo(todo.id)!!
        assertTrue(result.tags.contains("本地标签"))
        assertTrue(result.tags.contains("远端标签"))
    }

    @Test
    fun checklistMergedById() {
        val engine = engine()
        val todo = engine.createTodo("清单合并")
        engine.addChecklistItem(todo.id, "本地项")
        val withLocal = engine.todo(todo.id)!!
        val localItemId = withLocal.checklist.first().id

        val remoteItem = ChecklistItem("remote-item", "远端项", true)
        val remote = withLocal.copy(
            checklist = withLocal.checklist + remoteItem,
            updatedAt = withLocal.updatedAt + 1000
        )
        engine.applyRemote(listOf(upsertOp(todo.id, remote, withLocal.updatedAt + 1000)))

        val ids = engine.todo(todo.id)!!.checklist.map { it.id }
        assertTrue(ids.contains(localItemId), "本地独有的清单项应保留")
        assertTrue(ids.contains("remote-item"), "远端独有的清单项应合入")
    }

    @Test
    fun deleteCreatesTombstoneAndBlocksResurrection() {
        val engine = engine()
        val todo = engine.createTodo("将被删除")
        engine.deleteTodo(todo.id)
        assertTrue(engine.todo(todo.id) == null, "已删除待办不应出现在查询里")

        // 更早时间的 upsert 不能让它复活
        val zombie = Todo(id = todo.id, title = "复活尝试", `when` = When.TODAY, updatedAt = baseTs - 60_000)
        engine.applyRemote(listOf(upsertOp(todo.id, zombie, baseTs - 60_000)))
        assertTrue(engine.todo(todo.id) == null, "墓碑必须阻止实体复活(契约 §7.3.5)")
    }

    @Test
    fun outboxGrowsOnWriteAndShrinksOnAck() {
        val engine = engine()
        val before = engine.pendingOpCount()
        val todo = engine.createTodo("产生一条 op")
        engine.addTag(todo.id, "标签")
        assertTrue(engine.pendingOpCount() >= before + 2)

        val ids = engine.pendingOps().map { it.opId }
        engine.ackOps(ids)
        assertEquals(0, engine.pendingOpCount())
    }

    @Test
    fun opsAreIdempotentOnServerSideContract() {
        // 同一 opId 重复推送:服务端唯一索引去重,这里验证客户端不会因为重试产生重复实体
        val engine = engine()
        val todo = engine.createTodo("幂等")
        val ops = engine.pendingOps().filter { it.entityId == todo.id }
        assertEquals(1, ops.size)
        val accepted = ops.map { it.opId }
        engine.ackOps(accepted)
        engine.applyRemote(ops.map { it.copy(seq = 42) })
        assertEquals(1, engine.snapshot.todos.count { it.id == todo.id })
    }

    @Test
    fun syncEnginePushPullRoundTrip() = runTest {
        val engine = engine("dev-a")
        engine.createTodo("待同步的待办")
        val api = FakeSyncApi()
        val sync = SyncEngine(engine, api)

        val result = sync.syncOnce()
        assertTrue(result.ok, "同步应成功:${result.error}")
        assertEquals(1, result.pushed)
        assertEquals(0, engine.pendingOpCount(), "推送成功后 outbox 应清空")

        // 第二次同步:无待推送,服务端返回一条远端 op
        api.remoteOps = listOf(
            upsertOp("remote-9", Todo(id = "remote-9", title = "来自其它设备", `when` = When.TODAY, updatedAt = baseTs + 9000), baseTs + 9000, seq = 2)
        )
        val second = sync.syncOnce()
        assertTrue(second.ok)
        assertEquals("来自其它设备", engine.todo("remote-9")!!.title)
        assertEquals(2, engine.lastServerSeq())
    }

    @Test
    fun syncEngineFullResyncReplacesLocal() = runTest {
        val engine = engine()
        engine.createTodo("本地旧数据")
        val api = FakeSyncApi().apply {
            snapshotTodos = listOf(Todo(id = "srv-1", title = "服务端数据", `when` = When.TODAY, updatedAt = baseTs))
            serverSeqValue = 77
        }
        val result = SyncEngine(engine, api).fullResync()
        assertTrue(result.ok)
        assertEquals(1, engine.snapshot.todos.size)
        assertEquals("服务端数据", engine.snapshot.todos.first().title)
        assertEquals(77, engine.lastServerSeq())
        assertEquals(1, engine.pendingOpCount(), "全量替换应保留本地未推送的 outbox")
    }

    @Test
    fun remoteBlankTitleDeletesTodo() {
        // 契约 §7.3.6:远端下发的"空标题 upsert"同样必须删除实体(不只是 DELETE op)
        val engine = engine()
        val todo = engine.createTodo("将被远端清空标题")
        val local = engine.todo(todo.id)!!
        val blank = local.copy(title = "", updatedAt = local.updatedAt + 1_000)
        engine.applyRemote(listOf(upsertOp(todo.id, blank, local.updatedAt + 1_000)))
        assertNull(engine.todo(todo.id), "空标题的远端 upsert 应删除本地实体")
    }

    @Test
    fun localBlankTitleDeletesTodo() {
        val engine = engine()
        val todo = engine.createTodo("将被本地清空标题")
        engine.setTitle(todo.id, "   ")
        assertNull(engine.todo(todo.id), "本地把标题清空应视为删除")
        assertTrue(engine.pendingOps().any { it.entityId == todo.id })
    }

    @Test
    fun tombstonePersistsAcrossReload() {
        val storage = InMemoryStorage()
        val engine = OrdoEngine(storage, FixedOrdoClock(baseTs))
        val todo = engine.createTodo("删除并重启")
        engine.deleteTodo(todo.id)
        assertTrue(storage.loadTombstones().isNotEmpty())

        val reloaded = OrdoEngine(storage, FixedOrdoClock(baseTs + 1000))
        assertFalse(reloaded.snapshot.todos.any { it.id == todo.id && !it.deleted })
    }

    /** 极简假服务端:只做记录与返回,验证客户端流程 */
    private class FakeSyncApi : SyncApi {
        var remoteOps: List<Op> = emptyList()
        var snapshotTodos: List<Todo> = emptyList()
        var serverSeqValue: Long = 1
        private var pushedBatches = 0

        override suspend fun push(request: PushRequest): PushResponse {
            pushedBatches++
            val delta = remoteOps
            remoteOps = emptyList()
            return PushResponse(
                serverSeq = serverSeqValue,
                accepted = request.ops.map { it.opId },
                rejected = emptyList(),
                ops = delta
            )
        }

        override suspend fun pull(sinceSeq: Long, limit: Int): PullResponse {
            val delta = remoteOps
            remoteOps = emptyList()
            return PullResponse(serverSeq = serverSeqValue, ops = delta, hasMore = false)
        }

        override suspend fun fetchSnapshot(): SnapshotResponse =
            SnapshotResponse(serverSeq = serverSeqValue, todos = snapshotTodos)
    }
}
