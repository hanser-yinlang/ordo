//
//  TokenStore.swift
//  Ordo
//
//  契约 §8:`kv(key, value)` 保存 `lastServerSeq`、tokens、`deviceId`。
//  本文件把令牌与设备标识落到 kv 表,并提供设备标识来源实现。
//
//  安全(契约 §9):令牌不写入日志、不落 UserDefaults 明文;
//  如需 Keychain 强化,可在此文件替换实现(`OrdoTokenStore` 协议不变)。
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 基于本地 kv 表的令牌存储。
public actor OrdoStorageTokenStore: OrdoTokenStore, OrdoDeviceIdentifying {

    private let storage: OrdoStorageProtocol
    private var cachedDeviceId: String?

    public init(storage: OrdoStorageProtocol) {
        self.storage = storage
    }

    // MARK: OrdoTokenStore

    public func load() async -> OrdoTokens? {
        do {
            guard let access = try await storage.kvGet(OrdoKVKey.accessToken),
                  let refresh = try await storage.kvGet(OrdoKVKey.refreshToken) else {
                return nil
            }
            let expiresAt = try await storage.kvInt(OrdoKVKey.tokenExpiry)
            return OrdoTokens(accessToken: access, refreshToken: refresh, expiresAt: expiresAt)
        } catch {
            return nil
        }
    }

    public func save(_ tokens: OrdoTokens?) async {
        do {
            if let tokens {
                try await storage.kvSet(OrdoKVKey.accessToken, value: tokens.accessToken)
                try await storage.kvSet(OrdoKVKey.refreshToken, value: tokens.refreshToken)
                try await storage.kvSetInt(OrdoKVKey.tokenExpiry, value: tokens.expiresAt)
            } else {
                try await storage.kvSet(OrdoKVKey.accessToken, value: nil)
                try await storage.kvSet(OrdoKVKey.refreshToken, value: nil)
                try await storage.kvSetInt(OrdoKVKey.tokenExpiry, value: 0)
            }
        } catch {
            // 存储失败不抛出:调用方(网络层)会在下一次请求时得到 401 并走登录态。
        }
    }

    public func save(session: OrdoAuthSession) async {
        await save(OrdoTokens(session: session))
        await saveDeviceId(session.device.id)
        try? await storage.kvSet(OrdoKVKey.userEmail, value: session.user.email)
    }

    // MARK: 设备标识

    public func currentDeviceId() async -> String {
        if let cachedDeviceId { return cachedDeviceId }
        if let stored = try? await storage.kvGet(OrdoKVKey.deviceId), !stored.isEmpty {
            cachedDeviceId = stored
            return stored
        }
        let generated = "dev_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
        let value = String(generated)
        try? await storage.kvSet(OrdoKVKey.deviceId, value: value)
        cachedDeviceId = value
        return value
    }

    public func saveDeviceId(_ deviceId: String) async {
        cachedDeviceId = deviceId
        try? await storage.kvSet(OrdoKVKey.deviceId, value: deviceId)
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

    public func userEmail() async -> String? {
        try? await storage.kvGet(OrdoKVKey.userEmail)
    }

    public func isSignedIn() async -> Bool {
        await load() != nil
    }
}
