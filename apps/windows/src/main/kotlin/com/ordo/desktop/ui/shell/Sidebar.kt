package com.ordo.desktop.ui.shell

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsHoveredAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.ordo.core.model.Project
import com.ordo.desktop.app.OrdoRoute
import com.ordo.desktop.app.OrdoViewModel
import com.ordo.desktop.app.UiState
import com.ordo.desktop.ui.common.OrdoIcons
import com.ordo.desktop.ui.common.OrdoIconButton
import com.ordo.desktop.ui.common.OrdoTextField
import com.ordo.desktop.ui.common.ProgressRing
import com.ordo.desktop.ui.theme.OrdoRadius
import com.ordo.desktop.ui.theme.OrdoSize
import com.ordo.desktop.ui.theme.OrdoSpace
import com.ordo.desktop.ui.theme.OrdoType
import com.ordo.desktop.ui.theme.ordoColors

/**
 * 侧栏(04-UI规范 §3):固定清单 → 区域/项目(进度环)→ 标签 → 底部工具。
 * 宽 248,项高 34,选中态为主色 12% 底 + 图标着主色。
 */
@Composable
fun Sidebar(state: UiState, vm: OrdoViewModel, modifier: Modifier = Modifier) {
    val colors = ordoColors
    var addingArea by remember { mutableStateOf(false) }
    var addingProjectIn by remember { mutableStateOf<String?>(null) }

    Column(
        modifier
            .width(OrdoSpace.sidebarWidth)
            .fillMaxHeight()
            .background(colors.sidebar)
    ) {
        BrandHeader()
        Column(Modifier.padding(horizontal = OrdoSpace.s)) {
            SidebarItem(OrdoIcons.Inbox, "收件箱", state.counts.inbox, state.route == OrdoRoute.Inbox, onClick = {
                vm.navigate(OrdoRoute.Inbox)
            })
            SidebarItem(OrdoIcons.Today, "今天", state.counts.today, state.route == OrdoRoute.Today, onClick = {
                vm.navigate(OrdoRoute.Today)
            })
            SidebarItem(OrdoIcons.Upcoming, "计划", state.counts.upcoming, state.route == OrdoRoute.Upcoming, onClick = {
                vm.navigate(OrdoRoute.Upcoming)
            })
            SidebarItem(OrdoIcons.Anytime, "随时", state.counts.anytime, state.route == OrdoRoute.Anytime, onClick = {
                vm.navigate(OrdoRoute.Anytime)
            })
            SidebarItem(OrdoIcons.Someday, "某天", state.counts.someday, state.route == OrdoRoute.Someday, onClick = {
                vm.navigate(OrdoRoute.Someday)
            })
            SidebarItem(OrdoIcons.Logbook, "日志簿", state.counts.logbook, state.route == OrdoRoute.Logbook, onClick = {
                vm.navigate(OrdoRoute.Logbook)
            })
        }

        Box(Modifier.padding(horizontal = OrdoSpace.m, vertical = OrdoSpace.s)) {
            Box(Modifier.fillMaxWidth().height(1.dp).background(colors.hairline))
        }

        Column(
            Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = OrdoSpace.s)
        ) {
            Row(
                Modifier.fillMaxWidth().padding(start = OrdoSpace.m, end = OrdoSpace.xs, top = OrdoSpace.xs),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text("区域", style = OrdoType.micro, color = colors.textSecondary)
                Spacer(Modifier.weight(1f))
                OrdoIconButton(OrdoIcons.Add, "新建区域", { addingArea = true }, size = 24.dp, iconSize = 14.dp)
            }
            if (addingArea) {
                InlineCreator(
                    placeholder = "区域名称,回车确认",
                    onCommit = { name ->
                        vm.createArea(name)
                        addingArea = false
                    },
                    onCancel = { addingArea = false }
                )
            }
            state.areas.forEach { area ->
                val projects = state.projects.filter { it.areaId == area.id && it.status == com.ordo.core.model.Status.OPEN }
                AreaNode(
                    name = area.name,
                    count = projects.sumOf { state.counts.projects[it.id] ?: 0 },
                    selected = state.route is OrdoRoute.Area && (state.route as OrdoRoute.Area).id == area.id,
                    onClick = { vm.navigate(OrdoRoute.Area(area.id)) },
                    onAddProject = { addingProjectIn = area.id },
                    onRename = { vm.renameArea(area.id, it) },
                    onDelete = { vm.requestDeleteArea(area.id, area.name) }
                )
                if (addingProjectIn == area.id) {
                    InlineCreator(
                        placeholder = "项目名称,回车确认",
                        onCommit = { name ->
                            vm.createProject(name, area.id)
                            addingProjectIn = null
                        },
                        onCancel = { addingProjectIn = null }
                    )
                }
                projects.forEach { project ->
                    ProjectNode(
                        project = project,
                        count = state.counts.projects[project.id] ?: 0,
                        progress = state.counts.projectProgress[project.id] ?: 0f,
                        selected = state.route is OrdoRoute.Project && (state.route as OrdoRoute.Project).id == project.id,
                        onClick = { vm.navigate(OrdoRoute.Project(project.id)) },
                        onRename = { vm.renameProject(project.id, it) },
                        onDelete = { vm.requestDeleteProject(project.id, project.name) }
                    )
                }
            }
            /* 无区域的项目 */
            val orphans = state.projects.filter { it.areaId == null && it.status == com.ordo.core.model.Status.OPEN }
            if (orphans.isNotEmpty()) {
                Row(
                    Modifier.fillMaxWidth().padding(start = OrdoSpace.m, top = OrdoSpace.s),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text("无区域", style = OrdoType.micro, color = colors.textSecondary)
                }
                orphans.forEach { project ->
                    ProjectNode(
                        project = project,
                        count = state.counts.projects[project.id] ?: 0,
                        progress = state.counts.projectProgress[project.id] ?: 0f,
                        selected = state.route is OrdoRoute.Project && (state.route as OrdoRoute.Project).id == project.id,
                        onClick = { vm.navigate(OrdoRoute.Project(project.id)) },
                        onRename = { vm.renameProject(project.id, it) },
                        onDelete = { vm.requestDeleteProject(project.id, project.name) }
                    )
                }
            }

            if (state.tags.isNotEmpty()) {
                Box(Modifier.padding(horizontal = OrdoSpace.s, vertical = OrdoSpace.s)) {
                    Box(Modifier.fillMaxWidth().height(1.dp).background(colors.hairline))
                }
                Text(
                    "标签",
                    style = OrdoType.micro,
                    color = colors.textSecondary,
                    modifier = Modifier.padding(start = OrdoSpace.m, bottom = OrdoSpace.xs)
                )
                state.tags.forEach { tag ->
                    val selected = state.route is OrdoRoute.Tag && (state.route as OrdoRoute.Tag).name == tag.name
                    SidebarItem(
                        icon = OrdoIcons.Tag,
                        label = tag.name,
                        count = state.counts.tags[tag.name] ?: 0,
                        selected = selected,
                        onClick = { vm.navigate(OrdoRoute.Tag(tag.name)) }
                    )
                }
            }
            Spacer(Modifier.height(OrdoSpace.l))
        }

        SidebarFooter(state, vm)
    }
}

