//
//  OrdoApp.swift
//  Ordo
//
//  应用入口(@main)+ Scene 配置 + 深链(设计规范 §7 平台映射:iOS 使用 Universal Links + `ordo://`)。
//
//  启动顺序:
//    1. `RootView.task` 调用 `AppEnvironment.bootstrap()`:打开本地库 → 必要时写入示例数据
//       → 装配 KMP 引擎 / 同步 / 提醒;
//    2. `OrdoShellView.task` 调用 `environment.start()`:订阅引擎快照、申请通知权限、启动同步。
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

// MARK: - 根视图(装配 + 启动画面 + 深链接收)

struct RootView: View {

    @State private var environment: AppEnvironment?
    @State private var pendingURL: URL?
    @State private var bootstrapError: String?
    @State private var didBootstrap = false

    var body: some View {
        Group {
            if let environment {
                OrdoShellView(environment: environment, externalURL: $pendingURL)
            } else if let bootstrapError {
                EmptyStateView(kind: .error(bootstrapError), actionTitle: "重试") {
                    Task { await bootstrap() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(OrdoColor.canvas)
            } else {
                splash
            }
        }
        .onOpenURL { url in
            pendingURL = url
        }
        .task { await bootstrap() }
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

    private func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        do {
            environment = await AppEnvironment.bootstrap()
        } catch {
            bootstrapError = "初始化失败:\(error.localizedDescription)"
            didBootstrap = false
        }
    }
}
