//
//  URLSessionSyncApi.swift
//  Ordo
//
//  契约 §7.4 同步接口实现:`/v1/health`、`/v1/sync/snapshot`、`/v1/sync/push`、`/v1/sync/pull`、
//  `/v1/devices/register`。基于 URLSession async/await。
//
//  限制(契约 §7.4):单次 push ≤ 500 ops;单 op payload ≤ 256 KB;pull limit ≤ 1000。
//  超出上限时本实现主动分片,避免服务端返回 VALIDATION_FAILED。
//

import Foundation

public actor URLSessionSyncApi: OrdoSyncAPI {

    private let client: OrdoHTTPClient

    public init(client: OrdoHTTPClient) {
        self.client = client
    }

    // MARK: 健康检查

    public func health() async throws -> OrdoHealth {
        try await client.send(OrdoEndpoint.get("/v1/health", authorized: false), as: OrdoHealth.self)
    }

    // MARK: 全量快照

    public func snapshot() async throws -> OrdoRemoteSnapshot {
        try await client.send(OrdoEndpoint.get("/v1/sync/snapshot"), as: OrdoRemoteSnapshot.self)
    }

    // MARK: 推送(自动分片)

    public func push(_ request: OrdoPushRequest) async throws -> OrdoPushResponse {
        let chunks = Self.chunk(request.ops)
        var accepted: [String] = []
        var rejected: [OrdoRejectedOp] = []
        var piggybacked: [OrdoOp] = []
        var serverSeq = request.sinceSeq

        for chunk in chunks {
            let body = try OrdoJSON.encode(
                OrdoPushRequest(deviceId: request.deviceId, sinceSeq: serverSeq, ops: chunk)
            )
            let response = try await client.send(
                OrdoEndpoint(method: "POST", path: "/v1/sync/push", body: body),
                as: OrdoPushResponse.self
            )
            accepted.append(contentsOf: response.accepted)
            rejected.append(contentsOf: response.rejected)
            piggybacked.append(contentsOf: response.ops)
            serverSeq = max(serverSeq, response.serverSeq)
        }

        return OrdoPushResponse(serverSeq: serverSeq, accepted: accepted, rejected: rejected, ops: piggybacked)
    }

    // MARK: 拉取

    public func pull(sinceSeq: Int64, limit: Int = 500) async throws -> OrdoPullResponse {
        let bounded = min(max(limit, 1), 1000)
        return try await client.send(
            OrdoEndpoint.get("/v1/sync/pull", query: [
                "sinceSeq": String(sinceSeq),
                "limit": String(bounded)
            ]),
            as: OrdoPullResponse.self
        )
    }

    // MARK: 设备登记

    public func registerDevice(_ registration: OrdoDeviceRegistration) async throws {
        let body = try OrdoJSON.encode(registration)
        try await client.sendVoid(OrdoEndpoint(method: "POST", path: "/v1/devices/register", body: body))
    }

    // MARK: 分片

    /// 契约 §7.4 的两个上限:500 ops/次、256 KB/op。
    /// 超限的 op 会被 `oversized(_:)` 挑出并由 SyncCoordinator 记入同步日志。
    static func chunk(_ ops: [OrdoOp]) -> [[OrdoOp]] {
        let usable = ops.filter { OrdoPayloadCodec.payloadSize(of: $0) <= OrdoPayloadCodec.maxPayloadBytes }
        guard !usable.isEmpty else { return [] }
        return stride(from: 0, to: usable.count, by: OrdoPayloadCodec.maxOpsPerPush).map {
            Array(usable[$0..<min($0 + OrdoPayloadCodec.maxOpsPerPush, usable.count)])
        }
    }

    /// 供 SyncCoordinator 判断哪些 op 因过大被跳过。
    static func oversized(_ ops: [OrdoOp]) -> [OrdoOp] {
        ops.filter { OrdoPayloadCodec.payloadSize(of: $0) > OrdoPayloadCodec.maxPayloadBytes }
    }
}
