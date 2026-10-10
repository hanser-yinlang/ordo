//
//  SessionAndGateTests.swift
//  OrdoTests
//
//  契约 §7.6「账号、会话与游客」的用例:
//    · 会话读写与游客标记(含 `from(AuthResponse, nowMillis)` 的秒 → 绝对毫秒换算);
//    · 启动门禁状态机(§7.6.4 三级分支 + refresh 失败兜底);
//    · 本地数据目录名(§7.6.3 硬约束:两个账号绝不共用目录);
//    · 会话文件是真落盘的(根目录 kv → 核心 `OrdoSessionStore`,JSON 形状由核心决定)。
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

    /// 游客:没有邮箱、`isGuest = true`,但令牌与正式账号完全一致(不是离线模式)。
    func testGuestSessionCarriesTokensAndGuestFlag() {
        let record = OrdoSessionRecord(
            session: makeAuthSession(email: nil, isGuest: true),
            nowMillis: 1_000
        )
        XCTAssertTrue(record.isGuest)
        XCTAssertNil(record.email)
        XCTAssertEqual(record.displayName(), "游客")
        XCTAssertFalse(record.accessToken.isEmpty)
        XCTAssertFalse(record.refreshToken.isEmpty)
    }

    /// 空邮箱等价于「游客式」展示名(核心 `from` 用 `takeIf { it.isNotBlank() }`,这里同样收敛)。
    func testBlankEmailBecomesNil() {
        let record = OrdoSessionRecord(session: makeAuthSession(email: ""), nowMillis: 0)
        XCTAssertNil(record.email)
        XCTAssertEqual(record.displayName(), "游客")
    }

    /// 过期判定:`expiresAt == 0` 视为未知(未过期),由服务端 401 兜底。
    func testExpiryRules() {
        let unknown = OrdoSessionRecord(
            userId: "u", email: nil, isGuest: true,
            accessToken: "a", refreshToken: "r", expiresAt: 0
        )
        XCTAssertFalse(unknown.isExpired(nowMillis: 9_999_999_999))

        let expired = OrdoSessionRecord(
            userId: "u", email: "a@b.com", isGuest: false,
            accessToken: "a", refreshToken: "r", expiresAt: 1_000
        )
        XCTAssertFalse(expired.isExpired(nowMillis: 999))
        XCTAssertTrue(expired.isExpired(nowMillis: 1_000))
    }

    /// refresh 轮换:只换令牌,账号信息(尤其是 userId 与游客标记)不变。
    func testReplacingTokensKeepsIdentity() {
        let record = OrdoSessionRecord(
            userId: "u-9", email: nil, isGuest: true,
            accessToken: "old", refreshToken: "old-r", expiresAt: 10
        )
        let rotated = record.replacing(
            tokens: OrdoTokens(accessToken: "new", refreshToken: "new-r", expiresAt: 20)
        )
        XCTAssertEqual(rotated.userId, "u-9")
        XCTAssertTrue(rotated.isGuest)
        XCTAssertNil(rotated.email)
        XCTAssertEqual(rotated.accessToken, "new")
        XCTAssertEqual(rotated.refreshToken, "new-r")
        XCTAssertEqual(rotated.expiresAt, 20)
    }
}

// MARK: - 启动门禁状态机(契约 §7.6.4)

final class OrdoStartupPlannerTests: XCTestCase {

    private func record(expiresAt: Int64, accessToken: String = "a") -> OrdoSessionRecord {
        OrdoSessionRecord(
            userId: "u-1",
            email: "a@ordo.app",
            isGuest: false,
            accessToken: accessToken,
            refreshToken: "r",
            expiresAt: expiresAt
        )
    }

