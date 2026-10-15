package com.ordo.desktop

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import com.ordo.desktop.ui.common.OrdoOverlay
import com.ordo.desktop.ui.common.OrdoPageEnter
import com.ordo.desktop.ui.common.rememberLastState
import com.ordo.desktop.ui.theme.OrdoMotion
import com.ordo.desktop.ui.theme.OrdoTheme
import com.ordo.desktop.ui.theme.motionMillis
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.awt.image.BufferedImage
import java.io.ByteArrayInputStream
import java.io.File
import javax.imageio.ImageIO

/**
 * 过渡动效(04-UI规范 §5.5)的**离屏渲染验收**:像素级钉住三条硬约束。
 *
 * 1. 浮层面板**不能**被 alpha 图层包住 —— `Modifier.shadow` 在 alpha < 1 的图层里不绘制,
 *    所以面板在整段过渡里必须是**纯色**(这里取纯绿当探针:任何透明度都会把它掺成灰绿)。
 * 2. **冷启动没有过场** —— 第 0 帧必须是终态,否则离屏截图与窗口首帧都会闪一下。
 * 3. **退场期间继续用可见快照** —— 宿主状态清空后,那 200ms 画面还得是关掉前的样子。
 *
 * 帧推进必须显式传时间戳:Compose Desktop 的 `scene.render()` 不带参数时帧时钟停在 0,
 * 动画永远不前进(见 `StartupAndShellRenderTest` 的同款注释)。用例里的帧数必须够跑完
 * §5.5 的时长(入场 280ms ≈ 18 帧),否则"落位/卸载"的断言会截在中途。
 */
@OptIn(ExperimentalComposeUiApi::class)
class OrdoMotionRenderTest {

    private var frameTime = 0L

    // ---------------------------------------------------------------- 工具

    /** 渲染 1 帧(时间戳单调递增)并返回 PNG 字节 */
    private fun frameBytes(scene: ImageComposeScene): ByteArray {
        val bytes = scene.render(frameTime).encodeToData()!!.bytes
        frameTime += 16_000_000L
        return bytes
    }

    private fun readImage(bytes: ByteArray): BufferedImage =
        ImageIO.read(ByteArrayInputStream(bytes))

    private fun grey(image: BufferedImage, x: Int, y: Int): Int = image.getRGB(x, y) and 0xFF

    /** 自上而下找第一行"明显偏绿"的像素(纯绿面板的上边缘);找不到返回 -1 */
    private fun firstGreenRow(image: BufferedImage, x: Int): Int {
        for (y in 0 until image.height) {
            val rgb = image.getRGB(x, y)
            val r = (rgb shr 16) and 0xFF
            val g = (rgb shr 8) and 0xFF
            if (g > 100 && r < 150) return y
        }
        return -1
    }

    private fun save(bytes: ByteArray, name: String) {
        val dir = File(System.getProperty("ordo.reportDir") ?: "build/reports")
        dir.mkdirs()
        File(dir, name).writeBytes(bytes)
    }

    // ---------------------------------------------------------------- 用例

    @Test
    fun `浮层打开时首帧就是终态`() {
        frameTime = 0L
        val scene = ImageComposeScene(width = 240, height = 240, density = Density(1f)) {
            OrdoTheme(dark = false) {
                Box(Modifier.fillMaxSize().background(Color.White)) {
                    OrdoOverlay(visible = true, onDismiss = {}) {
                        Box(Modifier.size(80.dp).background(GREEN))
                    }
                }
            }
        }
        val image = readImage(frameBytes(scene))

        // 直接 openSettings() 再取第 0 帧的离屏用例(RenderSmokeTest)靠这条:不能是"刚淡入到 0"的透明图
        assertEquals("打开态首帧应是落位后的纯色面板", GREEN_RGB, image.getRGB(120, 120))
        val corner = grey(image, 2, 2)
        assertTrue("遮罩首帧就该到位(28% 黑压在白底上约 183),实际 $corner", corner in 150..220)
        scene.close()
    }

    @Test
    fun `浮层入场时面板由小到大且全程纯色`() {
        frameTime = 0L
        var open by mutableStateOf(false)
        val scene = ImageComposeScene(width = 240, height = 240, density = Density(1f)) {
            OrdoTheme(dark = false) {
                Box(Modifier.fillMaxSize().background(Color.White)) {
                    OrdoOverlay(visible = open, onDismiss = {}) {
                        Box(Modifier.size(120.dp).background(GREEN))
                    }
                }
            }
        }

        assertEquals("关闭态不该画出浮层", WHITE_RGB, readImage(frameBytes(scene)).getRGB(120, 120))

        open = true
        val edges = ArrayList<Int>()
        var midFrame: ByteArray? = null
        repeat(24) {
            val bytes = frameBytes(scene)
            val image = readImage(bytes)
            // 关键断言:面板中心从头到尾都是**纯绿**。若面板被 alpha 图层包住,这里会随进度掺白/掺灰
            assertEquals("面板本体 alpha 必须恒为 1(不能藏在透明度层里)", GREEN_RGB, image.getRGB(120, 120))
            val edge = firstGreenRow(image, 120)
            edges += edge
            if (midFrame == null && edge > 0) midFrame = bytes
        }
        midFrame?.let { save(it, "ordo-transition-overlay.png") }

        // 面板 120dp 居中于 240px:落位后上边缘 = 120 - 60 = 60;入场首帧 scale 0.96 + 下移 14px ≈ 76
        assertTrue(
            "入场时面板应从小(0.96)长到 1:上边缘应自下收上来,实测 $edges",
            edges.first() > edges.last()
        )
        assertTrue("入场首帧应仍在下方(≈76),实测 ${edges.first()}", edges.first() >= 70)
        assertEquals("落位后面板上边缘应回到 60", 60, edges.last())
        scene.close()
    }

