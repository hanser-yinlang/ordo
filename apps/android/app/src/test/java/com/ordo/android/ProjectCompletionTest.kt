package com.ordo.android

import com.ordo.android.vm.ProjectCardAction
import com.ordo.android.vm.ProjectCompleteOutcome
import com.ordo.android.vm.labelRes
import com.ordo.android.vm.messageArgs
import com.ordo.android.vm.messageRes
import com.ordo.android.vm.projectCardAction
import com.ordo.android.vm.resolveProjectComplete
import com.ordo.core.model.EntityType
import com.ordo.core.model.Op
import com.ordo.core.model.OpType
import com.ordo.core.model.Status
import com.ordo.core.store.OrdoEngine
import com.ordo.core.store.TodoOptions
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 契约 §2.2「项目完成规则」v1.1（2026-10-09 修订）的 Android 端验收。
 *
 * 修订要点：唯一硬约束是「项目下所有 todo 的 status ∈ {done, canceled}」；
 * **heading 是否归档不再阻塞完成**，引擎在完成项目时会自动归档未归档的标题
 * （每个标题一条 Op，与手工归档同构）。因此：
 *   ① 有未完成待办 → 拒绝，且文案只说"还有 N 项未完成的待办"，不得再提「标题」；
 *   ② 待办都结束但标题未归档 → **允许完成**，标题被自动归档，项目 status = DONE；
 *   ③ `pendingOps()` 里同时出现 heading 归档 Op 与 project 完成 Op。
 *
 * 全部断言只依赖 shared:core 与 JDK（固定时钟 = 2026-10-08 09:00），与真实时间无关。
 */
class ProjectCompletionTest {

    private fun engine(): OrdoEngine = TestSupport.engine()

    private fun OrdoEngine.payloadOf(op: Op): JsonObject =
        op.payload as? JsonObject ?: JsonObject(emptyMap())

    private fun JsonObject.bool(name: String): Boolean? =
        (this[name] as? JsonPrimitive)?.content?.toBooleanStrictOrNull()

    private fun JsonObject.text(name: String): String? = (this[name] as? JsonPrimitive)?.content

    /** 某个标题"被置为已归档"的 Op（不含创建时的 archived=false） */
    private fun OrdoEngine.archiveOpsFor(headingId: String): List<Op> = pendingOps().filter {
        it.entity == EntityType.HEADING && it.entityId == headingId && payloadOf(it).bool("archived") == true
    }

    @Test
    fun `还有未完成待办时拒绝完成 且文案只说明未完成的待办`() {
        val engine = engine()
        val project = engine.createProject("发布项目")
        engine.createTodo("写文案", TodoOptions(projectId = project.id))
        engine.createTodo("出图", TodoOptions(projectId = project.id))
        engine.createTodo("发版", TodoOptions(projectId = project.id))

        val openCount = engine.counts().projects[project.id] ?: 0
        assertEquals(3, openCount)

        val completed = engine.completeProject(project.id)

        assertFalse("存在未完成待办时必须拒绝", completed)
        assertEquals("被拒绝时项目仍应是进行中", Status.OPEN, engine.project(project.id)?.status)

        val outcome = resolveProjectComplete(completed, Status.OPEN, openCount)
        assertEquals(ProjectCompleteOutcome.Blocked(3), outcome)
        assertEquals(R.string.toast_project_blocked, outcome.messageRes)
        assertArrayEquals(arrayOf<Any>(3), outcome.messageArgs())

        // 文案本体：必须能填进未完成的数量，且不得再出现「标题」
        val template = TestStrings.value("toast_project_blocked")
        assertTrue("拒绝文案必须带未完成数量占位符，实际：$template", template.contains("%1\$d"))
        assertTrue("拒绝文案必须说明是未完成的待办，实际：$template", template.contains("未完成的待办"))
        assertFalse("标题不阻塞完成，拒绝文案不得再提「标题」，实际：$template", template.contains("标题"))
    }

    @Test
    fun `待办都完成但标题未归档时允许完成 且标题被自动归档`() {
        val engine = engine()
        val project = engine.createProject("上线项目")
        val design = engine.createHeading(project.id, "设计")
        val build = engine.createHeading(project.id, "开发")
        val draft = engine.createTodo("出稿", TodoOptions(projectId = project.id, headingId = design.id))
        val code = engine.createTodo("实现", TodoOptions(projectId = project.id, headingId = build.id))
        engine.toggleDone(draft.id)
        engine.toggleDone(code.id)

        // 完成前：进度 100%、未完成 0 项，但两个标题都还没归档（旧规则正是卡在这里）
        assertEquals(1f, engine.projectProgress(project.id), 0.0001f)
        assertEquals(0, engine.counts().projects[project.id])
        assertEquals("标题尚未归档", 2, engine.headingsOf(project.id).size)

        val completed = engine.completeProject(project.id)

        assertTrue("待办全部结束、标题未归档时必须允许完成", completed)
        assertEquals(Status.DONE, engine.project(project.id)?.status)
        assertTrue(
            "完成项目时未归档的标题应由引擎自动归档",
            engine.snapshot.headings.filter { it.projectId == project.id }.all { it.archived },
        )
        assertTrue("归档后的标题不再出现在项目视图里", engine.headingsOf(project.id).isEmpty())

        val outcome = resolveProjectComplete(completed, Status.OPEN, 0)
        assertEquals(ProjectCompleteOutcome.Completed, outcome)
        assertEquals(R.string.toast_project_completed, outcome.messageRes)
        assertArrayEquals(emptyArray<Any>(), outcome.messageArgs())
    }

