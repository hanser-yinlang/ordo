package com.ordo.desktop.ui.quickadd

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
import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.store.OrdoEngine
import com.ordo.desktop.app.OrdoViewModel
import com.ordo.desktop.ui.list.ListPane
import com.ordo.desktop.ui.theme.OrdoSize
import com.ordo.desktop.ui.theme.OrdoSpace
import com.ordo.desktop.ui.theme.OrdoTheme
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * 快加号集群重构(04-UI规范 §5.2「去掉多余元素」)。
 *
 * 客户实测截图里右下角有两个互相叠压的圆形按钮:56dp 的蓝色「+」与 28dp 的白色折叠箭头。
 * 规范要求**只保留一个**:单击开输入行,长按 400ms 展开菜单,菜单展开时按钮旋转 45°。
 *
 * 这里覆盖:尺寸与"多余元素已删除"的源码级回归、单击/长按的分支判定、按钮的旋转与缩放,
 * 以及离屏场景里真实的按下-抬起与长按(不抢占用户鼠标)。
 */
@OptIn(ExperimentalComposeUiApi::class)
class QuickAddRefactorTest {

    private fun vm(): OrdoViewModel {
        val storage = InMemoryStorage()
        val engine = OrdoEngine(storage)
        engine.seedDemoData(force = true)
        return OrdoViewModel(engine = engine, storage = storage, scope = CoroutineScope(Dispatchers.Unconfined))
    }

    // ------------------------------------------------------------ 只有一个按钮

    @Test
    fun `快加号直径是 56dp`() {
        assertEquals(56f, OrdoSize.fab.value, 0.01f)
    }

    @Test
    fun `多余元素已删除_源码里不再有第二个圆形按钮`() {
        val source = quickAddSource() ?: return
        val text = source.readText()

        assertFalse("折叠箭头按钮必须删除(客户:不要有多余的东西)", text.contains("OrdoQuickAddCaret"))
        assertFalse("折叠箭头图标不该再被引用", text.contains("ExpandMore"))
        assertEquals(
            "有且只有一个圆形按钮用 fab 直径(只数 size(OrdoSize.fab),不误伤 fabGlow 这类令牌)",
            1,
            Regex("""size\(OrdoSize\.fab\)""").findAll(text).count()
        )
        assertTrue("按钮直径 56", text.contains("val fab: Dp = 56.dp") || OrdoSize.fab.value == 56f)
    }

