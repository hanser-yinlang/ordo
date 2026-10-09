package com.ordo.android.ui.list

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ordo.android.R
import com.ordo.android.ui.common.EmptyState
import com.ordo.android.ui.common.MarkdownPreview
import com.ordo.android.ui.common.MetaPill
import com.ordo.android.ui.common.MetaTone
import com.ordo.android.ui.common.OrdoButton
import com.ordo.android.ui.common.OrdoIcon
import com.ordo.android.ui.common.OrdoIconKind
import com.ordo.android.ui.common.ProgressRing
import com.ordo.android.ui.theme.OrdoLayout
import com.ordo.android.ui.theme.OrdoSpace
import com.ordo.android.ui.theme.OrdoTheme
import com.ordo.android.vm.OrdoViewModel
import com.ordo.android.vm.ProjectHeaderUi
import com.ordo.android.vm.UiState
import com.ordo.core.query.SectionKind

/** 列表区：大标题下的内容（日程 / 分组 / 待办行 / 空状态） */
@Composable
fun ListScreen(
    state: UiState,
    vm: OrdoViewModel,
    onTagClick: (String) -> Unit = {},
) {
    val colors = OrdoTheme.colors
    val projectHeader = state.projectHeader
    val newHeadingName = stringResource(R.string.heading_default_name)

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .widthIn(max = OrdoLayout.contentMaxWidth),
        contentPadding = PaddingValues(
            start = OrdoSpace.l,
            end = OrdoSpace.l,
            top = OrdoSpace.s,
            bottom = 96.dp,
        ),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        if (state.routeKey.startsWith("tag/")) {
            item(key = "tag-toggle") {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .padding(vertical = OrdoSpace.s),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    OrdoButton(
                        label = stringResource(
                            if (state.showCompleted) R.string.row_hide_completed else R.string.row_show_completed,
                        ),
                        onClick = { vm.toggleShowCompleted() },
                    )
                }
            }
        }

        if (projectHeader != null) {
            item(key = "project-header") {
                ProjectHeader(header = projectHeader, vm = vm)
            }
        }

        if (state.agenda.isNotEmpty()) {
            item(key = "agenda-title") {
                SectionTitle(
                    title = stringResource(R.string.section_today_agenda),
                    count = state.agenda.size,
                    tone = MetaTone.NORMAL,
                )
            }
            items(state.agenda, key = { it.id }) { event ->
                Row(
                    Modifier
                        .fillMaxWidth()
                        .padding(vertical = 5.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = event.time,
                        style = OrdoTheme.type.caption,
                        color = if (event.past) colors.textTertiary else colors.textSecondary,
                        modifier = Modifier.width(48.dp),
                    )
                    Box(
                        Modifier
                            .width(3.dp)
                            .height(18.dp)
                            .background(if (event.past) colors.hairline else colors.accent),
                    )
                    Spacer(Modifier.width(OrdoSpace.s))
                    Text(
                        text = event.title,
                        style = OrdoTheme.type.body,
                        color = if (event.past) colors.textTertiary else colors.textPrimary,
                    )
                    Spacer(Modifier.weight(1f))
                    Text(
                        text = event.calendar,
                        style = OrdoTheme.type.micro,
                        color = colors.textTertiary,
                    )
                }
            }
            item(key = "agenda-space") { Spacer(Modifier.height(OrdoSpace.s)) }
        }

        state.sections.forEach { section ->
            item(key = "section-${section.title ?: "default"}-${section.headingId ?: ""}") {
                SectionTitle(
                    title = section.title ?: "",
                    count = section.todos.size,
                    tone = when (section.kind) {
                        SectionKind.TONIGHT -> MetaTone.TONIGHT
                        else -> MetaTone.NORMAL
                    },
                    collapsible = section.headingId != null,
                    collapsed = section.collapsed,
                    onToggle = section.headingId?.let { id -> { vm.toggleHeadingCollapsed(id) } },
                    onAdd = { vm.openComposer(section.headingId?.let { "heading/$it" }) },
                )
            }
            if (!section.collapsed) {
                items(section.todos, key = { it.id }) { row ->
                    TodoRow(
                        row = row,
                        selected = state.selectedTodoId == row.id && state.detail == null,
                        showCompletedMeta = section.kind == SectionKind.COMPLETION_DAY && state.routeKey == UiState.ROUTE_LOGBOOK,
                        onOpen = { vm.openDetail(row.id) },
                        onToggle = { vm.toggleDone(row.id) },
                        onSchedule = { vm.openSchedule(row.id) },
                        onDelete = { vm.deleteTodo(row.id) },
                        onTagClick = onTagClick,
                        showRestore = state.routeKey == UiState.ROUTE_LOGBOOK,
                        onRestore = { vm.restore(row.id) },
                    )
                }
            }
        }

        if (state.totalCount == 0 && projectHeader == null) {
            item(key = "empty") {
                EmptyState(
                    title = stringResource(emptyTitleFor(state.routeKey)),
                    subtitle = stringResource(emptySubtitleFor(state.routeKey)),
                )
            }
        }

        if (projectHeader != null) {
            item(key = "project-actions") {
                Spacer(Modifier.height(OrdoSpace.l))
                Row(horizontalArrangement = Arrangement.spacedBy(OrdoSpace.s)) {
                    OrdoButton(
                        label = stringResource(R.string.composer_new_heading),
                        onClick = { vm.createHeading(projectHeader.id, newHeadingName) },
                    )
                    OrdoButton(
                        label = stringResource(R.string.project_complete),
                        onClick = { vm.completeProject(projectHeader.id) },
                        primary = projectHeader.openCount == 0,
                    )
                }
            }
        }
    }
}

