package com.ordo.desktop.ui.list

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.unit.Density
import com.ordo.core.query.ListQuery
import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.store.OrdoEngine
import com.ordo.desktop.app.OrdoViewModel
import com.ordo.desktop.ui.theme.OrdoSpace
import com.ordo.desktop.ui.theme.OrdoTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 长按拖拽(04-UI规范 §5.4「统一为独立手势」)。
 *
 * 变更要点:
 *  - "按下即可拖"改成**长按 400ms 才进入拖拽**;
 *  - 移动 <6px 视为点击(不能抢走"打开详情");
 *  - 行尾手柄保留作为可见提示,并且**在手柄上按下可直接拖**(免长按);
 *  - `Esc` 取消:行回原位,不写库。
 *
 * 全部在离屏场景里用真实指针事件完成,不抢占用户鼠标。
 */
@OptIn(ExperimentalComposeUiApi::class)
class LongPressDragTest {

    private val sceneWidth = 1440
    private val sceneHeight = 900

    private fun viewModel(): OrdoViewModel {
        val storage = InMemoryStorage()
        val engine = OrdoEngine(storage)
        engine.seedDemoData(force = true)
        return OrdoViewModel(engine = engine, storage = storage, scope = CoroutineScope(Dispatchers.Unconfined))
    }

    private fun scene(vm: OrdoViewModel, drag: ListReorderState): ImageComposeScene =
        ImageComposeScene(width = sceneWidth, height = sceneHeight, density = Density(1f)) {
            val state by vm.state.collectAsState()
            OrdoTheme(dark = false) {
                Box(Modifier.fillMaxSize()) {
                    ListPane(state = state, vm = vm, dragState = drag)
                }
            }
        }

    /** 行内一个安全的横向落点(内容区 720 居中,取靠左 1/4 处,避开行尾手柄) */
    private fun rowX(): Float = sceneWidth / 2f - OrdoSpace.contentMaxWidth.value / 2f + 140f

    private fun pressAt(scene: ImageComposeScene, x: Float, y: Float) {
        scene.sendPointerEvent(PointerEventType.Move, Offset(x, y))
        scene.render()
        scene.sendPointerEvent(PointerEventType.Press, Offset(x, y))
        scene.render()
    }

    private fun moveTo(scene: ImageComposeScene, x: Float, y: Float) {
        scene.sendPointerEvent(PointerEventType.Move, Offset(x, y))
        scene.render()
    }

    private fun releaseAt(scene: ImageComposeScene, x: Float, y: Float) {
        scene.sendPointerEvent(PointerEventType.Release, Offset(x, y))
        scene.render()
    }

    private fun todayIds(vm: OrdoViewModel): List<String> = vm.engine.list(ListQuery.Today).map { it.id }

    @Test
    fun `长按 400ms 后拖动会写回顺序`() {
        val vm = viewModel()
        val drag = ListReorderState()
        val scene = scene(vm, drag)
        try {
            scene.render()
            val before = todayIds(vm)
            val rows = drag.spansOf(0)
            assertTrue("今天应至少登记 3 行", rows.size >= 3)
            val first = rows[0]
            val target = rows[2]

            val x = rowX()
            val y = drag.rootYOf(first.center)
            pressAt(scene, x, y)

            // 400ms 之前绝不能进入拖拽(这一条正是"按下即可拖"被否掉的地方)
            assertFalse("刚按下不该就进入拖拽", drag.active)

            Thread.sleep(460L)
            scene.render()

            assertTrue("按住 400ms 后进入拖拽", drag.active)
            assertEquals("被拖的就是按下的那一行", first.id, drag.draggedId)

            // 落点在目标行中点略下方(与 ReorderMath.insertIndex 的"过中点即下一格"一致)
            val targetY = drag.rootYOf(target.center + 4f)
            moveTo(scene, x, targetY)
            releaseAt(scene, x, targetY)
            scene.close()

            val after = todayIds(vm)
            assertFalse("拖动后顺序应变化", before == after)
            assertEquals("被拖行应落到第三行之前", first.id, after[2])
            assertTrue("重排要落库(outbox 有记录)", vm.engine.pendingOpCount() > 0)
        } finally {
            runCatching { scene.close() }
        }
    }

