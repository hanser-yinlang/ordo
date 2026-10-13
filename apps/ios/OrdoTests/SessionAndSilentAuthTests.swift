//
//  SessionAndSilentAuthTests.swift
//  OrdoTests
//
//  v1.3「没有登录界面 + 静默匿名会话」的用例(取代 v1.2 的 `SessionAndGateTests`):
//    · 会话模型(秒 → 绝对毫秒、离线占位会话、refresh 轮换只换令牌与账号标识);
//    · 启动路由(有效 → resume;过期 → refresh;网络失败 → resume 离线可用;
//      服务端否认 / 无会话 → 静默 createAnonymous);
//    · 本机账号标识(生成格式、跨实例稳定)—— 它是「不换目录、不丢数据」的关键;
//    · 静默匿名会话服务(建号沿用本机 userId、401 重建不换目录、离线占位会话落盘);
//    · 本地数据目录隔离与会话落盘(核心 `OrdoSessionStore` 往返);
//    · 服务端地址**隐藏覆盖**(UserDefaults 的 `ordo.apiBaseURL`;非法值回落默认)。
//
//  ⚠️ 本机(Windows)没有 macOS/Swift 工具链,这些用例**无法运行**,
//     必须在 macOS 上跑:`bash apps/ios/tools/verify_ios.sh`(或 Xcode 的 OrdoTests)。
//     涉及 `OrdoCore`(KMP)的断言还需要先 `./gradlew :shared:core:assembleOrdoCoreXCFramework`。
//

import XCTest
// 模块名两条构建路径不同:Xcode 工程(PRODUCT_NAME=Ordo)是 `Ordo`,SwiftPM 是 `OrdoKit`。
#if canImport(OrdoKit)
@testable import OrdoKit
#else
@testable import Ordo
#endif

// MARK: - 内存会话存储(测试桩)

/// 内存版会话存储:与 `OrdoCoreSessionStore` 同协议,便于在无 KMP 依赖下驱动状态机。
final class OrdoMemorySessionStore: OrdoSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: OrdoSessionRecord?

    init(initial: OrdoSessionRecord? = nil) {
        self.stored = initial
    }

    func load() async -> OrdoSessionRecord? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func save(_ session: OrdoSessionRecord) async {
        lock.lock()
        stored = session
        lock.unlock()
    }

    func clear() async {
        lock.lock()
        stored = nil
        lock.unlock()
    }
}

// MARK: - 会话模型

final class OrdoSessionRecordTests: XCTestCase {

    private func makeAuthSession(
        userId: String = "u-1",
        email: String? = "a@ordo.app",
        isGuest: Bool = false,
        expiresIn: Int = 1800
    ) -> OrdoAuthSession {
        OrdoAuthSession(
            user: OrdoUser(id: userId, email: email, isGuest: isGuest),
            device: OrdoDevice(id: "dev-1", name: "iPhone", platform: "ios/1.0.0"),
            accessToken: "access-1",
            refreshToken: "refresh-1",
            expiresIn: expiresIn
        )
    }

    /// `expiresIn` 是**秒**,会话里存的是绝对毫秒(与核心 `OrdoSessionStore.from` 一致)。
    func testAuthResponseMapsExpiryToAbsoluteMillis() {
        let now: Int64 = 1_759_900_000_000
        let record = OrdoSessionRecord(session: makeAuthSession(expiresIn: 1800), nowMillis: now)
        XCTAssertEqual(record.expiresAt, now + 1_800_000)
        XCTAssertEqual(record.userId, "u-1")
        XCTAssertEqual(record.accessToken, "access-1")
        XCTAssertEqual(record.refreshToken, "refresh-1")
        XCTAssertFalse(record.isGuest)
    }

    /// 静默匿名会话:服务端返回的账号 id 被**本机标识**覆盖(目录必须稳定)。
    func testAnonymousSessionKeepsLocalUserId() {
        let record = OrdoSessionRecord(
            session: makeAuthSession(userId: "server-u-9", email: nil, isGuest: true),
            nowMillis: 1_000,
            userId: "local-abc123"
        )
        XCTAssertEqual(record.userId, "local-abc123")
        XCTAssertTrue(record.isGuest)
        XCTAssertNil(record.email)
        XCTAssertEqual(record.accessToken, "access-1")
        XCTAssertTrue(record.hasCloudTokens)
    }

