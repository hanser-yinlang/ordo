package com.ordo.desktop.ui.list

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.scrollBy
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
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.snapshots.SnapshotStateMap
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.ordo.core.model.CalendarEvent
import com.ordo.core.model.Heading
import com.ordo.core.model.Project
import com.ordo.core.model.Status
import com.ordo.core.model.Todo
import com.ordo.core.model.When
import com.ordo.core.query.ListSection
import com.ordo.core.query.SectionKind
import com.ordo.core.util.OrdoDate
import com.ordo.desktop.app.OrdoRoute
import com.ordo.desktop.app.OrdoViewModel
import com.ordo.desktop.app.UiState
import com.ordo.desktop.ui.common.EmptyState
import com.ordo.desktop.ui.common.MarkdownNote
import com.ordo.desktop.ui.common.OrdoIconButton
import com.ordo.desktop.ui.common.OrdoIcons
import com.ordo.desktop.ui.common.OrdoTextButton
import com.ordo.desktop.ui.common.OrdoTextField
import com.ordo.desktop.ui.common.ProgressRing
import com.ordo.desktop.ui.common.SectionHeader
import com.ordo.desktop.ui.theme.OrdoMotion
import com.ordo.desktop.ui.theme.OrdoRadius
import com.ordo.desktop.ui.theme.OrdoSize
import com.ordo.desktop.ui.theme.OrdoSpace
import com.ordo.desktop.ui.theme.OrdoType
import com.ordo.desktop.ui.theme.motionMillis
import com.ordo.desktop.ui.theme.ordoColors
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/**
 * 列表区(04-UI规范 §3):大标题 + 内容区(最大宽度 720,居中)。
 * 详情以内联卡片形式展开在对应行下方。
 *
 * 拖拽排序(04-UI规范 §6)也住在这里:今天 / 收件箱 / 计划 / 随时 / 某天 / 项目等清单共用同一个容器,
 * 因此一处实现即处处可用,按分组计算插入位、松手整表写回 `order`(契约 §4)。
 *
 * @param dragState 仅测试注入;为空时由容器自建
 */
