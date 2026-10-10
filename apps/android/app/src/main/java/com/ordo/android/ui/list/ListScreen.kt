package com.ordo.android.ui.list

import androidx.activity.compose.BackHandler
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
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
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
import com.ordo.android.ui.gesture.DragReorder
import com.ordo.android.ui.theme.OrdoLayout
import com.ordo.android.ui.theme.OrdoSpace
import com.ordo.android.ui.theme.OrdoTheme
import com.ordo.android.vm.OrdoViewModel
import com.ordo.android.vm.ProjectCardAction
import com.ordo.android.vm.ProjectHeaderUi
import com.ordo.android.vm.UiState
import com.ordo.android.vm.labelRes
import com.ordo.android.vm.projectCardAction
import com.ordo.core.model.Status
import com.ordo.core.query.SectionKind

/**
 * 当前拖拽会话（UI §5.4）。
 *
 * 被拖行**不改变列表顺序**，只做纵向平移；插入槽位由位移 / 行高换算（[DragReorder]），
 * 松手时才落库，位置未变则不写库。
 */
private data class DragSessionUi(
    val todoId: String,
    val sectionIndex: Int,
    val originIndex: Int,
    val offsetY: Float,
    val targetIndex: Int,
    val rowHeightPx: Float,
)

/** 列表区：大标题下的内容（日程 / 分组 / 待办行 / 空状态） */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ListScreen(
    state: UiState,
    vm: OrdoViewModel,
    onTagClick: (String) -> Unit = {},
) {
    val colors = OrdoTheme.colors
    val projectHeader = state.projectHeader
    val newHeadingName = stringResource(R.string.heading_default_name)

    var session by remember { mutableStateOf<DragSessionUi?>(null) }

    // 拖拽中按返回键 = 取消（行回原位，不写库）
    BackHandler(enabled = session != null) { session = null }

    // 下拉刷新与状态栏刷新键共用同一状态机，表现必须一致（UI §5.3）
    PullToRefreshBox(
        isRefreshing = state.refresh.spinning,
        onRefresh = vm::refresh,
        modifier = Modifier.fillMaxSize(),
    ) {
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

            state.sections.forEachIndexed { sectionIndex, section ->
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
                    val maxIndex = section.todos.lastIndex.coerceAtLeast(0)
                    itemsIndexed(section.todos, key = { _, row -> row.id }) { rowIndex, row ->
                        val active = session?.takeIf { it.sectionIndex == sectionIndex }
                        val isDragged = active?.todoId == row.id
                        Column {
                            // 插入指示线：目标槽位在起始槽位上方 → 画在该项上方
                            if (active != null && active.targetIndex == rowIndex && active.targetIndex <= active.originIndex) {
                                DragIndicator()
                            }
                            TodoRow(
                                row = row,
                                selected = state.selectedTodoId == row.id && state.detail == null,
                                showCompletedMeta = section.kind == SectionKind.COMPLETION_DAY &&
                                    state.routeKey == UiState.ROUTE_LOGBOOK,
                                onOpen = { vm.openDetail(row.id) },
                                onToggle = { vm.toggleDone(row.id) },
                                onSchedule = { vm.openSchedule(row.id) },
                                onDelete = { vm.deleteTodo(row.id) },
                                onTagClick = onTagClick,
                                showRestore = state.routeKey == UiState.ROUTE_LOGBOOK,
                                onRestore = { vm.restore(row.id) },
                                lifted = isDragged,
                                dragging = isDragged,
                                dragOffsetY = if (isDragged) active?.offsetY ?: 0f else 0f,
                                dragShiftY = if (active != null && !isDragged) {
                                    DragReorder.shiftFor(rowIndex, active.originIndex, active.targetIndex) *
                                        active.rowHeightPx
                                } else {
                                    0f
                                },
                                sectionIndex = sectionIndex,
                                rowIndex = rowIndex,
                                onDragStart = { sIdx, rIdx, heightPx ->
                                    session = DragSessionUi(
                                        todoId = row.id,
                                        sectionIndex = sIdx,
                                        originIndex = rIdx,
                                        offsetY = 0f,
                                        targetIndex = rIdx,
                                        rowHeightPx = heightPx,
                                    )
                                },
                                onDragMove = { deltaY ->
                                    session = session?.let { current ->
                                        val offset = current.offsetY + deltaY
                                        current.copy(
                                            offsetY = offset,
                                            targetIndex = DragReorder.targetIndex(
                                                originIndex = current.originIndex,
                                                offsetYPx = offset,
                                                rowHeightPx = current.rowHeightPx,
                                                minIndex = 0,
                                                maxIndex = maxIndex,
                                            ),
                                        )
                                    }
                                },
                                onDragEnd = {
                                    session?.let { current ->
                                        if (current.targetIndex != current.originIndex) {
                                            // 松手才落库；位置未变则完全不写库
                                            val ids = section.todos.map { it.id }.toMutableList()
                                            val moved = ids.removeAt(current.originIndex)
                                            ids.add(current.targetIndex.coerceIn(0, ids.size), moved)
                                            vm.reorderSection(ids)
                                        }
                                    }
                                    session = null
                                },
                                onDragCancel = { session = null },
                            )
                            if (active != null && active.targetIndex == rowIndex && active.targetIndex > active.originIndex) {
                                DragIndicator()
                            }
                        }
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
                        when (projectCardAction(projectHeader.status)) {
                            // 契约 §2.2 v1.1：已完成的项目显示「重新打开」而不是「完成项目」
                            //（后者只会被幂等拒绝，且旧文案会把原因说错）
                            ProjectCardAction.REOPEN -> OrdoButton(
                                label = stringResource(ProjectCardAction.REOPEN.labelRes),
                                onClick = { vm.reopenProject(projectHeader.id) },
                            )

                            ProjectCardAction.COMPLETE -> OrdoButton(
                                label = stringResource(ProjectCardAction.COMPLETE.labelRes),
                                onClick = { vm.completeProject(projectHeader.id) },
                                primary = projectHeader.openCount == 0,
                            )
                        }
                    }
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
            // 已完成态与核心的 project.status 一一对应（不再让"完成项目"按钮出现在已完成的项目上）
            if (header.status == Status.DONE) {
                MetaPill(
                    text = stringResource(R.string.project_status_done),
                    icon = OrdoIconKind.Check,
                    tone = MetaTone.ACCENT,
                )
            } else {
                MetaPill(text = stringResource(R.string.project_status_open), tone = MetaTone.NORMAL)
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