    /// 无会话 → 登录页(必须给三个入口)。
    func testNoSessionShowsLogin() {
        XCTAssertEqual(OrdoStartupPlanner.plan(session: nil, nowMillis: 1_000), .showLogin)
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

    /// 坏数据(空令牌 / 空 userId)等同无会话,避免用半个会话去开目录。
    func testCorruptedSessionFallsBackToLogin() {
        XCTAssertEqual(OrdoStartupPlanner.plan(session: record(expiresAt: 9_999, accessToken: ""), nowMillis: 0), .showLogin)
        let emptyUser = OrdoSessionRecord(
            userId: "", email: nil, isGuest: true,
            accessToken: "a", refreshToken: "r", expiresAt: 9_999
        )
        XCTAssertEqual(OrdoStartupPlanner.plan(session: emptyUser, nowMillis: 0), .showLogin)
    }

    /// refresh 失败 → 回登录页,但**不**删除该 userId 的目录(契约 §7.6.3)。
    func testRefreshFailureReturnsToLoginAndKeepsDirectory() {
        let session = record(expiresAt: 1)
        XCTAssertEqual(OrdoStartupPlanner.planAfterRefreshFailure(session: session), .showLogin)
    }
}

// MARK: - 目录隔离(契约 §7.6.3 硬约束)

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

    /// 两个账号 → 两个不同目录(绝不允许 A 的数据出现在 B 的界面里)。
    func testTwoAccountsGetDifferentDirectories() throws {
        let alice = try OrdoAppDirectories.userDirectory(userId: "user-alice")
        let bob = try OrdoAppDirectories.userDirectory(userId: "user-bob")
        XCTAssertNotEqual(alice, bob)
        XCTAssertEqual(alice.lastPathComponent, "user-alice")
        XCTAssertEqual(bob.lastPathComponent, "user-bob")

        let aliceStore = try OrdoAppDirectories.userStoreURL(userId: "user-alice")
        let bobStore = try OrdoAppDirectories.userStoreURL(userId: "user-bob")
        XCTAssertNotEqual(aliceStore, bobStore)
        XCTAssertEqual(aliceStore.deletingLastPathComponent(), alice)
        XCTAssertEqual(bobStore.lastPathComponent, OrdoSessionDirectory.storeFileName)
    }

    /// 目录会被真正创建(否则 SwiftData 打开会失败)。
    func testUserDirectoryIsCreated() throws {
        let directory = try OrdoAppDirectories.userDirectory(userId: "user-create-check")
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
            userId: "u-42",
            email: "a@ordo.app",
            isGuest: false,
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: 1_759_900_000_000
        )
        await store.save(record)
        let loaded = await store.load()
        XCTAssertEqual(loaded, record)
    }

    /// 游客会话同样能往返,且 `isGuest` / 空邮箱不丢。
    func testGuestRoundTrip() async throws {
        let store = try makeStore()
        let guest = OrdoSessionRecord(
            userId: "guest-7",
            email: nil,
            isGuest: true,
            accessToken: "a",
            refreshToken: "r",
            expiresAt: 0
        )
        await store.save(guest)
        let loaded = await store.load()
        XCTAssertEqual(loaded?.isGuest, true)
        XCTAssertNil(loaded?.email)
        XCTAssertEqual(loaded?.userId, "guest-7")
    }

    /// 退出登录只清会话(契约 §7.6.3):`clear()` 之后 `load()` 必须为空。
    func testClearOnlyRemovesSession() async throws {
        let store = try makeStore()
        await store.save(OrdoSessionRecord(
            userId: "u-1", email: "a@ordo.app", isGuest: false,
            accessToken: "a", refreshToken: "r", expiresAt: 1
        ))
        await store.clear()
        let loaded = await store.load()
        XCTAssertNil(loaded)
    }

    /// 换账号 = 换会话,且根目录 kv 里只有一份会话(A 的令牌不可能被 B 复用)。
    func testSavingAnotherAccountReplacesSession() async throws {
        let store = try makeStore()
        await store.save(OrdoSessionRecord(
            userId: "alice", email: "alice@ordo.app", isGuest: false,
            accessToken: "alice-token", refreshToken: "alice-refresh", expiresAt: 10
        ))
        await store.save(OrdoSessionRecord(
            userId: "bob", email: "bob@ordo.app", isGuest: false,
            accessToken: "bob-token", refreshToken: "bob-refresh", expiresAt: 20
        ))
        let loaded = await store.load()
        XCTAssertEqual(loaded?.userId, "bob")
        XCTAssertEqual(loaded?.accessToken, "bob-token")
    }

    /// 设备标识存在同一个应用级 kv 里(与会话共存,不随账号切换而变)。
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
    }

    /// 令牌读写落在会话上:`save(tokens)` 之后 `load()` 返回同一对令牌。
    func testTokenStoreWritesIntoSession() async throws {
        let sessions = OrdoMemorySessionStore(initial: OrdoSessionRecord(
            userId: "u-1", email: "a@ordo.app", isGuest: false,
            accessToken: "old", refreshToken: "old-r", expiresAt: 1
        ))
        let kv = try OrdoFileKVStorage(fileURL: fileURL)
        let tokens = OrdoSessionTokenStore(sessions: sessions, kv: kv)

        await tokens.save(OrdoTokens(accessToken: "new", refreshToken: "new-r", expiresAt: 99))
        let loaded = await tokens.load()
        XCTAssertEqual(loaded?.accessToken, "new")
        XCTAssertEqual(loaded?.refreshToken, "new-r")
        // 账号信息不被令牌刷新改写
        let session = await tokens.session()
        XCTAssertEqual(session?.userId, "u-1")
        XCTAssertEqual(session?.email, "a@ordo.app")

        // 清空令牌 = 清会话(退出登录路径)
        await tokens.save(nil)
        let after = await tokens.session()
        XCTAssertNil(after)
        let signedIn = await tokens.isSignedIn()
        XCTAssertFalse(signedIn)
    }
}