@Composable
private fun ProjectHeader(header: ProjectHeaderUi, vm: OrdoViewModel) {
    val colors = OrdoTheme.colors
    Column(Modifier.padding(bottom = OrdoSpace.m)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            ProgressRing(
                progress = header.progress,
                size = 44.dp,
                strokeWidth = 4.dp,
                tint = if (header.progress >= 1f) colors.success else colors.accent,
                pulse = header.progress >= 1f,
            )
            Spacer(Modifier.width(OrdoSpace.m))
            Column(Modifier.weight(1f)) {
                Text(text = header.name, style = OrdoTheme.type.title, color = colors.textPrimary)
                Text(
                    text = stringResource(
                        R.string.subtitle_project,
                        (header.progress * 100).toInt(),
                        header.openCount,
                    ),
                    style = OrdoTheme.type.caption,
                    color = colors.textSecondary,
                )
            }
            header.areaName?.let { area ->
                MetaPill(text = area, icon = OrdoIconKind.Area)
            }
        }
        if (header.note.isNotBlank()) {
            Spacer(Modifier.height(OrdoSpace.s))
            MarkdownPreview(text = header.note, modifier = Modifier.fillMaxWidth())
        }
        Spacer(Modifier.height(OrdoSpace.s))
    }
}

@Composable
private fun SectionTitle(
    title: String,
    count: Int,
    tone: MetaTone,
    collapsible: Boolean = false,
    collapsed: Boolean = false,
    onToggle: (() -> Unit)? = null,
    onAdd: (() -> Unit)? = null,
) {
    val colors = OrdoTheme.colors
    val titleColor = when (tone) {
        MetaTone.TONIGHT -> colors.tonight
        else -> colors.textSecondary
    }
    Row(
        Modifier
            .fillMaxWidth()
            .padding(top = OrdoSpace.l, bottom = OrdoSpace.xs),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (collapsible && onToggle != null) {
            OrdoIcon(
                kind = if (collapsed) OrdoIconKind.ChevronRight else OrdoIconKind.ChevronDown,
                size = 14.dp,
                tint = colors.textTertiary,
                modifier = Modifier
                    .clickableRow(onToggle)
                    .padding(end = OrdoSpace.xs),
            )
        }
        Text(text = title, style = OrdoTheme.type.micro, color = titleColor)
        if (count > 0) {
            Spacer(Modifier.width(OrdoSpace.s))
            Text(text = count.toString(), style = OrdoTheme.type.micro, color = colors.textTertiary)
        }
        Spacer(Modifier.weight(1f))
        if (onAdd != null) {
            OrdoIcon(
                kind = OrdoIconKind.Plus,
                size = 14.dp,
                tint = colors.textTertiary,
                modifier = Modifier
                    .clickableRow(onAdd)
                    .padding(OrdoSpace.xs),
            )
        }
    }
}

private fun Modifier.clickableRow(onClick: () -> Unit): Modifier =
    this.then(Modifier.clickable(onClick = onClick))

private fun emptyTitleFor(route: String): Int = when (route) {
    UiState.ROUTE_INBOX -> R.string.empty_inbox_title
    UiState.ROUTE_TODAY -> R.string.empty_today_title
    UiState.ROUTE_UPCOMING -> R.string.empty_upcoming_title
    UiState.ROUTE_ANYTIME -> R.string.empty_anytime_title
    UiState.ROUTE_SOMEDAY -> R.string.empty_someday_title
    UiState.ROUTE_LOGBOOK -> R.string.empty_logbook_title
    UiState.ROUTE_SEARCH -> R.string.empty_search_title
    else -> if (route.startsWith("project/")) R.string.empty_project_title else R.string.empty_today_title
}

private fun emptySubtitleFor(route: String): Int = when (route) {
    UiState.ROUTE_INBOX -> R.string.empty_inbox_sub
    UiState.ROUTE_TODAY -> R.string.empty_today_sub
    UiState.ROUTE_UPCOMING -> R.string.empty_upcoming_sub
    UiState.ROUTE_ANYTIME -> R.string.empty_anytime_sub
    UiState.ROUTE_SOMEDAY -> R.string.empty_someday_sub
    UiState.ROUTE_LOGBOOK -> R.string.empty_logbook_sub
    UiState.ROUTE_SEARCH -> R.string.empty_search_sub
    else -> if (route.startsWith("project/")) R.string.empty_project_sub else R.string.empty_generic_sub
}
