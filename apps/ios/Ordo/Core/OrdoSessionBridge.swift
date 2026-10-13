//
//  OrdoSessionBridge.swift
//  Ordo
//
//  契约 §7.6 的 **Kotlin 桥接层**:会话、应用级 kv 与「按 userId 分目录」的落地。
//
//  ─────────────────────────────────────────────────────────────────────────
//  已核对的 Kotlin 事实(shared/core/src/commonMain/kotlin/com/ordo/core/sync/Session.kt)
//  ─────────────────────────────────────────────────────────────────────────
//  ✓ `data class OrdoSession(userId, email: String?, isGuest: Boolean, accessToken,
//                            refreshToken, expiresAt: Long)`
//      · `isExpired(nowMillis: Long): Boolean`
//      · `displayName(): String`(邮箱为空 → "游客")
//  ✓ `class OrdoSessionStore(storage: OrdoStorage)`
//      · `load(): OrdoSession?` / `save(session: OrdoSession)` / `clear()`
//      · 伴生:`from(response: AuthResponse, nowMillis: Long): OrdoSession`
//              `userDataDirName(userId: String): String`
//              `const val KEY_SESSION = "ordo.session"`
//  ✓ 会话 JSON 的**磁盘形状由核心的 kotlinx.serialization 决定**(四端一致),
//    因此 iOS 侧绝不用 Swift 的 Codable 去写 `ordo.session`。
//
//  ─────────────────────────────────────────────────────────────────────────
//  目录布局(契约 §7.6.3 的「一个账号一个目录」;v1.3 起 userId = 本机账号标识)
//  ─────────────────────────────────────────────────────────────────────────
//    Application Support/Ordo/                  ← 应用级(设备级)
//      ├── session.json                         ← kv 载体:ordo.session / ordo.deviceId
//      │                                                  / ordo.localAccountId
//      ├── <userDataDirName(userId)>/           ← 本机账号的全部本地数据
//      │     └── Ordo.store(+ -shm / -wal)      ← SwiftData
//      └── (历史账号目录)                        ← 不再产生新目录,但**永不删除**(不做迁移)
//
//  为什么会话在根目录:启动时必须**先读会话(才知道 userId)**才能打开数据目录;
//  若会话也在 userId 子目录里就是死循环。目录名一律走核心 `userDataDirName(userId)`
//  (Swift 侧不复制清洗规则)。
//
//  为什么 userId 是本机标识而不是服务端账号 id:v1.3 没有登录界面,服务端身份(匿名令牌)
//  可以被静默重建(离线首启 / refresh 令牌被否认),而**目录必须稳定**,否则用户会看到数据消失。
//  详见 `OrdoSession.swift` 的 `OrdoLocalAccount`。
//

import Foundation
import OrdoCore
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 应用级目录

/// 沙盒内的目录解析(契约 §7.6.3)。
public enum OrdoAppDirectories {

