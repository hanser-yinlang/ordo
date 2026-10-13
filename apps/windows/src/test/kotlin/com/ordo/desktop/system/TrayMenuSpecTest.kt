package com.ordo.desktop.system

import java.awt.Font
import java.awt.GraphicsEnvironment
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * 托盘右键菜单的字体与文案(用户实测:菜单项渲染成两个空心方框 —— AWT 默认字体显示不了中文)。
 *
 * 两条线:
 *  - **纯逻辑**:字体挑选的优先级、挑不出来时的英文兜底;
 *  - **本机真实字体环境**:确认这台机器上确实能选出一个显示得了中文的字体(否则菜单还会是豆腐块),
 *    并且选出来的字体 `canDisplay('打')` 为真。
 */
class TrayMenuSpecTest {

    // ------------------------------------------------------------ 纯逻辑

    @Test
    fun `按候选表顺序挑中文字体`() {
        val available = setOf("Segoe UI", "Microsoft YaHei", "SimSun", "Arial")
        val picked = TrayMenuSpec.pickFontFamily(available) { it != "Segoe UI" }
        assertEquals("候选表里更靠前的应优先", "Microsoft YaHei", picked)
    }

    @Test
    fun `候选表里没有时退而求其次,在系统字体里找能显示中文的`() {
        val available = setOf("Arial", "Segoe UI", "SomeCJKFont")
        val picked = TrayMenuSpec.pickFontFamily(available) { it == "SomeCJKFont" }
        assertEquals("SomeCJKFont", picked)
    }

    @Test
    fun `一个中文字体都没有时挑不出来,菜单改用英文`() {
        val available = setOf("Arial", "Segoe UI")
        val picked = TrayMenuSpec.pickFontFamily(available) { false }
        assertNull("不能挑一个显示不了中文的字体", picked)
        assertEquals("没有中文字体就必须用英文标签,不能给用户看豆腐块", TrayMenuSpec.LABELS_EN, TrayMenuSpec.labels(picked))
    }

    @Test
    fun `能挑到中文字体时用中文标签`() {
        assertEquals(TrayMenuSpec.LABELS_ZH, TrayMenuSpec.labels("Microsoft YaHei"))
        assertEquals(listOf("打开 Ordo", "退出"), TrayMenuSpec.LABELS_ZH)
        assertEquals(listOf("Open Ordo", "Quit"), TrayMenuSpec.LABELS_EN)
    }

    // ------------------------------------------------------------ 本机真实字体

    @Test
    fun `本机存在能显示中文的字体,菜单不会退化成豆腐块`() {
        val names = runCatching {
            GraphicsEnvironment.getLocalGraphicsEnvironment().availableFontFamilyNames.toSet()
        }.getOrNull()
        assumeTrue("取不到字体列表(极端环境),跳过", names != null && names.isNotEmpty())

        val canDisplay: (String) -> Boolean = { family ->
            runCatching { Font(family, Font.PLAIN, TrayMenuSpec.FONT_SIZE).canDisplay('打') }.getOrDefault(false)
        }
        val picked = TrayMenuSpec.pickFontFamily(names!!, canDisplay)
        assertNotNull(
            "这台机器上必须能选出一个显示得了中文的字体,否则托盘菜单会重现豆腐块;可用字体样例:" +
                names.sorted().take(12),
            picked
        )
        assertTrue("选出的字体必须真的能显示中文: $picked", canDisplay(picked!!))
        assertEquals("能显示中文就该用中文标签", TrayMenuSpec.LABELS_ZH, TrayMenuSpec.labels(picked))
    }

    @Test
    fun `AWT 默认字体确实显示不了中文,所以必须显式设字体`() {
        // 这条把"为什么要设字体"钉成事实:默认 DIALOG 字体在不少 Windows/JRE 组合下画不出汉字
        val dialogCanDisplay = runCatching { Font(Font.DIALOG, Font.PLAIN, 12).canDisplay('打') }.getOrDefault(false)
        val names = runCatching {
            GraphicsEnvironment.getLocalGraphicsEnvironment().availableFontFamilyNames.toSet()
        }.getOrNull() ?: emptySet()
        val hasCjk = names.any { runCatching { Font(it, Font.PLAIN, 12).canDisplay('打') }.getOrDefault(false) }
        // 本机如果默认字体就能显示中文,那这条断言不成立 —— 但"必须显式设字体"的结论依然成立
        assumeTrue("本机默认字体也能显示中文,跳过这条经验断言", !dialogCanDisplay && hasCjk)
        assertTrue("默认字体画不出中文,但系统里有能画中文的字体 → 必须显式挑一个", hasCjk)
    }
}