    /** 找到 QuickAdd.kt 的源码(测试工作目录是模块目录;找不到就跳过源码级断言) */
    private fun quickAddSource(): File? {
        val relative = "src/main/kotlin/com/ordo/desktop/ui/quickadd/QuickAdd.kt"
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, relative)
            if (candidate.isFile) return candidate
            dir = dir.parentFile
        }
        assumeTrue("找不到 QuickAdd.kt,跳过源码级断言", false)
        return null
    }

    // ------------------------------------------------------------ 分支判定

    @Test
    fun `单击展开菜单,菜单展开时单击收起菜单`() {
        // 2026-10-13 按用户指定的参照原型调整:点按钮先出菜单(新建待办走菜单第一项 / Ctrl+N)
        assertEquals(QuickAddAction.EXPAND_MENU, QuickAddGesture.clickAction(menuOpen = false))
        assertEquals(QuickAddAction.CLOSE_MENU, QuickAddGesture.clickAction(menuOpen = true))
    }

    @Test
    fun `长按 400ms 展开菜单`() {
        assertEquals(QuickAddAction.EXPAND_MENU, QuickAddGesture.longPressAction(menuOpen = false))
        assertEquals("菜单已经开着就保持不动,不来回切", QuickAddAction.KEEP_MENU, QuickAddGesture.longPressAction(menuOpen = true))
    }

    @Test
    fun `菜单展开时按钮旋转 45 度,收起转回 0 度`() {
        assertEquals(0f, QuickAddVisual.rotation(menuOpen = false), 0.001f)
        assertEquals(45f, QuickAddVisual.rotation(menuOpen = true), 0.001f)
        assertEquals(45f, QuickAddVisual.OPEN_ROTATION, 0.001f)
    }

    @Test
    fun `按压 0_96,长按到位 1_06`() {
        assertEquals(1f, QuickAddVisual.scale(pressed = false, armed = false), 0.001f)
        assertEquals(0.96f, QuickAddVisual.scale(pressed = true, armed = false), 0.001f)
        assertEquals("长按到 400ms 轻微放大并保持(提示可以松手了)", 1.06f, QuickAddVisual.scale(pressed = true, armed = true), 0.001f)
    }

    // ------------------------------------------------------------ 离屏场景:真实指针

    private fun scene(vm: OrdoViewModel, width: Int, height: Int) = ImageComposeScene(
        width = width,
        height = height,
        density = Density(1f)
    ) {
        val state by vm.state.collectAsState()
        OrdoTheme(dark = false) {
            Box(Modifier.fillMaxSize()) {
                ListPane(state = state, vm = vm)
                QuickAdd(state = state, vm = vm, modifier = Modifier.matchParentSize())
            }
        }
    }

    /** 加号圆心:与 QuickAdd 的布局对齐(右 xl;底 = 状态栏高度 + 光晕厚度 + 按钮半径) */
    private fun fabCenter(width: Int, height: Int): Offset {
        val margin = OrdoSpace.xl.value
        val bottom = OrdoSize.statusBar.value + OrdoSize.fabGlow.value
        val size = OrdoSize.fab.value
        return Offset(width - margin - size / 2f, height - bottom - size / 2f)
    }

    @Test
    fun `离屏单击加号展开菜单,不再直接开输入行`() {
        val vm = vm()
        val scene = scene(vm, width = 1280, height = 800)
        try {
            scene.render()
            val center = fabCenter(1280, 800)

            scene.sendPointerEvent(PointerEventType.Move, center)
            scene.render()
            scene.sendPointerEvent(PointerEventType.Press, center)
            scene.render()
            scene.sendPointerEvent(PointerEventType.Release, center)
            scene.render()

            // 2026-10-13 按用户指定的参照原型:点按钮先出菜单(新建待办走菜单第一项 / Ctrl+N)
            assertTrue("单击应展开菜单", vm.state.value.quickAddMenuOpen)
            assertFalse("单击不再直接打开输入行", vm.state.value.composerOpen)

            // 菜单展开时再单击一次 → 收起(与真人的按下-抬起节奏一致)
            scene.sendPointerEvent(PointerEventType.Press, center)
            scene.render()
            Thread.sleep(30L)
            scene.sendPointerEvent(PointerEventType.Release, center)
            scene.render()
            assertFalse("菜单展开中单击应收起", vm.state.value.quickAddMenuOpen)
        } finally {
            scene.close()
        }
    }

    @Test
    fun `离屏长按 400ms 展开菜单,按钮进入展开态`() {
        val vm = vm()
        val scene = scene(vm, width = 1280, height = 800)
        try {
            scene.render()
            val center = fabCenter(1280, 800)

            scene.sendPointerEvent(PointerEventType.Move, center)
            scene.render()
            scene.sendPointerEvent(PointerEventType.Press, center)
            scene.render()

            // 按住 400ms 以上(长按定时是真实时间)
            Thread.sleep(460L)
            scene.render()

            assertTrue("长按 400ms 应展开菜单", vm.state.value.quickAddMenuOpen)
            assertFalse("长按不该顺手打开输入行", vm.state.value.composerOpen)
            assertEquals("菜单展开 → 按钮旋转 45°", 45f, QuickAddVisual.rotation(vm.state.value.quickAddMenuOpen), 0.001f)

            scene.sendPointerEvent(PointerEventType.Release, center)
            scene.render()
            assertTrue("松手后菜单仍然开着", vm.state.value.quickAddMenuOpen)
            assertFalse("长按松手不等于单击:不该顺手开输入行", vm.state.value.composerOpen)
        } finally {
            scene.close()
        }
    }
}