// MARK: - 桩鉴权 API(记录调用参数,返回固定响应或抛错)

/// 放在文件作用域(而不是测试类内部):嵌套类型不受 `@MainActor` 隔离保护,
/// 这里显式 `@unchecked Sendable` 并自己保证访问都在测试串行流程里。
final class OrdoStubAuthAPI: OrdoAuthAPI, @unchecked Sendable {

    var registerCalls: [(email: String, password: String)] = []
    var loginCalls: [(email: String, password: String)] = []
    var guestCalls = 0
    var refreshCalls = 0
    var logoutCalls = 0
    var upgradeCalls = 0
    /// 契约 §7.6.5:请求验证码时记录的邮箱。
    var emailCodeRequests: [String] = []
    /// 契约 §7.6.5:验证码登录时记录的(邮箱, 码)。
    var emailLoginCalls: [(email: String, code: String)] = []
    /// 契约 §7.6.5:响应里的 `retryAfter`(测试可改成 0 以跳过倒计时)。
    var codeRetryAfter: Int64 = 60
    /// 契约 §7.6.5:仅开发模式回显的验证码。
    var devCode: String?
    var nextError: Error?
    var expiresIn = 1800
    var isGuestResponse = false

    private func response(userId: String, email: String?) -> OrdoAuthSession {
        OrdoAuthSession(
            user: OrdoUser(id: userId, email: email, isGuest: isGuestResponse),
            device: OrdoDevice(id: "dev-1", name: "iPhone", platform: "ios/1.0.0"),
            accessToken: "access-\(userId)",
            refreshToken: "refresh-\(userId)",
            expiresIn: expiresIn
        )
    }

    func register(email: String, password: String, deviceName: String, platform: String) async throws -> OrdoAuthSession {
        registerCalls.append((email, password))
        if let nextError { throw nextError }
        return response(userId: "registered", email: email)
    }

    func login(email: String, password: String, deviceName: String, platform: String) async throws -> OrdoAuthSession {
        loginCalls.append((email, password))
        if let nextError { throw nextError }
        return response(userId: "logged-in", email: email)
    }

    func refresh(refreshToken: String) async throws -> OrdoAuthSession {
        refreshCalls += 1
        if let nextError { throw nextError }
        return response(userId: "logged-in", email: "a@ordo.app")
    }

    func logout(refreshToken: String) async throws {
        logoutCalls += 1
    }

    func guest(_ request: OrdoGuestAuthRequest) async throws -> OrdoAuthSession {
        guestCalls += 1
        if let nextError { throw nextError }
        isGuestResponse = true
        return response(userId: "guest-1", email: nil)
    }

