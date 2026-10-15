package com.ordo.desktop.ui.common

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * 过渡动效(04-UI规范 §5.5)的**源码级契约**:时长、几何、以及三条"踩过坑"的结构约束。
 *
 * 像素行为由 [com.ordo.desktop.OrdoMotionRenderTest] 钉;这里钉的是**结构**:
 * 时长只在 `OrdoMotion` 里写一次、面板必须走 `graphicsLayer`(否则丢阴影)、
 * 浮层宿主必须常驻组合(否则退场播不出来)。与 `QuickAddFabLookTest` 同款思路 —— 只读源码,不启动界面。
 */
class OrdoMotionContractTest {

    /** 从测试工作目录往上找仓库根,再读 `apps/windows/<relativePath>` */
    private fun source(relativePath: String): String {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, "apps/windows/$relativePath")
            if (candidate.isFile) return candidate.readText(Charsets.UTF_8)
            dir = dir.parentFile
        }
        error("找不到 apps/windows/$relativePath(工作目录 ${System.getProperty("user.dir")})")
    }

    /** 去掉注释后再断言 —— 说明"不要用 AnimatedVisibility"的注释本身会包含这个词 */
    private fun code(relativePath: String): String = source(relativePath)
        .replace(Regex("""/\*.*?\*/""", RegexOption.DOT_MATCHES_ALL), " ")
        .replace(Regex("""//[^\n]*"""), " ")

    private fun occurrences(haystack: String, needle: String): Int =
        haystack.split(needle).size - 1

    @Test
    fun `过渡动效时长与规范 5_5 一致`() {
        val tokens = source("src/main/kotlin/com/ordo/desktop/ui/theme/OrdoTokens.kt")
        assertTrue("浮层入场应为 280ms", tokens.contains("const val OVERLAY_IN = 280"))
        assertTrue("浮层退场应为 200ms", tokens.contains("const val OVERLAY_OUT = 200"))
        assertTrue("页面切换应为 240ms", tokens.contains("const val PAGE_FADE = 240"))
        assertTrue("详情栏应为 280ms", tokens.contains("const val DETAIL = 280"))
    }

    @Test
    fun `面板几何只走 graphicsLayer_不许藏进 alpha 图层`() {
        val motion = code("src/main/kotlin/com/ordo/desktop/ui/common/Motion.kt")

        assertFalse("过渡动效不得使用 AnimatedVisibility", motion.contains("AnimatedVisibility"))
        assertFalse(
            "过渡动效不得使用 fadeIn( —— alpha < 1 的图层里 Modifier.shadow 不绘制,面板会丢阴影",
            motion.contains("fadeIn(")
        )
        assertTrue("面板几何必须走 graphicsLayer", motion.contains("Modifier.graphicsLayer {"))
        assertTrue("入场缩放必须自 0.96 起", motion.contains("OrdoOverlaySpec.SCALE_FROM +"))
        assertTrue(
            "所有时长都要经过减弱动态效果开关",
            occurrences(motion, "motionMillis(") >= 3
        )
        assertTrue(
            "§5.5 四段过渡都要用「柔起长滑」的过渡曲线(不是起步过猛的 standard)",
            occurrences(motion, "easing = OrdoEasing.transition") >= 4
        )
        assertTrue(
            "过渡曲线应为 cubic-bezier(0.2, 0, 0, 1)",
            motion.contains("CubicBezierEasing(0.2f, 0f, 0f, 1f)")
        )

        // 只截 OrdoOverlay 的面板图层:里面只许有几何,不许有 alpha(淡入淡出交给遮罩)
        val overlayBody = motion.substringAfter("fun OrdoOverlay(").substringBefore("fun OrdoPageEnter(")
        assertTrue("遮罩应自行按进度淡入淡出", overlayBody.contains("scrim.copy(alpha = scrim.alpha * p)"))
        val panelLayer = overlayBody.substringAfter("Modifier.graphicsLayer {").substringBefore("}")
        assertFalse("面板图层里不得出现 alpha:面板 alpha 必须恒为 1", panelLayer.contains("alpha"))
        assertTrue("面板图层应驱动 scaleX", panelLayer.contains("scaleX"))
        assertTrue("面板图层应驱动 translationY", panelLayer.contains("translationY"))
    }

    @Test
    fun `浮层宿主无条件组合_页面切换走 OrdoPageEnter`() {
        val app = code("src/main/kotlin/com/ordo/desktop/ui/shell/OrdoApp.kt")

        assertTrue("页面切换应由 OrdoPageEnter 统一驱动", app.contains("OrdoPageEnter(key = state.route"))

        assertFalse(
            "浮层不能被 if 包住,否则关闭时整棵子树消失、140ms 退场播不出来",
            app.contains("if (state.scheduleTargetId != null)")
        )
        assertFalse(app.contains("if (state.fastFindOpen)"))
        assertFalse(app.contains("if (state.settingsOpen)"))

        assertTrue("排期宿主应常驻组合", app.contains("ScheduleSheet(state = state, vm = vm)"))
        assertTrue("快找宿主应常驻组合", app.contains("FastFindOverlay(state = state, vm = vm)"))
        assertTrue("设置宿主应常驻组合", app.contains("SettingsView(state = state, vm = vm)"))
    }

    @Test
    fun `三个浮层宿主都用 OrdoOverlay 且退场读可见快照`() {
        val hosts = listOf(
            "ui/schedule/ScheduleSheet.kt",
            "ui/search/FastFind.kt",
            "ui/settings/SettingsView.kt"
        )
        for (host in hosts) {
            val src = code("src/main/kotlin/com/ordo/desktop/$host")
            assertTrue("$host 的宿主应使用 OrdoOverlay", src.contains("OrdoOverlay("))
            assertTrue("$host 退场期间要用可见快照渲染面板", src.contains("rememberLastState"))
        }
    }

    @Test
    fun `行内详情卡片入场走 OrdoRiseIn`() {
        val pane = code("src/main/kotlin/com/ordo/desktop/ui/list/ListPane.kt")
        assertTrue("详情卡片入场应由 OrdoRiseIn 驱动", pane.contains("OrdoRiseIn { DetailCardHost("))
    }
}
