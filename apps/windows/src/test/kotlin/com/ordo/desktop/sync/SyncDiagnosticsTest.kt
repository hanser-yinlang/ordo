package com.ordo.desktop.sync

import com.ordo.core.model.EntityType
import com.ordo.core.model.OpType
import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.store.OrdoEngine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 设置页「同步诊断」的数据来源测试(契约 §7.2 / §7.4)。
 *
 * 面板展示的三块数据必须来自真实引擎状态:待推送条数(outbox)、最后 serverSeq(kv)、上次错误(最近一次同步结果)。
 */
class SyncDiagnosticsTest {

    private fun engine() = OrdoEngine(InMemoryStorage())

    @Test
    fun `待推送条数与服务端序号来自引擎`() {
        val engine = engine()
        assertTrue("刚建的引擎 outbox 为空", SyncDiagnostics.of(engine, null).pendingCount == 0)

        engine.createTodo("离线新增的待办")
        engine.createTodo("再来一条")
        engine.setLastServerSeq(42)

        val diag = SyncDiagnostics.of(engine, lastError = null)
        assertEquals(2, diag.pendingCount)
        assertEquals(42L, diag.lastServerSeq)
        assertNull(diag.lastError)
        assertTrue(diag.hasPending)
    }

    @Test
    fun `outbox 明细带实体 opId 与 clientTs,且只取前 10 条`() {
        val engine = engine()
        val created = (1..12).map { engine.createTodo("第 $it 条") }

        val diag = SyncDiagnostics.of(engine, lastError = null)
        assertEquals(12, diag.pendingCount)
        assertEquals("明细只展示前 10 条", SyncDiagnostics.DEFAULT_LIMIT, diag.recent.size)
        assertTrue("超出部分要有提示", diag.truncated)

        // 明细顺序与 outbox 一致(先写先展示)
        assertEquals(engine.pendingOps().take(10).map { it.opId }, diag.recent.map { it.opId })
        val row = diag.recent.first()
        assertEquals("todo", row.entity)
        assertEquals("upsert", row.type)
        assertEquals(created.first().id, row.entityId)
        assertTrue("opId 是 ULID 幂等键", row.opId.isNotBlank())
        assertTrue("clientTs 是本地写入时间戳", row.clientTs > 0L)
        assertEquals("todo · upsert", row.label)

        val ops = engine.pendingOps()
        assertEquals(EntityType.TODO, ops.first().entity)
        assertEquals(OpType.UPSERT, ops.first().type)
    }

    @Test
    fun `上次错误透传,空白视为无错误`() {
        val engine = engine()
        assertEquals("SYNC_SEQ_GAP: 序号缺口", SyncDiagnostics.of(engine, "SYNC_SEQ_GAP: 序号缺口").lastError)
        assertNull(SyncDiagnostics.of(engine, "   ").lastError)
        assertNull(SyncDiagnostics.of(engine, null).lastError)
    }

    @Test
    fun `读诊断不产生新的 outbox 记录`() {
        val engine = engine()
        engine.createTodo("只读检查")
        val before = engine.pendingOpCount()
        repeat(3) { SyncDiagnostics.of(engine, "boom") }
        assertEquals("读诊断必须是只读操作", before, engine.pendingOpCount())
        assertFalse(SyncDiagnostics.of(engine, null).truncated)
    }
}