    /// 空邮箱等价于「匿名」展示名(核心 `from` 用 `takeIf { it.isNotBlank() }`,这里同样收敛)。
    func testBlankEmailBecomesNil() {
        let record = OrdoSessionRecord(session: makeAuthSession(email: ""), nowMillis: 0)
        XCTAssertNil(record.email)
        XCTAssertEqual(record.displayName(), "游客")
    }

    /// 离线占位会话:只有本机 userId,没有任何令牌,也没有过期时间。
    func testLocalOnlySessionHasNoTokens() {
        let record = OrdoSessionRecord.localOnly(userId: "local-offline")
        XCTAssertEqual(record.userId, "local-offline")
        XCTAssertTrue(record.isGuest)
        XCTAssertNil(record.email)
        XCTAssertFalse(record.hasCloudTokens)
        XCTAssertFalse(record.isExpired(nowMillis: 9_999_999_999), "0 = 未知,不按过期处理")
    }

    /// 过期判定:`expiresAt == 0` 视为未知(未过期),由服务端 401 兜底。
    func testExpiryRules() {
        let unknown = OrdoSessionRecord.localOnly(userId: "u")
        XCTAssertFalse(unknown.isExpired(nowMillis: 9_999_999_999))

        let expired = OrdoSessionRecord(
            userId: "u", email: "a@b.com", isGuest: false,
            accessToken: "a", refreshToken: "r", expiresAt: 1_000
        )
        XCTAssertFalse(expired.isExpired(nowMillis: 999))
        XCTAssertTrue(expired.isExpired(nowMillis: 1_000))
    }

    /// refresh 轮换:只换令牌,账号标识(决定目录)与匿名标记不变。
    func testReplacingTokensKeepsIdentity() {
        let record = OrdoSessionRecord(
            userId: "local-9", email: nil, isGuest: true,
            accessToken: "old", refreshToken: "old-r", expiresAt: 10
        )
        let rotated = record.replacing(
            tokens: OrdoTokens(accessToken: "new", refreshToken: "new-r", expiresAt: 20)
        )
        XCTAssertEqual(rotated.userId, "local-9")
        XCTAssertTrue(rotated.isGuest)
        XCTAssertNil(rotated.email)
        XCTAssertEqual(rotated.accessToken, "new")
        XCTAssertEqual(rotated.refreshToken, "new-r")
        XCTAssertEqual(rotated.expiresAt, 20)
    }
}

// MARK: - 本机账号标识(v1.3:目录不随服务端账号变化)

final class OrdoLocalAccountTests: XCTestCase {

    /// 生成格式:前缀 `local-` + 16 位小写十六进制(天然满足核心目录名清洗规则)。
    func testGeneratedIdFormat() {
        let value = OrdoLocalAccount.generate()
        XCTAssertTrue(value.hasPrefix("local-"))
        XCTAssertEqual(value.count, "local-".count + 16)
        let suffix = String(value.dropFirst("local-".count))
        XCTAssertTrue(
            suffix.allSatisfy { $0.isNumber || ("a"..."f").contains($0) },
            "后缀应是小写十六进制:\(suffix)"
        )
        XCTAssertEqual(OrdoCoreSessionStore.userDataDirName(value), value, "生成值不应被清洗规则改写")
    }

    /// 每次生成都不同(避免两台设备撞同一个目录标识)。
    func testGeneratedIdsAreDistinct() {
        XCTAssertNotEqual(OrdoLocalAccount.generate(), OrdoLocalAccount.generate())
    }

    /// `resolve` 首次生成并落盘,之后(含新实例读同一文件)始终返回同一个值。
    func testResolveIsStableAcrossInstances() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ordo-local-account-\(UUID().uuidString).json")

        let first = OrdoLocalAccount.resolve(in: try OrdoFileKVStorage(fileURL: fileURL))
        let second = OrdoLocalAccount.resolve(in: try OrdoFileKVStorage(fileURL: fileURL))
        XCTAssertEqual(first, second)

