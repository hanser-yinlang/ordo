package com.ordo.desktop.app

import com.ordo.core.storage.InMemoryStorage
import com.ordo.core.store.OrdoEngine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 切换外观背景色的提示条(需求:在 Windows 端切换背景颜色要提示「已切换到深色模式」)。
 *
 * 提示**不是**散在各个按钮里的,而是统一由 [OrdoViewModel.setTheme] 发出 —— 设置页三个选项、
 * 侧栏主题按钮、`Ctrl+D` 都汇聚到它。所以这里既锁文案逐字一致,也锁"三个入口都走同一条路"。
 *
 * 提示里的深浅一律取自**同一次** `resolveDark` 的结果:提示说深色,画面就一定是深色,
 * 不存在"提示说深色但界面还是浅色"这种最容易被用户抓住的错位。
 */
class ThemeSwitchToastTest {

    private fun viewModel(storage: InMemoryStorage = InMemoryStorage()): Pair<OrdoViewModel, InMemoryStorage> {
        val engine = OrdoEngine(storage)
        engine.seedDemoData(force = true)
        val vm = OrdoViewModel(engine = engine, storage = storage, scope = CoroutineScope(Dispatchers.Unconfined))
        return vm to storage
    }

    @Test
    fun `设置页切到深色要提示已切换到深色模式`() {
        val (vm, storage) = viewModel()

        vm.setTheme(ThemeMode.DARK)

        val toast = vm.state.value.toast
        assertNotNull("切换背景颜色必须有提示条", toast)
        assertEquals("已切换到深色模式", toast!!.text)
        assertEquals(ThemeMode.DARK, vm.state.value.themeMode)
        assertTrue("提示说深色,界面就必须是深色", vm.state.value.dark)
        assertEquals("偏好要落库,下次启动还是深色", ThemeMode.DARK.name, storage.kvGet(OrdoViewModel.KEY_THEME))
    }

    @Test
    fun `设置页切到浅色要提示已切换到浅色模式`() {
        val (vm, _) = viewModel()
        vm.setTheme(ThemeMode.DARK)

        vm.setTheme(ThemeMode.LIGHT)

        assertEquals("已切换到浅色模式", vm.state.value.toast!!.text)
        assertEquals(ThemeMode.LIGHT, vm.state.value.themeMode)
        assertTrue("提示说浅色,界面就不能还是深色", !vm.state.value.dark)
    }

    @Test
    fun `自动模式的提示要报出当时跟随到的深浅`() {
        val (vm, _) = viewModel()

        vm.setTheme(ThemeMode.AUTO)

        val toast = vm.state.value.toast
        assertNotNull(toast)
        // 系统此刻是深是浅由注册表决定,这里只锁"提示与画面同源":报深色就真的是深色
        assertEquals(
            "已切换到跟随系统模式(${if (vm.state.value.dark) "深色" else "浅色"})",
            toast!!.text
        )
        assertEquals(ThemeMode.AUTO, vm.state.value.themeMode)
    }

    @Test
    fun `侧栏按钮与 Ctrl+D 的循环也走同一条提示`() {
        val (vm, _) = viewModel()

        vm.setTheme(ThemeMode.DARK)
        vm.cycleTheme()
        assertEquals("深色之后是自动", ThemeMode.AUTO, vm.state.value.themeMode)
        assertTrue(
            "循环到自动也要提示:${vm.state.value.toast?.text}",
            vm.state.value.toast?.text?.startsWith("已切换到跟随系统模式") == true
        )

        vm.setTheme(ThemeMode.LIGHT)
        vm.cycleTheme()
        assertEquals("浅色之后是深色", ThemeMode.DARK, vm.state.value.themeMode)
        assertEquals("已切换到深色模式", vm.state.value.toast!!.text)

        vm.setTheme(ThemeMode.AUTO)
        vm.cycleTheme()
        assertEquals("自动之后是浅色", ThemeMode.LIGHT, vm.state.value.themeMode)
        assertEquals("已切换到浅色模式", vm.state.value.toast!!.text)
    }

    @Test
    fun `连点同一个模式也会重新提示并重新计时`() {
        val (vm, _) = viewModel()
        vm.setTheme(ThemeMode.DARK)
        val first = vm.state.value.toast!!

        vm.setTheme(ThemeMode.DARK)

        val second = vm.state.value.toast!!
        assertEquals("报的还是现在是什么模式", first.text, second.text)
        assertTrue("id 必须变化,否则第二次点击会悄无声息", second.id > first.id)
    }

    @Test
    fun `提示文案与设置页选项同源`() {
        assertEquals(
            "设置页三个选项的中文名",
            listOf("跟随系统", "浅色", "深色"),
            ThemeMode.entries.map { it.label }
        )
        assertEquals("已切换到深色模式", ThemeMode.DARK.switchToast(dark = true))
        assertEquals("已切换到浅色模式", ThemeMode.LIGHT.switchToast(dark = false))
        assertEquals("已切换到跟随系统模式(深色)", ThemeMode.AUTO.switchToast(dark = true))
        assertEquals("已切换到跟随系统模式(浅色)", ThemeMode.AUTO.switchToast(dark = false))
        ThemeMode.entries.forEach { mode ->
            assertTrue(
                "$mode 的提示必须含设置页里的同一个模式名",
                mode.switchToast(dark = false).contains(mode.label)
            )
        }
    }

    @Test
    fun `启动读取已存偏好时不该弹提示`() {
        val storage = InMemoryStorage()
        storage.kvSet(OrdoViewModel.KEY_THEME, ThemeMode.DARK.name)

        val (vm, _) = viewModel(storage)

        assertEquals(ThemeMode.DARK, vm.state.value.themeMode)
        assertTrue("上次是深色,启动就该是深色", vm.state.value.dark)
        assertNull("开机启动没有「切换」这个动作,不该弹提示条", vm.state.value.toast)
    }

    @Test
    fun `坏掉的偏好值回退到自动而不是崩`() {
        val storage = InMemoryStorage()
        storage.kvSet(OrdoViewModel.KEY_THEME, "NEON")

        val (vm, _) = viewModel(storage)

        assertEquals(ThemeMode.AUTO, vm.state.value.themeMode)
        assertNull(vm.state.value.toast)
    }
}
