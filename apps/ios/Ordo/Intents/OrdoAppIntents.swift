//
//  OrdoAppIntents.swift
//  Ordo
//
//  系统集成(设计规范 §7 平台映射):App Intents 提供「新建待办」等快捷指令,
//  供「快捷指令」App、Siri、聚焦搜索与操作按钮调用。
//
//  契约 §5 的自然语言解析由 KMP `NaturalDateParser` 完成,因此快捷指令的文本参数
//  支持「明天 18:00 交季度报告 #重要」这类写法。
//
//  说明:App Intents 的 `perform()` 是异步的,这里通过一个 `@MainActor` 的共享写入器
//  直接使用 KMP 引擎与本地存储,避免依赖 UI 生命周期。
//

import AppIntents
import Foundation
import SwiftData

// MARK: - 新建待办

@available(iOS 17.0, *)
struct CreateTodoIntent: AppIntent {

    static var title: LocalizedStringResource = "新建待办"
    static var description = IntentDescription("把一条待办加入序 Ordo;文本支持「明天 18:00 交季度报告 #重要」。")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "内容", description: "例如:明天 18:00 交季度报告 #重要")
    var text: String

    @Parameter(title: "清单", description: "留空则进入收件箱", default: nil)
    var listName: String?

    static var parameterSummary: some ParameterSummary {
        Summary("新建待办 \(\.$text)") {
            \.$listName
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = OrdoIntentStore.shared
        let created = try await store.createTodo(rawText: text, listName: listName)
        let dialog = created.map { "已添加:\($0.title)" } ?? "没能理解这条待办,请换个说法。"
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

// MARK: - 打开清单

@available(iOS 17.0, *)
struct OpenListIntent: AppIntent {

    static var title: LocalizedStringResource = "打开清单"
    static var description = IntentDescription("打开收件箱 / 今天 / 计划 / 随时 / 某天 / 日志簿。")
    static var openAppWhenRun: Bool = true

    enum Target: String, AppEnum {
        case inbox, today, upcoming, anytime, someday, logbook

        static var typeDisplayRepresentation: TypeDisplayRepresentation = "清单"
        static var caseDisplayRepresentations: [Target: DisplayRepresentation] = [
            .inbox: "收件箱",
            .today: "今天",
            .upcoming: "计划",
            .anytime: "随时",
            .someday: "某天",
            .logbook: "日志簿"
        ]

        var kind: OrdoListKind {
            switch self {
            case .inbox: return .inbox
            case .today: return .today
            case .upcoming: return .upcoming
            case .anytime: return .anytime
            case .someday: return .someday
            case .logbook: return .logbook
            }
        }
    }

    @Parameter(title: "清单")
    var target: Target

    func perform() async throws -> some IntentResult {
        let url = OrdoDeepLink.url(for: OrdoListQuery(kind: target.kind))
        await MainActor.run {
            OrdoIntentStore.shared.enqueueDeepLink(url)
        }
        return .result()
    }
}

// MARK: - 完成待办

@available(iOS 17.0, *)
struct CompleteTodoIntent: AppIntent {

    static var title: LocalizedStringResource = "完成待办"
    static var description = IntentDescription("按标题关键词找到待办并标记完成。")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "标题关键词")
    var keyword: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = OrdoIntentStore.shared
        guard let todo = try await store.findOpenTodo(matching: keyword) else {
            return .result(dialog: "没有找到包含「\(keyword)」的未完成待办。")
        }
        try await store.complete(todoId: todo.id)
        return .result(dialog: IntentDialog(stringLiteral: "已完成:\(todo.title)"))
    }
}

// MARK: - 快捷指令集合

@available(iOS 17.0, *)
struct OrdoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateTodoIntent(),
            phrases: [
                "用 \(.applicationName) 记一件事",
                "在 \(.applicationName) 新建待办"
            ],
            shortTitle: "新建待办",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: OpenListIntent(),
            phrases: [
                "打开 \(.applicationName) 的今天",
                "在 \(.applicationName) 打开清单"
            ],
            shortTitle: "打开清单",
            systemImageName: "list.bullet"
        )
        AppShortcut(
            intent: CompleteTodoIntent(),
            phrases: [
                "在 \(.applicationName) 完成待办"
            ],
            shortTitle: "完成待办",
            systemImageName: "checkmark.circle"
        )
    }
}