@Composable
private fun BrandHeader() {
    val colors = ordoColors
    Row(
        Modifier.fillMaxWidth().padding(horizontal = OrdoSpace.l, vertical = OrdoSpace.l),
        verticalAlignment = Alignment.CenterVertically
    ) {
        OrdoLogo()
        Spacer(Modifier.width(OrdoSpace.s))
        Column {
            Text("Ordo", style = OrdoType.title, color = colors.textPrimary)
            Text("把今天理清楚", style = OrdoType.micro, color = colors.textTertiary)
        }
    }
}

/** 品牌 Logo:开口圆环 + 向内的短划线(04-UI规范 §1) */
@Composable
fun OrdoLogo(size: androidx.compose.ui.unit.Dp = 28.dp, tint: Color? = null) {
    val colors = ordoColors
    val color = tint ?: colors.accent
    Canvas(Modifier.size(size)) {
        val stroke = this.size.minDimension * 0.14f
        val inset = stroke * 1.6f
        drawArc(
            color = color,
            startAngle = 55f,
            sweepAngle = 285f,
            useCenter = false,
            topLeft = Offset(inset, inset),
            size = androidx.compose.ui.geometry.Size(this.size.width - inset * 2, this.size.height - inset * 2),
            style = Stroke(width = stroke, cap = StrokeCap.Round)
        )
        drawLine(
            color = color,
            start = Offset(this.size.width * 0.5f, this.size.height * 0.5f),
            end = Offset(this.size.width * 0.72f, this.size.height * 0.5f),
            strokeWidth = stroke,
            cap = StrokeCap.Round
        )
    }
}

