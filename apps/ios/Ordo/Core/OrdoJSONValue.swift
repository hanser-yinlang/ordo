//
//  OrdoJSONValue.swift
//  Ordo
//
//  与语言无关的 JSON 值表示。
//
//  用途:契约 §7.2 的 `Op.payload` 是「实体完整快照」的任意 JSON。Swift 侧需要
//  一个可 `Sendable`、可 `Codable`、可与 `JSONSerialization` 互转的中间表示,
//  以便同步层在不依赖具体实体类型的情况下透传、记录与比较 payload。
//

import Foundation

public enum OrdoJSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([OrdoJSONValue])
    case object([String: OrdoJSONValue])

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([OrdoJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: OrdoJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法识别的 JSON 值")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: 访问器

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int64? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int64(value)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [OrdoJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: OrdoJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> OrdoJSONValue? {
        objectValue?[key]
    }

    // MARK: 与 Foundation 互转

    public init(any value: Any) throws {
        switch value {
        case is NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .int(Int64(value))
        case let value as Int64:
            self = .int(value)
        case let value as Double:
            self = .double(value)
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(try value.map { try OrdoJSONValue(any: $0) })
        case let value as [String: Any]:
            var object: [String: OrdoJSONValue] = [:]
            for (key, item) in value {
                object[key] = try OrdoJSONValue(any: item)
            }
            self = .object(object)
        default:
            throw OrdoJSONError.unsupportedType(String(describing: type(of: value)))
        }
    }

    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(\.anyValue)
        case .object(let value): return value.mapValues(\.anyValue)
        }
    }

    public func data(prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> OrdoJSONValue {
        try JSONDecoder().decode(OrdoJSONValue.self, from: data)
    }
}

public enum OrdoJSONError: Error, LocalizedError {
    case unsupportedType(String)
    case notAnObject
    case missingField(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedType(let name): return "不支持的 JSON 类型:\(name)"
        case .notAnObject: return "JSON 根节点不是对象"
        case .missingField(let name): return "JSON 缺少必需字段:\(name)"
        }
    }
}