        // 同一实例再读也只返回已落盘的值。
        let kv = try OrdoFileKVStorage(fileURL: fileURL)
        XCTAssertEqual(OrdoLocalAccount.resolve(in: kv), first)
        XCTAssertEqual(kv.kvGet(key: OrdoLocalAccount.kvKey), first)
    }
}

// MARK: - 启动路由(v1.3:启动即主界面)

final class OrdoStartupPlannerTests: XCTestCase {

    private func record(expiresAt: Int64, accessToken: String = "a") -> OrdoSessionRecord {
        OrdoSessionRecord(
            userId: "local-1",
            email: nil,
            isGuest: true,
            accessToken: accessToken,
            refreshToken: "r",
            expiresAt: expiresAt
        )
    }

    /// 无会话 → 静默创建匿名会话(**不再有登录页**)。
    func testNoSessionCreatesAnonymous() {
        XCTAssertEqual(OrdoStartupPlanner.plan(session: nil, nowMillis: 1_000), .createAnonymous)
    }

    /// 有且未过期 → 直接进主界面。
    func testValidSessionResumes() {
        let session = record(expiresAt: 5_000)
        XCTAssertEqual(OrdoStartupPlanner.plan(session: session, nowMillis: 4_999), .resume(session))
    }

    /// 有但过期 → 先 refresh。
    func testExpiredSessionRefreshesFirst() {
        let session = record(expiresAt: 5_000)
        XCTAssertEqual(OrdoStartupPlanner.plan(session: session, nowMillis: 5_000), .refresh(session))
    }

    /// 离线占位会话(没有令牌、但有本机 userId)→ 照常进主界面,联网后再补令牌。
    func testOfflinePlaceholderSessionResumes() {
        let offline = OrdoSessionRecord.localOnly(userId: "local-1")
        XCTAssertEqual(OrdoStartupPlanner.plan(session: offline, nowMillis: 9_999_999), .resume(offline))
    }

    /// 没有 userId 的会话无法决定目录 → 等同无会话(静默建号)。
    func testSessionWithoutUserIdCreatesAnonymous() {
        let broken = OrdoSessionRecord(
            userId: "", email: nil, isGuest: true,
            accessToken: "a", refreshToken: "r", expiresAt: 9_999
        )
        XCTAssertEqual(OrdoStartupPlanner.plan(session: broken, nowMillis: 0), .createAnonymous)
    }

    /// refresh **网络失败** → 保留会话继续离线可用(目录与数据都不动)。
    func testRefreshNetworkFailureKeepsSession() {
        let session = record(expiresAt: 1)
        XCTAssertEqual(
            OrdoStartupPlanner.planAfterRefreshFailure(session: session, serverRejected: false),
            .resume(session)
        )
    }

    /// refresh **被服务端否认** → 静默重建匿名会话。
    func testRefreshServerRejectionCreatesAnonymous() {
        let session = record(expiresAt: 1)
        XCTAssertEqual(
            OrdoStartupPlanner.planAfterRefreshFailure(session: session, serverRejected: true),
            .createAnonymous
        )
        // 连会话都没有时也只能建号。
        XCTAssertEqual(
            OrdoStartupPlanner.planAfterRefreshFailure(session: nil, serverRejected: false),
            .createAnonymous
        )
    }
}

// MARK: - 目录隔离(核心 `userDataDirName` 的可核对证据)

final class OrdoSessionDirectoryTests: XCTestCase {

    /// 目录名清洗规则来自核心 `OrdoSessionStore.userDataDirName`(不在 Swift 侧复制)。
    func testDirectoryNameComesFromCore() {
        XCTAssertEqual(OrdoCoreSessionStore.userDataDirName("0f3a-11_zz"), "0f3a-11_zz")
        // 非法字符统一替换为 `_`(核心实现:`isLetterOrDigit || '-' || '_'` 之外一律 `_`)
        XCTAssertEqual(OrdoCoreSessionStore.userDataDirName("a/b:c"), "a_b_c")
        XCTAssertEqual(OrdoCoreSessionStore.userDataDirName("../../etc"), ".._.._etc")
    }

    /// 会话键名与契约 §7.6.1 一致(`kv["ordo.session"]`)。
    func testSessionKeyMatchesContract() {
        XCTAssertEqual(OrdoCoreSessionStore.keySession, "ordo.session")
    }

