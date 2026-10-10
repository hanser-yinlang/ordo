package com.ordo.android

import com.ordo.android.ui.gesture.DragReorder
import com.ordo.android.ui.gesture.FabClickAction
import com.ordo.android.ui.gesture.FabGesture
import com.ordo.android.ui.gesture.LongPressDragState
import com.ordo.android.ui.gesture.OrdoGesture
import com.ordo.android.ui.gesture.QuickAddGesture
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 手势规则的纯逻辑验收（UI §5.2 快加号集群 / §5.4 长按拖拽）。
 *
 * 这两处的硬指标是"400ms""<6px""单击 vs 长按"，全部集中在
 * `ui/gesture/OrdoGesture.kt`，界面层只负责把指针事件喂进来。
 */
class GestureRulesTest {

    /* ---------------------------- 阈值本身 ---------------------------- */

    @Test
    fun `长按阈值是 400ms 点击位移阈值是 6px`() {
        assertEquals("§5.2 与 §5.4 统一 400ms", 400L, OrdoGesture.LONG_PRESS_MILLIS)
        assertEquals("移动 <6px 视为点击", 6f, OrdoGesture.TAP_SLOP_PX)
    }

    /* ------------------------ FAB 单击 vs 长按分支 ------------------------ */

    @Test
    fun `短按且几乎没移动判为单击`() {
        assertEquals(FabGesture.CLICK, QuickAddGesture.classify(holdMillis = 120L, movedPx = 0f))
        assertEquals(FabGesture.CLICK, QuickAddGesture.classify(holdMillis = 399L, movedPx = 5.9f))
    }

    @Test
    fun `按住到 400ms 判为展开菜单`() {
        assertEquals(FabGesture.MENU, QuickAddGesture.classify(holdMillis = 400L, movedPx = 0f))
        assertEquals(FabGesture.MENU, QuickAddGesture.classify(holdMillis = 900L, movedPx = 2f))
    }

    @Test
    fun `位移达到 6px 时两个分支都不触发`() {
        assertEquals(
            "长按但手指划走了：既不开输入行也不展开菜单",
            FabGesture.IGNORE,
            QuickAddGesture.classify(holdMillis = 800L, movedPx = 6f),
        )
        assertEquals(FabGesture.IGNORE, QuickAddGesture.classify(holdMillis = 100L, movedPx = 12f))
    }

    @Test
    fun `菜单展开时按钮旋转 45 度_收起转回 0 度`() {
        assertEquals(45f, QuickAddGesture.rotationDegrees(menuOpen = true))
        assertEquals("收起必须转回 0°（「×」变回「+」）", 0f, QuickAddGesture.rotationDegrees(menuOpen = false))
    }

    @Test
    fun `菜单展开中单击是收起菜单而不是打开输入行`() {
        assertEquals(FabClickAction.CLOSE_MENU, QuickAddGesture.clickAction(menuOpen = true))
        assertEquals(FabClickAction.OPEN_COMPOSER, QuickAddGesture.clickAction(menuOpen = false))
    }

    @Test
    fun `按压 0_96 长按保持 1_06`() {
        assertEquals(0.96f, QuickAddGesture.scale(pressed = true, longPressReached = false))
        assertEquals(1.06f, QuickAddGesture.scale(pressed = true, longPressReached = true))
        assertEquals("松手回到 1.0", 1f, QuickAddGesture.scale(pressed = false, longPressReached = false))
    }

    /* ---------------------------- 长按拖拽 ---------------------------- */

    @Test
    fun `移动小于 6px 抬起仍是点击_不抢打开详情`() {
        val drag = LongPressDragState()
        drag.onPressDown(index = 2)
        drag.onMove(3f)
        drag.onMove(-2f)

        val release = drag.onRelease()

        assertEquals("位移 5px < 6px：必须仍是点击", LongPressDragState.Release.Click, release)
        assertEquals(LongPressDragState.Phase.IDLE, drag.phase)
    }

    @Test
    fun `移动超过 6px 抬起不算点击`() {
        val drag = LongPressDragState()
        drag.onPressDown(index = 0)
        drag.onMove(7f)

        assertFalse("超过阈值后不再是点击候选", drag.clickCandidate)
        assertEquals(LongPressDragState.Release.Canceled, drag.onRelease())
    }

