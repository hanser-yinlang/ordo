//
//  OrdoApp.swift
//  Ordo
//
//  应用入口(@main)+ Scene 配置 + 深链(设计规范 §7 平台映射:iOS 使用 Universal Links + `ordo://`)。
//
//  启动顺序(契约 §7.6.4 登录门禁):
//    1. `RootView.task` 装配 `OrdoAuthService`(根目录会话文件 + URLSession 网络层);
//    2. `restore()` 读会话:
//         · 有且未过期            → 直接进主界面(后台静默 refresh)
//         · 有但 accessToken 过期 → 先 refresh;refresh 失败 → 登录页(保留 userId 目录)
//         · 无 / 已清             → 登录页(登录 / 注册 / **以游客身份继续** 三入口)
//    3. 有会话后才 `AppEnvironment.bootstrap(...)`:打开 `Application Support/Ordo/<userId>/`
//       的 SwiftData 库并装配引擎(契约 §7.6.3:两个账号绝不共用同一目录);
//    4. `OrdoShellView.task` 调用 `environment.start()`:订阅引擎快照、申请通知权限、启动同步。
//
//  会话变化(RootView 观察 `auth.session`):
//    · 登录成功 → 装配主界面;· 退出登录 / 令牌失效 → 拆掉主界面(停同步)并回到登录页。
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

// MARK: - 根视图(登录门禁 + 装配 + 启动画面 + 深链接收)

struct RootView: View {

    /// 启动阶段。
    enum Stage: Equatable {
        case booting
        case login
        case ready
        case failed(String)
    }

    @State private var stage: Stage = .booting
    @State private var auth: OrdoAuthService?
    @State private var environment: AppEnvironment?
    @State private var pendingURL: URL?
    @State private var didBootstrap = false

    var body: some View {
        Group {
            switch stage {
            case .booting:
                splash
            case .login:
                if let auth {
                    LoginView(auth: auth) { session in
                        Task { await startMainInterface(session: session) }
                    }
                    .transition(.opacity)
                } else {
                    splash
                }
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
        .onChange(of: auth?.session) { _, session in
            // 退出登录 / 令牌失效:会话没了就拆掉主界面,回到登录页(本地目录保留)。
            guard session == nil, stage == .ready else { return }
            Task { await teardownMainInterface() }
        }
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
            case .showLogin:
                stage = .login
            case .resume(let session):
                await startMainInterface(session: session)
            case .refresh(let session):
                // `restore()` 内部已处理 refresh 分支,这里只作为兜底(仍以会话为准)。
                await startMainInterface(session: session)
            }
        } catch {
            stage = .failed("初始化失败:\(error.localizedDescription)")
            didBootstrap = false
        }
    }

    /// 有会话 → 打开该账号的本地库并进入主界面(契约 §7.6.3)。
    private func startMainInterface(session: OrdoSessionRecord) async {
        guard let auth else { return }
        await teardownMainInterface()
        let environment = await AppEnvironment.bootstrap(auth: auth, session: session)
        self.environment = environment
        withAnimation(OrdoMotion.resolved(OrdoMotion.Login.mainIn, reduceMotion: false)) {
            stage = .ready
        }
        // 登录成功后把本地数据推上去,或拉取远端快照(契约 §7.1)。
        await environment.finishSignIn()
        // 契约 §7.6.4:有且未过期 → 后台静默 refresh。
        await auth.refreshInBackground()
    }

    private func teardownMainInterface() async {
        guard let environment else { return }
        await environment.shutdown()
        self.environment = nil
    }
}
