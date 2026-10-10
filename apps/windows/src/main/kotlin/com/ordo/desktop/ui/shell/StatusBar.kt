package com.ordo.desktop.ui.shell

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.ordo.desktop.app.OrdoViewModel
import com.ordo.desktop.app.UiState
import com.ordo.desktop.ui.common.OrdoIcons
import com.ordo.desktop.ui.theme.LocalOrdoReduceMotion
import com.ordo.desktop.ui.theme.OrdoSpace
import com.ordo.desktop.ui.theme.OrdoType
import com.ordo.desktop.ui.theme.ordoColors

/**
 * 状态栏(04-UI规范 §3):共 N 项 · 已完成 M 项 · **刷新控件**(§5.3)。
 *
 * 刷新控件 = 28dp 圆形图标按钮([OrdoIcons.Refresh])+ 状态文字:
 * 点击(或 `Ctrl+R`)后图标连续旋转到同步结束,成功短暂转 success 色、失败常驻 danger 色。
 */
@Composable
fun StatusBar(state: UiState, vm: OrdoViewModel) {
    val colors = ordoColors
    val total = state.totalCount
    val done = state.counts.logbook
    val reduceMotion = LocalOrdoReduceMotion.current

    val model = remember { RefreshControlModel() }
    var visual by remember { mutableStateOf(model.visual(0L)) }

    // 状态变化 → 喂给模型;需要动效时按帧推进(帧时钟在生产与离屏渲染里是同一个来源)
    LaunchedEffect(state.syncStatus) {
        var nowMillis = withFrameNanos { it } / 1_000_000L
        model.onStatusChanged(state.syncStatus, nowMillis)
        visual = model.visual(nowMillis)
        while (model.needsFrames(nowMillis)) {
            nowMillis = withFrameNanos { it } / 1_000_000L
            visual = model.visual(nowMillis)
        }
    }

    // 连续旋转:每圈 900ms,linear,直到同步结束(§5.3)
    val spin = rememberInfiniteTransition(label = "ordoRefreshSpin")
    val angle by spin.animateFloat(
        initialValue = 0f,
        targetValue = 360f,
        animationSpec = infiniteRepeatable(
            animation = tween(RefreshControlModel.SPIN_PERIOD_MILLIS, easing = LinearEasing)
        ),
        label = "ordoRefreshAngle"
    )

    Box(Modifier.fillMaxWidth().height(1.dp).background(colors.hairline))
    Row(
        Modifier
            .fillMaxWidth()
            .background(colors.canvas)
            .padding(horizontal = OrdoSpace.xl, vertical = OrdoSpace.s),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OrdoSpace.s)
    ) {
        Text("共 $total 项 · 已完成 $done 项", style = OrdoType.caption, color = colors.textSecondary)
        Spacer(Modifier.weight(1f))
        state.syncDetail?.let { detail ->
            Text(detail.take(60), style = OrdoType.micro, color = colors.textTertiary)
            Spacer(Modifier.width(OrdoSpace.s))
        }
        RefreshButton(
            visual = visual,
            angle = if (visual.spinning && !reduceMotion) angle else 0f,
            onClick = {
                // 同步中 / 防抖期内不响应(§5.3:防止重复触发)
                if (visual.enabled) vm.syncNow()
            }
        )
    }
}

/** 图标 + 文字的刷新控件:图标 28dp 圆形按钮,颜色跟随状态 */
@Composable
private fun RefreshButton(visual: RefreshVisual, angle: Float, onClick: () -> Unit) {
    val colors = ordoColors
    val tone = when (visual.tone) {
        RefreshTone.NEUTRAL -> colors.textSecondary
        RefreshTone.ACCENT -> colors.accent
        RefreshTone.SUCCESS -> colors.success
        RefreshTone.DANGER -> colors.danger
    }
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()

    Row(
        Modifier
            .clip(CircleShape)
            .alpha(if (visual.enabled) 1f else 0.6f)
            .clickable(
                interactionSource = interaction,
                indication = null,
                enabled = visual.enabled,
                onClick = onClick
            )
            .padding(horizontal = OrdoSpace.xs, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            Modifier
                .size(28.dp)
                .clip(CircleShape)
                .background(if (hovered && visual.enabled) colors.hover else Color.Transparent, CircleShape),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = OrdoIcons.Refresh,
                contentDescription = visual.label,
                tint = tone,
                modifier = Modifier
                    .size(16.dp)
                    .rotate(angle)
            )
        }
        Spacer(Modifier.width(OrdoSpace.xs))
        Text(visual.label, style = OrdoType.caption, color = tone)
    }
}
