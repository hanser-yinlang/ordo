//
//  OrdoSession.swift
//  Ordo
//
//  契约 §7.6「账号、会话与游客」的 Swift 侧门面。
//
//  权威实现在共享核心(shared/core/src/commonMain/kotlin/com/ordo/core/sync/Session.kt):
//    · `OrdoSession`      —— userId / email? / isGuest / accessToken / refreshToken / expiresAt,
//                            `isExpired(nowMillis)`、`displayName()`;
//    · `OrdoSessionStore` —— `load() / save() / clear()`,伴生 `from(AuthResponse, nowMillis)`、
//                            `userDataDirName(userId)`、常量 `KEY_SESSION = "ordo.session"`。
//
//  **落盘一律走核心**(见 `OrdoSessionBridge.swift` 的 `OrdoCoreSessionStore`),
//  本文件的 `OrdoSessionRecord` 只是把核心模型搬进 Swift 内存态,便于 UI / 测试消费:
//  它的 `Codable` 只用于 Swift 侧传递(内存实现、测试桩),**不是**磁盘上的 JSON 形状。
//
//  启动流程(契约 §7.6.4,四端一致)由 `OrdoStartupPlanner` 给出:
//    读 session
//      ├─ 有且未过期            → 直接进主界面(后台静默 refresh)
//      ├─ 有但 accessToken 过期 → 先 refresh;失败 → 登录页(保留该 userId 的目录)
//      └─ 无                    → 登录页(登录 / 注册 / 游客登录 三个入口)
//

import Foundation

// MARK: - 会话模型

/// 本地会话(契约 §7.6.1 的 `session`)。
///
/// 与核心 `sync.OrdoSession` **逐字段一致**;派生方法(`isExpired` / `displayName`)是核心同名方法的
/// 一行等价实现,`OrdoSessionTests` 里有与核心 `userDataDirName`/`isExpired` 的交叉断言防止漂移。
public struct OrdoSessionRecord: Codable, Hashable, Sendable {

    public var userId: String
    /// 游客为 `nil`(契约 §7.6.1:游客没有邮箱)。
    public var email: String?
    /// `true` = 游客账号(**不是**离线模式:令牌与同步能力完全一致)。
    public var isGuest: Bool
    public var accessToken: String
    public var refreshToken: String
    /// 过期时刻(epoch millis);`0` 表示未知(按未过期处理,由服务端 401 兜底)。
    public var expiresAt: Int64

    public init(
        userId: String,
        email: String?,
        isGuest: Bool,
        accessToken: String,
        refreshToken: String,
        expiresAt: Int64
    ) {
        self.userId = userId
        self.email = email
        self.isGuest = isGuest
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// 由登录 / 注册 / 游客登录的响应构造(对应核心伴生 `OrdoSessionStore.from(response, nowMillis)`)。
    ///
    /// `expiresIn` 是**秒**;<= 0 时按「未知」处理(0),与核心一致。
    public init(session: OrdoAuthSession, nowMillis: Int64) {
        let email = session.user.email
        self.init(
            userId: session.user.id,
            email: (email?.isEmpty ?? true) ? nil : email,
            isGuest: session.user.isGuest,
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            expiresAt: session.expiresIn > 0 ? nowMillis + Int64(session.expiresIn) * 1000 : 0
        )
    }

    /// 是否已过期(契约 §7.6.4)。`expiresAt == 0` 视为未知 → 未过期。
    public func isExpired(nowMillis: Int64) -> Bool {
        expiresAt > 0 && nowMillis >= expiresAt
    }

    /// 展示名:正式账号用邮箱,游客用「游客」(与核心 `displayName()` 一致)。
    public func displayName() -> String {
        if let email, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return email }
        return "游客"
    }

    /// 会话里的令牌(HTTP 层消费;契约 §7.6.1 的会话即令牌的唯一宿主)。
    public var tokens: OrdoTokens {
        OrdoTokens(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt)
    }

