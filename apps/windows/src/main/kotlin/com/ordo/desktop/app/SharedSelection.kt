package com.ordo.desktop.app

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * 多窗口之间的"跟随选中"总线。
 *
 * 规范只要求**每窗口独立路由**(04-UI规范 §3),所以这里不同步路由,只同步"用户刚打开了哪条待办":
 * 任一窗口点开某条待办,其它窗口如果正好显示这条待办就把它高亮出来,方便一眼定位。
 * 开关在设置页(`ordo.followSelection`,默认开),视图模型通过 [OrdoViewModel.attachSelectionBus] 订阅。
 */
class SharedSelection {

    private val _current = MutableStateFlow<String?>(null)

    /** 最近一次被打开的待办 id(任何窗口) */
    val current: StateFlow<String?> = _current.asStateFlow()

    fun publish(todoId: String?) {
        if (_current.value != todoId) _current.value = todoId
    }
}
