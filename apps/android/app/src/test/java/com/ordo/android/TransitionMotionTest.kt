package com.ordo.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 过渡动效（04-UI 规范 §5.5）的**源码级契约**。
 *
 * 这里钉的是**结构与时长**：时长只在 `OrdoMotion` 里写一次并统一经过"减弱动态效果"折算、
 * 浮层面板必须走 `graphicsLayer`（alpha < 1 的图层里 `Modifier.shadow` 不绘制，§5.2 的坑）、
 * 浮层宿主必须常驻组合（否则关掉时整棵子树消失、200ms 退场根本播不出来）。
 * 像素行为在 Windows 端由 `OrdoMotionRenderTest` 覆盖；Android 侧沿用仓库惯用的源码断言（[TestSource]）。
 */
class TransitionMotionTest {

    private val motionPath = "java/com/ordo/android/ui/common/Motion.kt"

    private fun occurrences(haystack: String, needle: String): Int =
        haystack.split(needle).size - 1

    @Test
    fun `过渡时长与规范 5_5 同值`() {
        val tokens = TestSource.readCode("java/com/ordo/android/ui/theme/Tokens.kt")
        assertTrue("浮层入场 280ms", tokens.contains("POP_IN = 280"))
        assertTrue("浮层退场 200ms", tokens.contains("POP_OUT = 200"))
        assertTrue("页面切换 240ms", tokens.contains("PAGE_FADE = 240"))
        assertTrue("侧栏抽屉 260ms", tokens.contains("SHEET_COLLAPSE = 260"))
        assertTrue("既有动效仍用规范的三次贝塞尔", tokens.contains("CubicBezierEasing(0.2f, 0.8f, 0.2f, 1f)"))
        assertTrue(
            "§5.5 过渡要用「柔起长滑」的曲线 cubic-bezier(0.2, 0, 0, 1)",
            tokens.contains("CubicBezierEasing(0.2f, 0f, 0f, 1f)")
        )
    }

    @Test
    fun `所有过渡时长都经过减弱动态效果折算`() {
        val theme = TestSource.readCode("java/com/ordo/android/ui/theme/Theme.kt")
        for (name in listOf("popIn", "popOut", "pageFade", "drawer", "detail")) {
            assertTrue("OrdoTheme 应提供 $name", theme.contains("val $name: Int"))
        }
        assertTrue(
            "fast/base/slow/popIn/popOut/pageFade/drawer/detail 共 8 个取值都要按 reduceMotion 归零",
            occurrences(theme, "if (reduceMotion) 0 else") >= 8
        )
    }

    @Test
    fun `浮层面板只动几何_不藏进 alpha 图层`() {
        val code = TestSource.readCode(motionPath)
        assertTrue(code.contains("fun OrdoOverlay("))
        assertTrue(code.contains("fun OrdoPageEnter("))
        assertTrue(code.contains("fun OrdoRiseIn("))
        assertTrue(code.contains("fun OrdoDrawer("))
        assertTrue("浮层几何必须走 graphicsLayer", code.contains("Modifier.graphicsLayer {"))
        assertFalse("过渡动效不得使用 AnimatedVisibility", code.contains("AnimatedVisibility"))
        assertFalse("过渡动效不得使用 fadeIn(", code.contains("fadeIn("))
        assertTrue("退场期间要读得到可见快照", code.contains("rememberLastState"))
        assertTrue(
            "§5.5 六段过渡都要用 easingEnter（起步过猛的 standard 只留给既有动效）",
            occurrences(code, "easing = OrdoMotion.easingEnter)") >= 6
        )

        val overlayBody = code.substringAfter("fun OrdoOverlay(").substringBefore("fun OrdoPageEnter(")
        assertTrue("淡入淡出只能交给遮罩", overlayBody.contains("scrim.copy(alpha = scrim.alpha * p)"))
        val panel = overlayBody.substringAfter("Modifier.graphicsLayer {").substringBefore("}")
        assertFalse("面板图层里不得出现 alpha：面板 alpha 必须恒为 1", panel.contains("alpha"))
        assertTrue("面板图层应驱动 scaleX", panel.contains("scaleX"))
        assertTrue("面板图层应驱动 translationY", panel.contains("translationY"))
    }

    @Test
    fun `浮层宿主常驻组合_页面切换统一走 OrdoPageEnter`() {
        val shell = TestSource.readCode("java/com/ordo/android/ui/shell/OrdoShell.kt")
        assertTrue("页面切换由 OrdoPageEnter 统一驱动", shell.contains("OrdoPageEnter(key = state.routeKey)"))
        assertFalse("快找宿主不能被 if 包住，否则退场播不出来", shell.contains("if (state.fastFindOpen)"))
        assertFalse("排期宿主不能被 if 包住", shell.contains("if (state.scheduleTarget != null)"))
        assertTrue("排期宿主应常驻组合", shell.contains("ScheduleSheet(state = state, vm = vm)"))
        assertTrue("快找宿主应常驻组合", shell.contains("FastFind("))
        assertTrue("抽屉走 OrdoDrawer", shell.contains("OrdoDrawer("))
        assertTrue("宽屏详情栏入场", shell.contains("OrdoRiseIn { DetailColumn(state = state, vm = vm) }"))
        assertTrue("窄屏全屏详情入场", shell.contains("OrdoRiseIn(Modifier.fillMaxSize())"))
    }

    @Test
    fun `navigation 自带过渡必须关掉_避免与页面淡入叠加`() {
        val nav = TestSource.readCode("java/com/ordo/android/nav/OrdoNavHost.kt")
        assertTrue(nav.contains("enterTransition = { EnterTransition.None }"))
        assertTrue(nav.contains("exitTransition = { ExitTransition.None }"))
        assertTrue(nav.contains("popEnterTransition = { EnterTransition.None }"))
        assertTrue(nav.contains("popExitTransition = { ExitTransition.None }"))
    }

    @Test
    fun `清单展开走 AnimatedVisibility 且 220ms`() {
        val sidebar = TestSource.readCode("java/com/ordo/android/ui/shell/Sidebar.kt")
        assertTrue(sidebar.contains("AnimatedVisibility("))
        assertTrue(sidebar.contains("expandVertically(animationSpec = tween(OrdoTheme.base"))
        assertTrue(sidebar.contains("shrinkVertically(animationSpec = tween(OrdoTheme.base"))
        assertTrue("清单展开也要走 §5.5 的过渡曲线", sidebar.contains("easing = OrdoMotion.easingEnter"))
    }

    @Test
    fun `遮罩与浮层面板拆成两层`() {
        val components = TestSource.readCode("java/com/ordo/android/ui/common/Components.kt")
        assertTrue(components.contains("fun OrdoScrim(onClick: () -> Unit, alpha: Float = 1f)"))
        assertTrue(components.contains("fun OrdoPopoverPanel("))
    }
}
