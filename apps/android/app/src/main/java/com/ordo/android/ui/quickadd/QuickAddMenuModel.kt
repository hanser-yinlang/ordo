package com.ordo.android.ui.quickadd

import com.ordo.android.ui.common.OrdoIconKind

/* ============================================================================
 * 快加号长按菜单的纯逻辑模型（UI §5.2「菜单项图标 v1.3 对齐参照原型，四端一致」）
 *
 * 这里只描述**形状语义**、**展示顺序/文案**与**排版硬指标**，具体绘制由
 * [OrdoIconKind]（OrdoIcons.kt 的 Canvas 矢量实现）完成；不含 Android 框架依赖，
 * 因此顺序、文案、快捷键、几何数值都能直接跑 JVM 单测，四端也便于逐项对照。
 *
 * 颜色不在这里定义：一律走主题令牌（图标 textSecondary、文字 textPrimary、
 * 悬停/按下 selected），**不引入参照原型的蓝色**。
 * ========================================================================== */

/**
 * 菜单项前导图标的形状语义（20×20 viewBox 的等价形状）。
 *
 * @param shapeId 可读形状 id（排错与用例断言用）
 * @param iconKind 绘制用的图标枚举（OrdoIcons.kt）
 * @param strokeWidth 描边宽度（viewBox 单位，圆头）
 */
enum class QuickAddIconShape(
    val shapeId: String,
    val iconKind: OrdoIconKind,
    val strokeWidth: Float,
) {
    /** ＋：两条直线 (4,10)-(16,10)、(10,4)-(10,16)，stroke 2.1 圆头（「新建待办」） */
    PLUS("plus", OrdoIconKind.Plus, 2.1f),

    /** H：两竖 x=5/x=15（y 4→16）+ 中间一横 y=10（x 5→15），stroke 1.7 圆头（「新建项目」） */
    LETTER_H("letter-h", OrdoIconKind.LetterH, 1.7f),

    /** 圆角方框 + 中心点：方框 rect(3,3,14,14) rx=4，stroke **1.5**；中心 circle(10,10) r=2.6 实心（「新建区域」） */
    ROUNDED_BOX_DOT("rounded-box-dot", OrdoIconKind.RoundedSquareDot, 1.5f),

    /** 三横线（≡）：三条横线 y=5/10/15（x 4.5→15.5），stroke 1.7 圆头；Ordo 自有项（「新建标题」） */
    THREE_BARS("three-bars", OrdoIconKind.TripleLine, 1.7f),
}

/**
 * 快捷菜单的四个动作。
 *
 * **声明顺序即展示顺序**；UI §5.2 明确"菜单仍是 4 项"（指项目视图下的完整菜单），
 * 「新建标题」不得删除（它是 Ordo 自有项，参照原型没有），但它 **仅在项目视图出现**：
 * heading 必须归属某个 project，其它视图下该入口必然失败，因此隐藏。
 * 文案取自 strings.xml：这里只存资源名，由界面 `stringResource` 解析，
 * 文案契约用例直读 `strings.xml` 校验原文。
 *
 * @param labelResName `strings.xml` 里的 `<string name>`（不含 `@string/`）
 * @param iconShape 前导图标形状
 * @param shortcutResName 快捷键提示的资源名；**仅「新建待办」有**（Android 硬件键盘 Ctrl+N）
 * @param requiresProject 是否只在项目视图可用（§5.2：「新建标题」为 true）
 */
enum class QuickAddAction(
    val labelResName: String,
    val iconShape: QuickAddIconShape,
    val shortcutResName: String? = null,
    val requiresProject: Boolean = false,
) {
    NEW_TODO("quickadd_todo", QuickAddIconShape.PLUS, "quickadd_shortcut_todo"),
    NEW_PROJECT("quickadd_project", QuickAddIconShape.LETTER_H),
    NEW_AREA("quickadd_area", QuickAddIconShape.ROUNDED_BOX_DOT),
    NEW_HEADING("quickadd_heading", QuickAddIconShape.THREE_BARS, requiresProject = true),
}

/** §5.2 的硬指标与展示顺序（唯一事实来源：界面与单测都读这里） */
object QuickAddMenuRules {

    /** 展示顺序：4 项，不得增删；顺序即体验顺序 */
    val actions: List<QuickAddAction> = listOf(
        QuickAddAction.NEW_TODO,
        QuickAddAction.NEW_PROJECT,
        QuickAddAction.NEW_AREA,
        QuickAddAction.NEW_HEADING,
    )

    /** 第 index 个菜单项（越界返回 null，便于用例断言"没有第 5 项"） */
    fun actionAt(index: Int): QuickAddAction? = actions.getOrNull(index)

    /**
     * 当前视图下真正显示的菜单项（§5.2 v1.3）。
     *
     * 「新建标题」仅在项目视图出现（heading 必须归属 project）：项目视图 = 4 项，
     * 其它视图 = 前三项。`actions` 仍是完整的 4 项定义（顺序与文案的唯一事实来源）。
     */
    fun visibleActions(inProjectView: Boolean): List<QuickAddAction> =
        actions.filter { isAvailable(it, inProjectView) }

    /** 某一项在当前视图是否可用（与 [visibleActions] 同源，避免两处判定漂移） */
    fun isAvailable(action: QuickAddAction, inProjectView: Boolean): Boolean =
        inProjectView || !action.requiresProject

    /** 面板最小宽（§5.2：≥208） */
    const val PANEL_MIN_WIDTH_DP = 208

    /** 面板圆角（§5.2：radius 12） */
    const val PANEL_RADIUS_DP = 12

    /** 面板描边（§5.2：1px hairline） */
    const val PANEL_BORDER_DP = 1

    /** 条目最小高（§5.2：≥44，同时满足触控目标 ≥44） */
    const val ITEM_MIN_HEIGHT_DP = 44

    /** 条目左内边距（§5.2：9） */
    const val ITEM_START_PADDING_DP = 9

    /** 图标与文字间距（§5.2：8） */
    const val ICON_TEXT_GAP_DP = 8

    /** 条目圆角（§5.2：radius 7） */
    const val ITEM_RADIUS_DP = 7

    /** 条目字号（§5.2：13.5，介于 `caption` 13 与 `body` 15 之间） */
    const val LABEL_FONT_SIZE_SP = 13.5f

    /** 菜单图标显示尺寸（形状按 20×20 viewBox 描述，此处只放大到条目视觉平衡的 16dp） */
    const val ICON_SIZE_DP = 16
}