    @Test
    fun `浮层退场期间继续用可见快照渲染面板`() {
        frameTime = 0L
        var open by mutableStateOf(true)
        val scene = ImageComposeScene(width = 240, height = 240, density = Density(1f)) {
            OrdoTheme(dark = false) {
                Box(Modifier.fillMaxSize().background(Color.White)) {
                    // 与 ScheduleSheet / FastFind 宿主同款:可见时写快照,退场期间读快照
                    val last = rememberLastState<Boolean>()
                    if (open) last.value = true
                    OrdoOverlay(visible = open, onDismiss = {}) {
                        last.value?.let { Box(Modifier.size(80.dp).background(GREEN)) }
                    }
                }
            }
        }

        assertEquals("打开态面板可见", GREEN_RGB, readImage(frameBytes(scene)).getRGB(120, 120))

        open = false
        val firstExit = readImage(frameBytes(scene))
        assertEquals(
            "退场第一帧仍应是关掉前的面板(宿主要用快照,而不是读已经清空的实时状态)",
            GREEN_RGB, firstExit.getRGB(120, 120)
        )

        // 200ms(≈13 帧)后应当卸载,画面回到白底
        var after = firstExit
        repeat(18) { after = readImage(frameBytes(scene)) }
        assertEquals("退场结束后应整棵卸载", WHITE_RGB, after.getRGB(120, 120))
        scene.close()
    }

    @Test
    fun `页面切换首帧不过场_切换后淡入并上浮`() {
        frameTime = 0L
        var route by mutableStateOf(0)
        val scene = ImageComposeScene(width = 240, height = 240, density = Density(1f)) {
            OrdoTheme(dark = false) {
                Box(Modifier.fillMaxSize().background(Color.White)) {
                    OrdoPageEnter(key = route) {
                        Box(Modifier.fillMaxSize().background(GREEN))
                    }
                }
            }
        }

        assertEquals("冷启动首帧应直接是终态(不过场)", GREEN_RGB, readImage(frameBytes(scene)).getRGB(120, 120))

        route = 1
        val edges = ArrayList<Int>()
        val alphas = ArrayList<Int>()
        var midFrame: ByteArray? = null
        repeat(18) {
            val bytes = frameBytes(scene)
            val image = readImage(bytes)
            edges += firstGreenRow(image, 120)
            alphas += (image.getRGB(120, 120) shr 16) and 0xFF
            if (midFrame == null && edges.last() > 0) midFrame = bytes
        }
        midFrame?.let { save(it, "ordo-transition-page.png") }

        assertTrue(
            "切清单时应看到上浮过程(内容整体下移 10px,顶部露出底色),实测 $edges",
            edges.any { it >= 2 }
        )
        assertTrue(
            "切清单时应看到淡入过程(中途不是纯绿也不是纯白),实测 $alphas",
            alphas.any { it in 30..235 }
        )
        assertEquals("240ms 后应回到终态", 0, edges.last())
        assertEquals("落位后应是纯绿", GREEN_RGB, readImage(frameBytes(scene)).getRGB(120, 120))
        scene.close()
    }

    @Test
    fun `减弱动态效果开启时过渡时长归零`() {
        var normal = -1
        var reduced = -1
        var normalPage = -1
        var reducedPage = -1

        val scene = ImageComposeScene(width = 8, height = 8, density = Density(1f)) {
            OrdoTheme(dark = false) {
                normal = motionMillis(OrdoMotion.OVERLAY_IN)
                normalPage = motionMillis(OrdoMotion.PAGE_FADE)
            }
        }
        scene.render(0L)
        scene.close()

        val reducedScene = ImageComposeScene(width = 8, height = 8, density = Density(1f)) {
            OrdoTheme(dark = false, reduceMotion = true) {
                reduced = motionMillis(OrdoMotion.OVERLAY_IN)
                reducedPage = motionMillis(OrdoMotion.PAGE_FADE)
            }
        }
        reducedScene.render(0L)
        reducedScene.close()

        assertEquals("默认应取 §5.5 的 280ms", 280, normal)
        assertEquals("默认页面切换应取 §5.5 的 240ms", 240, normalPage)
        assertEquals("减弱动态效果开启后浮层入场应为 0ms", 0, reduced)
        assertEquals("减弱动态效果开启后页面切换应为 0ms", 0, reducedPage)
    }

    private companion object {
        val GREEN: Color = Color(0xFF00FF00)
        val GREEN_RGB: Int = 0xFF00FF00.toInt()
        val WHITE_RGB: Int = 0xFFFFFFFF.toInt()
    }
}