    /// 两个账号标识 → 两个不同目录(数据绝不串门);本机标识跨启动稳定 → 目录也稳定。
    func testTwoAccountsGetDifferentDirectories() throws {
        let alice = try OrdoAppDirectories.userDirectory(userId: "local-alice")
        let bob = try OrdoAppDirectories.userDirectory(userId: "local-bob")
        XCTAssertNotEqual(alice, bob)
        XCTAssertEqual(alice.lastPathComponent, "local-alice")
        XCTAssertEqual(bob.lastPathComponent, "local-bob")

        let aliceStore = try OrdoAppDirectories.userStoreURL(userId: "local-alice")
        XCTAssertEqual(aliceStore.deletingLastPathComponent(), alice)
        XCTAssertEqual(aliceStore.lastPathComponent, OrdoSessionDirectory.storeFileName)

        // 同一个本机标识反复解析得到同一个目录(v1.3 的「不换目录」保证)。
        XCTAssertEqual(try OrdoAppDirectories.userDirectory(userId: "local-alice"), alice)
    }

    /// 目录会被真正创建(否则 SwiftData 打开会失败)。
    func testUserDirectoryIsCreated() throws {
        let directory = try OrdoAppDirectories.userDirectory(userId: "local-create-check")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }
}

// MARK: - 会话落盘(根目录 kv → 核心 OrdoSessionStore)

final class OrdoCoreSessionStoreTests: XCTestCase {

    private var fileURL: URL!

    override func setUp() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ordo-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("session.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func makeStore() throws -> OrdoCoreSessionStore {
        let kv = try OrdoFileKVStorage(fileURL: fileURL)
        return OrdoCoreSessionStore(kvStorage: kv)
    }

    /// save → load 往返(JSON 由核心的 kotlinx.serialization 序列化)。
    func testRoundTripThroughCoreStore() async throws {
        let store = try makeStore()
        let record = OrdoSessionRecord(
            userId: "local-42",
            email: nil,
            isGuest: true,
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: 1_759_900_000_000
        )
        await store.save(record)
        let loaded = await store.load()
        XCTAssertEqual(loaded, record)
    }

    /// 离线占位会话同样能往返(没有令牌的会话也必须能可靠落盘,否则每次启动都会换目录)。
    func testOfflinePlaceholderRoundTrip() async throws {
        let store = try makeStore()
        let offline = OrdoSessionRecord.localOnly(userId: "local-offline")
        await store.save(offline)
        let loaded = await store.load()
        XCTAssertEqual(loaded, offline)
        XCTAssertFalse(loaded?.hasCloudTokens ?? true)
    }

    /// 会话可以被清掉(本地重置路径),`load()` 之后必须为空。
    func testClearRemovesSession() async throws {
        let store = try makeStore()
        await store.save(OrdoSessionRecord.localOnly(userId: "local-1"))
        await store.clear()
        let loaded = await store.load()
        XCTAssertNil(loaded)
    }

    /// 新会话覆盖旧会话,且根目录 kv 里只有一份(A 的令牌不可能被 B 复用)。
    func testSavingAnotherSessionReplacesIt() async throws {
        let store = try makeStore()
        await store.save(OrdoSessionRecord(
            userId: "local-alice", email: nil, isGuest: true,
            accessToken: "alice-token", refreshToken: "alice-refresh", expiresAt: 10
        ))
        await store.save(OrdoSessionRecord(
            userId: "local-bob", email: nil, isGuest: true,
            accessToken: "bob-token", refreshToken: "bob-refresh", expiresAt: 20
        ))
        let loaded = await store.load()
        XCTAssertEqual(loaded?.userId, "local-bob")
        XCTAssertEqual(loaded?.accessToken, "bob-token")
    }

