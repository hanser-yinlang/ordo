package com.ordo.android.vm

/* ============================================================================
 * 「新建待办」浮层（快加号）的状态机
 *
 * 对应实测缺陷「点蓝色加号没有反应」的三个同源根因：
 *   1. 浮层打开后**不抢焦点** —— 没有焦点就没有光标、软键盘也不弹，看起来"点了没用"；
 *   2. 已经打开时再点加号是**空操作** —— 用户得不到任何反馈，甚至以为按钮坏了；
 *   3. 空标题 / 关闭路径没有统一约定 —— 关掉浮层可能留下空待办。
 *
 * 这里把「点加号之后会发生什么」收敛成纯状态转移（不依赖 Android 框架，可直接 JVM 单测）：
 *   - [focusRequest] 每点一次加号都递增：Compose 侧用它当 `LaunchedEffect` 的 key，
 *     每次点击都重新 requestFocus + 弹软键盘，重复点击**不再是空操作**；
 *   - 已经打开时重复点击只递增 [focusRequest]，**不清空 [draft]**（不丢已输入内容）；
 *   - [closed] 丢弃草稿；空标题提交也只会关闭浮层，**绝不产生空待办**。
 * ========================================================================== */

/**
 * 新建待办浮层的状态。
 *
 * @param open 浮层是否可见
 * @param target 落地位置：`project/{id}` · `area/{id}` · `heading/{id}`；null = 当前清单的默认归属
 * @param draft 输入框内容（受控：由 ViewModel 持有，重复点击不会重建）
 * @param focusRequest 焦点请求序号：每次「打开 / 再次点击加号」都 +1
 */
data class ComposerState(
    val open: Boolean = false,
    val target: String? = null,
    val draft: String = "",
    val focusRequest: Int = 0,
) {

    /**
     * 点加号（或分组右侧的「+」）。
     * 未打开 → 打开并清空草稿；**已打开 → 保留草稿，只重新请求焦点**。
     */
    fun opened(target: String?): ComposerState = if (open) {
        copy(focusRequest = focusRequest + 1)
    } else {
        ComposerState(open = true, target = target, draft = "", focusRequest = focusRequest + 1)
    }

    /** 输入框内容变化 */
    fun edited(text: String): ComposerState = copy(draft = text)

    /** 关闭（返回键 / Esc / 点遮罩 / 提交完成）：草稿丢弃，不产生任何待办 */
    fun closed(): ComposerState = ComposerState(focusRequest = focusRequest)

    /** 提交判定：空白 → [Submission.Empty]（只关闭，不创建） */
    fun submission(): Submission {
        val title = draft.trim()
        return if (title.isEmpty()) Submission.Empty else Submission.Create(title)
    }

    /** 提交结果 */
    sealed interface Submission {
        /** 空标题：关闭浮层，绝不产生空待办 */
        data object Empty : Submission

        /** 有效标题（已去掉首尾空白）：交给引擎按契约 §5 解析日期/时间/标签后创建 */
        data class Create(val title: String) : Submission
    }
}