@Composable
fun ListPane(
    state: UiState,
    vm: OrdoViewModel,
    modifier: Modifier = Modifier,
    dragState: ListReorderState? = null
) {
    val colors = ordoColors
    Column(
        modifier
            .fillMaxSize()
            .background(colors.canvas)
    ) {
        ListHeader(state, vm)
        Box(Modifier.weight(1f)) {
            val scroll = rememberScrollState()
            val drag = dragState ?: remember { ListReorderState() }

            // 视口位置 / 滚动量 → 拖拽状态(指针坐标换算成内容坐标)
            LaunchedEffect(drag) {
                snapshotFlow { scroll.value }.collect { drag.scrollOffset = it.toFloat() }
            }
            // Esc 取消拖动:由 OrdoViewModel.escape() 递增令牌
            LaunchedEffect(state.dragCancelToken) {
                if (state.dragCancelToken > 0L) drag.cancel()
            }
            // 拖动中会让全局 Esc/快捷键优先级变化,状态同步给状态层
            LaunchedEffect(drag.active) { vm.setDragActive(drag.active) }
            // 拖到视口上下边缘附近时自动滚动:长清单也能一次拖到看不见的位置
            LaunchedEffect(drag.active) {
                if (!drag.active) return@LaunchedEffect
                while (isActive) {
                    val top = drag.scrollOffset
                    val bottom = top + drag.viewportHeight
                    val y = drag.pointerContentY
                    val delta = when {
                        y < top + AUTO_SCROLL_EDGE_PX -> -AUTO_SCROLL_STEP_PX
                        y > bottom - AUTO_SCROLL_EDGE_PX -> AUTO_SCROLL_STEP_PX
                        else -> 0f
                    }
                    if (delta != 0f) runCatching { scroll.scrollBy(delta) }
                    withFrameNanos { }
                }
            }
            // 换清单时丢弃未完成的拖动
            LaunchedEffect(state.route) { drag.cancel() }

            Column(
                Modifier
                    .fillMaxSize()
                    .verticalScroll(scroll)
                    .onGloballyPositioned { coords ->
                        drag.viewportTop = coords.positionInRoot().y
                        drag.viewportHeight = coords.size.height.toFloat()
                    }
                    .padding(horizontal = OrdoSpace.xl)
            ) {
                // 04-UI规范 §3:内容区最大宽度 720,在清单区内居中
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
                    Box(
                        Modifier
                            .widthIn(max = OrdoSpace.contentMaxWidth)
                            .fillMaxWidth()
                    ) {
                        Column {
                            ListContent(state, vm, drag)
                            Spacer(Modifier.height(96.dp))
                        }
                        ReorderOverlay(state, drag)
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------- 顶部

@Composable
private fun ListHeader(state: UiState, vm: OrdoViewModel) {
    val colors = ordoColors
    val project = (state.route as? OrdoRoute.Project)?.let { vm.engine.project(it.id) }
    val area = (state.route as? OrdoRoute.Area)?.let { vm.engine.area(it.id) }
    val title = when (val route = state.route) {
        is OrdoRoute.Project -> project?.name ?: "项目"
        is OrdoRoute.Area -> area?.name ?: "区域"
        is OrdoRoute.Tag -> "#${route.name}"
        is OrdoRoute.Search -> if (route.text.isBlank()) "搜索" else "搜索：${route.text}"
        else -> route.title
    }
    val total = state.totalCount
    val done = state.counts.logbook

    Row(
        Modifier.fillMaxWidth().padding(start = OrdoSpace.xxl, end = OrdoSpace.xl, top = OrdoSpace.xl, bottom = OrdoSpace.s),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = OrdoType.display, color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                text = subtitleFor(state, total, done),
                style = OrdoType.caption,
                color = colors.textSecondary
            )
        }
        OrdoIconButton(OrdoIcons.Search, "快找 (Ctrl+K)", { vm.openFastFind() })
        OrdoIconButton(OrdoIcons.Add, "新建待办 (Ctrl+N)", { vm.openComposer() })
        OrdoIconButton(OrdoIcons.Settings, "设置", { vm.openSettings() })
    }
}

private fun subtitleFor(state: UiState, total: Int, done: Int): String = when (state.route) {
    OrdoRoute.Logbook -> "共 $total 项已完成"
    OrdoRoute.Today -> {
        val evening = state.sections.firstOrNull { it.kind == SectionKind.TONIGHT }?.todos?.size ?: 0
        val day = total - evening
        "今天 $day 项" + if (evening > 0) " · 今晚 $evening 项" else ""
    }
    OrdoRoute.Upcoming -> "未来 14 天 · $total 项"
    else -> if (done > 0 && total == 0) "已完成 $done 项" else "共 $total 项"
}

// ---------------------------------------------------------------- 拖拽排序

/**
 * 该分组是否支持拖拽排序:日志簿按完成时间、标签与搜索按更新时间,`order` 无意义。
 *
 * 随时与某天由 [com.ordo.desktop.app.orderedSections] 补齐 `order` 排序,因此同样可用。
 */
private fun canReorder(route: OrdoRoute, section: ListSection): Boolean =
    section.todos.size > 1 &&
        section.kind != SectionKind.COMPLETION_DAY &&
        route !is OrdoRoute.Search &&
        route !is OrdoRoute.Tag

/** 拖拽中的浮层:插入指示线 + 跟随指针的"提起来的行" */
@Composable
private fun ReorderOverlay(state: UiState, drag: ListReorderState) {
    val colors = ordoColors
    val draggedId = drag.draggedId ?: return
    val indicator = drag.indicatorY() ?: return
    val todo = state.flatTodos.firstOrNull { it.id == draggedId }

    Box(Modifier.fillMaxWidth()) {
        Row(
            Modifier
                .fillMaxWidth()
                .offset { IntOffset(0, indicator.roundToInt() - 1) },
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                Modifier
                    .size(6.dp)
                    .clip(CircleShape)
                    .background(colors.accent)
            )
            Box(
                Modifier
                    .height(2.dp)
                    .widthIn(min = 40.dp)
                    .weight(1f)
                    .clip(RoundedCornerShape(OrdoRadius.pill))
                    .background(colors.accent)
            )
        }
        if (todo != null) {
            val shape = RoundedCornerShape(OrdoRadius.row)
            Row(
                Modifier
                    .offset { IntOffset(GHOST_LEFT_DP, (drag.pointerContentY - GHOST_HALF_DP).roundToInt()) }
                    .widthIn(max = 380.dp)
                    .clip(shape)
                    .background(colors.surface)
                    .border(1.dp, colors.hairline, shape)
                    .padding(horizontal = OrdoSpace.m, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(OrdoIcons.Drag, contentDescription = null, tint = colors.textTertiary, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(OrdoSpace.s))
                Text(
                    text = todo.title.ifBlank { "(无标题)" },
                    style = OrdoType.caption,
                    color = colors.textPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }
    }
}

/** 跟随指针的"提起来的行"相对内容左侧的偏移(dp)与自身半高 */
private const val GHOST_LEFT_DP = 72
private const val GHOST_HALF_DP = 14

/** 拖动到距视口边缘多少像素内开始自动滚动,以及每帧滚动量 */
private const val AUTO_SCROLL_EDGE_PX = 44f
private const val AUTO_SCROLL_STEP_PX = 20f

// ---------------------------------------------------------------- 内容

@Composable
private fun ListContent(state: UiState, vm: OrdoViewModel, drag: ListReorderState) {
    val completing = remember { mutableStateMapOf<String, Boolean>() }
    val scope = rememberCoroutineScope()
    val reduceMotion = com.ordo.desktop.ui.theme.LocalOrdoReduceMotion.current

    val onToggle: (Todo) -> Unit = { todo ->
        if (todo.status.isClosed) {
            vm.reopen(todo.id)
        } else {
            completing[todo.id] = true
            scope.launch {
                delay(if (reduceMotion) 0L else OrdoMotion.COMPLETE_REMOVE.toLong())
                vm.toggleDone(todo.id)
                completing.remove(todo.id)
            }
        }
    }

    /** 松手:算出分组内的新顺序 → 拼回整表顺序 → 一次 `vm.reorder(ids)` 落库(契约 §4) */
    fun finishDrag() {
        val drop = drag.drop()
        drag.cancel()
        if (drop == null || !drop.changed) return
        val viewIds = state.flatTodos.map { it.id }
        val newViewIds = ReorderMath.applySectionOrder(viewIds, drop.sectionIds, drop.newSectionIds)
        if (newViewIds == viewIds) return
        vm.reorder(newViewIds)
    }

    if (state.composerOpen) {
        ComposerRow(state, vm)
        Spacer(Modifier.height(OrdoSpace.s))
    }

    val project = (state.route as? OrdoRoute.Project)?.let { vm.engine.project(it.id) }
    if (project != null) {
        ProjectCard(project, state, vm)
        Spacer(Modifier.height(OrdoSpace.m))
    }

    if (state.route == OrdoRoute.Today && state.agenda.isNotEmpty()) {
        AgendaBlock(state.agenda)
        Spacer(Modifier.height(OrdoSpace.l))
    }

    if (state.sections.isEmpty()) {
        EmptyBlock(state, vm)
        return
    }

    state.sections.forEachIndexed { sectionIndex, section ->
        SectionBlock(
            section = section,
            sectionIndex = sectionIndex,
            state = state,
            vm = vm,
            completing = completing,
            onToggle = onToggle,
            project = project,
            drag = drag,
            onDropDrag = { finishDrag() }
        )
    }
}

@Composable
private fun EmptyBlock(state: UiState, vm: OrdoViewModel) {
    val colors = ordoColors
    val (title, subtitle) = when (state.route) {
        OrdoRoute.Inbox -> "收件箱是空的" to "想到什么就先记下来，晚点再决定什么时候做"
        OrdoRoute.Today -> "今天没有安排" to "把「随时」里的事挑几件放进今天，或者按 Ctrl+N 新建"
        OrdoRoute.Upcoming -> "未来 14 天没有安排" to "给待办排个日期，它会出现在这里"
        OrdoRoute.Anytime -> "没有「随时」的待办" to "这些是可以随时开始做的事"
        OrdoRoute.Someday -> "「某天」是空的" to "还没想好什么时候做的事放这里"
        OrdoRoute.Logbook -> "日志簿是空的" to "完成的待办会归档到这里"
        else -> "这里还没有内容" to "按 Ctrl+N 新建一条待办"
    }
    Box(Modifier.fillMaxWidth().heightIn(min = 320.dp)) {
        EmptyState(
            title = title,
            subtitle = subtitle,
            icon = OrdoIcons.Checklist,
            action = {
                OrdoTextButton("新建待办", { vm.openComposer() }, emphasized = true)
            }
        )
    }
}

/** 日程区块(只读,契约 §2.8) */
@Composable
private fun AgendaBlock(events: List<CalendarEvent>) {
    val colors = ordoColors
    Column(Modifier.fillMaxWidth()) {
        SectionHeader("日程", events.size.toString())
        events.forEach { event ->
            Row(
                Modifier.fillMaxWidth().heightIn(min = 30.dp).padding(vertical = 3.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = com.ordo.desktop.ui.common.OrdoFormat.timeOf(event.start),
                    style = OrdoType.caption,
                    color = colors.textSecondary,
                    modifier = Modifier.width(44.dp)
                )
                Box(
                    Modifier
                        .width(2.dp)
                        .height(16.dp)
                        .background(colors.accent, RoundedCornerShape(OrdoRadius.pill))
                )
                Spacer(Modifier.width(OrdoSpace.s))
                Text(event.title, style = OrdoType.body, color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (event.calendar.isNotBlank()) {
                    Spacer(Modifier.width(OrdoSpace.s))
                    Text(event.calendar, style = OrdoType.micro, color = colors.textTertiary)
                }
            }
        }
    }
}

/** 分组:普通 / 今晚 / 按天 / 标题 / 更晚 / 完成日 */
@Composable
private fun SectionBlock(
    section: ListSection,
    sectionIndex: Int,
    state: UiState,
    vm: OrdoViewModel,
    completing: SnapshotStateMap<String, Boolean>,
    onToggle: (Todo) -> Unit,
    project: Project?,
    drag: ListReorderState,
    onDropDrag: () -> Unit
) {
    val colors = ordoColors
    val accent = if (section.kind == SectionKind.TONIGHT) colors.tonight else null
    val heading: Heading? = section.headingId?.let { id -> state.headings.firstOrNull { it.id == id } }
    val collapsed = heading?.collapsed == true
    val draggable = canReorder(state.route, section)

    Column(Modifier.fillMaxWidth()) {
        if (section.kind == SectionKind.DAY || section.kind == SectionKind.COMPLETION_DAY || section.kind == SectionKind.LATER) {
            Spacer(Modifier.height(OrdoSpace.l))
        }
        when (section.kind) {
            SectionKind.HEADING -> HeadingRow(heading, section, vm)
            else -> SectionHeader(
                title = section.title.ifBlank { "待办" },
                subtitle = section.subtitle,
                accent = accent,
                trailing = {
                    if (section.kind == SectionKind.TONIGHT || section.kind == SectionKind.PLAIN_TODAY) {
                        OrdoIconButton(
                            OrdoIcons.Add,
                            "在此分组新建待办",
                            {
                                vm.openComposer(if (section.kind == SectionKind.TONIGHT) When.EVENING else When.TODAY)
                            },
                            size = 24.dp,
                            iconSize = 14.dp
                        )
                    }
                }
            )
        }
        if (!collapsed) {
            section.todos.forEachIndexed { rowIndex, todo ->
                val selected = state.selectedId == todo.id
                TodoRow(
                    todo = todo,
                    selected = selected,
                    highlighted = state.highlightId == todo.id,
                    showWhen = showWhenFor(state.route),
                    completing = completing[todo.id] == true,
                    onToggle = { onToggle(todo) },
                    onOpen = { vm.toggleDetail(todo.id) },
                    onSchedule = { vm.openSchedule(todo.id) },
                    onOpenTag = { tag -> vm.navigate(OrdoRoute.Tag(tag)) },
                    onRestore = if (todo.status.isClosed) {
                        { vm.reopen(todo.id) }
                    } else null,
                    showCompletion = section.kind == SectionKind.COMPLETION_DAY,
                    dragHandle = if (draggable) {
                        RowDragHandle(
                            todoId = todo.id,
                            state = drag,
                            sectionIndex = sectionIndex,
                            index = rowIndex,
                            onEnd = onDropDrag,
                            onCancel = { drag.cancel() }
                        )
                    } else {
                        null
                    }
                )
                if (selected) {
                    DetailCardHost(todo, state, vm)
                }
            }
        }
    }
}

private fun showWhenFor(route: OrdoRoute): Boolean = when (route) {
    OrdoRoute.Anytime, OrdoRoute.Someday, OrdoRoute.Logbook, OrdoRoute.Inbox -> true
    is OrdoRoute.Area, is OrdoRoute.Tag, is OrdoRoute.Search -> true
    else -> false
}

@Composable
private fun HeadingRow(heading: Heading?, section: ListSection, vm: OrdoViewModel) {
    val colors = ordoColors
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    var renaming by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf(heading?.name ?: section.title) }

    if (renaming && heading != null) {
        Row(
            Modifier.fillMaxWidth().height(OrdoSize.rowHeight).padding(horizontal = OrdoSpace.s),
            verticalAlignment = Alignment.CenterVertically
        ) {
            OrdoTextField(
                value = draft,
                onValueChange = { draft = it },
                textStyle = OrdoType.bodyStrong,
                modifier = Modifier.weight(1f),
                onEnter = {
                    vm.renameHeading(heading.id, draft)
                    renaming = false
                },
                onEscape = { renaming = false }
            )
        }
        return
    }

    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 34.dp)
            .clip(RoundedCornerShape(OrdoRadius.row))
            .clickable(interactionSource = interaction, indication = null) {
                if (heading != null) vm.toggleHeadingCollapsed(heading.id)
            }
            .padding(horizontal = OrdoSpace.s, vertical = OrdoSpace.xs),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = if (heading?.collapsed == true) OrdoIcons.ChevronRight else OrdoIcons.ExpandMore,
            contentDescription = if (heading?.collapsed == true) "展开" else "折叠",
            tint = colors.textTertiary,
            modifier = Modifier.size(16.dp)
        )
        Spacer(Modifier.width(OrdoSpace.xs))
        Text(section.title, style = OrdoType.bodyStrong, color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        section.subtitle?.let {
            Spacer(Modifier.width(6.dp))
            Text(it, style = OrdoType.micro, color = colors.textTertiary)
        }
        Spacer(Modifier.weight(1f))
        if (hovered && heading != null) {
            OrdoIconButton(OrdoIcons.Add, "在此标题下新建待办", {
                vm.openComposer(When.ANYTIME, heading.id)
            }, size = 24.dp, iconSize = 14.dp)
            OrdoIconButton(OrdoIcons.Edit, "重命名标题", { renaming = true }, size = 24.dp, iconSize = 14.dp)
            OrdoIconButton(OrdoIcons.Archive, "归档标题", { vm.archiveHeading(heading.id) }, size = 24.dp, iconSize = 14.dp)
            OrdoIconButton(OrdoIcons.Delete, "删除标题", { vm.requestDeleteHeading(heading.id, heading.name) }, size = 24.dp, iconSize = 14.dp)
        }
    }
}

/** 项目卡片:大进度环 + 备注 + 完成项目 */
@Composable
private fun ProjectCard(project: Project, state: UiState, vm: OrdoViewModel) {
    val colors = ordoColors
    val progress = state.counts.projectProgress[project.id] ?: 0f
    val animated by animateFloatAsState(
        targetValue = progress,
        animationSpec = tween(motionMillis(OrdoMotion.BASE)),
        label = "projectProgress"
    )
    val openCount = state.counts.projects[project.id] ?: 0
    var editingNote by remember { mutableStateOf(false) }
    var noteDraft by remember(project.id) { mutableStateOf(project.note) }

    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(OrdoRadius.card))
            .background(colors.surface)
            .padding(OrdoSpace.l)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(44.dp), contentAlignment = Alignment.Center) {
                ProgressRing(progress = animated, size = 44.dp, strokeWidth = 3.dp)
                Text("${(animated * 100).toInt()}%", style = OrdoType.micro, color = colors.textSecondary)
            }
            Spacer(Modifier.width(OrdoSpace.m))
            Column(Modifier.weight(1f)) {
                Text("${state.sections.sumOf { it.todos.size }} 项待办 · 剩 $openCount 项未完成", style = OrdoType.caption, color = colors.textSecondary)
                Text(
                    if (project.status == Status.DONE) "已完成" else "进行中",
                    style = OrdoType.micro,
                    color = if (project.status == Status.DONE) colors.success else colors.accent
                )
            }
            if (project.status == Status.DONE) {
                OrdoTextButton("重新打开", { vm.reopenProject(project.id) })
            } else {
                OrdoTextButton(
                    text = "完成项目",
                    onClick = { vm.completeProject(project.id) },
                    enabled = (state.counts.projects[project.id] ?: 0) == 0 && state.sections.all { it.kind != SectionKind.HEADING || it.todos.isEmpty() }
                )
            }
        }
        Spacer(Modifier.height(OrdoSpace.m))
        if (editingNote) {
            OrdoTextField(
                value = noteDraft,
                onValueChange = {
                    noteDraft = it
                    vm.setProjectNote(project.id, it)
                },
                placeholder = "项目备注(支持 Markdown)",
                textStyle = OrdoType.caption,
                singleLine = false,
                onEscape = { editingNote = false }
            )
        } else if (project.note.isBlank()) {
            OrdoTextButton("添加备注", { editingNote = true })
        } else {
            Box(Modifier.clickable { editingNote = true }) {
                MarkdownNote(project.note)
            }
        }
    }
}