@Composable
private fun SidebarItem(
    icon: ImageVector,
    label: String,
    count: Int?,
    selected: Boolean,
    onClick: () -> Unit,
    trailing: @Composable (() -> Unit)? = null,
    indent: androidx.compose.ui.unit.Dp = 0.dp
) {
    val colors = ordoColors
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    val shape = RoundedCornerShape(OrdoRadius.row)
    Row(
        Modifier
            .fillMaxWidth()
            .height(OrdoSize.sidebarItem)
            .clip(shape)
            .background(
                when {
                    selected -> colors.selected
                    hovered -> colors.hover
                    else -> Color.Transparent
                },
                shape
            )
            .clickable(interactionSource = interaction, indication = null, onClick = onClick)
            .padding(start = OrdoSpace.m + indent, end = OrdoSpace.s),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = if (selected) colors.accent else colors.textSecondary,
            modifier = Modifier.size(OrdoSize.icon)
        )
        Spacer(Modifier.width(10.dp))
        Text(
            text = label,
            style = OrdoType.body,
            color = if (selected) colors.textPrimary else colors.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f)
        )
        if (trailing != null) {
            trailing()
        } else if (count != null && count > 0) {
            Text("$count", style = OrdoType.caption, color = colors.textSecondary)
        }
    }
}

@Composable
private fun AreaNode(
    name: String,
    count: Int,
    selected: Boolean,
    onClick: () -> Unit,
    onAddProject: () -> Unit,
    onRename: (String) -> Unit,
    onDelete: () -> Unit
) {
    val colors = ordoColors
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    var renaming by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf(name) }

    if (renaming) {
        InlineCreator(
            initial = name,
            placeholder = "区域名称",
            onCommit = {
                onRename(it)
                renaming = false
            },
            onCancel = { renaming = false }
        )
        return
    }

    val shape = RoundedCornerShape(OrdoRadius.row)
    Row(
        Modifier
            .fillMaxWidth()
            .height(OrdoSize.sidebarItem)
            .clip(shape)
            .background(if (selected) colors.selected else if (hovered) colors.hover else Color.Transparent, shape)
            .clickable(interactionSource = interaction, indication = null, onClick = onClick)
            .padding(start = OrdoSpace.s, end = OrdoSpace.xs),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(OrdoIcons.Area, contentDescription = null, tint = colors.textSecondary, modifier = Modifier.size(OrdoSize.icon))
        Spacer(Modifier.width(8.dp))
        Text(name, style = OrdoType.body, color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        if (hovered) {
            OrdoIconButton(OrdoIcons.Add, "在此区域新建项目", onAddProject, size = 22.dp, iconSize = 13.dp)
            OrdoIconButton(OrdoIcons.Edit, "重命名区域", { editing = name; renaming = true }, size = 22.dp, iconSize = 13.dp)
            OrdoIconButton(OrdoIcons.Delete, "删除区域", onDelete, size = 22.dp, iconSize = 13.dp)
        } else if (count > 0) {
            Text("$count", style = OrdoType.caption, color = colors.textSecondary)
        }
    }
}

