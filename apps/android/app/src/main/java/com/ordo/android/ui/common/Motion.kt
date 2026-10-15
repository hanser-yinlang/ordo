package com.ordo.android.ui.common

import androidx.compose.animation.core.Animatable
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
import com.ordo.android.ui.theme.OrdoLayout
import com.ordo.android.ui.theme.OrdoMotion
import com.ordo.android.ui.theme.OrdoTheme

/**
 * 过渡动效（04 文档 §5.5）：三端同一张表。
 *
 * | 场景          | 时长  | 曲线       | 变化                                     |
 * |---------------|-------|------------|------------------------------------------|
 * | 浮层入场      | 280ms | 过渡缓动   | 遮罩淡入；面板 0.96→1 + 上浮 14           |
 * | 浮层退场      | 200ms | 过渡缓动   | 面板缩回 0.96 + 下沉 14，遮罩淡出         |
 * | 页面/清单切换 | 240ms | 过渡缓动   | 淡入 + 上浮 10                            |
 * | 详情          | 280ms | 过渡缓动   | 淡入 + 上浮 10（仅入场）                  |
 * | 侧栏抽屉      | 260ms | 过渡缓动   | 从左侧平移入/出，遮罩同步淡入淡出         |
 *
 * v1.7：时长整体放慢、几何加大、曲线换成「柔起长滑」的 [OrdoMotion.easingEnter] ——
 * v1.6 的 180/140/160 + `cubic-bezier(.2,.8,.2,1)` 前半段冲得太快，观感「像硬切、不通畅」。
 *
 * 「减弱动态效果」开启时全部降为 0ms（[OrdoTheme.popIn] 等取值处统一折算）。
 */
object OrdoOverlaySpec {
    /** 面板入场起始缩放：0.96 → 1（4% 的「贴入」：再小就看不出是一段过渡了） */
    const val SCALE_FROM = 0.96f

    /** 浮层面板的入场位移：居中浮层自下方上浮 14dp，顶部浮层（快找）自上方下落 14dp */
    val RISE: Dp = 14.dp

    /** 页面切换 / 详情栏的上浮幅度 */
    val RISE_PAGE: Dp = 10.dp
}

/**
 * 组合期「记住最近一次有效状态」的小容器。
 *
 * 浮层退场的 200ms 里 [OrdoOverlay] 的 visible 已是 false、宿主状态也被清空了，而画面还得停在
 * 关闭前那一帧上；所以宿主在「可见时」把状态快照写进这里，退场期间继续用这一份。快照是不可变的
 * UiState 数据类，存住它不会连带存住实时状态。
 */
class OrdoLastState<T : Any> {
    var value: T? = null
}

@Composable
fun <T : Any> rememberLastState(): OrdoLastState<T> = remember { OrdoLastState<T>() }

/**
 * 浮层容器（04 文档 §5.5）：遮罩淡入淡出 + 面板 pop-in（0.96→1 缩放 + 14dp 上浮）。
 *
 * 三条硬约束，都是这个仓库里踩过的坑：
 *
 * 1. **面板自身绝不做 alpha 动画**。`shadow` 在 alpha < 1 的图层里根本不画阴影，给整棵子树蒙一层
 *    alpha 会让面板在整段过渡里零投影，最后一帧才「啪」地补上（见 QuickAdd 的菜单面板注释与
 *    `QuickAddFabLookTest`）。这里只动 scale / translationY，**面板 alpha 恒为 1**；淡入淡出只交给遮罩。
 * 2. **宿主必须一直组合**。宿主被 `if (开) { … }` 包着时，关闭就是整棵子树被移除，退场根本没机会播放 ——
 *    所以宿主无条件组合，由 [visible] 驱动过渡。
 * 3. **退场期间内容要还在**。宿主状态已被清空，内容 lambda 必须继续读到关闭前的快照
 *    （见 [rememberLastState]），否则这 200ms 只能看到一块空白遮罩。
 *
 * 首次组合就是打开态时直接落在终态、不播入场：离屏渲染用例（第 0 帧取图）必须拿到完整面板。
 *
 * @param onDismiss 点遮罩空白处的关闭回调
 * @param scrimColor 遮罩色，null 取主题令牌 `OrdoTheme.colors.scrim`；其 alpha 按进度淡入淡出
 * @param alignment 面板在窗口里的对齐方式（排期居中、快找顶部居中）
 * @param slideFromTop 顶部浮层（快找）：自上方下落，且以「上边中点」为缩放锚点
 */
