package com.ordo.android.ui.quickadd

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ordo.android.R
import com.ordo.android.ui.common.OrdoIcon
import com.ordo.android.ui.common.OrdoIconKind
import com.ordo.android.ui.common.OrdoPopover
import com.ordo.android.ui.common.OrdoScrim
import com.ordo.android.ui.common.OrdoTextField
import com.ordo.android.ui.theme.OrdoLayout
import com.ordo.android.ui.theme.OrdoRadius
import com.ordo.android.ui.theme.OrdoSpace
import com.ordo.android.ui.theme.OrdoTheme
import com.ordo.android.vm.OrdoViewModel
import com.ordo.android.vm.UiState

/** 快加号（04 文档 §4）：直径 52，accent 底 + 白色加号；单击新建，长按展开菜单 */
@Composable
fun QuickAddFab(
    state: UiState,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OrdoTheme.colors
    Box(
        modifier = modifier
            .size(OrdoLayout.fabSize)
            .clip(CircleShape)
            .background(colors.accent)
            .pointerInput(state.routeKey) {
                detectTapGestures(
                    onTap = { onClick() },
                    onLongPress = { onLongClick() },
                )
            },
        contentAlignment = Alignment.Center,
    ) {
        OrdoIcon(
            kind = OrdoIconKind.Plus,
            size = 22.dp,
            tint = colors.onAccent,
            strokeWidth = 2.1f,
        )
    }
}

/** 快加号长按菜单：新建待办 / 项目 / 区域（标题在项目内提供） */
@Composable
fun QuickAddMenu(state: UiState, vm: OrdoViewModel) {
    var projectDraft by remember { mutableStateOf("") }
    var areaDraft by remember { mutableStateOf("") }
    var mode by remember { mutableStateOf(Mode.MENU) }

    OrdoPopover(onDismiss = { vm.openQuickAddMenu(false) }) {
        when (mode) {
            Mode.MENU -> {
                MenuItem(OrdoIconKind.Anytime, stringResource(R.string.quickadd_todo)) {
                    vm.openQuickAddMenu(false)
                    vm.openComposer(null)
                }
                MenuItem(OrdoIconKind.Project, stringResource(R.string.quickadd_project)) { mode = Mode.PROJECT }
                MenuItem(OrdoIconKind.Area, stringResource(R.string.quickadd_area)) { mode = Mode.AREA }
            }

            Mode.PROJECT -> {
                Text(
                    text = stringResource(R.string.quickadd_project_hint),
                    style = OrdoTheme.type.micro,
                    color = OrdoTheme.colors.textTertiary,
                )
                Spacer(Modifier.height(OrdoSpace.s))
                OrdoTextField(
                    value = projectDraft,
                    onValueChange = { projectDraft = it },
                    placeholder = stringResource(R.string.quickadd_project_hint),
                    modifier = Modifier.fillMaxWidth(),
                    onSubmit = {
                        vm.createProject(projectDraft, currentAreaId(state))
                        vm.openQuickAddMenu(false)
                    },
                )
            }

            Mode.AREA -> {
                Text(
                    text = stringResource(R.string.quickadd_area_hint),
                    style = OrdoTheme.type.micro,
                    color = OrdoTheme.colors.textTertiary,
                )
                Spacer(Modifier.height(OrdoSpace.s))
                OrdoTextField(
                    value = areaDraft,
                    onValueChange = { areaDraft = it },
                    placeholder = stringResource(R.string.quickadd_area_hint),
                    modifier = Modifier.fillMaxWidth(),
                    onSubmit = {
                        vm.createArea(areaDraft)
                        vm.openQuickAddMenu(false)
                    },
                )
            }
        }
    }
}

private enum class Mode { MENU, PROJECT, AREA }

private fun currentAreaId(state: UiState): String? = when {
    state.routeKey.startsWith("area/") -> state.routeKey.removePrefix("area/")
    state.projectHeader != null -> state.projectHeader.areaName?.let { name ->
        state.areas.firstOrNull { it.name == name }?.id
    }
    else -> null
}

@Composable
private fun MenuItem(icon: OrdoIconKind, label: String, onClick: () -> Unit) {
    val colors = OrdoTheme.colors
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(OrdoRadius.row))
            .clickable(onClick = onClick)
            .padding(vertical = OrdoSpace.s, horizontal = OrdoSpace.xs),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        OrdoIcon(icon, size = 16.dp, tint = colors.textSecondary)
        Spacer(Modifier.width(OrdoSpace.s))
        Text(text = label, style = OrdoTheme.type.body, color = colors.textPrimary)
    }
}

/** 新建待办输入浮层：标题里的日期与 #标签 由 shared:core 的 NLP 解析（契约 §5） */
@Composable
fun ComposerSheet(state: UiState, vm: OrdoViewModel) {
    var draft by remember { mutableStateOf("") }
    val focusRequester = remember { FocusRequester() }
    LaunchedEffect(Unit) { focusRequester.requestFocus() }

    Box(Modifier.fillMaxSize()) {
        OrdoScrim(onClick = vm::closeComposer)
        Column(
            Modifier
                .fillMaxWidth()
                .align(Alignment.BottomCenter)
                .padding(OrdoSpace.l),
        ) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(OrdoRadius.sheet))
                    .background(OrdoTheme.colors.surface)
                    .padding(OrdoSpace.m),
            ) {
                Text(
                    text = state.title,
                    style = OrdoTheme.type.micro,
                    color = OrdoTheme.colors.textTertiary,
                )
                Spacer(Modifier.height(OrdoSpace.s))
                OrdoTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    placeholder = stringResource(R.string.composer_hint),
                    modifier = Modifier
                        .fillMaxWidth()
                        .focusRequester(focusRequester),
                    onSubmit = {
                        vm.submitComposer(draft)
                        draft = ""
                        vm.closeComposer()
                    },
                )
            }
        }
    }
}
