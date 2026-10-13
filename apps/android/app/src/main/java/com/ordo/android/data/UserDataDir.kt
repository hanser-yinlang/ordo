package com.ordo.android.data

import com.ordo.core.sync.OrdoSessionStore
import java.io.File

/**
 * 本地数据按**本机稳定账号标识**隔离（契约 §7.6.3 + §7.6.6 硬约束）。
 *
 * ```
 * filesDir/ordo-bootstrap.db      ← 引导库：session / 服务器地址 / 设备标识 / 本机目录 id（先于账号读到）
 * filesDir/<dirId>/ordo.db        ← 该工作区的实体、outbox、墓碑、同步游标
 * ```
 *
 * **绝不允许两个工作区共用同一份本地数据目录** —— 否则 A 的待办会出现在 B 的界面里。
 * 目录名由 [OrdoSessionStore.userDataDirName] 统一生成（四端一致），这里只把它落成真实路径。
 *
 * v1.3（不再有登录界面，契约 §7.6.6）：`dirId` 是**本机钉住的标识**（[LocalAccount]），
 * 首次运行生成 `local-<16hex>` 并持久化，**永不因会话重建而改变**；升级前已在用的
 * `<服务端 userId>` 目录继续沿用（不做迁移）。服务端 userId 只用于鉴权与同步。
 */
object UserDataDir {

    /** 工作区目录内的数据库文件名 */
    const val DB_NAME = "ordo.db"

    /** 引导库文件名（放在 filesDir 根下，不放在任何工作区目录里） */
    const val BOOTSTRAP_DB_NAME = "ordo-bootstrap.db"

    /** 目录名（已做防御性清洗；dirId 为空时返回空串，调用方必须拒绝） */
    fun dirName(dirId: String): String = OrdoSessionStore.userDataDirName(dirId)

    /** `filesDir/<dirId>/` */
    fun dirFor(baseDir: File, dirId: String): File = File(baseDir, dirName(dirId))

    /** `filesDir/<dirId>/ordo.db` */
    fun dbFileFor(baseDir: File, dirId: String): File = File(dirFor(baseDir, dirId), DB_NAME)

    /** `filesDir/ordo-bootstrap.db` */
    fun bootstrapDbFile(baseDir: File): File = File(baseDir, BOOTSTRAP_DB_NAME)

    /**
     * 两个工作区的数据目录是否已经隔离。
     *
     * 同一个 dirId 必须得到同一个目录（重启/会话重建后数据还在），
     * 不同 dirId 必须得到不同目录（契约 §7.6.3）。
     */
    fun isolated(baseDir: File, dirIdA: String, dirIdB: String): Boolean =
        dirIdA.isNotBlank() && dirIdB.isNotBlank() &&
            (dirIdA == dirIdB || dirFor(baseDir, dirIdA) != dirFor(baseDir, dirIdB))

    /** 确保目录存在（SQLiteOpenHelper 不会自动建父目录） */
    fun ensureDir(baseDir: File, dirId: String): File {
        val dir = dirFor(baseDir, dirId)
        if (!dir.exists()) dir.mkdirs()
        return dir
    }

    /**
     * 磁盘上**已有数据**的工作区目录 id（含 `local-*` 与升级前的服务端 userId 目录）。
     *
     * 只统计"里面真的有 `ordo.db`"的目录：引导库是文件不算，空目录也不算。
     * 契约 §7.6.6 的"升级前已在用的目录继续沿用"用它来判定。
     */
    fun existingDirIds(baseDir: File): List<String> =
        baseDir.listFiles()
            ?.filter { it.isDirectory && File(it, DB_NAME).isFile }
            ?.map { it.name }
            ?.filter { it.isNotBlank() }
            ?.sorted()
            ?: emptyList()
}