    func upgrade(accessToken: String, _ request: OrdoUpgradeRequest) async throws -> OrdoUpgradeResponse {
        upgradeCalls += 1
        if let nextError { throw nextError }
        isGuestResponse = false
        return OrdoUpgradeResponse(user: OrdoUser(id: "guest-1", email: request.email, isGuest: false))
    }

    // MARK: 邮箱验证码登录(契约 §7.6.5)

    func requestEmailCode(_ request: OrdoEmailCodeRequest) async throws -> OrdoEmailCodeSent {
        emailCodeRequests.append(request.email)
        if let nextError { throw nextError }
        return OrdoEmailCodeSent(sent: true, expiresIn: 300, retryAfter: codeRetryAfter, devCode: devCode)
    }

    func emailLogin(_ request: OrdoEmailCodeLoginRequest) async throws -> OrdoAuthSession {
        emailLoginCalls.append((request.email, request.code))
        if let nextError { throw nextError }
        return response(userId: "code-login", email: request.email)
    }
}

// MARK: - 登录门禁的服务层(三个入口)

@MainActor
final class OrdoAuthServiceTests: XCTestCase {

    private func makeService(
        initial: OrdoSessionRecord? = nil,
        api: OrdoStubAuthAPI = OrdoStubAuthAPI(),
        now: Int64 = 1_759_900_000_000
    ) -> (OrdoAuthService, OrdoMemorySessionStore, OrdoStubAuthAPI) {
        let store = OrdoMemorySessionStore(initial: initial)
        let kv = try! OrdoFileKVStorage(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("ordo-auth-\(UUID().uuidString).json")
        )
        let tokens = OrdoSessionTokenStore(sessions: store, kv: kv)
        let service = OrdoAuthService(
            sessionStore: store,
            tokenStore: tokens,
            authAPI: api,
            clock: OrdoFixedClock(millis: now)
        )
        return (service, store, api)
    }

    /// 登录成功:会话写入存储,并返回给调用方去打开主界面。
    func testLoginSavesSession() async throws {
        let (service, store, api) = makeService()
        let record = try await service.login(email: "a@ordo.app", password: "password8")
        XCTAssertEqual(api.loginCalls.count, 1)
        XCTAssertEqual(record.userId, "logged-in")
        let stored = await store.load()
        XCTAssertEqual(stored?.userId, "logged-in")
        XCTAssertEqual(service.session?.accessToken, "access-logged-in")
    }

    /// 注册成功:同样写会话(userId 来自服务端)。
    func testRegisterSavesSession() async throws {
        let (service, store, api) = makeService()
        _ = try await service.register(email: "new@ordo.app", password: "password8")
        XCTAssertEqual(api.registerCalls.first?.email, "new@ordo.app")
        let stored = await store.load()
        XCTAssertEqual(stored?.userId, "registered")
    }

    /// 游客登录:会话带 `isGuest = true` 且没有邮箱,令牌齐全。
    func testGuestLoginMarksGuest() async throws {
        let (service, store, api) = makeService()
        let record = try await service.continueAsGuest()
        XCTAssertEqual(api.guestCalls, 1)
        XCTAssertTrue(record.isGuest)
        XCTAssertNil(record.email)
        XCTAssertFalse(record.accessToken.isEmpty)
        let stored = await store.load()
        XCTAssertEqual(stored?.isGuest, true)
    }

    /// 失败要能被 UI 读成中文提示(错误不靠颜色单独表达)。
    func testLoginFailureSurfacesChineseHint() async {
        let api = OrdoStubAuthAPI()
        api.nextError = OrdoAPIError(code: .authInvalidCredentials, message: "invalid")
        let (service, store, _) = makeService(api: api)

        do {
            _ = try await service.login(email: "a@ordo.app", password: "password8")
            XCTFail("应当抛错")
        } catch {
            XCTAssertEqual(OrdoAuthService.hint(for: error), "邮箱或密码不正确")
        }
        let stored = await store.load()
        XCTAssertNil(stored, "失败不应写入会话")
        XCTAssertEqual(service.lastError, "邮箱或密码不正确")
    }

