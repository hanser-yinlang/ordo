package com.ordo.desktop.app

import com.ordo.core.model.Op
import com.ordo.core.query.ListQuery
import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.store.OrdoEngine
import com.ordo.core.sync.AuthApi
import com.ordo.core.sync.AuthRequest
import com.ordo.core.sync.AuthResponse
import com.ordo.core.sync.PullResponse
import com.ordo.core.sync.PushRequest
import com.ordo.core.sync.PushResponse
import com.ordo.core.sync.SnapshotResponse
import com.ordo.core.sync.SyncApi
import com.ordo.desktop.net.TokenStore
import com.ordo.desktop.sync.SyncCoordinator
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 多窗口(04-UI规范 §3「每窗口独立路由」)与托盘常驻的视图模型契约。
 *
 * 一个窗口 = 一份 [OrdoViewModel]:路由 / 选中 / 浮层各自独立,但共享同一个引擎 →
 * 任一窗口的写入都会让所有窗口刷新;同步状态则由 [SyncCoordinator] 广播给每个窗口。
 */
class MultiWindowTest {

    private class FakeSyncApi : SyncApi {
        override suspend fun push(request: PushRequest) =
            PushResponse(serverSeq = request.sinceSeq, accepted = request.ops.map(Op::opId))

        override suspend fun pull(sinceSeq: Long, limit: Int) =
            PullResponse(serverSeq = sinceSeq, ops = emptyList(), hasMore = false)

        override suspend fun fetchSnapshot() = SnapshotResponse(serverSeq = 0L)
    }

    private class FakeAuthApi : AuthApi {
        override suspend fun register(request: AuthRequest): AuthResponse = error("测试不使用注册")
        override suspend fun login(request: AuthRequest): AuthResponse = error("测试不使用登录")
        override suspend fun refresh(refreshToken: String): AuthResponse = error("测试不使用刷新")
    }

    private fun setup(): Triple<InMemoryStorage, OrdoEngine, CoroutineScope> {
        val storage = InMemoryStorage()
        val engine = OrdoEngine(storage)
        engine.seedDemoData(force = true)
        return Triple(storage, engine, CoroutineScope(Dispatchers.Unconfined))
    }

    private fun window(engine: OrdoEngine, storage: InMemoryStorage, scope: CoroutineScope) =
        OrdoViewModel(engine = engine, storage = storage, scope = scope)

    @Test
    fun `两个窗口各自独立路由`() {
        val (storage, engine, scope) = setup()
        val first = window(engine, storage, scope)
        val second = window(engine, storage, scope)

        assertEquals(OrdoRoute.Today, first.state.value.route)
        second.navigate(OrdoRoute.Inbox)

        assertEquals("第二个窗口切清单不影响第一个", OrdoRoute.Today, first.state.value.route)
        assertEquals(OrdoRoute.Inbox, second.state.value.route)
        assertTrue(first.state.value.flatTodos.all { it.`when` != com.ordo.core.model.When.INBOX })
        assertTrue(second.state.value.flatTodos.all { it.`when` == com.ordo.core.model.When.INBOX })
        first.dispose()
        second.dispose()
    }

    @Test
    fun `任一窗口写入,所有窗口都刷新`() {
        val (storage, engine, scope) = setup()
        val first = window(engine, storage, scope)
        val second = window(engine, storage, scope)
        second.navigate(OrdoRoute.Inbox)
        val before = second.state.value.flatTodos.size

        first.createTodo("在第一个窗口新建的收件箱待办", com.ordo.core.store.TodoOptions(`when` = com.ordo.core.model.When.INBOX))

        assertEquals("第二个窗口应看到新待办", before + 1, second.state.value.flatTodos.size)
        assertEquals("计数也同步", before + 1, second.state.value.counts.inbox)
        first.dispose()
        second.dispose()
    }

