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
//  启动流程(**v1.3 产品决定:不再有登录界面**,见 `OrdoStartupPlanner`):
//    读 session
//      ├─ 有 userId        → 直接用(令牌为空 = 离线占位会话,联网后由后台重试补齐)
//      │     └─ accessToken 过期 → 先 refresh;网络失败 → 继续离线用;服务端否认 → 静默重建匿名会话
//      └─ 无 / userId 为空 → 静默 `POST /v1/auth/guest` 建匿名会话(网络不可达则先用本机 id 占位)
//
//  目录与会话 userId 的关系(见 `OrdoLocalAccount`):会话的 `userId` 现在是**本机稳定标识**,
//  服务端账号 id 不再决定目录 —— 这样离线首启与 401 重建都不会换目录、不会丢数据(不做迁移)。
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

    /// 由鉴权响应构造(对应核心伴生 `OrdoSessionStore.from(response, nowMillis)`)。
    ///
    /// `expiresIn` 是**秒**;<= 0 时按「未知」处理(0),与核心一致。
    ///
    /// - Parameter userId: 覆盖会话的 `userId`。默认取服务端返回的账号 id;
    ///   静默匿名会话传入**本机稳定标识**(`OrdoLocalAccount`),
    ///   保证「离线首启 → 联网认领」与「401 重建匿名会话」都不会改变本地目录。
    public init(session: OrdoAuthSession, nowMillis: Int64, userId: String? = nil) {
        let email = session.user.email
        self.init(
            userId: userId ?? session.user.id,
            email: (email?.isEmpty ?? true) ? nil : email,
            isGuest: session.user.isGuest,
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            expiresAt: session.expiresIn > 0 ? nowMillis + Int64(session.expiresIn) * 1000 : 0
        )
    }

    /// 离线占位会话:还没有连上云端(或首启无网),只有本机账号标识、没有任何令牌。
    ///
    /// 它让「网络不可达也照常进主界面」成立:目录由 `userId` 决定并保持稳定,
    /// 后台退避重试拿到匿名令牌后,再原地补上令牌(`replacing(tokens:)` 之外的字段都保持)。
    public static func localOnly(userId: String) -> OrdoSessionRecord {
        OrdoSessionRecord(
            userId: userId,
            email: nil,
            isGuest: true,
            accessToken: "",
            refreshToken: "",
            expiresAt: 0
        )
    }

    /// 是否已拿到云端令牌(离线占位会话为 `false`)。
    public var hasCloudTokens: Bool {
        !accessToken.isEmpty
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
    /// 只清会话,**不动**该本机账号的数据目录(会话损坏或本地重置时使用)。
    func clear() async
}

/// 令牌 + 设备标识 + 账号态的统一读写面(HTTP 客户端与同步协调器消费)。
///
/// 令牌只存在于会话中(refresh 轮换 = 会话内换令牌),不存在令牌与目录错配的路径。
public protocol OrdoAccountTokenStore: OrdoTokenStore, OrdoDeviceIdentifying {
    func save(session: OrdoSessionRecord) async
    func session() async -> OrdoSessionRecord?
    /// 是否已拿到云端令牌(离线占位会话为 `false`)。
    func isSignedIn() async -> Bool
    /// 清会话(**不动**数据目录);仅用于本地重置路径。
    func signOut() async
}

// MARK: - 本机账号标识(v1.3:不再有登录界面)

/// 会话里的 `userId` 现在是**本机稳定标识**,而不是服务端账号 id。
///
/// 为什么这样做(产品决定「不做迁移 + 离线也要能进主界面」的必然结论):
/// · 本地目录 = `<userId>/`,所以 `userId` 必须**跨启动稳定**;
/// · 服务端身份(accessToken / refreshToken)是**可静默重建**的 —— 首启离线、refresh 令牌
///   过期被服务端否认时,客户端会重新 `POST /v1/auth/guest` 拿到**新的**服务端账号;
/// · 若目录跟着服务端账号走,上述两种情况都会换目录,用户会看到「数据不见了」;
///   保持本机 id 后,目录永不改变,本地数据还会在下次同步时被推到新账号上。
///
/// 服务端**不消费**这个字段:推送只带 `deviceId`,账号由令牌决定(见 `OrdoPushRequest`)。
public enum OrdoLocalAccount {

    /// 根目录 kv 的键(与 `ordo.session` / `ordo.deviceId` 同一个应用级文件)。
    public static let kvKey = "ordo.localAccountId"

    /// 生成一个本机账号 id(仅小写字母/数字与 `-`,天然满足核心目录名清洗规则)。
    public static func generate() -> String {
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "local-" + hex.prefix(16)
    }

    /// 读本机账号 id;首次运行生成并落盘(此后永不改变)。
    public static func resolve(in kv: OrdoFileKVStorage) -> String {
        if let existing = kv.kvGet(key: kvKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }
        let generated = generate()
        kv.kvSet(key: kvKey, value: generated)
        return generated
    }
}

// MARK: - 启动流程(v1.3:启动即主界面)

/// 启动时的路由结果(**没有登录分支**:任何路径都直接进主界面)。
public enum OrdoStartupPlan: Equatable, Sendable {
    /// 有可用会话 → 直接进入主界面(令牌为空则先以本地模式进入)。
    case resume(OrdoSessionRecord)
    /// 有会话但 accessToken 已过期 → 先 refresh。
    case refresh(OrdoSessionRecord)
    /// 无可用会话 → **静默**创建匿名会话(`POST /v1/auth/guest`)。
    case createAnonymous
}

/// 启动路由(纯函数,便于在无 macOS 环境下做状态机断言)。
public enum OrdoStartupPlanner {

    /// 读会话后的第一步。
    public static func plan(session: OrdoSessionRecord?, nowMillis: Int64) -> OrdoStartupPlan {
        // 没有 userId 就无法决定本地目录 → 只能静默建匿名会话。
        guard let session, !session.userId.isEmpty else { return .createAnonymous }
        // 令牌为空 = 上次没连上云端(离线占位会话):照常进主界面,后台重试补齐令牌。
        guard !session.accessToken.isEmpty else { return .resume(session) }
        return session.isExpired(nowMillis: nowMillis) ? .refresh(session) : .resume(session)
    }

    /// refresh 失败后的兜底(**不再回登录页**):
    /// · **网络类失败**(离线 / 超时)→ `.resume`:保留现有会话继续离线可用,目录不变,联网后再刷新;
    /// · **服务端明确否认**(401 / 令牌失效)→ `.createAnonymous`:会话已不可用,静默重建匿名会话。
    public static func planAfterRefreshFailure(
        session: OrdoSessionRecord?,
        serverRejected: Bool
    ) -> OrdoStartupPlan {
        if !serverRejected, let session, !session.userId.isEmpty {
            return .resume(session)
        }
        return .createAnonymous
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