/** 新建待办的行内输入 */
@Composable
private fun ComposerRow(state: UiState, vm: OrdoViewModel) {
    val colors = ordoColors
    var draft by remember { mutableStateOf("") }
    val options = composerOptions(state)
    val focusRequester = remember { FocusRequester() }

    // Ctrl+N 之后输入框必须拿到焦点:等第一帧布局完成再请求,节点未就绪时不至于抛异常
    LaunchedEffect(Unit) {
        withFrameNanos { }
        runCatching { focusRequester.requestFocus() }
    }

    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(OrdoRadius.row))
            .background(colors.surface)
            .padding(horizontal = OrdoSpace.m, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Box(
            Modifier
                .size(OrdoSize.checkbox)
                .clip(RoundedCornerShape(OrdoRadius.checkbox))
                .background(Color.Transparent)
        )
        Spacer(Modifier.width(OrdoSpace.s))
        OrdoTextField(
            value = draft,
            onValueChange = { draft = it },
            placeholder = "新待办（试试「明天 18:00 交报告 #重要」）",
            textStyle = OrdoType.body,
            modifier = Modifier.weight(1f).focusRequester(focusRequester),
            onEnter = {
                if (draft.isNotBlank()) {
                    vm.createTodo(draft, options)
                    draft = ""
                    vm.closeComposer()
                }
            },
            // 空输入 Esc 直接关闭,不产生空待办
            onEscape = { vm.closeComposer() }
        )
    }
}