    /// refresh 轮换后替换令牌,账号信息不变。
    public func replacing(tokens: OrdoTokens) -> OrdoSessionRecord {
        OrdoSessionRecord(
            userId: userId,
            email: email,
            isGuest: isGuest,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: tokens.expiresAt
        )
    }
}

// MARK: - 读写协议

/// 会话的本地读写(磁盘实现见 `OrdoCoreSessionStore`;测试用内存实现)。
public protocol OrdoSessionStoring: AnyObject, Sendable {
    func load() async -> OrdoSessionRecord?
    func save(_ session: OrdoSessionRecord) async
    /// 契约 §7.6.3:退出登录**只清会话**,保留该 userId 的本地数据目录。
    func clear() async
}

/// 令牌 + 设备标识 + 账号态的统一读写面(HTTP 客户端与同步协调器消费)。
///
/// 与旧实现(`OrdoStorageTokenStore`,令牌散落在各用户目录的 kv 里)的区别:
/// 令牌只存在于会话中,因此「换账号 = 换会话」,不存在 A 的令牌被 B 复用的路径。
public protocol OrdoAccountTokenStore: OrdoTokenStore, OrdoDeviceIdentifying {
    func save(session: OrdoSessionRecord) async
    func session() async -> OrdoSessionRecord?
    func userEmail() async -> String?
    func userIsGuest() async -> Bool
    func isSignedIn() async -> Bool
    /// 清会话(保留本地数据目录);契约 §7.6.3。
    func signOut() async
}

// MARK: - 启动流程(契约 §7.6.4)

/// 启动时的路由结果。
public enum OrdoStartupPlan: Equatable, Sendable {
    /// 有且未过期 → 直接进入主界面。
    case resume(OrdoSessionRecord)
    /// 有但 accessToken 已过期 → 先 refresh。
    case refresh(OrdoSessionRecord)
    /// 无会话(或 refresh 失败后)→ 登录页,必须给出三个入口。
    case showLogin
}

/// 启动路由(纯函数,便于在无 macOS 环境下做状态机断言)。
public enum OrdoStartupPlanner {

    /// 读会话后的第一步(契约 §7.6.4 的前两级)。
    public static func plan(session: OrdoSessionRecord?, nowMillis: Int64) -> OrdoStartupPlan {
        guard let session else { return .showLogin }
        // 空令牌的会话是坏数据:等同无会话(核心 `load()` 遇到损坏 JSON 也返回 nil)。
        guard !session.accessToken.isEmpty, !session.userId.isEmpty else { return .showLogin }
        return session.isExpired(nowMillis: nowMillis) ? .refresh(session) : .resume(session)
    }

    /// refresh 失败后的兜底:回登录页,**保留**该 userId 的本地目录(契约 §7.6.4)。
    public static func planAfterRefreshFailure(session: OrdoSessionRecord?) -> OrdoStartupPlan {
        _ = session   // 目录由 userId 决定,登录页不删除任何数据;这里显式表达「仍然保留」。
        return .showLogin
    }
}

// MARK: - 数据目录(契约 §7.6.3)

/// 目录命名的 Swift 侧说明。
///
/// **规则本身在核心**(`OrdoSessionStore.userDataDirName`),iOS 通过
/// `OrdoCoreSessionStore.userDataDirName(_:)` 调用,不在 Swift 侧复制清洗逻辑,
/// 避免四端出现「同一 userId 落到不同目录名」的漂移。
public enum OrdoSessionDirectory {
    /// 本地数据根目录名(沙盒内 `Application Support/Ordo/`)。
    public static let appFolderName = "Ordo"
    /// SwiftData 存储文件名(实际落盘为 `Ordo.store` / `-shm` / `-wal`)。
    public static let storeFileName = "Ordo.store"
    /// 会话文件名的说明:会话是**应用级指针**,存在根目录(kv 键 `ordo.session`),
    /// 而不是任何 userId 子目录里 —— 否则「先读会话才知道 userId」就成了死循环。
    public static let sessionFileName = "session.json"
}