    /// 设备标识存在同一个应用级 kv 里(与本地账号标识共存,不随会话重建而变)。
    func testDeviceIdIsAppLevel() async throws {
        let kv = try OrdoFileKVStorage(fileURL: fileURL)
        let tokens = OrdoSessionTokenStore(sessions: OrdoMemorySessionStore(), kv: kv)
        let first = await tokens.currentDeviceId()
        XCTAssertTrue(first.hasPrefix("dev_"))
        let second = await tokens.currentDeviceId()
        XCTAssertEqual(first, second)

        // 新实例读同一个文件 → 设备标识保持(不因进程重启而改变)
        let reopened = OrdoSessionTokenStore(
            sessions: OrdoMemorySessionStore(),
            kv: try OrdoFileKVStorage(fileURL: fileURL)
        )
        let reloaded = await reopened.currentDeviceId()
        XCTAssertEqual(reloaded, first)

        // 本地账号标识也在同一个文件里,两者互不影响。
        let localId = OrdoLocalAccount.resolve(in: kv)
        XCTAssertEqual(OrdoLocalAccount.resolve(in: try OrdoFileKVStorage(fileURL: fileURL)), localId)
        let deviceAfter = await tokens.currentDeviceId()
        XCTAssertEqual(deviceAfter, first)
    }

    /// 令牌读写落在会话上:`save(tokens)` 之后 `load()` 返回同一对令牌。
    func testTokenStoreWritesIntoSession() async throws {
        let sessions = OrdoMemorySessionStore(initial: OrdoSessionRecord(
            userId: "local-1", email: nil, isGuest: true,
            accessToken: "old", refreshToken: "old-r", expiresAt: 1
        ))
        let kv = try OrdoFileKVStorage(fileURL: fileURL)
        let tokens = OrdoSessionTokenStore(sessions: sessions, kv: kv)

        await tokens.save(OrdoTokens(accessToken: "new", refreshToken: "new-r", expiresAt: 99))
        let loaded = await tokens.load()
        XCTAssertEqual(loaded?.accessToken, "new")
        XCTAssertEqual(loaded?.refreshToken, "new-r")
        // 账号标识不被令牌刷新改写(决定目录,绝不能变)
        let session = await tokens.session()
        XCTAssertEqual(session?.userId, "local-1")
        XCTAssertTrue(await tokens.isSignedIn())

        // 清空令牌 = 清会话
        await tokens.save(nil)
        let after = await tokens.session()
        XCTAssertNil(after)
        let signedIn = await tokens.isSignedIn()
        XCTAssertFalse(signedIn)
    }

    /// **离线占位会话不算「已连接云端」**:同步层据此保持本地模式,不去发必然 401 的请求。
    func testOfflinePlaceholderIsNotSignedIn() async throws {
        let sessions = OrdoMemorySessionStore(initial: OrdoSessionRecord.localOnly(userId: "local-1"))
        let tokens = OrdoSessionTokenStore(
            sessions: sessions,
            kv: try OrdoFileKVStorage(fileURL: fileURL)
        )
        let signedIn = await tokens.isSignedIn()
        XCTAssertFalse(signedIn)
        let session = await tokens.session()
        XCTAssertEqual(session?.userId, "local-1", "会话本身仍然在,目录仍可解析")
    }
}

// MARK: - 桩鉴权 API(只保留静默匿名所需的两个方法)

/// 放在文件作用域(而不是测试类内部):嵌套类型不受 `@MainActor` 隔离保护,
/// 这里显式 `@unchecked Sendable` 并自己保证访问都在测试串行流程里。
final class OrdoStubAuthAPI: OrdoAuthAPI, @unchecked Sendable {

    var guestCalls = 0
    var refreshCalls = 0
    var nextError: Error?
    var expiresIn = 1800
    /// 服务端返回的账号 id(客户端会用本机标识覆盖它,见 `OrdoLocalAccount`)。
    var serverUserId = "server-guest"

    private func response(userId: String) -> OrdoAuthSession {
        OrdoAuthSession(
            user: OrdoUser(id: userId, email: nil, isGuest: true),
            device: OrdoDevice(id: "dev-1", name: "iPhone", platform: "ios/1.0.0"),
            accessToken: "access-\(userId)",
            refreshToken: "refresh-\(userId)",
            expiresIn: expiresIn
        )
    }

    func refresh(refreshToken: String) async throws -> OrdoAuthSession {
        refreshCalls += 1
        if let nextError { throw nextError }
        return response(userId: serverUserId)
    }

    func guest(_ request: OrdoGuestAuthRequest) async throws -> OrdoAuthSession {
        guestCalls += 1
        if let nextError { throw nextError }
        return response(userId: serverUserId)
    }
}

// MARK: - 静默匿名会话的服务层