/** 新建待办的落地位置:路由上下文 + 可选的"何时"覆盖 + 标题归属 */
private fun composerOptions(state: UiState): com.ordo.core.store.TodoOptions {
    val route = state.route
    val whenOverride = state.composerWhen
    val headingId = state.composerHeadingId
    val projectId = (route as? OrdoRoute.Project)?.id
    if (projectId != null) {
        return com.ordo.core.store.TodoOptions(
            `when` = whenOverride ?: When.ANYTIME,
            projectId = projectId,
            headingId = headingId
        )
    }
    return when {
        whenOverride != null -> com.ordo.core.store.TodoOptions(`when` = whenOverride)
        route is OrdoRoute.Area -> com.ordo.core.store.TodoOptions(areaId = route.id)
        route is OrdoRoute.Tag -> com.ordo.core.store.TodoOptions(tags = listOf(route.name))
        route == OrdoRoute.Someday -> com.ordo.core.store.TodoOptions(`when` = When.SOMEDAY)
        route == OrdoRoute.Anytime -> com.ordo.core.store.TodoOptions(`when` = When.ANYTIME)
        route == OrdoRoute.Today -> com.ordo.core.store.TodoOptions(`when` = When.TODAY)
        route == OrdoRoute.Upcoming -> com.ordo.core.store.TodoOptions(`when` = When.DATE, date = OrdoDate.plusDays(OrdoDate.todayISO(), 1))
        else -> com.ordo.core.store.TodoOptions(`when` = When.INBOX)
    }
}

/** 详情卡片宿主(占位实现见 ui/detail/DetailCard.kt 的实际入口) */
@Composable
private fun DetailCardHost(todo: Todo, state: UiState, vm: OrdoViewModel) {
    com.ordo.desktop.ui.detail.DetailCard(todo = todo, state = state, vm = vm)
}