@Composable
private fun ProjectNode(
    project: Project,
    count: Int,
    progress: Float,
    selected: Boolean,
    onClick: () -> Unit,
    onRename: (String) -> Unit,
    onDelete: () -> Unit
) {
    val colors = ordoColors
    val interaction = remember { MutableInteractionSource() }
    val hovered by interaction.collectIsHoveredAsState()
    var renaming by remember { mutableStateOf(false) }

    if (renaming) {
        InlineCreator(
            initial = project.name,
            placeholder = "项目名称",
            onCommit = {
                onRename(it)
                renaming = false
            },
            onCancel = { renaming = false }
        )
        return
    }

    val shape = RoundedCornerShape(OrdoRadius.row)
    Row(
        Modifier
            .fillMaxWidth()
            .height(OrdoSize.sidebarItem)
            .clip(shape)
            .background(if (selected) colors.selected else if (hovered) colors.hover else Color.Transparent, shape)
            .clickable(interactionSource = interaction, indication = null, onClick = onClick)
            .padding(start = OrdoSpace.xl, end = OrdoSpace.s),
        verticalAlignment = Alignment.CenterVertically
    ) {
        ProgressRing(progress = progress, size = OrdoSize.icon, strokeWidth = 2.dp)
        Spacer(Modifier.width(10.dp))
        Text(project.name, style = OrdoType.body, color = colors.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        if (hovered) {
            OrdoIconButton(OrdoIcons.Edit, "重命名项目", { renaming = true }, size = 22.dp, iconSize = 13.dp)
            OrdoIconButton(OrdoIcons.Delete, "删除项目", onDelete, size = 22.dp, iconSize = 13.dp)
        } else if (count > 0) {
            Text("$count", style = OrdoType.caption, color = colors.textSecondary)
        }
    }
}

@Composable
private fun InlineCreator(
    placeholder: String,
    onCommit: (String) -> Unit,
    onCancel: () -> Unit,
    initial: String = ""
) {
    val colors = ordoColors
    var value by remember { mutableStateOf(initial) }
    Row(
        Modifier
            .fillMaxWidth()
            .height(OrdoSize.sidebarItem)
            .clip(RoundedCornerShape(OrdoRadius.row))
            .background(colors.surface, RoundedCornerShape(OrdoRadius.row))
            .padding(horizontal = OrdoSpace.s),
        verticalAlignment = Alignment.CenterVertically
    ) {
        OrdoTextField(
            value = value,
            onValueChange = { value = it },
            placeholder = placeholder,
            textStyle = OrdoType.body,
            modifier = Modifier.weight(1f),
            onEnter = { if (value.isNotBlank()) onCommit(value.trim()) },
            onEscape = onCancel
        )
    }
}

@Composable
private fun SidebarFooter(state: UiState, vm: OrdoViewModel) {
    val colors = ordoColors
    Box(Modifier.padding(horizontal = OrdoSpace.m, vertical = OrdoSpace.s)) {
        Box(Modifier.fillMaxWidth().height(1.dp).background(colors.hairline))
    }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = OrdoSpace.s, vertical = OrdoSpace.s),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(OrdoSpace.xs)
    ) {
        OrdoIconButton(
            icon = if (state.dark) OrdoIcons.Light else OrdoIcons.Dark,
            contentDescription = "切换外观",
            onClick = { vm.cycleTheme() }
        )
        Spacer(Modifier.weight(1f))
        OrdoIconButton(OrdoIcons.Settings, "设置", { vm.openSettings() })
    }
}