@MainActor
final class OrdoSilentAuthServiceTests: XCTestCase {

    private func makeService(
        initial: OrdoSessionRecord? = nil,
        api: OrdoStubAuthAPI = OrdoStubAuthAPI(),
        localAccountId: String = "local-test",
        now: Int64 = 1_759_900_000_000
    ) -> (OrdoAuthService, OrdoMemorySessionStore, OrdoStubAuthAPI) {
        let store = OrdoMemorySessionStore(initial: initial)
        let kv = try! OrdoFileKVStorage(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("ordo-silent-auth-\(UUID().uuidString).json")
        )
        let tokens = OrdoSessionTokenStore(sessions: store, kv: kv)
        let service = OrdoAuthService(
            sessionStore: store,
            tokenStore: tokens,
            authAPI: api,
            localAccountId: localAccountId,
            clock: OrdoFixedClock(millis: now)
        )
        return (service, store, api)
    }

    // MARK: 启动

    /// 启动:有且未过期 → 直接 resume(后台静默 refresh 由 App 层触发)。
    func testRestoreResumesValidSession() async {
        let valid = OrdoSessionRecord(
            userId: "local-1", email: nil, isGuest: true,
            accessToken: "a", refreshToken: "r", expiresAt: 1_759_900_000_000 + 60_000
        )
        let (service, _, api) = makeService(initial: valid)
        let plan = await service.restore()
        XCTAssertEqual(plan, .resume(valid))
        XCTAssertEqual(api.refreshCalls, 0)
        XCTAssertEqual(api.guestCalls, 0, "有效会话不应触发建号")
    }

    /// 启动:离线占位会话(无令牌)→ 仍然 resume(离线可用),且不尝试 refresh。
    func testRestoreResumesOfflinePlaceholder() async {
        let offline = OrdoSessionRecord.localOnly(userId: "local-1")
        let (service, _, api) = makeService(initial: offline)
        let plan = await service.restore()
        XCTAssertEqual(plan, .resume(offline))
        XCTAssertEqual(api.refreshCalls, 0)
        XCTAssertEqual(service.session?.userId, "local-1")
    }

    /// 启动:accessToken 过期 → 先 refresh;成功后会话换成新令牌,但**账号标识不变**。
    func testRestoreRefreshesExpiredSessionKeepingLocalUserId() async {
        let expired = OrdoSessionRecord(
            userId: "local-1", email: nil, isGuest: true,
            accessToken: "old", refreshToken: "r", expiresAt: 1_759_900_000_000 - 1
        )
        let (service, store, api) = makeService(initial: expired)
        let plan = await service.restore()
        XCTAssertEqual(api.refreshCalls, 1)
        guard case .resume(let session) = plan else {
            return XCTFail("refresh 成功后应直接进入主界面,实际:\(plan)")
        }
        XCTAssertEqual(session.userId, "local-1", "刷新令牌不得改变本地目录标识")
        XCTAssertEqual(session.accessToken, "access-\(api.serverUserId)")
        let stored = await store.load()
        XCTAssertEqual(stored?.userId, "local-1")
    }

    /// 启动:refresh **网络失败** → 保留会话离线可用(不再有登录页)。
    func testRestoreKeepsSessionWhenRefreshFailsOffline() async {
        let expired = OrdoSessionRecord(
            userId: "local-1", email: nil, isGuest: true,
            accessToken: "old", refreshToken: "r", expiresAt: 1
        )
        let api = OrdoStubAuthAPI()
        api.nextError = OrdoAPIError.transport("网络不可达")
        let (service, store, _) = makeService(initial: expired, api: api)

        let plan = await service.restore()
        XCTAssertEqual(plan, .resume(expired), "断网时必须照常进主界面")
        let stored = await store.load()
        XCTAssertEqual(stored?.userId, "local-1", "断网不得清掉会话")
        XCTAssertEqual(service.session?.userId, "local-1")
    }