// MARK: - 供 Intents 使用的轻量写入器

/// 与 UI 生命周期解耦的写入器:直接使用 KMP 引擎 + 本地仓储。
/// 注意:它只做「解析 → 调用引擎 → 落盘」,业务规则仍全部来自 KMP 核心。
@MainActor
final class OrdoIntentStore {

    static let shared = OrdoIntentStore()

    private var storage: OrdoStorageProtocol?
    private var engine: OrdoEngineProtocol?
    private let parser = OrdoCoreNaturalLanguageParser()
    private let clock = OrdoSystemClock()
    /// 待 UI 消费的深链(由 `OrdoShellView` 读取)。
    private(set) var pendingDeepLink: String?

    func enqueueDeepLink(_ url: String) {
        pendingDeepLink = url
    }

    func consumeDeepLink() -> String? {
        defer { pendingDeepLink = nil }
        return pendingDeepLink
    }

    private func ensureReady() async throws -> (OrdoStorageProtocol, OrdoEngineProtocol) {
        if let storage, let engine { return (storage, engine) }
        let store: OrdoStorageProtocol
        do {
            // 契约 §7.6.3:必须打开**当前登录账号**的数据目录,
            // 否则「用 Siri 记一条」会落到另一个目录里,用户回到 App 看不到它。
            let container = try await Self.makeContainerForCurrentUser()
            store = SwiftDataStorage(container: container)
        } catch {
            store = OrdoMemoryStorage()
        }
        // 与 App 相同的装配路径:预加载镜像 → 构造 KMP 引擎(deviceId 用应用级 kv)。
        let bridge = await OrdoCoreBridge.make(storage: store, clock: clock, deviceId: Self.currentDeviceId())
        storage = store
        engine = bridge
        return (store, bridge)
    }

    /// 当前会话对应的账号目录;没有会话时退回系统默认位置(此时不写入任何账号数据)。
    private static func makeContainerForCurrentUser() async throws -> ModelContainer {
        guard let session = try? await OrdoCoreSessionStore.makeAppLevel().load() else {
            return try SwiftDataStorage.makeContainer()
        }
        return try SwiftDataStorage.makeUserContainer(userId: session.userId)
    }

    /// 设备标识:与应用级 kv 保持一致(契约 §7.6.1「同一账号可有多台设备」)。
    private static func currentDeviceId() -> String? {
        guard let kv = try? OrdoFileKVStorage(fileURL: OrdoAppDirectories.sessionFileURL()) else { return nil }
        let value = kv.kvGet(key: OrdoSessionTokenStore.deviceIdKey)
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// 标题的日期/时间/标签解析由 KMP 核心在 `createTodo` 内完成(契约 §5),
    /// 这里只负责把「清单名」翻译成 projectId / areaId / when。
    func createTodo(rawText: String, listName: String?) async throws -> OrdoTodo? {
        let (storage, engine) = try await ensureReady()

        var options = OrdoTodoOptions.none
        if let listName, !listName.isEmpty {
            let snapshot = engine.snapshot
            if let project = snapshot.projects.first(where: { $0.name == listName && !$0.deleted }) {
                options.projectId = project.id
                options.when = .anytime
            } else if let area = snapshot.areas.first(where: { $0.name == listName && !$0.deleted }) {
                options.areaId = area.id
                options.when = .anytime
            } else {
                switch listName {
                case "收件箱": options.when = .inbox
                case "今天": options.when = .today
                case "随时": options.when = .anytime
                case "某天": options.when = .someday
                default: options.when = .inbox
                }
            }
        }

        let created = engine.createTodo(title: rawText, options: options)
        await engine.flushStorage()
        _ = storage
        return created
    }

    func findOpenTodo(matching keyword: String) async throws -> OrdoTodo? {
        let (_, engine) = try await ensureReady()
        let lowered = keyword.lowercased()
        return engine.snapshot.todos.first {
            $0.status == .open && !$0.deleted && $0.title.lowercased().contains(lowered)
        }
    }

    func complete(todoId: String) async throws {
        let (_, engine) = try await ensureReady()
        engine.toggleDone(id: todoId)
        await engine.flushStorage()
    }
}
