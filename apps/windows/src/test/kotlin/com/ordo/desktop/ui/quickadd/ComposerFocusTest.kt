package com.ordo.desktop.ui.quickadd

import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.InternalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.unit.Density
import com.ordo.core.model.When
import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.store.OrdoEngine
import com.ordo.desktop.app.OrdoRoute
import com.ordo.desktop.app.OrdoViewModel
import com.ordo.desktop.ui.list.ListPane
import com.ordo.desktop.ui.theme.OrdoSize
import com.ordo.desktop.ui.theme.OrdoSpace
import com.ordo.desktop.ui.theme.OrdoTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 任务 2:右下角蓝色加号"点了没反应"。
 *
 * 根因:输入行 `ComposerRow` 渲染在**列表内容最顶端**,离右下角加号很远;
 * `OrdoFab { vm.openComposer() }` 只把 `composerOpen = true` ——
 * 既不抢键盘焦点,也不把列表滚过去;用户那一行本来就已经开着,于是再点就是彻底的空操作。
 *
 * 覆盖两条线:
 *  - 状态层(可测试的抽象):令牌自增、重复点击不丢状态、Esc 关闭不产生空待办;
 *  - 离屏场景(真实指针 / 真实按键 / 真实焦点回报):按真实坐标点右下角加号,
 *    断言输入框真的拿到键盘焦点、列表从底部回到输入行、语义树里确实存在可编辑节点。
 */
@OptIn(ExperimentalComposeUiApi::class)
class ComposerFocusTest {

    private fun vm(): OrdoViewModel {
        val storage = InMemoryStorage()
        return OrdoViewModel(
            engine = OrdoEngine(storage),
            storage = storage,
            scope = CoroutineScope(Dispatchers.Unconfined)
        )
    }

    // ------------------------------------------------------------ 打开 = 请求焦点 + 请求滚到可见

    @Test
    fun `打开输入框会请求焦点并给出滚动请求令牌`() {
        val vm = vm()
        val before = vm.state.value

        vm.openComposer()

        val after = vm.state.value
        assertTrue("输入框应处于打开状态", after.composerOpen)
        assertEquals("聚焦请求次数应 +1", before.composerFocusRequests + 1, after.composerFocusRequests)
        assertEquals("滚动/聚焦令牌应自增", before.composerFocusToken + 1L, after.composerFocusToken)
    }

    @Test
    fun `输入框已开着时再点加号不会丢状态,并重新请求聚焦`() {
        val vm = vm()
        vm.openComposer()
        val first = vm.state.value

        // 模拟"输入行本来就开着,用户又点了右下角加号"
        vm.openComposer()

        val second = vm.state.value
        assertTrue("重复点击后仍应是打开状态", second.composerOpen)
        assertEquals("每次点击都要重新请求聚焦(否则就是空操作)", first.composerFocusRequests + 1, second.composerFocusRequests)
        assertTrue("令牌必须继续自增,界面才会再次抢焦点并滚动", second.composerFocusToken > first.composerFocusToken)
        assertFalse("重复点击不该顺手弹出快加号菜单", second.quickAddMenuOpen)
    }

    @Test
    fun `带选项重复打开时新选项生效,不会退回旧上下文`() {
        val vm = vm()
        val project = vm.engine.snapshot.projects.first { !it.deleted }
        val heading = vm.engine.snapshot.headings.first { !it.deleted && it.projectId == project.id }

        vm.openComposer()
        vm.openComposer(When.ANYTIME, heading.id)

        val state = vm.state.value
        assertEquals("新请求的标题归属必须生效", heading.id, state.composerHeadingId)
        assertEquals(When.ANYTIME, state.composerWhen)
        assertEquals("两次请求 = 两次聚焦", 2, state.composerFocusRequests)
    }

    // ------------------------------------------------------------ Esc:关闭且不产生空待办

    @Test
    fun `输入为空时 Esc 关闭且不产生空待办`() {
        val vm = vm()
        val before = vm.engine.snapshot.todos.count { !it.deleted }
        vm.openComposer()
        assertTrue(vm.state.value.composerOpen)

        vm.escape()

        assertFalse("Esc 应关掉输入行", vm.state.value.composerOpen)
        assertEquals("空输入 Esc 绝不能留下空待办", before, vm.engine.snapshot.todos.count { !it.deleted })
        assertEquals("关闭后上下文也要清干净", null, vm.state.value.composerWhen)
        assertEquals(null, vm.state.value.composerHeadingId)
        assertFalse("焦点实况要复位,免得下次复用旧状态", vm.state.value.composerFocused)
    }

    @Test
    fun `空标题不会落库,视图模型直接挡掉`() {
        val vm = vm()
        val before = vm.engine.snapshot.todos.count { !it.deleted }

        val id = vm.createTodo("   ")

        assertEquals(null, id)
        assertEquals(before, vm.engine.snapshot.todos.count { !it.deleted })
    }