    /// 启动:refresh **被服务端否认** → 清掉死会话并静默重建匿名会话。
    func testRestoreCreatesAnonymousWhenServerRejectsRefresh() async {
        let expired = OrdoSessionRecord(
            userId: "local-1", email: nil, isGuest: true,
            accessToken: "old", refreshToken: "r", expiresAt: 1
        )
        let api = OrdoStubAuthAPI()
        api.nextError = OrdoAPIError(code: .authInvalidCredentials, message: "invalid", httpStatus: 401)
        let (service, store, _) = makeService(initial: expired, api: api)

        let plan = await service.restore()
        XCTAssertEqual(plan, .createAnonymous)
        let stored = await store.load()
        XCTAssertNil(stored, "失效的会话不该留在本地")
        XCTAssertNil(service.session)
    }

    /// 启动:没有会话 → 静默建号(不经过任何登录界面)。
    func testRestoreAsksForAnonymousWhenNoSession() async {
        let (service, _, _) = makeService()
        let plan = await service.restore()
        XCTAssertEqual(plan, .createAnonymous)
    }

    /// 启动:会话没有 userId(坏数据)→ 同样静默建号。
    func testRestoreAsksForAnonymousWhenSessionHasNoUserId() async {
        let broken = OrdoSessionRecord(
            userId: "", email: nil, isGuest: true,
            accessToken: "a", refreshToken: "r", expiresAt: 9_999
        )
        let (service, _, _) = makeService(initial: broken)
        let plan = await service.restore()
        XCTAssertEqual(plan, .createAnonymous)
    }

    // MARK: 静默匿名会话

    /// 首次启动建号:服务端账号 id 被本机标识覆盖并落盘。
    func testStartAnonymousSessionPersistsLocalUserId() async throws {
        let (service, store, api) = makeService(localAccountId: "local-first")
        let record = try await service.startAnonymousSession()

        XCTAssertEqual(api.guestCalls, 1)
        XCTAssertEqual(api.serverUserId, "server-guest")
        XCTAssertEqual(record.userId, "local-first", "目录标识必须是本机 id")
        XCTAssertTrue(record.hasCloudTokens)
        let stored = await store.load()
        XCTAssertEqual(stored?.userId, "local-first")
        XCTAssertEqual(stored?.accessToken, record.accessToken)
    }

    /// **401 重建不换目录**:老会话的 userId(哪怕是历史服务端 id)继续沿用。
    func testAnonymousRebuildKeepsExistingUserId() async throws {
        let legacy = OrdoSessionRecord(
            userId: "server-legacy-id", email: nil, isGuest: true,
            accessToken: "dead", refreshToken: "dead-r", expiresAt: 1
        )
        let (service, store, api) = makeService(initial: legacy, localAccountId: "local-new")
        _ = await service.restore()

        let rebuilt = try await service.startAnonymousSession()
        XCTAssertEqual(api.guestCalls, 1)
        XCTAssertEqual(rebuilt.userId, "server-legacy-id", "重建匿名会话不得改变本地目录")
        XCTAssertNotEqual(rebuilt.accessToken, "dead")
        let stored = await store.load()
        XCTAssertEqual(stored?.userId, "server-legacy-id")
    }

    /// 建号失败(无网)→ 抛错且不改本地状态,调用方据此进入离线模式。
    func testStartAnonymousSessionFailureKeepsLocalState() async throws {
        let api = OrdoStubAuthAPI()
        api.nextError = OrdoAPIError.transport("无网")
        let (service, store, _) = makeService(api: api)

        do {
            _ = try await service.startAnonymousSession()
            XCTFail("应当抛错")
        } catch {
            XCTAssertFalse(OrdoAuthService.isCredentialsRejected(error))
        }
        let stored = await store.load()
        XCTAssertNil(stored)
        XCTAssertNil(service.session)
    }

    /// 离线占位会话:落盘 + 复用既有 userId(连续离线启动也不会换目录)。
    func testStartLocalOnlySessionIsPersistedAndStable() async {
        let (service, store, _) = makeService(localAccountId: "local-offline")
        let first = await service.startLocalOnlySession()
        XCTAssertEqual(first.userId, "local-offline")
        XCTAssertFalse(first.hasCloudTokens)
        let stored = await store.load()
        XCTAssertEqual(stored, first)

        // 再调用不会生成新的标识(否则每次离线启动都会开新目录)。
        let second = await service.startLocalOnlySession()
        XCTAssertEqual(second.userId, "local-offline")
    }

