package com.ordo.android

import com.ordo.android.ui.common.OrdoIconKind
import com.ordo.android.ui.quickadd.QuickAddAction
import com.ordo.android.ui.quickadd.QuickAddIconShape
import com.ordo.android.ui.quickadd.QuickAddMenuRules
import com.ordo.android.ui.theme.OrdoLayout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 快加号长按菜单（UI §5.2「菜单项图标 v1.3 对齐参照原型」）的纯逻辑验收。
 *
 * 覆盖：① 仍是 4 项且顺序固定（「标题」不得删除）；② 图标枚举 → 形状 id / 绘制图标 / 描边宽度
 * （＋ 2.1、H 1.7、区域方框 1.5、≡ 1.7）；②b「新建标题」仅在项目视图出现；
 * ③ 待办必须是＋而不再是太阳图标；④ 快捷键提示只有「新建待办」；⑤ 面板与条目的排版硬指标；
 * ⑥ 菜单项文案与 strings.xml 原文一致（[TestStrings] 直读资源，不引入 Robolectric）。
 */
class QuickAddMenuTest {

    /* --------------------------- ① 四项与顺序 --------------------------- */

    @Test
    fun `菜单仍是四项且顺序固定`() {
        assertEquals(4, QuickAddMenuRules.actions.size)
        assertEquals(
            listOf(
                QuickAddAction.NEW_TODO,
                QuickAddAction.NEW_PROJECT,
                QuickAddAction.NEW_AREA,
                QuickAddAction.NEW_HEADING,
            ),
            QuickAddMenuRules.actions,
        )
        assertEquals(QuickAddAction.NEW_TODO, QuickAddMenuRules.actionAt(0))
        assertEquals(QuickAddAction.NEW_HEADING, QuickAddMenuRules.actionAt(3))
        assertNull("不得出现第 5 项", QuickAddMenuRules.actionAt(4))
        assertTrue("「标题」不得删除（Ordo 自有项）", QuickAddMenuRules.actions.contains(QuickAddAction.NEW_HEADING))
    }

    @Test
    fun `菜单项文案与资源名一致`() {
        assertEquals("新建待办", TestStrings.value(QuickAddAction.NEW_TODO.labelResName))
        assertEquals("新建项目", TestStrings.value(QuickAddAction.NEW_PROJECT.labelResName))
        assertEquals("新建区域", TestStrings.value(QuickAddAction.NEW_AREA.labelResName))
        assertEquals("新建标题", TestStrings.value(QuickAddAction.NEW_HEADING.labelResName))
    }

    /* --------------------- ② 图标枚举 → 形状映射 --------------------- */

    @Test
    fun `图标枚举到形状id的映射符合参照原型`() {
        assertEquals("plus", QuickAddAction.NEW_TODO.iconShape.shapeId)
        assertEquals("letter-h", QuickAddAction.NEW_PROJECT.iconShape.shapeId)
        assertEquals("rounded-box-dot", QuickAddAction.NEW_AREA.iconShape.shapeId)
        assertEquals("three-bars", QuickAddAction.NEW_HEADING.iconShape.shapeId)
        assertEquals(
            "四项形状必须互不相同，否则菜单项无法区分",
            4,
            QuickAddMenuRules.actions.map { it.iconShape }.toSet().size,
        )
    }

    @Test
    fun `形状映射到矢量绘制图标与描边宽度`() {
        assertEquals(OrdoIconKind.Plus, QuickAddIconShape.PLUS.iconKind)
        assertEquals(OrdoIconKind.LetterH, QuickAddIconShape.LETTER_H.iconKind)
        assertEquals(OrdoIconKind.RoundedSquareDot, QuickAddIconShape.ROUNDED_BOX_DOT.iconKind)
        assertEquals(OrdoIconKind.TripleLine, QuickAddIconShape.THREE_BARS.iconKind)

        assertEquals("＋ 为 stroke 2.1 圆头", 2.1f, QuickAddIconShape.PLUS.strokeWidth, 0.001f)
        assertEquals("H 为 1.7 圆头", 1.7f, QuickAddIconShape.LETTER_H.strokeWidth, 0.001f)
        assertEquals(
            "区域方框取参照原型 i-area 的原始 stroke 1.5（§5.2 表）",
            1.5f,
            QuickAddIconShape.ROUNDED_BOX_DOT.strokeWidth,
            0.001f,
        )
        assertEquals("三横线为 1.7 圆头", 1.7f, QuickAddIconShape.THREE_BARS.strokeWidth, 0.001f)
        assertNotEquals(
            "区域方框线宽必须与 H/≡ 的 1.7 区分开",
            QuickAddIconShape.LETTER_H.strokeWidth,
            QuickAddIconShape.ROUNDED_BOX_DOT.strokeWidth,
        )
    }

    /* ------------------- ②b「新建标题」仅在项目视图出现 ------------------- */

    @Test
    fun `仅标题要求项目视图`() {
        assertTrue("heading 必须归属 project", QuickAddAction.NEW_HEADING.requiresProject)
        assertFalse(QuickAddAction.NEW_TODO.requiresProject)
        assertFalse(QuickAddAction.NEW_PROJECT.requiresProject)
        assertFalse(QuickAddAction.NEW_AREA.requiresProject)
    }

