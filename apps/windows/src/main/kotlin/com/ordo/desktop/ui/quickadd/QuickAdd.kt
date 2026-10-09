package com.ordo.desktop.ui.quickadd

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import com.ordo.desktop.app.OrdoRoute
import com.ordo.desktop.app.OrdoViewModel
import com.ordo.desktop.app.UiState
import com.ordo.desktop.ui.common.OrdoIcons
import com.ordo.desktop.ui.common.OrdoTextField
import com.ordo.desktop.ui.theme.OrdoRadius
import com.ordo.desktop.ui.theme.OrdoSize
import com.ordo.desktop.ui.theme.OrdoSpace
import com.ordo.desktop.ui.theme.OrdoType
import com.ordo.desktop.ui.theme.ordoColors

private enum class NamePrompt { PROJECT, AREA, HEADING }

/**
 * 快加号(04-UI规范 §1.2 / §4):直径 52,主色底 + 白色加号,阴影 elev.sheet。
 * 单击 = 新建待办;点击右侧小箭头展开菜单(新建待办 / 项目 / 区域 / 标题)。
 */
@Composable
fun QuickAdd(state: UiState, vm: OrdoViewModel, modifier: Modifier = Modifier) {
    val colors = ordoColors
    var prompt by remember { mutableStateOf<NamePrompt?>(null) }

    Box(modifier.fillMaxSize(), contentAlignment = Alignment.BottomEnd) {
        Column(
            Modifier.padding(end = OrdoSpace.xl, bottom = OrdoSpace.xl),
            horizontalAlignment = Alignment.End,
            verticalArrangement = Arrangement.spacedBy(OrdoSpace.s)
        ) {
            if (state.quickAddMenuOpen) {
                Column(
                    Modifier
                        .width(200.dp)
                        .clip(RoundedCornerShape(OrdoRadius.card))
                        .background(colors.surface)
                        .padding(OrdoSpace.xs)
                ) {
                    MenuItem(OrdoIcons.Add, "新建待办", "Ctrl+N") {
                        vm.setQuickAddMenu(false)
                        vm.openComposer()
                    }
                    MenuItem(OrdoIcons.Area, "新建项目", null) {
                        vm.setQuickAddMenu(false)
                        prompt = NamePrompt.PROJECT
                    }
                    MenuItem(OrdoIcons.Area, "新建区域", null) {
                        vm.setQuickAddMenu(false)
                        prompt = NamePrompt.AREA
                    }
                    val projectRoute = state.route as? OrdoRoute.Project
                    if (projectRoute != null) {
                        MenuItem(OrdoIcons.Checklist, "新建标题", null) {
                            vm.setQuickAddMenu(false)
                            prompt = NamePrompt.HEADING
                        }
                    }
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                OrdoQuickAddCaret { vm.setQuickAddMenu(!state.quickAddMenuOpen) }
                Spacer(Modifier.width(OrdoSpace.s))
                OrdoFab { vm.openComposer() }
            }
        }

        prompt?.let { kind ->
            NameInputDialog(
                title = when (kind) {
                    NamePrompt.PROJECT -> "新建项目"
                    NamePrompt.AREA -> "新建区域"
                    NamePrompt.HEADING -> "新建标题"
                },
                placeholder = "名称,回车确认",
                onConfirm = { name ->
                    when (kind) {
                        NamePrompt.PROJECT -> vm.createProject(name, (state.route as? OrdoRoute.Area)?.id)
                        NamePrompt.AREA -> vm.createArea(name)
                        NamePrompt.HEADING -> (state.route as? OrdoRoute.Project)?.let { vm.createHeading(it.id, name) }
                    }
                    prompt = null
                },
                onDismiss = { prompt = null }
            )
        }
    }
}

@Composable
private fun MenuItem(icon: ImageVector, label: String, shortcut: String?, onClick: () -> Unit) {
    val colors = ordoColors
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    Row(
        Modifier
            .fillMaxWidth()
            .height(34.dp)
            .clip(RoundedCornerShape(OrdoRadius.row))
            .background(if (hovered) colors.hover else Color.Transparent, RoundedCornerShape(OrdoRadius.row))
            .clickable(interactionSource = interaction, indication = null, onClick = onClick)
            .padding(horizontal = OrdoSpace.s),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(icon, contentDescription = null, tint = colors.textSecondary, modifier = Modifier.size(OrdoSize.iconSm))
        Spacer(Modifier.width(OrdoSpace.s))
        Text(label, style = OrdoType.body, color = colors.textPrimary)
        Spacer(Modifier.weight(1f))
        if (shortcut != null) Text(shortcut, style = OrdoType.micro, color = colors.textTertiary)
    }
}

@Composable
private fun OrdoFab(onClick: () -> Unit) {
    val colors = ordoColors
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    Box(
        Modifier
            .size(OrdoSize.fab)
            .shadow(12.dp, CircleShape)
            .clip(CircleShape)
            .background(if (hovered) colors.accent.copy(alpha = 0.92f) else colors.accent, CircleShape)
            .clickable(interactionSource = interaction, indication = null, onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Icon(OrdoIcons.Add, contentDescription = "新建待办", tint = Color.White, modifier = Modifier.size(22.dp))
    }
}

@Composable
private fun OrdoQuickAddCaret(onClick: () -> Unit) {
    val colors = ordoColors
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    Box(
        Modifier
            .size(28.dp)
            .shadow(6.dp, CircleShape)
            .clip(CircleShape)
            .background(if (hovered) colors.chipBg else colors.surface, CircleShape)
            .clickable(interactionSource = interaction, indication = null, onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Icon(OrdoIcons.ExpandMore, contentDescription = "更多新建", tint = colors.textSecondary, modifier = Modifier.size(16.dp))
    }
}

/** 通用名称输入弹窗(新建项目 / 区域 / 标题) */
@Composable
fun NameInputDialog(
    title: String,
    placeholder: String,
    onConfirm: (String) -> Unit,
    onDismiss: () -> Unit
) {
    val colors = ordoColors
    var value by remember { mutableStateOf("") }
    val focusRequester = remember { FocusRequester() }
    LaunchedEffect(Unit) { focusRequester.requestFocus() }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.28f))
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { onDismiss() },
        contentAlignment = Alignment.Center
    ) {
        Column(
            Modifier
                .widthIn(min = 320.dp, max = 420.dp)
                .clip(RoundedCornerShape(OrdoRadius.card))
                .background(colors.surface)
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}
                .padding(OrdoSpace.l)
        ) {
            Text(title, style = OrdoType.title, color = colors.textPrimary)
            Spacer(Modifier.height(OrdoSpace.m))
            OrdoTextField(
                value = value,
                onValueChange = { value = it },
                placeholder = placeholder,
                textStyle = OrdoType.body,
                modifier = Modifier
                    .focusRequester(focusRequester)
                    .clip(RoundedCornerShape(OrdoRadius.row))
                    .background(colors.canvas)
                    .padding(OrdoSpace.m),
                onEnter = { if (value.isNotBlank()) onConfirm(value.trim()) },
                onEscape = onDismiss
            )
            Spacer(Modifier.height(OrdoSpace.s))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                com.ordo.desktop.ui.common.OrdoTextButton("取消", onDismiss)
                Spacer(Modifier.width(OrdoSpace.s))
                com.ordo.desktop.ui.common.OrdoTextButton(
                    "确定",
                    { if (value.isNotBlank()) onConfirm(value.trim()) },
                    emphasized = true
                )
            }
        }
    }
}