@Composable
fun OrdoOverlay(
    visible: Boolean,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    scrimColor: Color? = null,
    alignment: Alignment = Alignment.Center,
    slideFromTop: Boolean = false,
    content: @Composable () -> Unit,
) {
    val risePx = with(LocalDensity.current) { OrdoOverlaySpec.RISE.toPx() }
    // 「减弱动态效果」在组合期就折算成 0ms：LaunchedEffect 的块不是 @Composable 上下文，读不到 CompositionLocal
    val enterMs = OrdoTheme.popIn
    val exitMs = OrdoTheme.popOut
    val progress = remember { Animatable(if (visible) 1f else 0f) }

    LaunchedEffect(visible) {
        if (visible) {
            progress.animateTo(1f, animationSpec = tween(enterMs, easing = OrdoMotion.easingEnter))
        } else if (progress.value > 0f) {
            progress.animateTo(0f, animationSpec = tween(exitMs, easing = OrdoMotion.easingEnter))
        }
    }

    val p = progress.value
    if (!visible && p <= 0f) return
    val scrim = scrimColor ?: OrdoTheme.colors.scrim

    Box(modifier.fillMaxSize(), contentAlignment = alignment) {
        Box(
            Modifier
                .fillMaxSize()
                .background(scrim.copy(alpha = scrim.alpha * p))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = onDismiss,
                ),
        )
        Box(
            Modifier.graphicsLayer {
                // 只动 scale / translationY：面板 alpha 恒为 1（见上方第 1 条）
                scaleX = OrdoOverlaySpec.SCALE_FROM + (1f - OrdoOverlaySpec.SCALE_FROM) * p
                scaleY = scaleX
                transformOrigin = if (slideFromTop) TransformOrigin(0.5f, 0f) else TransformOrigin.Center
                translationY = (1f - p) * risePx * (if (slideFromTop) -1f else 1f)
            },
        ) {
            content()
        }
    }
}

/**
 * 页面 / 清单切换的入场动效（04 文档 §5.5）：淡入 240ms + 上浮 10dp。
 *
 * 首帧**不播** —— 冷启动直接就是终态：冷启动本来就不该有过场，且离屏渲染用例会在第 0 帧取图并断言
 * 「不是空白」，首帧淡入会让它们截到透明图。只有 [key] 变化（切清单 / 进项目 / 进区域 / 进标签）时才重放。
 */
@Composable
fun OrdoPageEnter(key: Any?, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    val risePx = with(LocalDensity.current) { OrdoOverlaySpec.RISE_PAGE.toPx() }
    val enterMs = OrdoTheme.pageFade
    val progress = remember { Animatable(1f) }
    var primed by remember { mutableStateOf(false) }
    LaunchedEffect(key) {
        if (!primed) {
            // 第一次组合就是首帧：停在终态，不播
            primed = true
            return@LaunchedEffect
        }
        progress.snapTo(0f)
        progress.animateTo(1f, animationSpec = tween(enterMs, easing = OrdoMotion.easingEnter))
    }
    Box(
        modifier
            .fillMaxSize()
            .graphicsLayer {
                alpha = progress.value
                translationY = (1f - progress.value) * risePx
            },
    ) {
        content()
    }
}

/**
 * 详情卡片的入场（04 文档 §5.5）：淡入 280ms + 上浮 10dp。
 *
 * 只做入场：卸载由调用方决定 —— 卡片消失时下面的内容本来就立刻回流，再叠一层退场只会让「点一下等两拍」。
 */
@Composable
fun OrdoRiseIn(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    val risePx = with(LocalDensity.current) { OrdoOverlaySpec.RISE_PAGE.toPx() }
    val enterMs = OrdoTheme.detail
    val progress = remember { Animatable(0f) }
    LaunchedEffect(Unit) {
        progress.animateTo(1f, animationSpec = tween(enterMs, easing = OrdoMotion.easingEnter))
    }
    Box(
        modifier.graphicsLayer {
            alpha = progress.value
            translationY = (1f - progress.value) * risePx
        },
    ) {
        content()
    }
}

/**
 * 侧栏抽屉（< 768dp，04 文档 §5.5「侧栏折叠 260ms」）：面板从左侧平移入/出，遮罩同步淡入淡出。
 *
 * 抽屉内容（[OrdoSidebar]）只依赖清单数据、不依赖 [visible]，所以退场期间那份 lambda 依然有效，
 * 不需要像浮层那样缓存状态快照。
 */
@Composable
fun OrdoDrawer(
    visible: Boolean,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val widthPx = with(LocalDensity.current) { OrdoLayout.sidebarWidth.toPx() }
    val durMs = OrdoTheme.drawer
    val progress = remember { Animatable(if (visible) 1f else 0f) }

    LaunchedEffect(visible) {
        if (visible) {
            progress.animateTo(1f, animationSpec = tween(durMs, easing = OrdoMotion.easingEnter))
        } else if (progress.value > 0f) {
            progress.animateTo(0f, animationSpec = tween(durMs, easing = OrdoMotion.easingEnter))
        }
    }

    val p = progress.value
    if (!visible && p <= 0f) return

    Box(modifier.fillMaxSize()) {
        OrdoScrim(alpha = p, onClick = onDismiss)
        Box(
            Modifier.graphicsLayer {
                translationX = -(1f - p) * widthPx
            },
        ) {
            content()
        }
    }
}