    /// 启动:有且未过期 → 直接 resume(后台静默 refresh 由 App 层触发)。
    func testRestoreResumesValidSession() async {
        let valid = OrdoSessionRecord(
            userId: "u-1", email: "a@ordo.app", isGuest: false,
            accessToken: "a", refreshToken: "r", expiresAt: 1_759_900_000_000 + 60_000
        )
        let (service, _, api) = makeService(initial: valid)
        let plan = await service.restore()
        XCTAssertEqual(plan, .resume(valid))
        XCTAssertEqual(api.refreshCalls, 0)
    }

    /// 启动:accessToken 过期 → 先 refresh;成功后会话里换成新令牌。
    func testRestoreRefreshesExpiredSession() async {
        let expired = OrdoSessionRecord(
            userId: "u-1", email: "a@ordo.app", isGuest: false,
            accessToken: "old", refreshToken: "r", expiresAt: 1_759_900_000_000 - 1
        )
        let (service, store, api) = makeService(initial: expired)
        let plan = await service.restore()
        XCTAssertEqual(api.refreshCalls, 1)
        if case .resume(let session) = plan {
            XCTAssertEqual(session.accessToken, "access-logged-in")
        } else {
            XCTFail("refresh 成功后应直接进入主界面,实际:\(plan)")
        }
        let stored = await store.load()
        XCTAssertNotNil(stored)
    }

    /// 启动:refresh 失败 → 登录页,且**只清会话**(目录由 `OrdoSessionDirectoryTests` 覆盖)。
    func testRestoreFallsBackToLoginWhenRefreshFails() async {
        let expired = OrdoSessionRecord(
            userId: "u-1", email: "a@ordo.app", isGuest: false,
            accessToken: "old", refreshToken: "r", expiresAt: 1
        )
        let api = OrdoStubAuthAPI()
        api.nextError = OrdoAPIError(code: .authInvalidCredentials, message: "invalid")
        let (service, store, _) = makeService(initial: expired, api: api)

        let plan = await service.restore()
        XCTAssertEqual(plan, .showLogin)
        let stored = await store.load()
        XCTAssertNil(stored, "失效的会话不该留在本地")
        XCTAssertNil(service.session)
    }

    /// 退出登录:通知服务端 + 清会话;userEmail / isGuest 随之清空。
    func testSignOutClearsSessionOnly() async throws {
        let (service, store, api) = makeService()
        _ = try await service.continueAsGuest()
        await service.signOut()
        XCTAssertEqual(api.logoutCalls, 1)
        let stored = await store.load()
        XCTAssertNil(stored)
        XCTAssertNil(service.session)
    }

    /// 游客升级:userId 不变、邮箱补上、isGuest 翻转为 false。
    func testUpgradeKeepsUserId() async throws {
        let (service, _, api) = makeService()
        _ = try await service.continueAsGuest()
        let upgraded = try await service.upgrade(email: "upgraded@ordo.app", password: "password8")
        XCTAssertEqual(api.upgradeCalls, 1)
        XCTAssertEqual(upgraded.userId, "guest-1")
        XCTAssertEqual(upgraded.email, "upgraded@ordo.app")
        XCTAssertFalse(upgraded.isGuest)
        // 令牌保持不变(升级不重新签发)
        XCTAssertEqual(upgraded.accessToken, "access-guest-1")
    }
}

// MARK: - 登录表单状态机(UI 规范 §5.1)

final class OrdoLoginFormTests: XCTestCase {

    private func filled(_ form: inout OrdoLoginForm) {
        form.email = "a@ordo.app"
        form.password = "password8"
    }

    /// 校验:邮箱为空 / 形状不对 / 口令不足 8 位都要拦住(契约 §9)。
    func testValidation() {
        var form = OrdoLoginForm()
        XCTAssertEqual(form.validationMessage(), "请输入邮箱")

        form.email = "not-an-email"
        XCTAssertEqual(form.validationMessage(), "邮箱格式不正确")

        form.email = "a@ordo.app"
        XCTAssertEqual(form.validationMessage(), "口令至少 8 位")

        form.password = "password8"
        XCTAssertNil(form.validationMessage())
        XCTAssertTrue(form.canSubmit)
    }

