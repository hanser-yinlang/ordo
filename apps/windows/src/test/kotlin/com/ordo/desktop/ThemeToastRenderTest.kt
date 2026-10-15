package com.ordo.desktop

import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.unit.Density
import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.store.OrdoEngine
import com.ordo.desktop.app.OrdoViewModel
import com.ordo.desktop.app.ThemeMode
import com.ordo.desktop.ui.shell.OrdoApp
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.awt.image.BufferedImage
import java.io.ByteArrayInputStream
import java.io.File
import javax.imageio.ImageIO

/**
 * 切换外观的提示条**视觉证据**(离屏渲染,不创建 AWT 窗口,不抢用户鼠标)。
 *
 * 产物(1440×900,`<buildDir>/reports/`):
 *   · `ordo-theme-toast.png` —— 深色「今天」+ 底部提示条「已切换到深色模式」
 *   · `ordo-theme-toast-light.png` —— 同一处、浅色模式(对照组)
 *
 * 这里不只看"提示条说了什么",还要**量像素**:同一个点(列表区空白处)在深色画面里必须是暗的、
 * 在浅色画面里必须是亮的,提示条药丸必须是亮的 —— 否则"提示说深色"就只是句空话。
 */
@OptIn(ExperimentalComposeUiApi::class)
class ThemeToastRenderTest {

    /** 列表区空白处(避开文字与卡片);两种模式下这里都是纯背景色 */
    private val canvasX = 700
    private val canvasY = 500

    /** 提示条药丸所在区域(底部居中,留出余量以免药丸宽度微调就失配) */
    private val pillLeft = 620
    private val pillTop = 806
    private val pillRight = 820
    private val pillBottom = 848

    @Test
    fun `切到深色后的提示条可以离屏渲染`() {
        val dark = renderAndSave(ThemeMode.DARK, "ordo-theme-toast.png")
        val light = renderAndSave(ThemeMode.LIGHT, "ordo-theme-toast-light.png")

        // 1) 提示与画面同源:说深色,画面就真的是深色
        assertTrue("深色画面在列表空白处应当是暗的,实测亮度=${dark.canvasLuminance}", dark.canvasLuminance < 0.15f)
        assertTrue("浅色画面同一处应当是亮的,实测亮度=${light.canvasLuminance}", light.canvasLuminance > 0.85f)

        // 2) 提示条真的画出来了:深色画面里药丸是亮的(浅色画面上白药丸与浅底几乎同色,不做对比断言)
        assertTrue("深色画面里应当有一条亮色提示条,实测最亮=${dark.pillMaxLuminance}", dark.pillMaxLuminance > 0.7f)

        // 3) 提示条与画面确实形成对比(深色画面里的亮色药丸才是"看得见"的)
        assertTrue(
            "提示条必须与深色画面形成对比,实测药丸=${dark.pillMaxLuminance} 画面=${dark.canvasLuminance}",
            dark.pillMaxLuminance - dark.canvasLuminance > 0.5f
        )
    }

    /** 渲染一张整窗截图(切到指定外观 → 断言提示文案与 dark 标志 → 喂帧 → 存 PNG → 量像素) */
    private fun renderAndSave(mode: ThemeMode, fileName: String): Shot {
        val storage = InMemoryStorage()
        val engine = OrdoEngine(storage)
        engine.seedDemoData(force = true)
        val vm = OrdoViewModel(engine = engine, storage = storage, scope = CoroutineScope(Dispatchers.Unconfined))

        vm.setTheme(mode)
        val state = vm.state.value
        assertEquals("提示文案应与模式同源", mode.switchToast(state.dark), state.toast!!.text)
        assertEquals("提示说的深浅必须就是画面用的深浅", mode != ThemeMode.LIGHT, state.dark)

        val scene = ImageComposeScene(width = 1440, height = 900, density = Density(1f)) { OrdoApp(vm) }
        // 必须显式喂帧:不带参数的 render() 帧时钟恒为 0,提示条的淡入 + 上滑会永远停在第 0 帧(等于没画出来)
        var now = 0L
        repeat(40) {
            scene.render(now)
            now += 16_000_000L
        }
        val bytes = scene.render(now).encodeToData()!!.bytes
        scene.close()

        assertTrue("截图不应为空", bytes.size > 5_000)
        val out = File(reportDir(), fileName)
        out.writeBytes(bytes)
        assertTrue("截图应落盘:" + out.absolutePath, out.length() > 5_000)
        println("[ThemeToastRenderTest] 已输出截图:${out.absolutePath} (${out.length()} 字节)")

        val image = ImageIO.read(ByteArrayInputStream(bytes))
        val shot = Shot(
            bytes = bytes,
            canvasLuminance = luminanceAt(image, canvasX, canvasY),
            pillMaxLuminance = maxLuminanceIn(image, pillLeft, pillTop, pillRight, pillBottom)
        )
        println("  · $fileName 列表空白处亮度=${shot.canvasLuminance} 提示条区域最亮=${shot.pillMaxLuminance}")
        return shot
    }

    private class Shot(val bytes: ByteArray, val canvasLuminance: Float, val pillMaxLuminance: Float)

    private fun reportDir(): File = File(System.getProperty("ordo.reportDir") ?: "build/reports").apply { mkdirs() }

    /** 0(黑)~1(白) */
    private fun luminanceAt(image: BufferedImage, x: Int, y: Int): Float {
        val rgb = image.getRGB(x, y)
        return (((rgb shr 16) and 0xFF) + ((rgb shr 8) and 0xFF) + (rgb and 0xFF)) / (3f * 255f)
    }

    private fun maxLuminanceIn(image: BufferedImage, x0: Int, y0: Int, x1: Int, y1: Int): Float {
        var max = 0f
        for (y in y0 until y1) {
            for (x in x0 until x1) {
                val l = luminanceAt(image, x, y)
                if (l > max) max = l
            }
        }
        return max
    }
}