    @Test
    fun `完成项目同时写入标题归档 Op 与项目完成 Op`() {
        val engine = engine()
        val project = engine.createProject("归档项目")
        val pendingHeading = engine.createHeading(project.id, "未归档标题")
        val archivedHeading = engine.createHeading(project.id, "已归档标题")
        val first = engine.createTodo("甲", TodoOptions(projectId = project.id, headingId = pendingHeading.id))
        val second = engine.createTodo("乙", TodoOptions(projectId = project.id, headingId = archivedHeading.id))
        engine.toggleDone(first.id)
        engine.toggleDone(second.id)
        assertTrue("标题下无未完成待办时可以手工归档", engine.archiveHeading(archivedHeading.id))

        val archivedOpsBefore = engine.archiveOpsFor(archivedHeading.id).size

        assertTrue(engine.completeProject(project.id))

        val ops = engine.pendingOps()
        val headingOp = ops.lastOrNull {
            it.entity == EntityType.HEADING && it.entityId == pendingHeading.id &&
                engine.payloadOf(it).bool("archived") == true
        } ?: throw AssertionError("完成项目必须为未归档的标题写一条归档 Op")
        assertEquals(OpType.UPSERT, headingOp.type)

        val projectDoneOp = ops.lastOrNull { it.entity == EntityType.PROJECT && it.entityId == project.id }
            ?: throw AssertionError("完成项目必须写一条项目 Op")
        assertEquals(OpType.UPSERT, projectDoneOp.type)
        assertEquals("done", engine.payloadOf(projectDoneOp).text("status"))

        assertTrue(
            "标题归档 Op 必须先于项目完成 Op（引擎先归档、再置 DONE）",
            ops.indexOf(headingOp) < ops.indexOf(projectDoneOp),
        )
        assertEquals(
            "已经归档过的标题不应重复产生归档 Op",
            archivedOpsBefore,
            engine.archiveOpsFor(archivedHeading.id).size,
        )
    }

    @Test
    fun `已完成的项目不再接受完成 而是提示已是完成状态`() {
        val engine = engine()
        val project = engine.createProject("已结束项目")
        val only = engine.createTodo("唯一一条", TodoOptions(projectId = project.id))
        engine.toggleDone(only.id)
        assertTrue(engine.completeProject(project.id))
        assertEquals(Status.DONE, engine.project(project.id)?.status)

        val again = engine.completeProject(project.id)

        assertFalse(again)
        val outcome = resolveProjectComplete(again, Status.DONE, 0)
        assertEquals(ProjectCompleteOutcome.AlreadyDone, outcome)
        assertEquals(R.string.toast_project_already_done, outcome.messageRes)
        val template = TestStrings.value("toast_project_already_done")
        assertFalse("已完成态提示同样不得提「标题」，实际：$template", template.contains("标题"))
    }

    @Test
    fun `取消的待办不阻塞完成 且完成的项目可以重新打开`() {
        val engine = engine()
        val project = engine.createProject("可重开项目")
        val heading = engine.createHeading(project.id, "标题")
        val done = engine.createTodo("做完", TodoOptions(projectId = project.id, headingId = heading.id))
        val canceled = engine.createTodo("不做了", TodoOptions(projectId = project.id, headingId = heading.id))
        engine.toggleDone(done.id)
        engine.complete(canceled.id, canceled = true)

        assertEquals(Status.CANCELED, engine.todo(canceled.id)?.status)
        assertEquals("取消的待办不算未完成", 0, engine.counts().projects[project.id])

        assertTrue("契约 §2.2：status ∈ {done, canceled} 都算结束", engine.completeProject(project.id))
        assertEquals(Status.DONE, engine.project(project.id)?.status)
        assertTrue(engine.headingsOf(project.id).isEmpty())

        engine.reopenProject(project.id)
        assertEquals(Status.OPEN, engine.project(project.id)?.status)
        assertNull("重新打开后不应保留完成时间", engine.project(project.id)?.completedAt)
    }

    @Test
    fun `项目卡片的主动作与按钮文案随核心状态切换`() {
        // 进行中 → 完成项目；已完成 → 重新打开（已完成的项目不允许再出现"完成项目"）
        assertEquals(ProjectCardAction.COMPLETE, projectCardAction(Status.OPEN))
        assertEquals(ProjectCardAction.REOPEN, projectCardAction(Status.DONE))

        assertEquals("完成项目", TestStrings.value("project_complete"))
        assertEquals("重新打开", TestStrings.value("project_reopen"))
        assertEquals(R.string.project_complete, ProjectCardAction.COMPLETE.labelRes)
        assertEquals(R.string.project_reopen, ProjectCardAction.REOPEN.labelRes)

        assertEquals("已完成", TestStrings.value("project_status_done"))
        assertTrue(
            "已完成态提示必须存在，避免把「已经是 DONE」误报成「还有未完成待办」",
            TestStrings.value("toast_project_already_done").isNotBlank(),
        )
        assertFalse(
            "完成成功提示不得夹带其它原因",
            TestStrings.value("toast_project_completed").contains("标题"),
        )
    }
}
