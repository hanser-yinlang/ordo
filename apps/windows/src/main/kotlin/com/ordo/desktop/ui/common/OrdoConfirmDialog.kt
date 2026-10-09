package com.ordo.desktop.ui.common

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.ordo.desktop.ui.theme.OrdoRadius
import com.ordo.desktop.ui.theme.OrdoSpace
import com.ordo.desktop.ui.theme.OrdoType
import com.ordo.desktop.ui.theme.ordoColors

/**
 * 破坏性操作的二次确认(04-UI规范 §4 浮层规范:圆角 14、内边距 16、pop-in)。
 *
 * 删除一律是软删除,但项目/区域会连带影响其下内容,所以先问一句;`Esc` 与点击遮罩都算取消。
 */
@Composable
fun OrdoConfirmDialog(
    title: String,
    message: String,
    confirmText: String = "删除",
    cancelText: String = "取消",
    danger: Boolean = true,
    onConfirm: () -> Unit,
    onCancel: () -> Unit
) {
    val colors = ordoColors
    val scrim = remember { MutableInteractionSource() }
    val inner = remember { MutableInteractionSource() }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color(0x66000000))
            .clickable(interactionSource = scrim, indication = null) { onCancel() },
        contentAlignment = Alignment.Center
    ) {
        Column(
            Modifier
                .width(420.dp)
                .clip(RoundedCornerShape(OrdoRadius.card))
                .background(colors.surface)
                .clickable(interactionSource = inner, indication = null) { /* 吞掉点击 */ }
                .padding(OrdoSpace.l)
        ) {
            Text(title, style = OrdoType.title, color = colors.textPrimary, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(OrdoSpace.s))
            Text(message, style = OrdoType.caption, color = colors.textSecondary)
            Spacer(Modifier.height(OrdoSpace.l))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                OrdoTextButton(text = cancelText, onClick = onCancel)
                Spacer(Modifier.width(OrdoSpace.s))
                OrdoTextButton(text = confirmText, onClick = onConfirm, danger = danger, emphasized = danger)
            }
        }
    }
}
