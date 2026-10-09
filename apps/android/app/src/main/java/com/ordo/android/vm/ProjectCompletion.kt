package com.ordo.android.vm

import com.ordo.android.R
import com.ordo.core.model.Status

/* ============================================================================
 * 「完成项目」的判定与文案选择
 *
 * 契约 §2.2「项目完成规则」v1.1（2026-10-09 修订）：
 *   唯一硬约束 = 该项目下所有 todo 的 status ∈ {done, canceled}；
 *   **heading 是否归档不再阻塞完成** —— 引擎在完成时会自动归档未归档的标题
 *   （每个标题一条 Op，与手工归档同构）。
 *
 * 由此得到 Android 端必须遵守的两条界面契约：
 *   1. 拒绝的原因**只有一种**：还有 N 项未完成的待办 —— 文案必须带 N，
 *      且**不得再提「标题」**（旧文案「还有未完成的待办或标题」会让用户去归档标题，
 *      而归档标题根本不是完成项目的前提）。
 *   2. 已经 DONE 的项目不算「被拒绝」，而是「没有可完成的动作」：
 *      卡片必须显示已完成态并改为「重新打开」，而不是继续显示「完成项目」。
 *
 * 本文件是**纯逻辑**（只依赖 core 的枚举与 R 常量），因此可以在 JVM 单测里直接验证，
 * 不需要 Android 框架 —— 见 `src/test/.../ProjectCompletionTest.kt`。
 * ========================================================================== */

/** 「完成项目」的判定结果 */
sealed interface ProjectCompleteOutcome {

    /** 完成成功：引擎已把项目置为 DONE，并自动归档了该项目下未归档的标题 */
    data object Completed : ProjectCompleteOutcome

    /** 项目本来就是 DONE（按钮不该再出现，这里只做幂等兜底） */
    data object AlreadyDone : ProjectCompleteOutcome

    /** 被拒绝：项目下还有 [openCount] 项未完成的待办 */
    data class Blocked(val openCount: Int) : ProjectCompleteOutcome
}

/**
 * 由「引擎返回值 + 调用前的项目状态 + 调用前的未完成待办数」推出唯一结论。
 *
 * @param engineReturnedTrue `engine.completeProject(id)` 的返回值
 * @param projectStatusBefore 调用前项目的 `status`（项目不存在时为 null）
 * @param openTodoCount 调用前该项目下 `status == open` 的待办数
 *        （取自 `engine.counts().projects[id]`，与契约 §2.2 的判定同口径）
 */
fun resolveProjectComplete(
    engineReturnedTrue: Boolean,
    projectStatusBefore: Status?,
    openTodoCount: Int,
): ProjectCompleteOutcome = when {
    engineReturnedTrue -> ProjectCompleteOutcome.Completed
    projectStatusBefore == Status.DONE -> ProjectCompleteOutcome.AlreadyDone
    else -> ProjectCompleteOutcome.Blocked(openTodoCount.coerceAtLeast(0))
}

/** 提示文案：完成 / 已经是完成态 / 被拒绝（带未完成数量 N） */
val ProjectCompleteOutcome.messageRes: Int
    get() = when (this) {
        ProjectCompleteOutcome.Completed -> R.string.toast_project_completed
        ProjectCompleteOutcome.AlreadyDone -> R.string.toast_project_already_done
        is ProjectCompleteOutcome.Blocked -> R.string.toast_project_blocked
    }

/** [messageRes] 对应的格式化参数：只有被拒绝时需要把 N 填进文案 */
fun ProjectCompleteOutcome.messageArgs(): Array<Any> = when (this) {
    is ProjectCompleteOutcome.Blocked -> arrayOf(openCount)
    else -> emptyArray()
}

/* ------------------------------ 项目卡片的主动作 ------------------------------ */

/**
 * 项目卡片右下角的主动作。
 *
 * 与核心的 `project.status` 一一对应：进行中 → 完成项目；已完成 → 重新打开。
 * 已完成的项目**不允许**再出现「完成项目」按钮（点了只会被幂等拒绝，
 * 旧实现还会把它误报成「还有未完成的待办」）。
 */
enum class ProjectCardAction {
    COMPLETE,
    REOPEN,
}

/** 由核心的项目状态决定卡片主动作 */
fun projectCardAction(status: Status): ProjectCardAction =
    if (status == Status.DONE) ProjectCardAction.REOPEN else ProjectCardAction.COMPLETE

/** 主动作的按钮文案 */
val ProjectCardAction.labelRes: Int
    get() = when (this) {
        ProjectCardAction.COMPLETE -> R.string.project_complete
        ProjectCardAction.REOPEN -> R.string.project_reopen
    }
