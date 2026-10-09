package com.ordo.desktop.ui.search

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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.ordo.core.query.ListQuery
import com.ordo.desktop.app.OrdoRoute
import com.ordo.desktop.app.OrdoViewModel
import com.ordo.desktop.app.UiState
import com.ordo.desktop.ui.common.OrdoFormat
import com.ordo.desktop.ui.common.OrdoIcons
import com.ordo.desktop.ui.common.OrdoTextField
import com.ordo.desktop.ui.theme.OrdoRadius
import com.ordo.desktop.ui.theme.OrdoSize
import com.ordo.desktop.ui.theme.OrdoSpace
import com.ordo.desktop.ui.theme.OrdoType
import com.ordo.desktop.ui.theme.ordoColors

/** 快找结果条目 */
private data class FastFindItem(
    val icon: androidx.compose.ui.graphics.vector.ImageVector,
    val title: String,
    val hint: String,
    val route: OrdoRoute,
    val todoId: String? = null
)

/**
 * 快找浮层(04-UI规范 §1.2 / §4):输入即搜,`↑↓` 选择,`Enter` 直达,`Esc` 关闭。
 * 搜索范围:固定清单 / 项目 / 区域 / 标签 / 待办(引擎的 Search 查询)。
 */
@Composable
fun FastFindOverlay(state: UiState, vm: OrdoViewModel) {
    if (!state.fastFindOpen) return
    val colors = ordoColors
    var query by remember { mutableStateOf("") }
    var index by remember { mutableStateOf(0) }
    val focusRequester = remember { FocusRequester() }

    LaunchedEffect(Unit) { focusRequester.requestFocus() }

    val results = remember(query, state.projects, state.areas, state.tags, state.counts.inbox) {
        buildResults(query, state, vm)
    }
    if (index >= results.size) index = 0

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.28f))
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { vm.closeFastFind() },
        contentAlignment = Alignment.TopCenter
    ) {
        Column(
            Modifier
                .padding(top = 96.dp)
                .widthIn(min = 480.dp, max = 560.dp)
                .clip(RoundedCornerShape(OrdoRadius.sheet))
                .background(colors.surface)
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}
        ) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .height(52.dp)
                    .padding(horizontal = OrdoSpace.l),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(OrdoIcons.Search, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(OrdoSpace.m))
                OrdoTextField(
                    value = query,
                    onValueChange = {
                        query = it
                        index = 0
                    },
                    placeholder = "搜索待办、项目、区域、标签…",
                    textStyle = OrdoType.body,
                    modifier = Modifier
                        .weight(1f)
                        .focusRequester(focusRequester)
                        .onPreviewKeyEvent { event ->
                            if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                            when (event.key) {
                                Key.DirectionDown -> {
                                    if (results.isNotEmpty()) index = (index + 1) % results.size
                                    true
                                }
                                Key.DirectionUp -> {
                                    if (results.isNotEmpty()) index = (index - 1 + results.size) % results.size
                                    true
                                }
                                Key.Enter -> {
                                    results.getOrNull(index)?.let { open(vm, it) }
                                    true
                                }
                                else -> false
                            }
                        },
                    onEscape = { vm.closeFastFind() }
                )
                Text("Esc", style = OrdoType.micro, color = colors.textTertiary)
            }
            Box(Modifier.fillMaxWidth().height(1.dp).background(colors.hairline))
            Column(
                Modifier
                    .fillMaxWidth()
                    .heightIn(max = 380.dp)
                    .verticalScroll(rememberScrollState())
                    .padding(vertical = OrdoSpace.xs)
            ) {
                if (results.isEmpty()) {
                    Text(
                        "没有匹配结果",
                        style = OrdoType.caption,
                        color = colors.textTertiary,
                        modifier = Modifier.padding(OrdoSpace.l)
                    )
                }
                results.forEachIndexed { i, item ->
                    ResultRow(item, selected = i == index, onClick = { open(vm, item) })
                }
            }
            Box(Modifier.fillMaxWidth().height(1.dp).background(colors.hairline))
            Row(
                Modifier.fillMaxWidth().padding(horizontal = OrdoSpace.l, vertical = OrdoSpace.s),
                horizontalArrangement = Arrangement.spacedBy(OrdoSpace.m)
            ) {
                Text("↑↓ 选择", style = OrdoType.micro, color = colors.textTertiary)
                Text("Enter 打开", style = OrdoType.micro, color = colors.textTertiary)
                Text("Esc 关闭", style = OrdoType.micro, color = colors.textTertiary)
            }
        }
    }
}

