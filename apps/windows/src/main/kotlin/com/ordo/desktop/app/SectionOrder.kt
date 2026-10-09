package com.ordo.desktop.app

import com.ordo.core.query.ListSection

/**
 * 派生清单显示顺序的**适配层**(一行核心改动的替代方案)。
 *
 * 共享核心的「收件箱 / 今天 / 计划 / 项目 / 区域」都按 `order` 排序,唯独「随时 / 某天」直接沿用快照顺序
 * (即创建顺序),`order` 字段被忽略 —— 于是拖拽排序写回的 `order` 在这两个清单看不到效果。
 * 这里按与核心完全一致的 `(order, createdAt)` 口径重排分组内待办,让拖拽立刻可见。
 *
 * **待核心补上同样的排序后,本文件应整体删除**;已作为核心 API 请求登记在 `apps/windows/README.md §10`。
 * 标签 / 搜索仍保持核心的"最近更新优先",不受影响。
 */
internal fun orderedSections(sections: List<ListSection>, route: OrdoRoute): List<ListSection> {
    if (!needsLocalOrder(route)) return sections
    return sections.map { section ->
        section.copy(todos = section.todos.sortedWith(compareBy({ it.order }, { it.createdAt })))
    }
}

/** 核心未按 `order` 排序、需要本地补齐的清单(仅"随时"与"某天") */
internal fun needsLocalOrder(route: OrdoRoute): Boolean =
    route == OrdoRoute.Anytime || route == OrdoRoute.Someday
