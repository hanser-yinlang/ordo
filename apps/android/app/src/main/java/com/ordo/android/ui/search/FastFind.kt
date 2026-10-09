package com.ordo.android.ui.search

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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.ordo.android.R
import com.ordo.android.ui.common.EmptyState
import com.ordo.android.ui.common.MetaPill
import com.ordo.android.ui.common.OrdoCard
import com.ordo.android.ui.common.OrdoIcon
import com.ordo.android.ui.common.OrdoIconKind
import com.ordo.android.ui.common.OrdoScrim
import com.ordo.android.ui.common.OrdoTextField
import com.ordo.android.ui.theme.OrdoLayout
import com.ordo.android.ui.theme.OrdoRadius
import com.ordo.android.ui.theme.OrdoSpace
import com.ordo.android.ui.theme.OrdoTheme
import com.ordo.android.vm.OrdoViewModel
import com.ordo.android.vm.SearchKind
import com.ordo.android.vm.SearchResultUi
import com.ordo.android.vm.UiState

/** 快找浮层（04 文档 §4）：顶部输入 44 高、结果行 36、↑↓/Enter/Esc */
@Composable
fun FastFind(
    state: UiState,
    vm: OrdoViewModel,
    onNavigate: (String) -> Unit,
) {
    val colors = OrdoTheme.colors
    var query by remember { mutableStateOf(state.searchQuery) }
    var selected by remember { mutableIntStateOf(0) }
    val focusRequester = remember { FocusRequester() }

    LaunchedEffect(Unit) { focusRequester.requestFocus() }

    Box(Modifier.fillMaxSize()) {
        OrdoScrim(onClick = vm::closeFastFind)
        Column(
            Modifier
                .fillMaxWidth()
                .padding(OrdoSpace.l)
                .onPreviewKeyEvent { event ->
                    if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                    when (event.key) {
                        Key.DirectionDown -> {
                            selected = (selected + 1).coerceAtMost((state.searchResults.size - 1).coerceAtLeast(0))
                            true
                        }
                        Key.DirectionUp -> {
                            selected = (selected - 1).coerceAtLeast(0)
                            true
                        }
                        Key.Enter -> {
                            state.searchResults.getOrNull(selected)?.let { pick(it, vm, onNavigate) }
                            true
                        }
                        Key.Escape -> {
                            vm.closeFastFind()
                            true
                        }
                        else -> false
                    }
                },
        ) {
            OrdoCard(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(OrdoSpace.m)) {
                    OrdoTextField(
                        value = query,
                        onValueChange = {
                            query = it
                            selected = 0
                            vm.onSearchQueryChange(it)
                        },
                        placeholder = stringResource(R.string.fastfind_hint),
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(44.dp),
                        // 与新建浮层同源：焦点必须交给真正的可聚焦节点，
                        // 否则 ↑↓/Enter/Esc 收不到 key 事件（外层 Column 的 onPreviewKeyEvent 形同虚设）
                        focusRequester = focusRequester,
                    )
                    Spacer(Modifier.height(OrdoSpace.s))
                    if (state.searchResults.isEmpty()) {
                        Text(
                            text = stringResource(R.string.fastfind_empty),
                            style = OrdoTheme.type.caption,
                            color = colors.textSecondary,
                            modifier = Modifier.padding(vertical = OrdoSpace.s),
                        )
                    } else {
                        LazyColumn(Modifier.fillMaxWidth().height(320.dp)) {
                            itemsIndexed(state.searchResults, key = { _, item -> item.kind.name + item.id }) { index, item ->
                                SearchResultRow(
                                    result = item,
                                    selected = index == selected,
                                    onClick = { pick(item, vm, onNavigate) },
                                )
                            }
                        }
                    }
                    Spacer(Modifier.height(OrdoSpace.xs))
                    Text(
                        text = stringResource(R.string.fastfind_hint_keys),
                        style = OrdoTheme.type.micro,
                        color = colors.textTertiary,
                    )
                }
            }
        }
    }
}

/** 搜索页（路由 #/search）：与快找共用结果模型 */
@Composable
fun SearchScreen(state: UiState, vm: OrdoViewModel) {
    Column(
        Modifier
            .fillMaxSize()
            .padding(OrdoSpace.l),
        verticalArrangement = Arrangement.spacedBy(OrdoSpace.s),
    ) {
        OrdoTextField(
            value = state.searchQuery,
            onValueChange = vm::onSearchQueryChange,
            placeholder = stringResource(R.string.fastfind_hint),
            modifier = Modifier.fillMaxWidth(),
        )
        if (state.searchResults.isEmpty()) {
            EmptyState(
                title = stringResource(R.string.empty_search_title),
                subtitle = stringResource(R.string.empty_search_sub),
            )
        } else {
            LazyColumn(contentPadding = PaddingValues(bottom = 96.dp)) {
                itemsIndexed(state.searchResults, key = { _, item -> item.kind.name + item.id }) { _, item ->
                    SearchResultRow(
                        result = item,
                        selected = false,
                        onClick = { pick(item, vm, { route -> vm.navigate(route) }) },
                    )
                }
            }
        }
    }
}

@Composable
private fun SearchResultRow(
    result: SearchResultUi,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val colors = OrdoTheme.colors
    Row(
        Modifier
            .fillMaxWidth()
            .height(36.dp)
            .clip(RoundedCornerShape(OrdoRadius.row))
            .background(if (selected) colors.accentSoft else colors.surface)
            .clickable(onClick = onClick)
            .padding(horizontal = OrdoSpace.s),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        OrdoIcon(
            kind = when (result.kind) {
                SearchKind.TODO -> OrdoIconKind.Anytime
                SearchKind.PROJECT -> OrdoIconKind.Project
                SearchKind.AREA -> OrdoIconKind.Area
                SearchKind.TAG -> OrdoIconKind.Tag
            },
            size = OrdoLayout.metaIconSize,
            tint = colors.textSecondary,
        )
        Spacer(Modifier.width(OrdoSpace.s))
        Text(
            text = result.title,
            style = OrdoTheme.type.body,
            color = colors.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        result.subtitle?.let { subtitle ->
            MetaPill(text = subtitle)
        }
    }
}

private fun pick(result: SearchResultUi, vm: OrdoViewModel, onNavigate: (String) -> Unit) {
    if (result.route.startsWith(OrdoViewModel.ROUTE_DETAIL_PREFIX)) {
        vm.closeFastFind()
        vm.openDetail(result.id)
    } else {
        vm.closeFastFind()
        onNavigate(result.route)
    }
}
