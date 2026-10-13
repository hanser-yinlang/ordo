//
//  OrdoApp.swift
//  Ordo
//
//  应用入口(@main)+ Scene 配置 + 深链(设计规范 §7 平台映射:iOS 使用 Universal Links + `ordo://`)。
//
//  启动顺序(**v1.3:不再有登录界面与门禁**):
//    1. `RootView.task` 装配 `OrdoAuthService`(根目录会话文件 + URLSession 网络层);
//    2. `restore()` 读会话:
//         · 有 userId           → 直接进主界面(令牌为空 = 离线占位会话,照常可用)
//         · accessToken 已过期  → 先 refresh;成功 → 主界面
//         · refresh 网络失败    → **仍然进主界面**(离线可用),联网后自动重试
//         · refresh 被服务端否认 / 无会话 → **静默** `POST /v1/auth/guest` 建匿名会话
//         · 连匿名会话也建不上(无网首启) → 用本机账号标识开主界面 + 后台退避重试
//    3. `AppEnvironment.bootstrap(...)`:打开 `Application Support/Ordo/<userId>/` 的 SwiftData 库
//       并装配引擎。`userId` 是**本机稳定标识**(`OrdoLocalAccount`),所以匿名会话被重建、
//       或离线首启后联网,本地目录都不会改变(不做迁移);
//    4. `OrdoShellView.task` 调用 `environment.start()`:订阅引擎快照、申请通知权限、启动同步。
//
//  会话变化无需换界面:401 时 `AppEnvironment.handleAuthExpired()` 静默重建匿名会话并继续同步,
//  本地目录与已打开的环境都保持不变(这也是把目录绑定到本机 id 的原因)。
//
//  深链统一在 `RootView` 接收(冷启动与热启动都会命中),再交给 Shell 处理,
//  避免在 App 与 Shell 两处重复响应。
//  URL Scheme 在 Config/Info.plist 的 `CFBundleURLTypes` 中注册为 `ordo`。
//

import SwiftUI

@main
struct OrdoApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

// MARK: - 根视图(静默会话 + 装配 + 启动画面 + 深链接收)

struct RootView: View {

    /// 启动阶段(**没有 login 分支**)。
    enum Stage: Equatable {
        case booting
        case ready
        case failed(String)
    }

    @State private var stage: Stage = .booting
    @State private var auth: OrdoAuthService?
    @State private var environment: AppEnvironment?
    @State private var pendingURL: URL?
    @State private var didBootstrap = false
    /// 离线时后台退避重试建匿名会话的任务(拿到令牌后触发一次同步即可结束)。
    @State private var anonymousRetryTask: Task<Void, Never>?

    var body: some View {
        Group {
            switch stage {
            case .booting:
                splash
            case .ready:
                if let environment {
                    OrdoShellView(environment: environment, externalURL: $pendingURL)
                        .transition(.opacity)
                } else {
                    splash
                }
            case .failed(let message):
                EmptyStateView(kind: .error(message), actionTitle: "重试") {
                    didBootstrap = false
                    Task { await bootstrap() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(OrdoColor.canvas)
            }
        }
        .animation(.easeInOut(duration: OrdoMotion.base), value: stage)
        .onOpenURL { url in
            pendingURL = url
        }
        .task { await bootstrap() }
        .onDisappear { anonymousRetryTask?.cancel() }
    }

    private var splash: some View {
        VStack(spacing: OrdoSpacing.m) {
            OrdoLogoMark(size: 44)
            Text("序 Ordo")
                .font(OrdoFont.title)
                .foregroundStyle(OrdoColor.textPrimary)
            Text("把今天理清楚")
                .font(OrdoFont.caption)
                .foregroundStyle(OrdoColor.textSecondary)
            ProgressView()
                .controlSize(.small)
                .padding(.top, OrdoSpacing.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OrdoColor.canvas)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在启动序 Ordo")
    }

    // MARK: 启动

    private func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        do {
            let service = try OrdoAuthService.makeAppLevel()
            auth = service
            switch await service.restore() {
            case .resume(let session):
                await startMainInterface(session: session)
            case .refresh(let session):
                // `restore()` 内部已处理 refresh 分支,这里只作为兜底(仍以会话为准)。
                await startMainInterface(session: session)
            case .createAnonymous:
                await startAnonymousInterface(service)
            }
        } catch {
            stage = .failed("初始化失败:\(error.localizedDescription)")
            didBootstrap = false
        }
    }

    /// 没有可用会话:先静默建匿名账号;**网络不可达也照常进主界面**(离线可用),后台退避重试。
    private func startAnonymousInterface(_ service: OrdoAuthService) async {
        if let session = try? await service.startAnonymousSession() {
            await startMainInterface(session: session)
            return
        }
        // 无网首启:用本机账号标识开主界面(目录与本机 id 绑定,联网后原地补令牌)。
        let offline = await service.startLocalOnlySession()
        await startMainInterface(session: offline)
        startAnonymousRetryLoop()
    }

    /// 后台退避重试:2s → 4s → 8s … 60s 封顶;成功即停,并由环境触发一次同步。
    private func startAnonymousRetryLoop() {
        anonymousRetryTask?.cancel()
        anonymousRetryTask = Task { @MainActor in
            var delay: Double = 2
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard let auth else { return }
                if let session = try? await auth.startAnonymousSession() {
                    await environment?.adoptSilentlyRenewedSession(session)
                    return
                }
                delay = min(delay * 2, 60)
            }
        }
    }

    /// 有会话 → 打开本地库并进入主界面(目录由会话的 `userId` 决定)。
    private func startMainInterface(session: OrdoSessionRecord) async {
        guard let auth else { return }
        await teardownMainInterface()
        let environment = await AppEnvironment.bootstrap(auth: auth, session: session)
        self.environment = environment
        withAnimation(OrdoMotion.resolved(OrdoMotion.mainIn, reduceMotion: false)) {
            stage = .ready
        }
        // 远端为空则把本地推上去,否则拉取远端快照(契约 §7.1)。
        await environment.bootstrapRemoteIfNeeded()
        // 有云端令牌时后台静默 refresh(契约 §7.6.4 的「有且未过期」分支)。
        await auth.refreshInBackground()
    }

    private func teardownMainInterface() async {
        guard let environment else { return }
        await environment.shutdown()
        self.environment = nil
    }
}