    @Test
    fun `长按 400ms 进入抬起态`() {
        val drag = LongPressDragState()
        drag.onPressDown(index = 1)
        drag.onMove(2f)

        assertTrue("400ms 到点且位移 <6px → 行抬起", drag.onLongPressElapsed())
        assertEquals(LongPressDragState.Phase.ARMED, drag.phase)
        assertTrue("抬起态要画 scale 1.02 + 投影", drag.lifted)
        assertFalse(drag.dragging)
        assertEquals("抬起后不再是点击候选", false, drag.clickCandidate)
    }

    @Test
    fun `移动过多时长按到点不进入拖拽`() {
        val drag = LongPressDragState()
        drag.onPressDown(index = 1)
        drag.onMove(20f)

        assertFalse("已经在滚动列表，不能突然把行拎起来", drag.onLongPressElapsed())
        assertFalse(drag.lifted)
    }

    @Test
    fun `长按后拖动且位置变化才落库`() {
        val drag = LongPressDragState()
        drag.onPressDown(index = 0)
        assertTrue(drag.onLongPressElapsed())
        drag.onMove(10f)
        assertEquals("位移 ≥6px 后进入拖拽", LongPressDragState.Phase.DRAGGING, drag.phase)
        drag.onTargetIndex(3)

        val release = drag.onRelease()

        assertEquals(LongPressDragState.Release.Drop(committed = true, from = 0, to = 3), release)
        assertEquals(LongPressDragState.Phase.IDLE, drag.phase)
    }

    @Test
    fun `长按后没移动就松手_位置未变不写库`() {
        val drag = LongPressDragState()
        drag.onPressDown(index = 4)
        assertTrue(drag.onLongPressElapsed())

        val release = drag.onRelease()

        assertEquals(LongPressDragState.Release.Drop(committed = false, from = 4, to = 4), release)
    }

    @Test
    fun `拖回原位不写库`() {
        val drag = LongPressDragState()
        drag.onPressDown(index = 2)
        drag.onLongPressElapsed()
        drag.onMove(30f)
        drag.onTargetIndex(4)
        drag.onTargetIndex(2)

        assertEquals(
            LongPressDragState.Release.Drop(committed = false, from = 2, to = 2),
            drag.onRelease(),
        )
    }

    @Test
    fun `取消拖拽回原位且不写库`() {
        val drag = LongPressDragState()
        drag.onPressDown(index = 1)
        drag.onLongPressElapsed()
        drag.onMove(24f)
        drag.onTargetIndex(3)

        assertEquals("BackHandler 取消：不写库", LongPressDragState.Release.Canceled, drag.onCancel())
        assertEquals(LongPressDragState.Phase.IDLE, drag.phase)
        assertFalse(drag.lifted)
    }

    /* -------------------------- 槽位换算与让位 -------------------------- */

    @Test
    fun `插入槽位由位移与行高换算并夹紧在本分组内`() {
        // 行高 50px：位移 +130px ≈ 2.6 行 → 3 行
        assertEquals(3, DragReorder.targetIndex(0, 130f, 50f, 0, 5))
        // 向上拖 2 行
        assertEquals(1, DragReorder.targetIndex(3, -96f, 50f, 0, 5))
        // 越界夹紧：不允许跨分组移动
        assertEquals(5, DragReorder.targetIndex(4, 400f, 50f, 0, 5))
        assertEquals(0, DragReorder.targetIndex(1, -400f, 50f, 0, 5))
        // 行高未知时不下发新槽位
        assertEquals(2, DragReorder.targetIndex(2, 400f, 0f, 0, 5))
    }

    @Test
    fun `其余行让位方向正确`() {
        // 0 → 3：中间的行各上移一位
        assertEquals(-1, DragReorder.shiftFor(1, from = 0, to = 3))
        assertEquals(-1, DragReorder.shiftFor(3, from = 0, to = 3))
        assertEquals(0, DragReorder.shiftFor(4, from = 0, to = 3))
        assertEquals("被拖的那一行自己不让位", 0, DragReorder.shiftFor(0, from = 0, to = 3))
        // 3 → 0：中间的行各下移一位
        assertEquals(1, DragReorder.shiftFor(0, from = 3, to = 0))
        assertEquals(1, DragReorder.shiftFor(2, from = 3, to = 0))
        assertEquals(0, DragReorder.shiftFor(4, from = 3, to = 0))
    }
}