@Composable
private fun ResultRow(item: FastFindItem, selected: Boolean, onClick: () -> Unit) {
    val colors = ordoColors
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    Row(
        Modifier
            .fillMaxWidth()
            .height(36.dp)
            .padding(horizontal = OrdoSpace.s)
            .clip(RoundedCornerShape(OrdoRadius.row))
            .background(if (selected || hovered) colors.hover else Color.Transparent, RoundedCornerShape(OrdoRadius.row))
            .clickable(interactionSource = interaction, indication = null, onClick = onClick)
            .padding(horizontal = OrdoSpace.s),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(item.icon, contentDescription = null, tint = colors.textSecondary, modifier = Modifier.size(OrdoSize.iconSm))
        Spacer(Modifier.width(OrdoSpace.m))
        Text(item.title, style = OrdoType.body, color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.weight(1f))
        Text(item.hint, style = OrdoType.micro, color = colors.textTertiary)
    }
}

private fun open(vm: OrdoViewModel, item: FastFindItem) {
    vm.navigate(item.route)
    item.todoId?.let { vm.selectTodo(it) }
    vm.closeFastFind()
}

private fun buildResults(query: String, state: UiState, vm: OrdoViewModel): List<FastFindItem> {
    val q = query.trim()
    val items = ArrayList<FastFindItem>()
    if (q.isEmpty()) {
        OrdoRoute.fixed.forEach { route ->
            items.add(FastFindItem(iconFor(route), route.title, "清单", route))
        }
        return items.take(8)
    }
    val lower = q.lowercase()

    OrdoRoute.fixed.filter { it.title.lowercase().contains(lower) }.forEach { route ->
        items.add(FastFindItem(iconFor(route), route.title, "清单", route))
    }
    state.projects.filter { it.name.lowercase().contains(lower) }.take(6).forEach { project ->
        items.add(FastFindItem(OrdoIcons.Area, project.name, "项目", OrdoRoute.Project(project.id)))
    }
    state.areas.filter { it.name.lowercase().contains(lower) }.take(4).forEach { area ->
        items.add(FastFindItem(OrdoIcons.Area, area.name, "区域", OrdoRoute.Area(area.id)))
    }
    state.tags.filter { it.name.lowercase().contains(lower) }.take(4).forEach { tag ->
        items.add(FastFindItem(OrdoIcons.Tag, tag.name, "标签", OrdoRoute.Tag(tag.name)))
    }
    vm.engine.list(ListQuery.Search(q)).take(12).forEach { todo ->
        items.add(
            FastFindItem(
                icon = if (todo.status.isClosed) OrdoIcons.CheckCircle else OrdoIcons.Checklist,
                title = todo.title,
                hint = if (todo.status.isClosed) "已完成" else OrdoFormat.whenLabel(todo),
                route = state.route,
                todoId = todo.id
            )
        )
    }
    return items
}

private fun iconFor(route: OrdoRoute) = when (route) {
    OrdoRoute.Inbox -> OrdoIcons.Inbox
    OrdoRoute.Today -> OrdoIcons.Today
    OrdoRoute.Upcoming -> OrdoIcons.Upcoming
    OrdoRoute.Anytime -> OrdoIcons.Anytime
    OrdoRoute.Someday -> OrdoIcons.Someday
    OrdoRoute.Logbook -> OrdoIcons.Logbook
    else -> OrdoIcons.Search
}
