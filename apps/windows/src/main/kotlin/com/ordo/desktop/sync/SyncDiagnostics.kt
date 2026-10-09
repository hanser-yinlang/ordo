package com.ordo.desktop.sync

import com.ordo.core.model.Op
import com.ordo.core.store.OrdoEngine

/** outbox 里的一条待推送 op(设置页「同步诊断」逐条展示) */
data class OutboxRow(
    val opId: String,
    val entity: String,
    val type: String,
    val entityId: String,
    val clientTs: Long
) {
    /** `todo · upsert` 形式的短标签(entityId 太长,不占列宽) */
    val label: String get() = "$entity · $type"
}

/**
 * 同步诊断面板的数据来源(契约 §7.2 / §7.4)。
 *
 * 三块真数据:
 *  - **待推送条数**:`OrdoEngine.pendingOpCount()`,即 `outbox.json` 里的 op 数;
 *  - **最后服务端序号**:`OrdoEngine.lastServerSeq()`,即 kv 里的 `ordo.lastServerSeq`;
 *  - **上次错误**:最近一次同步结果里的错误码与描述([SyncCoordinator.currentError] / 视图模型状态)。
 *
 * 明细只取前 [DEFAULT_LIMIT] 条,避免设置页一次渲染上千行。
 */
data class SyncDiagnostics(
    val pendingCount: Int,
    val lastServerSeq: Long,
    val lastError: String?,
    val recent: List<OutboxRow>,
    val truncated: Boolean
) {
    val hasPending: Boolean get() = pendingCount > 0

    companion object {
        const val DEFAULT_LIMIT = 10

        fun of(engine: OrdoEngine, lastError: String?, limit: Int = DEFAULT_LIMIT): SyncDiagnostics {
            val ops = engine.pendingOps()
            return SyncDiagnostics(
                pendingCount = engine.pendingOpCount(),
                lastServerSeq = engine.lastServerSeq(),
                lastError = lastError?.takeIf { it.isNotBlank() },
                recent = ops.take(limit).map { it.toRow() },
                truncated = ops.size > limit
            )
        }

        private fun Op.toRow() = OutboxRow(
            opId = opId,
            entity = entity.wire,
            type = type.wire,
            entityId = entityId,
            clientTs = clientTs
        )
    }
}