    /// `Application Support/Ordo/`(不存在则创建)。
    public static func root() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base.appendingPathComponent(OrdoSessionDirectory.appFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 会话文件(`Application Support/Ordo/session.json`)。
    public static func sessionFileURL() throws -> URL {
        try root().appendingPathComponent(OrdoSessionDirectory.sessionFileName, isDirectory: false)
    }

    /// 某个本机账号的数据目录:`Application Support/Ordo/<userDataDirName(userId)>/`。
    ///
    /// 目录名由核心清洗(见 `OrdoCoreSessionStore.userDataDirName`),这里只做拼接与创建。
    /// `userId` 是会话里的本机账号标识(见 `OrdoLocalAccount`)。
    public static func userDirectory(userId: String) throws -> URL {
        let name = OrdoCoreSessionStore.userDataDirName(userId)
        let directory = try root().appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 某个账号的 SwiftData 存储文件 URL。
    public static func userStoreURL(userId: String) throws -> URL {
        try userDirectory(userId: userId)
            .appendingPathComponent(OrdoSessionDirectory.storeFileName, isDirectory: false)
    }
}

// MARK: - 应用级 kv(会话 + deviceId)

/// 只承载**应用级 kv** 的 Kotlin `OrdoStorage` 实现(JSON 文件,同步落盘)。
///
/// 用途:给核心 `OrdoSessionStore` 提供一个「能 kvGet / kvSet」的载体。
/// 它**不参与任何同步数据**:快照 / outbox / 墓碑一律返回空,因此不可能把两个账号的数据混在一起 ——
/// 真正的用户数据在 `Application Support/Ordo/<userId>/` 的 SwiftData 里(见 `OrdoAppDirectories`)。
///
/// 为什么是同步写:Kotlin 的 `OrdoStorage` 接口是同步的,而会话必须在「登录成功」返回前就落盘,
/// 否则崩溃/杀进程会丢掉刚写入的登录态。
public final class OrdoFileKVStorage: NSObject, OrdoStorage, @unchecked Sendable {

    private let fileURL: URL
    private let lock = NSLock()
    private var cache: [String: String]

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        self.cache = Self.read(from: fileURL)
        super.init()
    }

    private static func read(from url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        guard let dictionary = object as? [String: String] else { return [:] }
        return dictionary
    }

    private func persist() {
        guard let data = try? JSONSerialization.data(withJSONObject: cache, options: [.sortedKeys]) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    // MARK: Kotlin `OrdoStorage` 的 9 个同步方法(只有 kv 两个有实际语义)

    public func loadSnapshot() -> OrdoCore.OrdoSnapshot? { nil }

    public func saveSnapshot(snapshot: OrdoCore.OrdoSnapshot) {
        // 应用级 kv 不承载实体数据:显式忽略,避免误把账号数据写进根目录。
    }

    public func loadOutbox() -> [OrdoCore.Op] { [] }

    public func appendOutbox(op: OrdoCore.Op) {}

    public func clearOutbox(opIds: [String]) {}

    public func loadTombstones() -> [OrdoCore.Tombstone] { [] }

    public func saveTombstones(list: [OrdoCore.Tombstone]) {}

    public func kvGet(key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    public func kvSet(key: String, value: String?) {
        lock.lock()
        if let value {
            cache[key] = value
        } else {
            cache.removeValue(forKey: key)
        }
        persist()
        lock.unlock()
    }
}

// MARK: - 会话存储(核心 OrdoSessionStore 的 Swift 包装)

/// 契约 §7.6.1 的会话读写:JSON 形状与清洗规则都来自核心,Swift 只做值搬运。
public final class OrdoCoreSessionStore: OrdoSessionStoring, @unchecked Sendable {

    private let store: OrdoCore.OrdoSessionStore
    private let lock = NSLock()

    /// 绑定到**应用级** kv(根目录的 session.json)。
    public convenience init(kvStorage: OrdoFileKVStorage) {
        self.init(kotlinStorage: kvStorage)
    }

    public init(kotlinStorage: OrdoStorage) {
        self.store = OrdoCore.OrdoSessionStore(storage: kotlinStorage)
    }

    /// App 启动路径使用的实例(`Application Support/Ordo/session.json`)。
    public static func makeAppLevel() throws -> OrdoCoreSessionStore {
        let kv = try OrdoFileKVStorage(fileURL: OrdoAppDirectories.sessionFileURL())
        return OrdoCoreSessionStore(kvStorage: kv)
    }

    // MARK: 核心伴生成员

    /// 契约 §7.6.1 的 kv 键名,权威定义在核心 `OrdoSessionStore.KEY_SESSION`。
    public static var keySession: String { OrdoCore.OrdoSessionStore.companion.KEY_SESSION }

    /// 本地数据目录名(契约 §7.6.3):每个账号一个子目录,禁止两个账号共用。
    public static func userDataDirName(_ userId: String) -> String {
        OrdoCore.OrdoSessionStore.companion.userDataDirName(userId: userId)
    }

    // MARK: OrdoSessionStoring

    public func load() async -> OrdoSessionRecord? {
        lock.lock()
        let session = store.load()
        lock.unlock()
        guard let session else { return nil }
        return OrdoCoreSessionStore.map(session: session)
    }

    public func save(_ session: OrdoSessionRecord) async {
        let value = OrdoSession(
            userId: session.userId,
            email: session.email,
            isGuest: session.isGuest,
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            expiresAt: session.expiresAt
        )
        lock.lock()
        store.save(session: value)
        lock.unlock()
    }

    public func clear() async {
        lock.lock()
        store.clear()
        lock.unlock()
    }

    // MARK: 映射(Kotlin OrdoSession → Swift OrdoSessionRecord,只做搬运)

    static func map(session: OrdoCore.OrdoSession) -> OrdoSessionRecord {
        OrdoSessionRecord(
            userId: session.userId,
            email: session.email,
            isGuest: session.isGuest,
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            expiresAt: session.expiresAt
        )
    }
}

// MARK: - 令牌 / 设备标识(会话宿主)

/// 令牌与设备标识的**唯一宿主**。
///
/// · 令牌:读写会话本身(契约 §7.6.1 的 session 即令牌宿所),refresh 轮换 = 会话里换令牌;
/// · deviceId:应用级(设备级,契约 §7.6.1「同一账号可有多台设备」),存在根目录 kv 的
///   `ordo.deviceId`(与核心 `OrdoEngine.KEY_DEVICE_ID` 同名),并由桥接层显式传给引擎,
///   保证 HTTP 头 `X-Ordo-Device` 与引擎产出的 op.deviceId 完全一致。
public actor OrdoSessionTokenStore: OrdoAccountTokenStore {

    private let sessions: OrdoSessionStoring
    private let kv: OrdoFileKVStorage
    private var cachedDeviceId: String?

    public init(sessions: OrdoSessionStoring, kv: OrdoFileKVStorage) {
        self.sessions = sessions
        self.kv = kv
        self.cachedDeviceId = kv.kvGet(key: OrdoSessionTokenStore.deviceIdKey)
    }

    /// 与核心 `OrdoEngine.KEY_DEVICE_ID` 同名(契约 §7.2 的 `dev_<不透明串>`)。
    public static let deviceIdKey = "ordo.deviceId"

    // MARK: OrdoTokenStore

    public func load() async -> OrdoTokens? {
        await sessions.load()?.tokens
    }

    /// `nil` 等价于「清空登录态」(与旧 kv 实现的语义一致)。
    public func save(_ tokens: OrdoTokens?) async {
        guard let tokens else {
            await signOut()
            return
        }
        guard let current = await sessions.load() else { return }
        await sessions.save(current.replacing(tokens: tokens))
    }

    // MARK: 会话

    public func save(session record: OrdoSessionRecord) async {
        await sessions.save(record)
    }

    public func session() async -> OrdoSessionRecord? {
        await sessions.load()
    }

    /// 「已连上云端」的判据 = 会话在**且**有非空 accessToken。
    ///
    /// v1.3 起会存在**离线占位会话**(有本机 userId、没有令牌,见 `OrdoSessionRecord.localOnly`),
    /// 此时不能算已登录:同步层据此保持「本地模式」而不去发一个必然 401 的请求。
    public func isSignedIn() async -> Bool {
        guard let session = await sessions.load() else { return false }
        return session.hasCloudTokens
    }

    /// 清会话(**不动**本地数据目录);仅用于本地重置路径。
    public func signOut() async {
        await sessions.clear()
    }

    // MARK: OrdoDeviceIdentifying

    public func currentDeviceId() async -> String {
        if let cachedDeviceId { return cachedDeviceId }
        if let stored = kv.kvGet(key: Self.deviceIdKey), !stored.isEmpty {
            cachedDeviceId = stored
            return stored
        }
        let generated = "dev_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
        let value = String(generated)
        kv.kvSet(key: Self.deviceIdKey, value: value)
        cachedDeviceId = value
        return value
    }

    public func saveDeviceId(_ deviceId: String) async {
        cachedDeviceId = deviceId
        kv.kvSet(key: Self.deviceIdKey, value: deviceId)
    }

    public func deviceId() async -> String {
        await currentDeviceId()
    }

    public func deviceName() async -> String {
        #if canImport(UIKit)
        return await MainActor.run { UIDevice.current.name }
        #else
        return Host.current().localizedName ?? "iOS 设备"
        #endif
    }
}
