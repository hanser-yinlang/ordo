package com.ordo.android.data

import com.ordo.core.sync.OrdoSessionStore
import java.io.File

/**
 * 本地数据按用户隔离（契约 §7.6.3 硬约束）。
 *
 * ```
 * filesDir/ordo-bootstrap.db      ← 引导库：只存 session / 服务器地址（跨账号唯一，登录前就要读）
 * filesDir/<userId>/ordo.db       ← 该账号的实体、outbox、墓碑、同步游标
 * ```
 *
 * **绝不允许两个账号共用同一份本地数据目录** —— 否则 A 的待办会出现在 B 的界面里。
 * 目录名由 [OrdoSessionStore.userDataDirName] 统一生成（四端一致），这里只把它落成真实路径，
 * 并且刻意不做任何跨账号回退：拿到 userId 之前，界面层不会打开任何用户目录。
 */
object UserDataDir {

    /** 用户目录内的数据库文件名 */
    const val DB_NAME = "ordo.db"

    /** 引导库文件名（放在 filesDir 根下，不放在任何 userId 目录里） */
    const val BOOTSTRAP_DB_NAME = "ordo-bootstrap.db"

    /** 目录名（已做防御性清洗；userId 为空时返回空串，调用方必须拒绝） */
    fun dirName(userId: String): String = OrdoSessionStore.userDataDirName(userId)

    /** `filesDir/<userId>/` */
    fun dirFor(baseDir: File, userId: String): File = File(baseDir, dirName(userId))

    /** `filesDir/<userId>/ordo.db` */
    fun dbFileFor(baseDir: File, userId: String): File = File(dirFor(baseDir, userId), DB_NAME)

    /** `filesDir/ordo-bootstrap.db` */
    fun bootstrapDbFile(baseDir: File): File = File(baseDir, BOOTSTRAP_DB_NAME)

    /**
     * 两个账号的数据目录是否已经隔离。
     *
     * 同一个 userId 必须得到同一个目录（换设备/重登后数据还在），
     * 不同 userId 必须得到不同目录（契约 §7.6.3）。
     */
    fun isolated(baseDir: File, userIdA: String, userIdB: String): Boolean =
        userIdA.isNotBlank() && userIdB.isNotBlank() &&
            (userIdA == userIdB || dirFor(baseDir, userIdA) != dirFor(baseDir, userIdB))

    /** 确保目录存在（SQLiteOpenHelper 不会自动建父目录） */
    fun ensureDir(baseDir: File, userId: String): File {
        val dir = dirFor(baseDir, userId)
        if (!dir.exists()) dir.mkdirs()
        return dir
    }
}