    @Test
    fun `非项目视图只显示前三项_项目视图显示完整四项`() {
        assertEquals(
            "收件箱/今天/项目列表等视图下隐藏「新建标题」",
            listOf(QuickAddAction.NEW_TODO, QuickAddAction.NEW_PROJECT, QuickAddAction.NEW_AREA),
            QuickAddMenuRules.visibleActions(inProjectView = false),
        )
        assertEquals(
            "项目视图下是完整 4 项（含「新建标题」）",
            QuickAddMenuRules.actions,
            QuickAddMenuRules.visibleActions(inProjectView = true),
        )
        assertEquals(3, QuickAddMenuRules.visibleActions(inProjectView = false).size)
        assertEquals(4, QuickAddMenuRules.visibleActions(inProjectView = true).size)
    }

    @Test
    fun `可用性判定与可见项同源`() {
        QuickAddMenuRules.actions.forEach { action ->
            val inProject = QuickAddMenuRules.isAvailable(action, inProjectView = true)
            val outside = QuickAddMenuRules.isAvailable(action, inProjectView = false)
            assertTrue("所有动作在项目视图都可用", inProject)
            assertEquals(
                "非项目视图的可用性必须与 visibleActions 一致：$action",
                QuickAddMenuRules.visibleActions(inProjectView = false).contains(action),
                outside,
            )
        }
        assertFalse(QuickAddMenuRules.isAvailable(QuickAddAction.NEW_HEADING, inProjectView = false))
    }

    @Test
    fun `新建待办必须是加号而不是太阳图标`() {
        assertEquals(OrdoIconKind.Plus, QuickAddAction.NEW_TODO.iconShape.iconKind)
        assertNotEquals(
            "v1.3 起不得再用 Anytime 太阳形状（原实现缺陷）",
            OrdoIconKind.Anytime,
            QuickAddAction.NEW_TODO.iconShape.iconKind,
        )
    }

    @Test
    fun `项目H_区域圆角方框_标题三横线与侧栏旧图标区分开`() {
        assertEquals(OrdoIconKind.LetterH, QuickAddAction.NEW_PROJECT.iconShape.iconKind)
        assertEquals(OrdoIconKind.RoundedSquareDot, QuickAddAction.NEW_AREA.iconShape.iconKind)
        assertEquals(OrdoIconKind.TripleLine, QuickAddAction.NEW_HEADING.iconShape.iconKind)

        assertNotEquals("项目不得再用侧栏的环形图标", OrdoIconKind.Project, QuickAddAction.NEW_PROJECT.iconShape.iconKind)
        assertNotEquals("区域不得再用侧栏的方框图标", OrdoIconKind.Area, QuickAddAction.NEW_AREA.iconShape.iconKind)
        assertNotEquals("标题不得再用 H 形（H 归项目）", OrdoIconKind.Heading, QuickAddAction.NEW_HEADING.iconShape.iconKind)
        assertNotEquals(
            "三横线必须与 H 可区分",
            QuickAddAction.NEW_PROJECT.iconShape,
            QuickAddAction.NEW_HEADING.iconShape,
        )
    }

    /* --------------------------- ③ 快捷键提示 --------------------------- */

    @Test
    fun `快捷键提示只有新建待办显示Ctrl加N`() {
        assertEquals("Ctrl+N", TestStrings.value(QuickAddAction.NEW_TODO.shortcutResName!!))
        assertNull("其余项不显示快捷键", QuickAddAction.NEW_PROJECT.shortcutResName)
        assertNull(QuickAddAction.NEW_AREA.shortcutResName)
        assertNull(QuickAddAction.NEW_HEADING.shortcutResName)
        assertEquals("四个菜单项里只有一个带快捷键提示", 1, QuickAddMenuRules.actions.count { it.shortcutResName != null })
    }

    /* --------------------------- ④ 排版硬指标 --------------------------- */

    @Test
    fun `菜单面板与条目的硬指标符合UI规范`() {
        assertTrue("面板最小宽 ≥208", QuickAddMenuRules.PANEL_MIN_WIDTH_DP >= 208)
        assertEquals(208, QuickAddMenuRules.PANEL_MIN_WIDTH_DP)
        assertEquals(12, QuickAddMenuRules.PANEL_RADIUS_DP)
        assertEquals(1, QuickAddMenuRules.PANEL_BORDER_DP)

        assertTrue("条目高 ≥44（同时是触控目标下限）", QuickAddMenuRules.ITEM_MIN_HEIGHT_DP >= 44)
        assertEquals(44, QuickAddMenuRules.ITEM_MIN_HEIGHT_DP)
        assertEquals(9, QuickAddMenuRules.ITEM_START_PADDING_DP)
        assertEquals(8, QuickAddMenuRules.ICON_TEXT_GAP_DP)
        assertEquals(7, QuickAddMenuRules.ITEM_RADIUS_DP)
        assertEquals(13.5f, QuickAddMenuRules.LABEL_FONT_SIZE_SP, 0.001f)
        assertFalse("字号不得退化成默认体字号", QuickAddMenuRules.LABEL_FONT_SIZE_SP == 15f)
    }

    @Test
    fun `主题令牌里的菜单宽度与规范一致`() {
        assertTrue("设计令牌不得停留在旧的 200dp", OrdoLayout.quickAddMenuWidth.value >= 208f)
        assertEquals(
            "令牌与 QuickAddMenuRules 必须同值，避免两处漂移",
            QuickAddMenuRules.PANEL_MIN_WIDTH_DP.toFloat(),
            OrdoLayout.quickAddMenuWidth.value,
            0.001f,
        )
    }
}