    @Test
    fun `同步结果广播给每个窗口,dispose 后退订`() {
        val (storage, engine, scope) = setup()
        val tokens = TokenStore(storage)
        val coordinator = SyncCoordinator(
            engine = engine,
            syncApi = FakeSyncApi(),
            authApi = FakeAuthApi(),
            tokens = tokens,
            realtime = null,
            scope = scope
        )
        val first = window(engine, storage, scope)
        val second = window(engine, storage, scope)
        first.attachSync(coordinator)
        second.attachSync(coordinator)

        runBlocking { coordinator.syncOnce() }

        assertEquals("两个窗口都应收到同步结果", SyncStatus.SYNCED, first.state.value.syncStatus)
        assertEquals(SyncStatus.SYNCED, second.state.value.syncStatus)

        first.dispose()
        val before = first.state.value.syncStatus
        second.setSyncStatus(SyncStatus.SYNCING)
        runBlocking { coordinator.syncOnce() }

        assertEquals("已 dispose 的窗口不再被回调", before, first.state.value.syncStatus)
        assertEquals("仍在的窗口继续收到结果", SyncStatus.SYNCED, second.state.value.syncStatus)
        second.dispose()
    }

    @Test
    fun `关闭窗口默认最小化到托盘,可以改成直接退出`() {
        val (storage, engine, scope) = setup()
        val first = window(engine, storage, scope)
        assertTrue("默认托盘常驻", first.closeToTray())

        first.setCloseToTray(false)
        assertFalse(first.closeToTray())
        assertEquals("false", storage.kvGet(OrdoViewModel.KEY_CLOSE_TO_TRAY))

        // 新窗口(新视图模型)应读到同一个偏好
        val second = window(engine, storage, scope)
        assertFalse("偏好是全局的", second.closeToTray())
        second.setCloseToTray(true)
        assertTrue(second.closeToTray())

        first.dispose()
        second.dispose()
    }

    @Test
    fun `新建窗口回调由入口注入`() {
        val (storage, engine, scope) = setup()
        val vm = window(engine, storage, scope)
        var opened = 0
        vm.onNewWindow = { opened++ }

        vm.openNewWindow()
        vm.openNewWindow()

        assertEquals(2, opened)
        vm.dispose()
    }

    @Test
    fun `未注入多窗口回调时给出提示而不是崩溃`() {
        val (storage, engine, scope) = setup()
        val vm = window(engine, storage, scope)
        vm.openNewWindow()
        assertTrue(vm.state.value.toast?.text?.contains("多窗口") == true)
        vm.dispose()
    }

    @Test
    fun `开新窗口时继承当前清单`() {
        val (storage, engine, scope) = setup()
        val first = window(engine, storage, scope)
        first.navigate(OrdoRoute.Anytime)
        val second = window(engine, storage, scope)
        second.navigate(first.state.value.route)

        assertEquals(OrdoRoute.Anytime, second.state.value.route)
        assertNotEquals(emptyList<String>(), second.state.value.flatTodos.map { it.id })
        first.dispose()
        second.dispose()
    }

    @Test
    fun `窗口标题跟随各自清单`() {
        val (storage, engine, scope) = setup()
        val first = window(engine, storage, scope)
        val second = window(engine, storage, scope)
        second.navigate(OrdoRoute.Inbox)

        assertEquals("Ordo · 今天", first.windowTitle())
        assertEquals("Ordo · 收件箱", second.windowTitle())
        first.dispose()
        second.dispose()
    }

    @Test
    fun `新窗口不会重新播种演示数据`() {
        val (storage, engine, scope) = setup()
        val first = window(engine, storage, scope)
        engine.clearAll()
        assertTrue("清空后第一个窗口也是空的", first.state.value.flatTodos.isEmpty())

        val second = OrdoViewModel(engine, storage, scope, seedDemoData = false)

        assertTrue("清空数据后开新窗口不该冒出演示数据", second.state.value.flatTodos.isEmpty())
        first.dispose()
        second.dispose()
    }

    @Test
    fun `清单查询与计数仍然来自共享核心`() {
        val (storage, engine, scope) = setup()
        val vm = window(engine, storage, scope)
        vm.navigate(OrdoRoute.Upcoming)
        assertEquals(engine.list(ListQuery.Upcoming).map { it.id }, vm.state.value.flatTodos.map { it.id })
        assertNull(vm.state.value.confirm)
        vm.dispose()
    }
}