    @Test
    fun `400ms 之前移动超过 6px 不进入拖拽`() {
        val vm = viewModel()
        val drag = ListReorderState()
        val scene = scene(vm, drag)
        try {
            scene.render()
            val before = todayIds(vm)
            val rows = drag.spansOf(0)
            val first = rows[0]
            val x = rowX()
            val y = drag.rootYOf(first.center)

            pressAt(scene, x, y)
            // 立刻往下拖 40px(用户想快速拖动):超过 6px 容差 → 这次按下作废,交给滚动
            moveTo(scene, x, y + 40f)

            assertFalse("移动超过容差就不该进入拖拽", drag.active)
            assertNull(drag.draggedId)

            releaseAt(scene, x, y + 40f)
            scene.close()

            assertEquals("顺序不该有任何变化", before, todayIds(vm))
        } finally {
            runCatching { scene.close() }
        }
    }

    @Test
    fun `按下就抬起是点击,仍然会打开详情`() {
        val vm = viewModel()
        val drag = ListReorderState()
        val scene = scene(vm, drag)
        try {
            scene.render()
            val rows = drag.spansOf(0)
            val todo = vm.state.value.flatTodos.first { it.id == rows[0].id }
            val x = rowX()
            val y = drag.rootYOf(rows[0].center)

            pressAt(scene, x, y)
            releaseAt(scene, x, y)

            assertFalse("这只是一次点击,不是拖拽", drag.active)
            assertEquals("点击必须打开详情(长按层不许抢走)", todo.id, vm.state.value.selectedId)
        } finally {
            scene.close()
        }
    }

    @Test
    fun `Esc 取消长按拖拽,不写库`() {        val vm = viewModel()
        val drag = ListReorderState()
        val scene = scene(vm, drag)
        try {
            scene.render()
            val before = todayIds(vm)
            val rows = drag.spansOf(0)
            val x = rowX()
            val y = drag.rootYOf(rows[0].center)

            pressAt(scene, x, y)
            Thread.sleep(460L)
            scene.render()
            assertTrue(drag.active)

            moveTo(scene, x, drag.rootYOf(rows[2].center + 4f))
            assertTrue(drag.active)

            // Esc:全局快捷键在 Main.kt 里交给 vm.escape(),拖动中优先取消拖动
            // (离屏场景没有键盘焦点,这里直接调用同一条链路)
            vm.escape()
            scene.render()

            assertTrue("Esc 应产生取消令牌", vm.state.value.dragCancelToken > 0L)
            assertFalse("拖动已取消", drag.active)

            releaseAt(scene, x, drag.rootYOf(rows[2].center + 4f))
            scene.close()

            assertEquals("取消后顺序必须原样", before, todayIds(vm))
        } finally {
            runCatching { scene.close() }
        }
    }

    @Test
    fun `悬浮时行尾仍然保留可见的拖拽手柄`() {
        val vm = viewModel()
        val drag = ListReorderState()
        val scene = scene(vm, drag)
        try {
            scene.render()
            // 选中一行 → 手柄常驻(与悬浮等价的可见条件)。必须在选中之后再读行占位:
            // 详情卡片会把后面的行整体下移。
            vm.selectTodo(vm.state.value.flatTodos.first().id)
            scene.render()
            val rows = drag.spansOf(0)

            val y = drag.rootYOf(rows[0].center)
            scene.sendPointerEvent(PointerEventType.Move, Offset(rowX(), y))
            scene.render()

            // 手柄在行尾(内容区右侧),按下即拖:不需要等 400ms
            val handleX = sceneWidth / 2f + OrdoSpace.contentMaxWidth.value / 2f - OrdoSpace.s.value - 14f
            val handleY = drag.rootYOf(rows[0].top + 4f + 14f)
            val before = todayIds(vm)

            pressAt(scene, handleX, handleY)
            // 手柄上的按下不该让行级长按也武装起来(手柄会吃掉这次按下)
            Thread.sleep(460L)
            scene.render()
            assertFalse("手柄按下时行级长按必须作废(否则同一行会被拖两次)", drag.active)

            val targetY = drag.rootYOf(rows[2].center + 4f)
            moveTo(scene, handleX, targetY)
            assertTrue("手柄上按下可直接拖,无需长按", drag.active)
            releaseAt(scene, handleX, targetY)
            scene.close()

            assertFalse("手柄拖动同样写回顺序", before == todayIds(vm))
        } finally {
            runCatching { scene.close() }
        }
    }
}
