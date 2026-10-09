package com.ordo.android.ui.shell

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.res.stringResource
import com.ordo.android.R
import com.ordo.android.ui.common.OrdoIcon
import com.ordo.android.ui.common.OrdoIconKind
import com.ordo.android.ui.common.ProgressRing
import com.ordo.android.ui.theme.OrdoLayout
import com.ordo.android.ui.theme.OrdoRadius
import com.ordo.android.ui.theme.OrdoSpace
import com.ordo.android.ui.theme.OrdoTheme
import com.ordo.android.vm.AreaNodeUi
import com.ordo.android.vm.ProjectNodeUi
import com.ordo.android.vm.SidebarCountsUi
import com.ordo.android.vm.TagNodeUi
import com.ordo.android.vm.UiState

/** 侧栏（04 文档 §3 / §4）：固定清单 + 区域/项目(进度环) + 标签 */
@Composable
fun OrdoSidebar(
    state: UiState,
    onNavigate: (String) -> Unit,
    onToggleArea: (String) -> Unit,
    onOpenSettings: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = OrdoTheme.colors
    Column(
        modifier = modifier
            .fillMaxHeight()
            .width(OrdoLayout.sidebarWidth)
            .background(colors.sidebar)
            .padding(vertical = OrdoSpace.m),
    ) {
        BrandRow()
        Spacer(Modifier.height(OrdoSpace.m))

        Column(
            Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = OrdoSpace.s),
        ) {
            FixedListRow(R.string.nav_inbox, OrdoIconKind.Inbox, UiState.ROUTE_INBOX, state, onNavigate)
            FixedListRow(R.string.nav_today, OrdoIconKind.Today, UiState.ROUTE_TODAY, state, onNavigate)
            FixedListRow(R.string.nav_upcoming, OrdoIconKind.Upcoming, UiState.ROUTE_UPCOMING, state, onNavigate)
            FixedListRow(R.string.nav_anytime, OrdoIconKind.Anytime, UiState.ROUTE_ANYTIME, state, onNavigate)
            FixedListRow(R.string.nav_someday, OrdoIconKind.Someday, UiState.ROUTE_SOMEDAY, state, onNavigate)
            FixedListRow(R.string.nav_logbook, OrdoIconKind.Logbook, UiState.ROUTE_LOGBOOK, state, onNavigate)

            if (state.areas.isNotEmpty()) {
                SectionLabel(text = stringResource(R.string.nav_section_areas))
                state.areas.forEach { area ->
                    AreaRow(area = area, state = state, onNavigate = onNavigate, onToggleArea = onToggleArea)
                }
            }

            if (state.tags.isNotEmpty()) {
                SectionLabel(text = stringResource(R.string.nav_section_tags))
                state.tags.forEach { tag -> TagRow(tag = tag, state = state, onNavigate = onNavigate) }
            }
            Spacer(Modifier.height(OrdoSpace.l))
        }

        OrdoDividerSoft()
        Row(
            Modifier
                .fillMaxWidth()
                .clickable(onClick = onOpenSettings)
                .padding(horizontal = OrdoSpace.l, vertical = OrdoSpace.m),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OrdoIcon(OrdoIconKind.Settings, size = OrdoLayout.sidebarIconSize)
            Spacer(Modifier.width(OrdoSpace.s))
            Text(
                text = stringResource(R.string.nav_settings),
                style = OrdoTheme.type.caption,
                color = colors.textSecondary,
            )
        }
    }
}

@Composable
private fun BrandRow() {
    val colors = OrdoTheme.colors
    Row(
        Modifier.padding(horizontal = OrdoSpace.l),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        OrdoIcon(OrdoIconKind.Today, size = 22.dp, tint = colors.accent, strokeWidth = 1.8f)
        Spacer(Modifier.width(OrdoSpace.s))
        Text(text = stringResource(R.string.app_name), style = OrdoTheme.type.title, color = colors.textPrimary)
        Spacer(Modifier.width(OrdoSpace.s))
        Text(text = "Ordo", style = OrdoTheme.type.micro, color = colors.textTertiary)
    }
}

@Composable
private fun OrdoDividerSoft() {
    Box(
        Modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(OrdoTheme.colors.hairline),
    )
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text = text,
        style = OrdoTheme.type.micro,
        color = OrdoTheme.colors.textTertiary,
        modifier = Modifier.padding(start = OrdoSpace.m, top = OrdoSpace.m, bottom = OrdoSpace.xs),
    )
}

@Composable
private fun FixedListRow(
    labelRes: Int,
    icon: OrdoIconKind,
    route: String,
    state: UiState,
    onNavigate: (String) -> Unit,
) {
    SidebarRow(
        selected = state.routeKey == route,
        onClick = { onNavigate(route) },
    ) {
        OrdoIcon(
            kind = icon,
            size = OrdoLayout.sidebarIconSize,
            tint = if (state.routeKey == route) OrdoTheme.colors.accent else OrdoTheme.colors.textSecondary,
        )
        Spacer(Modifier.width(OrdoSpace.s))
        Text(
            text = stringResource(labelRes),
            style = OrdoTheme.type.body,
            color = OrdoTheme.colors.textPrimary,
            modifier = Modifier.weight(1f),
        )
        CountBadge(countFor(route, state.counts))
    }
}

