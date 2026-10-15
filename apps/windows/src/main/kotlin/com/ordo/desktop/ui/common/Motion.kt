package com.ordo.desktop.ui.common

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.Easing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.ordo.desktop.ui.theme.OrdoMotion
import com.ordo.desktop.ui.theme.motionMillis

/**
 * 过渡动效(04-UI规范 §5.5):三端同一张表。
 *
 * | 场景          | 时长  | 曲线       | 变化                                   |
 * |---------------|-------|------------|----------------------------------------|
 * | 浮层入场      | 280ms | 过渡缓动   | 遮罩淡入;面板 0.96→1 + 上浮 14          |
 * | 浮层退场      | 200ms | 过渡缓动   | 面板缩回 0.96 + 下沉 14,遮罩淡出       |
 * | 页面/清单切换 | 240ms | 过渡缓动   | 淡入 + 上浮 10                          |
 * | 详情栏        | 280ms | 过渡缓动   | 淡入 + 上浮 10(仅入场)                  |
 *
 * v1.7:时长整体放慢、几何加大、曲线换成「柔起长滑」的 [OrdoEasing.transition] ——
 * v1.6 的 180/140/160/220 + `cubic-bezier(.2,.8,.2,1)` 前半段冲得太快,观感"像硬切、不通畅"。
 *
 * 「减弱动态效果」开启时全部降为 0ms([motionMillis])。
 */
object OrdoEasing {
    /**
     * 标准缓动:cubic-bezier(0.2, 0.8, 0.2, 1)。
     *
     * 与 Harmony `OrdoMotion.easingStandard` 是同一条曲线(Android 侧用同系数构造),
     * 三端"起步快、收尾软"的手感因此是同一条。用于 §5 完成时序、§5.2 快加号等既有动效。
     */
    val standard: Easing = CubicBezierEasing(0.2f, 0.8f, 0.2f, 1f)

    /**
     * 过渡缓动:cubic-bezier(0.2, 0, 0, 1)(Material 3 standard)。
     *
     * 起步柔、中段匀速、收尾长滑,专门给 §5.5 的浮层/页面/详情过渡用 ——
     * 与 [standard] 相比,它把位移均匀铺在整段时长里,而不是前 1/3 就冲到终点再干等。
     * 三端同一条:Harmony `OrdoMotion.easingEnter`、Android `OrdoMotion.easingEnter`。
     */
    val transition: Easing = CubicBezierEasing(0.2f, 0f, 0f, 1f)
}

/** §5.5 过渡动效的几何常量(时长在 [OrdoMotion]) */
object OrdoOverlaySpec {
    /** 面板入场起始缩放:0.96 → 1(4% 的"贴入":再小就看不出是一段过渡了) */
    const val SCALE_FROM = 0.96f

    /** 常规浮层遮罩:28% 黑(排期 / 快找) */
    val SCRIM: Color = Color.Black.copy(alpha = 0.28f)

    /** 设置页遮罩更重:40% 黑(与旧实现逐像素一致) */
    val SCRIM_HEAVY: Color = Color(0x66000000)

    /** 浮层面板的入场位移:居中浮层自下方上浮 14dp,顶部浮层(快找)自上方下落 14dp */
    val RISE: Dp = 14.dp

    /** 页面切换 / 详情栏的上浮幅度 */
    val RISE_PAGE: Dp = 10.dp
}

/**
 * 组合期"记住最近一次有效状态"的小容器。
 *
 * 浮层退场的 200ms 里,[visible] 已经是 false、宿主状态也被清空了,而画面还得停在关闭前那一帧上;
 * 所以宿主在"可见时"把状态快照写进这里,退场期间继续用这一份。快照是 [UiState] 这类不可变数据类,
 * 存住它不会连带存住实时状态。
 */
class OrdoLastState<T : Any> {
    var value: T? = null
}

@Composable
fun <T : Any> rememberLastState(): OrdoLastState<T> = remember { OrdoLastState<T>() }

/**
 * 浮层容器(04-UI规范 §5.5):遮罩淡入淡出 + 面板 pop-in(0.96→1 缩放 + 14dp 上浮)。
 *
 * 三条硬约束,都是这个仓库里踩过的坑:
 *
 * 1. **面板自身绝不做 alpha 动画**。`Modifier.shadow` 在 alpha < 1 的图层里根本不画阴影,给整棵
 *    子树蒙一层 alpha 会让面板在整段过渡里零投影,最后一帧才"啪"地补上阴影和圆角(2026-10-14 客户
 *    实测,见 ui/quickadd/QuickAdd.kt 的注释与 QuickAddFabLookTest「菜单面板不能藏在 alpha 动画层里」)。
 *    这里只动 scale / translationY,**面板 alpha 恒为 1**;淡入淡出只交给遮罩。
 * 2. **宿主必须一直组合**。宿主被 `if (开) { … }` 包着时,关闭就是整棵子树被移除,退场根本没机会播
 *    放 —— 所以宿主无条件组合,由 [visible] 驱动过渡。
 * 3. **退场期间内容要还在**。宿主状态已被清空,内容 lambda 必须继续读到关闭前的快照
 *    (见 [rememberLastState]);否则这 200ms 只能看到一块空白遮罩。
 *
 * 首次组合就是打开态时(离屏渲染用例直接 `vm.openSettings()` 后取第 0 帧)直接落在终态,不播入场:
 * 单帧截图必须拿到完整的设置页,而不是一张刚淡入到 0 的透明图。
 *
 * @param onDismiss 点遮罩空白处(或按 Esc 之外的区域)时的关闭回调
 * @param scrim 遮罩色,其 alpha 按进度淡入淡出
 * @param alignment 面板在窗口里的对齐方式(排期/设置居中,快找顶部居中)
 * @param slideFromTop 顶部浮层(快找):自上方下落,且以"上边中点"为缩放锚点
 */