    /// 已有会话时 `startLocalOnlySession` 直接返回既有会话(不覆盖成占位会话)。
    func testStartLocalOnlySessionKeepsExistingSession() async {
        let existing = OrdoSessionRecord(
            userId: "local-1", email: nil, isGuest: true,
            accessToken: "a", refreshToken: "r", expiresAt: 9_999
        )
        let (service, _, _) = makeService(initial: existing)
        _ = await service.restore()
        let result = await service.startLocalOnlySession()
        XCTAssertEqual(result.accessToken, "a")
    }

    // MARK: 「服务端否认」判定

    /// 只有服务端明确否认才算会话失效;网络/限流/服务端故障都必须保留会话离线可用。
    func testCredentialsRejectionClassification() {
        XCTAssertTrue(OrdoAuthService.isCredentialsRejected(
            OrdoAPIError(code: .authRequired, message: "x", httpStatus: 401)
        ))
        XCTAssertTrue(OrdoAuthService.isCredentialsRejected(
            OrdoAPIError(code: .authInvalidCredentials, message: "x", httpStatus: 401)
        ))
        XCTAssertTrue(OrdoAuthService.isCredentialsRejected(
            OrdoAPIError(code: .authTokenExpired, message: "x", httpStatus: 401)
        ))
        // 错误体缺失时按 HTTP 状态兜底
        XCTAssertTrue(OrdoAuthService.isCredentialsRejected(
            OrdoAPIError(code: .internal, message: "x", httpStatus: 403)
        ))

        XCTAssertFalse(OrdoAuthService.isCredentialsRejected(OrdoAPIError.transport("offline")))
        XCTAssertFalse(OrdoAuthService.isCredentialsRejected(
            OrdoAPIError(code: .rateLimited, message: "slow", httpStatus: 429)
        ))
        XCTAssertFalse(OrdoAuthService.isCredentialsRejected(
            OrdoAPIError(code: .internal, message: "boom", httpStatus: 500)
        ))
        XCTAssertFalse(OrdoAuthService.isCredentialsRejected(OrdoJSONError.notAnObject))
    }
}

// MARK: - 服务端地址的隐藏覆盖(v1.3:设置页不再有输入框)

final class OrdoAPIEnvironmentResolverTests: XCTestCase {

    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "ordo.api-environment.tests.\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }

    /// 不配置 → 默认本机开发地址(「默认不动」)。
    func testMissingOverrideFallsBackToDefault() {
        XCTAssertEqual(
            OrdoAPIEnvironment.resolved(defaults: defaults()).baseURL,
            OrdoAPIEnvironment.default.baseURL
        )
    }

    /// 合法覆盖 → 用它(https + 端口;这里用 `URLComponents` 拼串,避免源码里出现裸 URL 常量)。
    func testValidOverrideWins() throws {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.example.com"
        components.port = 8443
        let raw = try XCTUnwrap(components.string)

        let store = defaults()
        store.set(raw, forKey: OrdoAPIEnvironment.baseURLDefaultsKey)
        let resolved = OrdoAPIEnvironment.resolved(defaults: store)
        XCTAssertEqual(resolved.baseURL.scheme, "https")
        XCTAssertEqual(resolved.baseURL.host, "api.example.com")
        XCTAssertEqual(resolved.baseURL.port, 8443)
        XCTAssertEqual(resolved.clientHeader, "ios/1.0.0")
    }

    /// 非法取值一律静默回落默认(空 / 空白 / 非 URL / 缺 host / 非 http(s) scheme / 相对路径)。
    func testInvalidOverrideFallsBackToDefault() {
        let cases = ["", "   ", "not a url", "http:", "ftp://example.com", "/relative/path"]
        for value in cases {
            let store = defaults()
            store.set(value, forKey: OrdoAPIEnvironment.baseURLDefaultsKey)
            XCTAssertEqual(
                OrdoAPIEnvironment.resolved(defaults: store).baseURL,
                OrdoAPIEnvironment.default.baseURL,
                "`\(value)` 应回落默认地址"
            )
        }
    }

    /// 覆盖键是隐藏约定,改名会破坏 README 里写的改法。
    func testOverrideKeyIsStable() {
        XCTAssertEqual(OrdoAPIEnvironment.baseURLDefaultsKey, "ordo.apiBaseURL")
    }
}
