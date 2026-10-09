package com.ordo.android.nav

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import com.ordo.android.ui.list.ListScreen
import com.ordo.android.ui.search.SearchScreen
import com.ordo.android.vm.OrdoViewModel
import com.ordo.android.vm.UiState

/**
 * 路由与契约 §4 的派生清单一致：
 *   inbox / today / upcoming / anytime / someday / logbook
 *   project/{id} · area/{id} · tag/{name} · search · settings
 */
@Composable
fun OrdoNavHost(
    navController: NavHostController,
    state: UiState,
    vm: OrdoViewModel,
    onNavigate: (String) -> Unit,
) {
    NavHost(
        navController = navController,
        startDestination = Routes.TODAY,
        modifier = Modifier.fillMaxSize(),
    ) {
        composable(Routes.INBOX) { RouteEffect(Routes.INBOX, vm); ListScreen(state, vm, onNavigate) }
        composable(Routes.TODAY) { RouteEffect(Routes.TODAY, vm); ListScreen(state, vm, onNavigate) }
        composable(Routes.UPCOMING) { RouteEffect(Routes.UPCOMING, vm); ListScreen(state, vm, onNavigate) }
        composable(Routes.ANYTIME) { RouteEffect(Routes.ANYTIME, vm); ListScreen(state, vm, onNavigate) }
        composable(Routes.SOMEDAY) { RouteEffect(Routes.SOMEDAY, vm); ListScreen(state, vm, onNavigate) }
        composable(Routes.LOGBOOK) { RouteEffect(Routes.LOGBOOK, vm); ListScreen(state, vm, onNavigate) }

        composable(Routes.PROJECT_PATTERN) { entry ->
            val id = entry.arguments?.getString(Routes.PROJECT_ARG).orEmpty()
            RouteEffect(Routes.project(id), vm)
            ListScreen(state, vm, onNavigate)
        }
        composable(Routes.AREA_PATTERN) { entry ->
            val id = entry.arguments?.getString(Routes.AREA_ARG).orEmpty()
            RouteEffect(Routes.area(id), vm)
            ListScreen(state, vm, onNavigate)
        }
        composable(Routes.TAG_PATTERN) { entry ->
            val name = entry.arguments?.getString(Routes.TAG_ARG).orEmpty()
            RouteEffect(Routes.tag(name), vm)
            ListScreen(state, vm, onNavigate)
        }

        composable(Routes.SEARCH) {
            RouteEffect(Routes.SEARCH, vm)
            SearchScreen(state = state, vm = vm)
        }
    }
}

/** 进入某个目的地时把「具体路由」同步给 ViewModel（ViewModel 据此决定派生清单） */
@Composable
private fun RouteEffect(routeKey: String, vm: OrdoViewModel) {
    LaunchedEffect(routeKey) { vm.navigate(routeKey) }
}