@Composable
fun OrdoOverlay(
    visible: Boolean,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    scrim: Color = OrdoOverlaySpec.SCRIM,
    alignment: Alignment = Alignment.Center,
    slideFromTop: Boolean = false,
    content: @Composable () -> Unit
) {
    val risePx = with(LocalDensity.current) { OrdoOverlaySpec.RISE.toPx() }
    // 「减弱动态效果」在组合期就折算成 0ms:LaunchedEffect 的块不是 @Composable 上下文,
    // 读不到 CompositionLocal,所以两个时长必须先在组合里算好再带进去。
    val enterMs = motionMillis(OrdoMotion.OVERLAY_IN)
    val exitMs = motionMillis(OrdoMotion.OVERLAY_OUT)
    val progress = remember { Animatable(if (visible) 1f else 0f) }

    LaunchedEffect(visible) {
        if (visible) {
            progress.animateTo(
                targetValue = 1f,
                animationSpec = tween(enterMs, easing = OrdoEasing.transition)
            )
        } else if (progress.value > 0f) {
            progress.animateTo(
                targetValue = 0f,
                animationSpec = tween(exitMs, easing = OrdoEasing.transition)
            )
        }
    }

    val p = progress.value
    if (!visible && p <= 0f) return

    Box(
        modifier
            .fillMaxSize()
            .background(scrim.copy(alpha = scrim.alpha * p))
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onDismiss
            ),
        contentAlignment = alignment
    ) {
        Box(
            Modifier.graphicsLayer {
                // 只动 scale / translationY:面板 alpha 恒为 1(见上方第 1 条)
                scaleX = OrdoOverlaySpec.SCALE_FROM + (1f - OrdoOverlaySpec.SCALE_FROM) * p
                scaleY = scaleX
                transformOrigin = if (slideFromTop) TransformOrigin(0.5f, 0f) else TransformOrigin.Center
                translationY = (1f - p) * risePx * (if (slideFromTop) -1f else 1f)
            }
        ) {
            content()
        }
    }
}

/**
 * 页面 / 清单切换的入场动效(04-UI规范 §5.5):淡入 240ms + 上浮 10dp。
 *
 * 首帧**不播** —— 冷启动直接就是终态。两个理由都不是审美问题:
 * 1. 冷启动本来就不该有过场;
 * 2. 离屏渲染用例会在第 0 帧取图并断言"不是空白 / 与静止时不同",首帧淡入会让它们截到透明图。
 *
 * 只有 [key] 变化(切清单 / 进项目 / 进区域 / 进标签)时才重放。
 */
@Composable
fun OrdoPageEnter(key: Any?, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    val risePx = with(LocalDensity.current) { OrdoOverlaySpec.RISE_PAGE.toPx() }
    val enterMs = motionMillis(OrdoMotion.PAGE_FADE)
    val progress = remember { Animatable(1f) }
    var primed by remember { mutableStateOf(false) }
    LaunchedEffect(key) {
        if (!primed) {
            // 第一次组合就是首帧:停在终态,不播
            primed = true
            return@LaunchedEffect
        }
        progress.snapTo(0f)
        progress.animateTo(
            targetValue = 1f,
            animationSpec = tween(enterMs, easing = OrdoEasing.transition)
        )
    }
    Box(
        modifier
            .fillMaxSize()
            .graphicsLayer {
                alpha = progress.value
                translationY = (1f - progress.value) * risePx
            }
    ) {
        content()
    }
}

/**
 * 内联详情卡片 / 分组的入场(04-UI规范 §5.5):淡入 280ms + 上浮 10dp。
 *
 * 只做入场:卸载由调用方决定 —— 卡片消失时下面的行本来就立刻回流,再叠一层退场只会让"点一下等两拍"。
 */
@Composable
fun OrdoRiseIn(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    val risePx = with(LocalDensity.current) { OrdoOverlaySpec.RISE_PAGE.toPx() }
    val enterMs = motionMillis(OrdoMotion.DETAIL)
    val progress = remember { Animatable(0f) }
    LaunchedEffect(Unit) {
        progress.animateTo(
            targetValue = 1f,
            animationSpec = tween(enterMs, easing = OrdoEasing.transition)
        )
    }
    Box(
        modifier.graphicsLayer {
            alpha = progress.value
            translationY = (1f - progress.value) * risePx
        }
    ) {
        content()
    }
}