    @Test
    fun `非空输入创建待办并关闭输入行`() {
        val vm = vm()
        vm.openComposer()

        val id = vm.createTodo("明天 18:00 交报告 #重要")
        vm.closeComposer()

        assertNotNull(id)
        assertFalse(vm.state.value.composerOpen)
        assertEquals("关闭后应清掉上一次的表头上下文", null, vm.state.value.composerHeadingId)
    }

    // ------------------------------------------------------------ 离屏场景脚手架

    /** 加号圆心:与 QuickAdd 的布局对齐(右 xl;底 = 状态栏高度 + 光晕厚度 + 按钮半径) */
    private fun fabCenter(sceneWidth: Int, sceneHeight: Int): Offset {
        val margin = OrdoSpace.xl.value
        val bottom = OrdoSize.statusBar.value + OrdoSize.fabGlow.value
        val size = OrdoSize.fab.value
        return Offset(sceneWidth - margin - size / 2f, sceneHeight - bottom - size / 2f)
    }

    /**
     * 离屏场景:与 `OrdoApp` 同构 —— 清单区铺满,快加号作为**浮层**叠在右下角。
     *
     * 这个结构很关键:直接把 `QuickAdd` 与 `ListPane` 并排放在场景根上并不是应用的布局,
     * 右下角的命中测试也就对不上,测试会误判成"点了没反应"。
     */
    private fun scene(
        vm: OrdoViewModel,
        width: Int,
        height: Int,
        scroll: ScrollState? = null
    ): ImageComposeScene = ImageComposeScene(width = width, height = height, density = Density(1f)) {
        val state by vm.state.collectAsState()
        OrdoTheme(dark = false) {
            Box(Modifier.fillMaxSize()) {
                ListPane(state = state, vm = vm, composerScroll = scroll)
                QuickAdd(state = state, vm = vm, modifier = Modifier.matchParentSize())
            }
        }
    }

    /**
     * 场景语义树里第一个"可编辑文本"节点。
     *
     * `rootSemanticsNode` 属于 Compose 模块间的 API,这里显式 opt-in,并且只读 `config` / `children`,
     * 用途也仅限于测试断言"输入框真的存在"。
     */
    @OptIn(InternalComposeUiApi::class)
    private fun editableNode(scene: ImageComposeScene): SemanticsNode? {
        for (owner in scene.semanticsOwners) {
            findEditable(owner.rootSemanticsNode)?.let { return it }
        }
        return null
    }

    private fun findEditable(node: SemanticsNode): SemanticsNode? {
        if (node.config.getOrNull(SemanticsProperties.EditableText) != null) return node
        for (child in node.children) {
            findEditable(child)?.let { return it }
        }
        return null
    }

    /** 在加号上发一次真实的按下-抬起(与用户鼠标手测同一条事件路径) */
    private fun clickFab(scene: ImageComposeScene, center: Offset) {
        scene.sendPointerEvent(PointerEventType.Move, center)
        scene.render()
        scene.sendPointerEvent(PointerEventType.Press, center)
        scene.render()
        scene.sendPointerEvent(PointerEventType.Release, center)
        scene.render()
    }

    /**
     * 打开输入行的**真实路径**(2026-10-13 起):点右下角加号 → 展开菜单 → 选第一项「新建待办」。
     *
     * 点加号那一步仍然发真实指针事件;菜单项的选择等价于 `vm.openComposer()`
     * (QuickAddMenu 的 TODO 分支就是它),这里直接调用,避免依赖菜单条目的像素坐标。
     */
    private fun openComposerThroughFab(scene: ImageComposeScene, vm: OrdoViewModel, center: Offset) {
        clickFab(scene, center)
        settleAnimation(scene)
        assertTrue("点加号应先展开菜单(不再直接开输入行)", vm.state.value.quickAddMenuOpen)
        vm.setQuickAddMenu(false)
        vm.openComposer()
        settleAnimation(scene)
    }

    /** 把列表滚到指定位置(用户"已经滚到底部"的现场);用真实的挂起 API,不用反射改内部字段 */
    private fun scrollTo(scroll: ScrollState, target: Int) = runBlocking { scroll.scrollTo(target) }

    /**
     * 走若干帧,让 160ms 的滚动动画真的跑完。
     *
     * 必须显式传时间戳:`ImageComposeScene.render()`(不带参数)用的帧时钟**永远是 0**,
     * `withFrameNanos` / 动画只会停在第 0 帧上永远不推进 —— 依赖时间的断言必须自己喂帧。
     * 起点取 0,与不带参数的 `render()` 对齐,之后每帧 +16ms(约 60fps)。
     */
    private fun settleAnimation(scene: ImageComposeScene, frames: Int = 40, stepNanos: Long = 16_000_000L) {
        var now = 0L
        repeat(frames) {
            now += stepNanos
            scene.render(now)
        }
    }

    // ------------------------------------------------------------ 离屏场景:真实指针与焦点

