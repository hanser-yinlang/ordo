package com.ordo.core.sync

import com.ordo.core.model.OrdoSnapshot
import com.ordo.core.store.OrdoEngine

/** 一次同步的结果 */
data class SyncResult(
    val ok: Boolean,
    val pushed: Int = 0,
    val pulled: Int = 0,
    val serverSeq: Long = 0,
    val error: String? = null
)

/**
 * 同步引擎(契约 §7)。
 *
 * 流程:①推送 outbox → ②应用应答中捎带的远端 ops → ③循环拉取直到没有更多。
 * 幂等由服务端 op_id 唯一索引保证;失败不丢数据,outbox 保留待下次重试。
 */
class SyncEngine(
    private val engine: OrdoEngine,
    private val api: SyncApi,
    private val pullLimit: Int = 500
) {

    suspend fun syncOnce(): SyncResult {
        var pushed = 0
        var pulled = 0
        return try {
            val pending = engine.pendingOps()
            if (pending.isNotEmpty()) {
                val response = api.push(PushRequest(engine.deviceId, engine.lastServerSeq(), pending))
                val acceptedIds = response.accepted
                // 被拒绝的 op(stale/invalid)不再重试,直接出队,避免死循环
                val dropIds = acceptedIds + response.rejected.map { it.opId }
                engine.ackOps(dropIds.ifEmpty { pending.map { it.opId } })
                pushed = acceptedIds.size
                pulled += engine.applyRemote(response.ops)
                engine.setLastServerSeq(maxOf(engine.lastServerSeq(), response.serverSeq))
            }

            var hasMore = true
            var guard = 0
            while (hasMore && guard < MAX_PULL_ROUNDS) {
                val page = api.pull(engine.lastServerSeq(), pullLimit)
                pulled += engine.applyRemote(page.ops)
                engine.setLastServerSeq(maxOf(engine.lastServerSeq(), page.serverSeq))
                hasMore = page.hasMore && page.ops.isNotEmpty()
                guard++
            }
            SyncResult(ok = true, pushed = pushed, pulled = pulled, serverSeq = engine.lastServerSeq())
        } catch (e: OrdoApiException) {
            SyncResult(false, pushed, pulled, engine.lastServerSeq(), "${e.code}: ${e.message}")
        } catch (e: Throwable) {
            SyncResult(false, pushed, pulled, engine.lastServerSeq(), e.message ?: e::class.simpleName ?: "unknown")
        }
    }

    /** 换设备/数据修复:用服务端快照整表替换(本地 outbox 保留) */
    suspend fun fullResync(): SyncResult = try {
        val remote = api.fetchSnapshot()
        engine.replaceWithRemote(
            OrdoSnapshot(
                schemaVersion = engine.schemaVersion,
                serverSeq = remote.serverSeq,
                areas = remote.areas,
                projects = remote.projects,
                headings = remote.headings,
                todos = remote.todos,
                tags = remote.tags
            )
        )
        SyncResult(ok = true, pulled = remote.todos.size, serverSeq = remote.serverSeq)
    } catch (e: Throwable) {
        SyncResult(false, 0, 0, engine.lastServerSeq(), e.message ?: "snapshot failed")
    }

    companion object {
        private const val MAX_PULL_ROUNDS = 20
    }
}
