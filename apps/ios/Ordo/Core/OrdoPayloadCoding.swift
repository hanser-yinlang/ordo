//
//  OrdoPayloadCoding.swift
//  Ordo
//
//  契约 §7.2:`Op.payload` 是「实体完整快照」的 JSON。
//  本文件提供 实体 ⇄ OrdoJSONValue 的双向编解码,供同步层、outbox、合并测试共用。
//
//  字段名与契约 §2 完全一致(依赖 OrdoModel.swift 中的 CodingKeys)。
//

import Foundation

public enum OrdoPayloadCodec {

    // MARK: 泛型编解码

    public static func encode<T: Encodable>(_ value: T) throws -> OrdoJSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return try OrdoJSONValue.decode(from: data)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from payload: OrdoJSONValue?) throws -> T {
        guard let payload else { throw OrdoJSONError.missingField("payload") }
        let data = try payload.data()
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: 实体枚举

    /// 带类型的实体载荷。
    public enum Entity: Sendable {
        case todo(OrdoTodo)
        case project(OrdoProject)
        case area(OrdoArea)
        case heading(OrdoHeading)
        case tag(OrdoTag)

        public var kind: OrdoEntityKind {
            switch self {
            case .todo: return .todo
            case .project: return .project
            case .area: return .area
            case .heading: return .heading
            case .tag: return .tag
            }
        }

        public var entityId: String {
            switch self {
            case .todo(let value): return value.id
            case .project(let value): return value.id
            case .area(let value): return value.id
            case .heading(let value): return value.id
            case .tag(let value): return value.id
            }
        }

        public var jsonValue: OrdoJSONValue {
            switch self {
            case .todo(let value): return (try? OrdoPayloadCodec.encode(value)) ?? .null
            case .project(let value): return (try? OrdoPayloadCodec.encode(value)) ?? .null
            case .area(let value): return (try? OrdoPayloadCodec.encode(value)) ?? .null
            case .heading(let value): return (try? OrdoPayloadCodec.encode(value)) ?? .null
            case .tag(let value): return (try? OrdoPayloadCodec.encode(value)) ?? .null
            }
        }

        /// 契约 §3:标题为空的实体视为删除。
        public var isEffectivelyDeleted: Bool {
            switch self {
            case .todo(let value): return value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .project(let value): return value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .area(let value): return value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .heading(let value): return value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .tag(let value): return value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    public static func decode(entity: OrdoEntityKind, payload: OrdoJSONValue?) throws -> Entity {
        switch entity {
        case .todo: return .todo(try decode(OrdoTodo.self, from: payload))
        case .project: return .project(try decode(OrdoProject.self, from: payload))
        case .area: return .area(try decode(OrdoArea.self, from: payload))
        case .heading: return .heading(try decode(OrdoHeading.self, from: payload))
        case .tag: return .tag(try decode(OrdoTag.self, from: payload))
        }
    }

    // MARK: Op 构造

    public static func upsertOp(
        entity: Entity,
        deviceId: String,
        opId: String,
        clientTs: Int64
    ) -> OrdoOp {
        OrdoOp(
            opId: opId,
            deviceId: deviceId,
            entity: entity.kind,
            entityId: entity.entityId,
            type: .upsert,
            payload: entity.jsonValue,
            clientTs: clientTs
        )
    }

    public static func deleteOp(
        entity: OrdoEntityKind,
        entityId: String,
        deviceId: String,
        opId: String,
        clientTs: Int64
    ) -> OrdoOp {
        OrdoOp(
            opId: opId,
            deviceId: deviceId,
            entity: entity,
            entityId: entityId,
            type: .delete,
            payload: nil,
            clientTs: clientTs
        )
    }

    /// 从 op 还原实体(upsert 才有载荷)。
    public static func entity(of op: OrdoOp) throws -> Entity? {
        guard op.type == .upsert else { return nil }
        return try decode(entity: op.entity, payload: op.payload)
    }

    /// 单 op 载荷大小上限(契约 §7.4:≤ 256 KB)。
    public static func payloadSize(of op: OrdoOp) -> Int {
        guard let payload = op.payload, let data = try? payload.data() else { return 0 }
        return data.count
    }

    public static let maxPayloadBytes = 256 * 1024
    /// 契约 §7.4:单次 push ≤ 500 ops。
    public static let maxOpsPerPush = 500
}