    @Test
    fun `离屏场景里点右下角加号真的让输入框拿到键盘焦点`() {
        val vm = vm()
        val scene = scene(vm, width = 1280, height = 800)
        try {
            scene.render()
            assertFalse("初始不应有输入框", vm.state.value.composerOpen)
            assertFalse("初始没有输入框时焦点实况必须是假", vm.state.value.composerFocused)

            openComposerThroughFab(scene, vm, fabCenter(1280, 800))

            assertTrue("走完菜单后必须打开输入框", vm.state.value.composerOpen)
            assertEquals("应恰好请求一次聚焦", 1, vm.state.value.composerFocusRequests)
            assertTrue("输入框必须真的拿到键盘焦点(onFocusChanged 回报)", vm.state.value.composerFocused)
            assertNotNull("语义树里应存在可编辑输入框节点", editableNode(scene))
        } finally {
            scene.close()
        }
    }

    @Test
    fun `列表已滚动到底部时点加号会把输入行滚回可见处`() {
        val vm = vm()
        val scroll = ScrollState(0)
        val scene = scene(vm, width = 1280, height = 620, scroll = scroll)
        try {
            scene.render()
            assertTrue("演示数据应足够长,能产生可滚动区域", scroll.maxValue > 0)

            // 用户把列表滚到底部(输入行此时远在视口之上,这就是"看不到"的现场)
            scrollTo(scroll, scroll.maxValue)
            scene.render()
            assertEquals("应确实滚到了底部", scroll.maxValue, scroll.value)

            clickFab(scene, fabCenter(1280, 620))
            settleAnimation(scene)

            // 2026-10-13 起:点加号先展开菜单(与参照原型一致),不再直接开输入行
            assertTrue("点加号应展开菜单", vm.state.value.quickAddMenuOpen)
            assertFalse("此时还没有输入行", vm.state.value.composerOpen)

            // 菜单第一项「新建待办」= vm.openComposer();输入行随即滚回可见处
            vm.setQuickAddMenu(false)
            vm.openComposer()
            settleAnimation(scene)

            assertTrue("打开输入行后列表必须离开底部", scroll.value < scroll.maxValue)
            assertEquals("输入行在内容顶端,所以终点就是 0", 0, scroll.value)
        } finally {
            scene.close()
        }
    }

    @Test
    fun `输入框已开着时再点加号依然有可见反馈(重新聚焦 + 重新滚动)`() {
        val vm = vm()
        val scroll = ScrollState(0)
        val scene = scene(vm, width = 1280, height = 620, scroll = scroll)
        try {
            scene.render()
            openComposerThroughFab(scene, vm, fabCenter(1280, 620))
            scene.render()
            val afterFirst = vm.state.value
            assertTrue(afterFirst.composerOpen)
            assertEquals(1, afterFirst.composerFocusRequests)

            // 输入框一直开着:这正是用户当时的现场,再走一次菜单 → 新建待办过去是彻底的空操作
            scrollTo(scroll, scroll.maxValue)
            scene.render()
            assertEquals(scroll.maxValue, scroll.value)

            openComposerThroughFab(scene, vm, fabCenter(1280, 620))

            assertTrue("输入框不该被关掉", vm.state.value.composerOpen)
            assertEquals("再点必须重新请求聚焦", 2, vm.state.value.composerFocusRequests)
            assertEquals("再点必须把列表重新滚回输入行", 0, scroll.value)
        } finally {
            scene.close()
        }
    }

    /** Esc 用离屏场景发送真实按键(不依赖真实窗口);`sendKeyEvent` 属模块间 API,这里显式 opt-in */
    @OptIn(InternalComposeUiApi::class)
    @Test
    fun `聚焦后的输入框按 Esc 关闭且不产生空待办`() {
        val vm = vm()
        val before = vm.engine.snapshot.todos.count { !it.deleted }
        val scene = scene(vm, width = 1280, height = 800)
        try {
            scene.render()
            openComposerThroughFab(scene, vm, fabCenter(1280, 800))
            scene.render()
            assertTrue("输入框应已拿到焦点", vm.state.value.composerFocused)

            scene.sendKeyEvent(KeyEvent(Key.Escape, KeyEventType.KeyDown))
            scene.render()

            assertFalse("Esc 应关掉输入行", vm.state.value.composerOpen)
            assertFalse("焦点实况应复位", vm.state.value.composerFocused)
            assertEquals("空输入 Esc 不得留下空待办", before, vm.engine.snapshot.todos.count { !it.deleted })
        } finally {
            scene.close()
        }
    }

    /** 项目清单里同一个加号也要有反馈(输入行与项目卡片共用同一容器,不该被挤没) */
    @Test
    fun `项目清单里点加号同样能打开并聚焦`() {
        val vm = vm()
        val project = vm.engine.snapshot.projects.first { !it.deleted }
        vm.navigate(OrdoRoute.Project(project.id))
        val scene = scene(vm, width = 1280, height = 800)
        try {
            scene.render()
            openComposerThroughFab(scene, vm, fabCenter(1280, 800))

            assertTrue("项目清单里点加号也一样要先出菜单再开输入行", vm.state.value.composerOpen)
            assertTrue("项目清单里也必须真的拿到焦点", vm.state.value.composerFocused)
        } finally {
            scene.close()
        }
    }
}
