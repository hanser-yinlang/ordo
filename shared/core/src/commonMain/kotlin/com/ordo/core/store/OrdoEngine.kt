package com.ordo.core.store

import com.ordo.core.model.ApplyResult
import com.ordo.core.model.Area
import com.ordo.core.model.EntityType
import com.ordo.core.model.Heading
import com.ordo.core.model.Op
import com.ordo.core.model.OpType
import com.ordo.core.model.OrdoSnapshot
import com.ordo.core.model.Project
import com.ordo.core.model.Status
import com.ordo.core.model.Tag
import com.ordo.core.model.Todo
import com.ordo.core.model.Tombstone
import com.ordo.core.model.When
import com.ordo.core.nlp.NaturalDateParser
import com.ordo.core.nlp.NlpResult
import com.ordo.core.platform.OrdoClock
import com.ordo.core.platform.PlatformTime
import com.ordo.core.platform.SystemOrdoClock
import com.ordo.core.query.ListQuery
import com.ordo.core.query.ListSection
import com.ordo.core.query.QueryEngine
import com.ordo.core.query.SidebarCounts
import com.ordo.core.repeat.RepeatEngine
import com.ordo.core.storage.OrdoStorage
import com.ordo.core.util.Ids
import com.ordo.core.util.OrdoDate
import com.ordo.core.util.OrdoJson
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull

/** 新建待办的可选参数 */
data class TodoOptions(
    val `when`: When? = null,
    val date: String? = null,
    val projectId: String? = null,
    val areaId: String? = null,
    val headingId: String? = null,
    val tags: List<String> = emptyList(),
    val note: String = "",
    val insertAtTop: Boolean = false
)

/**
 * Ordo 共享核心门面。
 *
 * 所有写操作:①改内存快照 → ②写本地存储 → ③产出 Op 进 outbox → ④通知订阅者。
 * 界面只与它交互;同步由 [com.ordo.core.sync.SyncEngine] 驱动。
 */
