package com.ordo.android.data

import com.ordo.core.model.Project
import com.ordo.core.model.Todo
import com.ordo.core.model.When

/* ============================================================================
 * 与 shared:core 的接触面适配层
 *
 * 契约 §2 规定"四端与后端字段名完全一致"，而 Kotlin 中 `when` 是保留字，
 * 只能以反引号访问。所有对 `when` 的读取都集中在这里（UI 层统一用 whenValue），
 * 这样共享核心若改用别名（如 whenValue）时只需改本文件。
 * ========================================================================== */

/** 读取 Todo.`when`（契约 §2.4） */
val Todo.whenValue: When get() = this.`when`

/** 读取 Project.`when`（契约 §2.2） */
val Project.whenValue: When get() = this.`when`