private fun countFor(route: String, counts: SidebarCountsUi): Int = when (route) {
    UiState.ROUTE_INBOX -> counts.inbox
    UiState.ROUTE_TODAY -> counts.today
    UiState.ROUTE_UPCOMING -> counts.upcoming
    UiState.ROUTE_ANYTIME -> counts.anytime
    UiState.ROUTE_SOMEDAY -> counts.someday
    UiState.ROUTE_LOGBOOK -> counts.logbook
    else -> 0
}

@Composable
private fun CountBadge(count: Int) {
    if (count <= 0) return
    Text(
        text = count.toString(),
        style = OrdoTheme.type.caption,
        color = OrdoTheme.colors.textSecondary,
    )
}

@Composable
private fun AreaRow(
    area: AreaNodeUi,
    state: UiState,
    onNavigate: (String) -> Unit,
    onToggleArea: (String) -> Unit,
) {
    val colors = OrdoTheme.colors
    val route = "area/${area.id}"
    Column {
        SidebarRow(
            selected = state.routeKey == route,
            onClick = { onNavigate(route) },
        ) {
            OrdoIcon(
                kind = if (area.collapsed) OrdoIconKind.ChevronRight else OrdoIconKind.ChevronDown,
                size = 14.dp,
                tint = colors.textTertiary,
                modifier = Modifier.clickable { onToggleArea(area.id) },
            )
            Spacer(Modifier.width(OrdoSpace.xs))
            OrdoIcon(OrdoIconKind.Area, size = OrdoLayout.sidebarIconSize, tint = colors.textSecondary)
            Spacer(Modifier.width(OrdoSpace.s))
            Text(
                text = area.name,
                style = OrdoTheme.type.body,
                color = colors.textPrimary,
                modifier = Modifier.weight(1f),
            )
        }
        if (!area.collapsed) {
            area.projects.forEach { project ->
                ProjectRowItem(project = project, route = "project/${project.id}", state = state, onNavigate = onNavigate)
            }
        }
    }
}

@Composable
private fun ProjectRowItem(
    project: ProjectNodeUi,
    route: String,
    state: UiState,
    onNavigate: (String) -> Unit,
) {
    val colors = OrdoTheme.colors
    val selected = state.routeKey == route
    Row(
        Modifier
            .fillMaxWidth()
            .padding(start = OrdoSpace.xl)
            .clip(RoundedCornerShape(OrdoRadius.row))
            .background(if (selected) colors.accentSoft else Color.Transparent)
            .clickable { onNavigate(route) }
            .padding(horizontal = OrdoSpace.m, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ProgressRing(
            progress = project.progress,
            size = OrdoLayout.projectRingSize,
            tint = if (project.progress >= 1f) colors.success else colors.accent,
            trackTint = colors.hairline,
        )
        Spacer(Modifier.width(OrdoSpace.s))
        Text(
            text = project.name,
            style = OrdoTheme.type.body,
            color = colors.textPrimary,
            modifier = Modifier.weight(1f),
        )
        CountBadge(project.openCount)
    }
}

@Composable
private fun TagRow(
    tag: TagNodeUi,
    state: UiState,
    onNavigate: (String) -> Unit,
) {
    val colors = OrdoTheme.colors
    val route = "tag/" + java.net.URLEncoder.encode(tag.name, "UTF-8")
    SidebarRow(selected = state.routeKey == route, onClick = { onNavigate(route) }) {
        Box(
            Modifier
                .size(8.dp)
                .clip(CircleShape)
                .background(parseHexColor(tag.color) ?: colors.accent),
        )
        Spacer(Modifier.width(OrdoSpace.s))
        Text(
            text = tag.name,
            style = OrdoTheme.type.body,
            color = colors.textPrimary,
            modifier = Modifier.weight(1f),
        )
        CountBadge(tag.count)
    }
}

@Composable
private fun SidebarRow(
    selected: Boolean,
    onClick: () -> Unit,
    content: @Composable androidx.compose.foundation.layout.RowScope.() -> Unit,
) {
    val colors = OrdoTheme.colors
    Row(
        Modifier
            .fillMaxWidth()
            .height(34.dp)
            .clip(RoundedCornerShape(OrdoRadius.row))
            .background(if (selected) colors.accentSoft else Color.Transparent)
            .clickable(onClick = onClick)
            .padding(horizontal = OrdoSpace.m),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Start,
        content = content,
    )
}

/** "#5B5BD6" → Color；解析失败返回 null */
fun parseHexColor(hex: String?): Color? {
    if (hex.isNullOrBlank()) return null
    return runCatching { Color(android.graphics.Color.parseColor(hex.trim())) }.getOrNull()
}
