//
//  DeepLink.swift
//  Ordo
//
//  深链:设计规范 §7 平台映射(iOS:Universal Links + `ordo://`)。
//
//  支持的形式:
//    ordo://today            固定清单
//    ordo://inbox|upcoming|anytime|someday|logbook
//    ordo://project/<id>
//    ordo://area/<id>
//    ordo://tag/<名称>
//    ordo://todo/<id>        直接打开某条待办的详情
//    ordo://search?q=关键词
//    https://ordo.app/todo/<id>   (Universal Links 兜底,取 path 部分同样解析)
//

import Foundation

public enum OrdoDeepLink: Equatable, Sendable {
    case list(OrdoListQuery)
    case todo(id: String)
    case search(text: String)
    case unknown(String)

    /// 解析 URL。失败返回 `.unknown`(调用方提示「无法识别的链接」)。
    public static func parse(_ url: URL) -> OrdoDeepLink {
        let scheme = url.scheme?.lowercased()
        guard scheme == "ordo" || scheme == "https" || scheme == "http" else {
            return .unknown(url.absoluteString)
        }

        // ordo://today → host = "today";https://ordo.app/todo/x → host = "ordo.app", path = "/todo/x"
        var segments: [String] = []
        if let host = url.host, host.lowercased() != "ordo.app" {
            segments.append(host)
        }
        segments.append(contentsOf: url.path.split(separator: "/").map(String.init))
        guard let head = segments.first?.lowercased() else { return .unknown(url.absoluteString) }

        let tail = segments.count > 1 ? segments[1] : nil
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "q" || $0.name == "query" }?
            .value

        switch head {
        case "inbox": return .list(.inbox)
        case "today": return .list(.today)
        case "upcoming": return .list(.upcoming)
        case "anytime": return .list(.anytime)
        case "someday": return .list(.someday)
        case "logbook": return .list(.logbook)
        case "project":
            guard let id = tail else { return .unknown(url.absoluteString) }
            return .list(.project(id.removingPercentEncoding ?? id))
        case "area":
            guard let id = tail else { return .unknown(url.absoluteString) }
            return .list(.area(id.removingPercentEncoding ?? id))
        case "tag":
            guard let name = tail else { return .unknown(url.absoluteString) }
            return .list(.tag(name.removingPercentEncoding ?? name))
        case "todo":
            guard let id = tail else { return .unknown(url.absoluteString) }
            return .todo(id: id)
        case "search":
            return .search(text: query ?? "")
        default:
            return .unknown(url.absoluteString)
        }
    }

    /// 生成分享/通知用的深链。
    public static func url(for query: OrdoListQuery) -> String {
        switch query.kind {
        case .project: return "ordo://project/\(query.id ?? "")"
        case .area: return "ordo://area/\(query.id ?? "")"
        case .tag: return "ordo://tag/\(query.id ?? "")"
        case .search: return "ordo://search?q=\(query.text ?? "")"
        default: return "ordo://\(query.kind.rawValue)"
        }
    }

    public static func url(forTodo id: String) -> String { "ordo://todo/\(id)" }
}