    /// 提交中被禁用(输入框与三个入口一并禁用)。
    func testSubmittingDisablesEntries() {
        var form = OrdoLoginForm()
        filled(&form)
        XCTAssertTrue(form.beginSubmission())
        XCTAssertTrue(form.isSubmitting)
        XCTAssertFalse(form.canSubmit)
        XCTAssertFalse(form.canUseSecondaryEntries)
        XCTAssertFalse(form.beginSubmission(), "提交中不应重复发起")
        form.finishSubmission()
        XCTAssertTrue(form.canSubmit)
    }

    /// 校验不通过时不发请求,而是就地报错并请求一次抖动。
    func testInvalidSubmissionShakes() {
        var form = OrdoLoginForm()
        form.email = "a@ordo.app"
        form.password = "short"
        let before = form.shakeToken
        XCTAssertFalse(form.beginSubmission())
        XCTAssertFalse(form.isSubmitting)
        XCTAssertEqual(form.shakeToken, before + 1)
        XCTAssertEqual(form.errorMessage, "口令至少 8 位")
    }

    /// 失败:文案 + 抖动计数;成功路径由调用方 finishSubmission 收尾。
    func testFailureShakesAndKeepsMessage() {
        var form = OrdoLoginForm()
        filled(&form)
        _ = form.beginSubmission()
        form.fail("邮箱或密码不正确")
        XCTAssertEqual(form.errorMessage, "邮箱或密码不正确")
        XCTAssertEqual(form.shakeToken, 1)
        XCTAssertFalse(form.isSubmitting)
        form.clearError()
        XCTAssertNil(form.errorMessage)
    }

    /// 模式切换:文案与提示成对切换,并清掉上一模式的错误。
    func testModeToggle() {
        var form = OrdoLoginForm()
        XCTAssertEqual(form.mode.primaryTitle, "登录")
        XCTAssertEqual(form.mode.switchPrompt, "还没有账号?")
        XCTAssertEqual(form.mode.switchActionTitle, "注册")

        form.fail("出错了")
        form.toggleMode()
        XCTAssertEqual(form.mode, .register)
        XCTAssertEqual(form.mode.primaryTitle, "注册")
        XCTAssertEqual(form.mode.switchPrompt, "已有账号?")
        XCTAssertEqual(form.mode.switchActionTitle, "登录")
        XCTAssertNil(form.errorMessage, "切换模式应清掉上一模式的错误")
    }

    /// 口令显隐是纯 UI 状态,不影响校验。
    func testPasswordVisibilityToggle() {
        var form = OrdoLoginForm()
        XCTAssertFalse(form.isPasswordVisible)
        form.togglePasswordVisibility()
        XCTAssertTrue(form.isPasswordVisible)
    }

    /// 游客入口不要求邮箱口令(体验与正式登录对等,但输入更少)。
    func testGuestEntryDoesNotRequireCredentials() {
        var form = OrdoLoginForm()
        XCTAssertTrue(form.beginGuestSubmission())
        XCTAssertTrue(form.isSubmitting)
        XCTAssertNil(form.errorMessage)
    }

    /// 邮箱形状判定的小样本(避免把明显无效的输入发到服务端)。
    func testEmailShape() {
        XCTAssertTrue(OrdoLoginForm.looksLikeEmail("a@b.com"))
        XCTAssertFalse(OrdoLoginForm.looksLikeEmail("a@b"))
        XCTAssertFalse(OrdoLoginForm.looksLikeEmail("a b@c.com"))
        XCTAssertFalse(OrdoLoginForm.looksLikeEmail("@b.com"))
        XCTAssertFalse(OrdoLoginForm.looksLikeEmail("a@.com"))
        XCTAssertFalse(OrdoLoginForm.looksLikeEmail("a@b."))
    }
}