class OrdoEngine(
    private val storage: OrdoStorage,
    private val clock: OrdoClock = SystemOrdoClock,
    private val uuid: () -> String = { Ids.uuid() },
    val deviceId: String = storage.kvGet(KEY_DEVICE_ID) ?: ("dev_" + Ids.ulid().takeLast(10).lowercase())
) {

    private var state: OrdoSnapshot = storage.loadSnapshot() ?: OrdoSnapshot()
    private val listeners = LinkedHashMap<Int, (OrdoSnapshot) -> Unit>()
    private var listenerSeq = 0
    private val queryEngine = QueryEngine({ state }, clock)
    private val outbox = storage.loadOutbox().toMutableList()
    private var tombstones = storage.loadTombstones()

    init {
        storage.kvSet(KEY_DEVICE_ID, deviceId)
    }

    // ---------------------------------------------------------------- 只读访问

    val snapshot: OrdoSnapshot get() = state

    val schemaVersion: Int get() = state.schemaVersion

    fun subscribe(listener: (OrdoSnapshot) -> Unit): () -> Unit {
        val key = ++listenerSeq
        listeners[key] = listener
        listener(state)
        return { listeners.remove(key) }
    }

    fun list(query: ListQuery): List<Todo> = queryEngine.list(query)

    fun sections(query: ListQuery): List<ListSection> = queryEngine.sections(query)

    fun counts(): SidebarCounts = queryEngine.counts()

    fun headingsOf(projectId: String): List<Heading> = queryEngine.headingsOf(projectId)

    fun projectProgress(projectId: String): Float = queryEngine.projectProgress(projectId)

    fun todo(id: String): Todo? = state.todos.firstOrNull { it.id == id && !it.deleted }

    fun project(id: String): Project? = state.projects.firstOrNull { it.id == id && !it.deleted }

    fun area(id: String): Area? = state.areas.firstOrNull { it.id == id && !it.deleted }

    // ---------------------------------------------------------------- 待办写操作

    /** 新建待办:标题走中文 NLP 解析(契约 §5) */
    fun createTodo(title: String, opts: TodoOptions = TodoOptions()): Todo {
        val parsed: NlpResult = NaturalDateParser.parse(title, OrdoDate.todayISO(clock), OrdoDate.nowHHmm(clock))
        val cleanTitle = parsed.cleanTitle.ifBlank { title.trim() }
        val now = clock.nowMillis()
        val `when` = parsed.`when` ?: opts.`when` ?: defaultWhen(opts)
        var todo = Todo(
            id = uuid(),
            title = cleanTitle,
            note = opts.note,
            `when` = `when`,
            date = if (`when` == When.DATE) (parsed.date ?: opts.date ?: OrdoDate.todayISO(clock)) else null,
            reminder = parsed.reminder,
            tags = (parsed.tags + opts.tags).distinct(),
            projectId = opts.projectId,
            areaId = opts.areaId,
            headingId = opts.headingId,
            order = nextOrder(`when`, opts),
            createdAt = now,
            updatedAt = now
        )
        parsed.tags.forEach { ensureTag(it, now) }
        todo = normalize(todo, now)
        state = state.copy(todos = state.todos + todo)
        persistAndEnqueue(EntityType.TODO, todo.id, todo)
        return todo
    }

    private fun defaultWhen(opts: TodoOptions): When =
        if (opts.projectId == null && opts.areaId == null && opts.headingId == null) When.INBOX else When.ANYTIME

    private fun nextOrder(`when`: When, opts: TodoOptions): Int {
        val scope = state.todos.filter {
            !it.deleted && it.`when` == `when` && it.projectId == opts.projectId && it.headingId == opts.headingId
        }
        return if (opts.insertAtTop) (scope.minOfOrNull { it.order } ?: 0) - 1 else (scope.maxOfOrNull { it.order } ?: 0) + 1
    }

    /** 通用更新:传入变换函数;自动维护 updatedAt 并产出 op */
    fun updateTodo(id: String, mutate: (Todo) -> Todo) {
        val index = state.todos.indexOfFirst { it.id == id }
        if (index < 0) return
        val now = clock.nowMillis()
        val updated = normalize(mutate(state.todos[index]).copy(updatedAt = now), now)
        // 契约 §7.3.6:标题被清空视为删除(本地编辑与远端下发行为一致)
        if (updated.title.isBlank()) {
            deleteTodo(id)
            return
        }
        val todos = state.todos.toMutableList()
        todos[index] = updated
        state = state.copy(todos = todos)
        updated.tags.forEach { ensureTag(it, now) }
        persistAndEnqueue(EntityType.TODO, id, updated)
    }

    fun setTitle(id: String, title: String) = updateTodo(id) { it.copy(title = title) }

    fun setNote(id: String, note: String) = updateTodo(id) { it.copy(note = note) }

    fun setWhen(id: String, `when`: When, date: String? = null) = updateTodo(id) { todo ->
        if (`when` == When.DATE) {
            val d = date ?: OrdoDate.todayISO(clock)
            todo.copy(`when` = When.DATE, date = d, reminder = realignReminder(todo.reminder, d))
        } else {
            todo.copy(`when` = `when`, date = null)
        }
    }

    fun setDeadline(id: String, date: String?) = updateTodo(id) { it.copy(deadline = date?.takeIf { d -> OrdoDate.isValidISO(d) }) }

    /** 设置提醒:自动与 `when`/date 对齐,并把无日期的待办移入今天(契约 §3) */
    fun setReminder(id: String, reminder: String?) = updateTodo(id) { todo ->
        if (reminder.isNullOrBlank() || !OrdoDate.isValidDateTime(reminder)) {
            todo.copy(reminder = null)
        } else {
            val invariant = when {
                todo.`when` == When.DATE -> todo
                todo.`when` == When.TODAY || todo.`when` == When.EVENING -> todo
                else -> todo.copy(`when` = When.TODAY, date = null)
            }
            invariant.copy(reminder = reminder)
        }
    }

    fun setRepeat(id: String, repeat: com.ordo.core.model.RepeatRule?) = updateTodo(id) { todo ->
        if (repeat == null) todo.copy(repeat = null)
        else {
            val withDate = when (todo.`when`) {
                When.ANYTIME, When.INBOX, When.SOMEDAY, When.EVENING ->
                    todo.copy(`when` = When.DATE, date = todo.date ?: OrdoDate.todayISO(clock))
                else -> todo
            }
            withDate.copy(repeat = repeat)
        }
    }

    fun moveTodo(id: String, projectId: String?, areaId: String?, headingId: String?) = updateTodo(id) { todo ->
        val heading = headingId?.takeIf { hid -> state.headings.any { it.id == hid && it.projectId == projectId && !it.deleted } }
        var moved = todo.copy(projectId = projectId, areaId = areaId, headingId = heading)
        if (projectId != null && moved.`when` == When.INBOX) moved = moved.copy(`when` = When.ANYTIME, date = null)
        if (projectId == null && moved.`when` == When.ANYTIME && areaId == null && todo.`when` == When.INBOX) {
            moved = moved.copy(`when` = When.INBOX)
        }
        moved
    }

    fun addTag(id: String, tag: String) {
        val name = tag.trim().removePrefix("#")
        if (name.isEmpty()) return
        ensureTag(name, clock.nowMillis())
        updateTodo(id) { todo -> if (todo.tags.contains(name)) todo else todo.copy(tags = todo.tags + name) }
    }

    fun removeTag(id: String, tag: String) = updateTodo(id) { todo -> todo.copy(tags = todo.tags.filter { it != tag }) }

    fun addChecklistItem(todoId: String, title: String) = updateTodo(todoId) { todo ->
        todo.copy(checklist = todo.checklist + com.ordo.core.model.ChecklistItem(uuid(), title, false))
    }

    fun setChecklistItemTitle(todoId: String, itemId: String, title: String) = updateTodo(todoId) { todo ->
        todo.copy(checklist = todo.checklist.map { if (it.id == itemId) it.copy(title = title) else it })
    }

    fun toggleChecklistItem(todoId: String, itemId: String) = updateTodo(todoId) { todo ->
        todo.copy(checklist = todo.checklist.map { if (it.id == itemId) it.copy(done = !it.done) else it })
    }

    fun removeChecklistItem(todoId: String, itemId: String) = updateTodo(todoId) { todo ->
        todo.copy(checklist = todo.checklist.filterNot { it.id == itemId })
    }

    fun duplicateTodo(id: String): Todo? {
        val source = todo(id) ?: return null
        val now = clock.nowMillis()
        val copy = source.copy(
            id = uuid(),
            title = source.title + "(副本)",
            status = Status.OPEN,
            completedAt = null,
            checklist = source.checklist.map { it.copy(id = uuid(), done = false) },
            createdAt = now,
            updatedAt = now
        )
        state = state.copy(todos = state.todos + copy)
        persistAndEnqueue(EntityType.TODO, copy.id, copy)
        return copy
    }

    /** 完成/取消切换;完成重复待办时自动生成下一次实例(契约 §6) */
    fun toggleDone(id: String) {
        val current = todo(id) ?: return
        if (current.status == Status.OPEN) complete(id) else reopen(id)
    }

    fun complete(id: String, canceled: Boolean = false) {
        val current = todo(id) ?: return
        val now = clock.nowMillis()
        val done = current.copy(
            status = if (canceled) Status.CANCELED else Status.DONE,
            completedAt = now,
            updatedAt = now
        )
        replaceTodo(done)
        persistAndEnqueue(EntityType.TODO, done.id, done)
        if (!canceled) {
            RepeatEngine.spawnNext(current, now, uuid(), PlatformTime.utcOffsetMillis())?.let { next ->
                state = state.copy(todos = state.todos + next)
                persistAndEnqueue(EntityType.TODO, next.id, next)
            }
        }
    }

    fun reopen(id: String) {
        val current = todo(id) ?: return
        val now = clock.nowMillis()
        val reopened = current.copy(status = Status.OPEN, completedAt = null, updatedAt = now)
        replaceTodo(reopened)
        persistAndEnqueue(EntityType.TODO, reopened.id, reopened)
    }

    fun deleteTodo(id: String) {
        val current = todo(id) ?: return
        val now = clock.nowMillis()
        val removed = current.copy(deleted = true, updatedAt = now)
        replaceTodo(removed)
        tombstones = (tombstones + Tombstone(EntityType.TODO, id, now, now)).distinctBy { it.entity to it.entityId }
        storage.saveTombstones(tombstones)
        persistAndEnqueue(EntityType.TODO, id, removed, delete = true)
    }

    /** 拖拽排序:把 id 插到 targetId 之前(before=true)或之后 */
    fun reorderTodos(ids: List<String>) {
        val now = clock.nowMillis()
        val updated = ArrayList<Todo>()
        ids.forEachIndexed { index, todoId ->
            val index0 = state.todos.indexOfFirst { it.id == todoId }
            if (index0 >= 0) {
                val t = state.todos[index0].copy(order = index, updatedAt = now)
                updated.add(t)
            }
        }
        updated.forEach { replaceTodo(it) }
        updated.forEach { persistAndEnqueue(EntityType.TODO, it.id, it) }
    }

    // ---------------------------------------------------------------- 项目 / 标题 / 区域

    fun createProject(name: String, areaId: String? = null, headingNames: List<String> = emptyList()): Project {
        val now = clock.nowMillis()
        val project = Project(
            id = uuid(),
            name = name,
            areaId = areaId,
            order = (state.projects.maxOfOrNull { it.order } ?: 0) + 1,
            createdAt = now,
            updatedAt = now
        )
        state = state.copy(projects = state.projects + project)
        persistAndEnqueue(EntityType.PROJECT, project.id, project)
        headingNames.forEachIndexed { index, headingName -> createHeading(project.id, headingName, index) }
        return project
    }

    fun updateProject(id: String, mutate: (Project) -> Project) {
        val index = state.projects.indexOfFirst { it.id == id }
        if (index < 0) return
        val now = clock.nowMillis()
        val updated = mutate(state.projects[index]).copy(updatedAt = now)
        val projects = state.projects.toMutableList()
        projects[index] = updated
        state = state.copy(projects = projects)
        persistAndEnqueue(EntityType.PROJECT, id, updated)
    }

    fun renameProject(id: String, name: String) = updateProject(id) { it.copy(name = name) }

    fun setProjectNote(id: String, note: String) = updateProject(id) { it.copy(note = note) }

    fun setProjectWhen(id: String, `when`: When, date: String? = null) = updateProject(id) { project ->
        if (`when` == When.DATE) project.copy(`when` = When.DATE, date = date ?: OrdoDate.todayISO(clock))
        else project.copy(`when` = `when`, date = null)
    }

    fun moveProject(id: String, areaId: String?) = updateProject(id) { it.copy(areaId = areaId) }

    /** 项目完成:必须所有子待办都结束(契约 §2.2 硬约束) */
    /**
     * 完成项目(契约 §2.2 项目完成规则,v1.1 修订)。
     *
     * 唯一硬约束:该项目下所有 todo 的 status ∈ {done, canceled}。
     * **未归档的 heading 不再阻塞完成** —— Heading 是组织容器不是工作项;
     * 完成时它们会被自动归档(每个标题一条 Op,与手工归档同构),
     * 从而保持"已完成的项目不含未归档标题"这一不变量。
     */
    fun completeProject(id: String): Boolean {
        val project = project(id) ?: return false
        if (project.status == Status.DONE) return false
        val openCount = state.todos.count { it.projectId == id && !it.deleted && it.status == Status.OPEN }
        if (openCount > 0) return false
        // 契约 §2.2 v1.1:未归档的标题自动归档(复用 archiveHeading,产出与手工归档同构的 Op)。
        // 此时该项目已无未完成待办,所以每个标题的 archiveHeading 都不会被拒。
        state.headings
            .filter { it.projectId == id && !it.deleted && !it.archived }
            .map { it.id }
            .forEach { archiveHeading(it) }
        updateProject(id) { it.copy(status = Status.DONE, completedAt = clock.nowMillis()) }
        return true
    }

    fun reopenProject(id: String) = updateProject(id) { it.copy(status = Status.OPEN, completedAt = null) }

    fun deleteProject(id: String) {
        val now = clock.nowMillis()
        updateProject(id) { it.copy(deleted = true) }
        state.todos.filter { it.projectId == id && !it.deleted }.forEach { child ->
            replaceTodo(child.copy(deleted = true, updatedAt = now))
            persistAndEnqueue(EntityType.TODO, child.id, child.copy(deleted = true), delete = true)
        }
        tombstones = (tombstones + Tombstone(EntityType.PROJECT, id, now, now)).distinctBy { it.entity to it.entityId }
        storage.saveTombstones(tombstones)
    }

    fun createHeading(projectId: String, name: String, order: Int = -1): Heading {
        val now = clock.nowMillis()
        val resolvedOrder = if (order >= 0) order else state.headings.count { it.projectId == projectId && !it.deleted }
        val heading = Heading(id = uuid(), projectId = projectId, name = name, order = resolvedOrder, updatedAt = now)
        state = state.copy(headings = state.headings + heading)
        persistAndEnqueue(EntityType.HEADING, heading.id, heading)
        return heading
    }

    fun updateHeading(id: String, mutate: (Heading) -> Heading) {
        val index = state.headings.indexOfFirst { it.id == id }
        if (index < 0) return
        val now = clock.nowMillis()
        val updated = mutate(state.headings[index]).copy(updatedAt = now)
        val headings = state.headings.toMutableList()
        headings[index] = updated
        state = state.copy(headings = headings)
        persistAndEnqueue(EntityType.HEADING, id, updated)
    }

    fun renameHeading(id: String, name: String) = updateHeading(id) { it.copy(name = name) }

    fun toggleHeadingCollapsed(id: String) {
        // collapsed 仅本地 UI 状态,不入 outbox
        val index = state.headings.indexOfFirst { it.id == id }
        if (index < 0) return
        val headings = state.headings.toMutableList()
        headings[index] = headings[index].copy(collapsed = !headings[index].collapsed)
        state = state.copy(headings = headings)
        storage.saveSnapshot(state)
        notifyListeners()
    }

    /** 归档标题:其下待办必须全部结束 */
    fun archiveHeading(id: String): Boolean {
        val openCount = state.todos.count { it.headingId == id && !it.deleted && it.status == Status.OPEN }
        if (openCount > 0) return false
        updateHeading(id) { it.copy(archived = true) }
        return true
    }

    fun deleteHeading(id: String) {
        val now = clock.nowMillis()
        updateHeading(id) { it.copy(deleted = true) }
        state.todos.filter { it.headingId == id && !it.deleted }.forEach { child ->
            val moved = child.copy(headingId = null, updatedAt = now)
            replaceTodo(moved)
            persistAndEnqueue(EntityType.TODO, moved.id, moved)
        }
        tombstones = (tombstones + Tombstone(EntityType.HEADING, id, now, now)).distinctBy { it.entity to it.entityId }
        storage.saveTombstones(tombstones)
    }

    fun createArea(name: String): Area {
        val now = clock.nowMillis()
        val area = Area(
            id = uuid(),
            name = name,
            order = (state.areas.maxOfOrNull { it.order } ?: 0) + 1,
            updatedAt = now
        )
        state = state.copy(areas = state.areas + area)
        persistAndEnqueue(EntityType.AREA, area.id, area)
        return area
    }

    fun renameArea(id: String, name: String) {
        val index = state.areas.indexOfFirst { it.id == id }
        if (index < 0) return
        val now = clock.nowMillis()
        val updated = state.areas[index].copy(name = name, updatedAt = now)
        val areas = state.areas.toMutableList()
        areas[index] = updated
        state = state.copy(areas = areas)
        persistAndEnqueue(EntityType.AREA, id, updated)
    }

    fun deleteArea(id: String) {
        val now = clock.nowMillis()
        val index = state.areas.indexOfFirst { it.id == id }
        if (index < 0) return
        val updated = state.areas[index].copy(deleted = true, updatedAt = now)
        val areas = state.areas.toMutableList()
        areas[index] = updated
        state = state.copy(areas = areas)
        state.projects.filter { it.areaId == id && !it.deleted }.forEach { project -> updateProject(project.id) { it.copy(areaId = null) } }
        persistAndEnqueue(EntityType.AREA, id, updated, delete = true)
    }

    fun ensureTag(name: String, now: Long = clock.nowMillis()): Tag {
        val existing = state.tags.firstOrNull { it.name == name && !it.deleted }
        if (existing != null) return existing
        val tag = Tag(id = uuid(), name = name, updatedAt = now)
        state = state.copy(tags = state.tags + tag)
        persistAndEnqueue(EntityType.TAG, tag.id, tag)
        return tag
    }

    fun tags(): List<Tag> = state.tags.filter { !it.deleted }.sortedBy { it.name }

    // ---------------------------------------------------------------- 同步支撑

    fun pendingOps(): List<Op> = outbox.toList()

    fun pendingOpCount(): Int = outbox.size

    fun lastServerSeq(): Long = storage.kvGet(KEY_LAST_SEQ)?.toLongOrNull() ?: 0L

    fun setLastServerSeq(seq: Long) {
        storage.kvSet(KEY_LAST_SEQ, seq.toString())
        state = state.copy(serverSeq = seq)
    }

    fun ackOps(opIds: List<String>) {
        if (opIds.isEmpty()) return
        storage.clearOutbox(opIds)
        outbox.removeAll { opIds.contains(it.opId) }
    }

    /** 应用远端 op,返回真正生效的条数(契约 §7.3) */
    fun applyRemote(ops: List<Op>): Int {
        var applied = 0
        ops.forEach { op ->
            if (applyOne(op)) applied++
            op.seq?.let { seq -> if (seq > lastServerSeq()) setLastServerSeq(seq) }
        }
        if (applied > 0) {
            storage.saveSnapshot(state)
            notifyListeners()
        }
        return applied
    }

    /** 用服务端快照全量替换本地(保留本地 outbox) */
    fun replaceWithRemote(snapshot: OrdoSnapshot) {
        state = snapshot.copy(schemaVersion = state.schemaVersion)
        storage.saveSnapshot(state)
        setLastServerSeq(snapshot.serverSeq)
        notifyListeners()
    }

    private fun applyOne(op: Op): Boolean {
        val tombstone = tombstones.firstOrNull { it.entity == op.entity && it.entityId == op.entityId }
        if (tombstone != null && tombstone.clientTs >= op.clientTs) return false

        return when (op.entity) {
            EntityType.TODO -> applyTodoOp(op)
            EntityType.PROJECT -> applyEntityOp(
                op, Project.serializer(),
                current = { state.projects.firstOrNull { it.id == op.entityId } },
                updatedAtOf = { it.updatedAt },
                replace = { remote ->
                    val list = state.projects.toMutableList()
                    val index = list.indexOfFirst { it.id == remote.id }
                    if (index >= 0) list[index] = remote else list.add(remote)
                    state = state.copy(projects = list)
                },
                remove = {
                    recordTombstone(op)
                    state = state.copy(projects = state.projects.map { p -> if (p.id == op.entityId) p.copy(deleted = true) else p })
                }
            )
            EntityType.AREA -> applyEntityOp(
                op, Area.serializer(),
                current = { state.areas.firstOrNull { it.id == op.entityId } },
                updatedAtOf = { it.updatedAt },
                replace = { remote ->
                    val list = state.areas.toMutableList()
                    val index = list.indexOfFirst { it.id == remote.id }
                    if (index >= 0) list[index] = remote else list.add(remote)
                    state = state.copy(areas = list)
                },
                remove = {
                    recordTombstone(op)
                    state = state.copy(areas = state.areas.map { a -> if (a.id == op.entityId) a.copy(deleted = true) else a })
                }
            )
            EntityType.HEADING -> applyEntityOp(
                op, Heading.serializer(),
                current = { state.headings.firstOrNull { it.id == op.entityId } },
                updatedAtOf = { it.updatedAt },
                replace = { remote ->
                    val list = state.headings.toMutableList()
                    val index = list.indexOfFirst { it.id == remote.id }
                    // collapsed 是本地 UI 状态,远端覆盖时保留本地值
                    if (index >= 0) list[index] = remote.copy(collapsed = list[index].collapsed) else list.add(remote)
                    state = state.copy(headings = list)
                },
                remove = {
                    recordTombstone(op)
                    state = state.copy(headings = state.headings.map { h -> if (h.id == op.entityId) h.copy(deleted = true) else h })
                }
            )
            EntityType.TAG -> applyEntityOp(
                op, Tag.serializer(),
                current = { state.tags.firstOrNull { it.id == op.entityId } },
                updatedAtOf = { it.updatedAt },
                replace = { remote ->
                    val list = state.tags.toMutableList()
                    val index = list.indexOfFirst { it.id == remote.id }
                    if (index >= 0) list[index] = remote else list.add(remote)
                    state = state.copy(tags = list)
                },
                remove = {
                    recordTombstone(op)
                    state = state.copy(tags = state.tags.map { t -> if (t.id == op.entityId) t.copy(deleted = true) else t })
                }
            )
        }
    }

    /** 区域/项目/标题/标签的通用 op 应用:LWW + 墓碑(契约 §7.3) */
    private fun <T : Any> applyEntityOp(
        op: Op,
        serializer: KSerializer<T>,
        current: () -> T?,
        updatedAtOf: (T) -> Long,
        replace: (T) -> Unit,
        remove: () -> Unit
    ): Boolean {
        val payload = op.payload
        val local = current()
        if (op.type == OpType.DELETE || payload == null || payload is JsonNull) {
            if (local == null) return false
            remove()
            return true
        }
        if (local != null && op.clientTs < updatedAtOf(local)) return false
        val remote = runCatching { OrdoJson.instance.decodeFromJsonElement(serializer, payload) }.getOrNull() ?: return false
        replace(remote)
        return true
    }

    private fun applyTodoOp(op: Op): Boolean {
        val payload = op.payload
        val local = state.todos.firstOrNull { it.id == op.entityId }
        if (op.type == OpType.DELETE || payload == null || payload is kotlinx.serialization.json.JsonNull) {
            if (local != null) {
                val list = state.todos.toMutableList()
                list[list.indexOfFirst { it.id == op.entityId }] = local.copy(deleted = true, updatedAt = op.clientTs)
                state = state.copy(todos = list)
                recordTombstone(op)
                return true
            }
            return false
        }
        val remote = runCatching { OrdoJson.instance.decodeFromJsonElement(Todo.serializer(), payload) }.getOrNull() ?: return false

        // 契约 §7.3.6:标题为空视为删除 —— 远端下发的空标题 upsert 同样必须删除实体(不只是 DELETE op)
        if (remote.title.isBlank()) {
            if (local == null || local.deleted) return false
            val list = state.todos.toMutableList()
            list[list.indexOfFirst { it.id == op.entityId }] =
                local.copy(deleted = true, updatedAt = maxOf(op.clientTs, local.updatedAt))
            state = state.copy(todos = list)
            recordTombstone(op)
            return true
        }

        val merged = mergeTodo(local, remote, op.clientTs) ?: return false
        val list = state.todos.toMutableList()
        val index = list.indexOfFirst { it.id == merged.id }
        if (index >= 0) list[index] = merged else list.add(merged)
        state = state.copy(todos = list)
        return true
    }

    /** 待办合并规则(契约 §7.3):LWW + 完成不可回滚 + 标签并集 + 清单项按 id 合并 */
    private fun mergeTodo(local: Todo?, remote: Todo, clientTs: Long): Todo? {
        if (local == null) return remote
        val localTs = local.updatedAt
        val completedGuard = local.status.isClosed && remote.status == Status.OPEN
        if (completedGuard) return null
        if (clientTs < localTs) return null
        val tags = (local.tags + remote.tags).distinct()
        val checklist = mergeChecklist(local.checklist, remote.checklist, preferRemote = clientTs >= localTs)
        return remote.copy(tags = tags, checklist = checklist)
    }

    private fun mergeChecklist(
        local: List<com.ordo.core.model.ChecklistItem>,
        remote: List<com.ordo.core.model.ChecklistItem>,
        preferRemote: Boolean
    ): List<com.ordo.core.model.ChecklistItem> {
        val byId = LinkedHashMap<String, com.ordo.core.model.ChecklistItem>()
        local.forEach { byId[it.id] = it }
        remote.forEach { item ->
            val existing = byId[item.id]
            byId[item.id] = if (existing == null) item else if (preferRemote) item else existing
        }
        return byId.values.toList()
    }

    private fun recordTombstone(op: Op) {
        tombstones = (tombstones + Tombstone(op.entity, op.entityId, op.clientTs, op.clientTs))
            .groupBy { it.entity to it.entityId }
            .map { (_, list) -> list.maxByOrNull { it.clientTs }!! }
        storage.saveTombstones(tombstones)
    }

    // ---------------------------------------------------------------- 演示数据

    /** 首次启动写入演示数据;force = true 时覆盖现有内容(设置里的"重置为示例数据") */
    fun seedDemoData(force: Boolean = false): Boolean {
        if (!force && state.todos.isNotEmpty()) return false
        state = com.ordo.core.seed.SeedData.demo(clock.nowMillis(), OrdoDate.todayISO(clock))
        storage.saveSnapshot(state)
        storage.kvSet(KEY_SCHEMA, state.schemaVersion.toString())
        notifyListeners()
        return true
    }

    /** 清空全部本地数据(账号注销 / 退出登录时使用) */
    fun clearAll() {
        state = OrdoSnapshot()
        storage.saveSnapshot(state)
        storage.saveTombstones(emptyList())
        tombstones = emptyList()
        val ids = outbox.map { it.opId }
        storage.clearOutbox(ids)
        outbox.clear()
        notifyListeners()
    }

    // ---------------------------------------------------------------- 内部

    private fun replaceTodo(todo: Todo) {
        val list = state.todos.toMutableList()
        val index = list.indexOfFirst { it.id == todo.id }
        if (index >= 0) list[index] = todo else list.add(todo)
        state = state.copy(todos = list)
    }

    /** 维护契约 §3 的字段不变量 */
    private fun normalize(todo: Todo, now: Long): Todo {
        var result = todo
        if (result.`when` == When.DATE && result.date == null) result = result.copy(date = OrdoDate.todayISO(clock))
        if (result.`when` != When.DATE && result.date != null) result = result.copy(date = null)
        result.date?.let { d -> result = result.copy(reminder = realignReminder(result.reminder, d)) }
        if (result.reminder != null && (result.`when` == When.INBOX || result.`when` == When.ANYTIME || result.`when` == When.SOMEDAY)) {
            result = result.copy(`when` = When.TODAY, date = null)
        }
        if (result.headingId != null) {
            val valid = state.headings.any { it.id == result.headingId && it.projectId == result.projectId && !it.deleted }
            if (!valid) result = result.copy(headingId = null)
        }
        return if (result.updatedAt == 0L) result.copy(updatedAt = now) else result
    }

    private fun realignReminder(reminder: String?, newDate: String): String? {
        val time = OrdoDate.timePartOf(reminder) ?: return reminder
        return OrdoDate.dateTime(newDate, time)
    }

    private fun persistAndEnqueue(
        entity: EntityType,
        entityId: String,
        value: Any,
        delete: Boolean = false
    ) {
        storage.saveSnapshot(state)
        val now = clock.nowMillis()
        val payload: JsonElement? = if (delete) null else when (value) {
            is Todo -> OrdoJson.instance.encodeToJsonElement(Todo.serializer(), value)
            is Project -> OrdoJson.instance.encodeToJsonElement(Project.serializer(), value)
            is Area -> OrdoJson.instance.encodeToJsonElement(Area.serializer(), value)
            is Heading -> OrdoJson.instance.encodeToJsonElement(Heading.serializer(), value.copy(collapsed = false))
            is Tag -> OrdoJson.instance.encodeToJsonElement(Tag.serializer(), value)
            else -> null
        }
        val op = Op(
            opId = Ids.ulid(now),
            deviceId = deviceId,
            entity = entity,
            entityId = entityId,
            type = if (delete) OpType.DELETE else OpType.UPSERT,
            payload = payload,
            clientTs = now
        )
        outbox.add(op)
        storage.appendOutbox(op)
        notifyListeners()
    }

    private fun notifyListeners() {
        listeners.values.toList().forEach { it(state) }
    }

    companion object {
        const val KEY_DEVICE_ID = "ordo.deviceId"
        const val KEY_LAST_SEQ = "ordo.lastServerSeq"
        const val KEY_SCHEMA = "ordo.schemaVersion"
    }
}
