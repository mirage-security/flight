import Foundation

/// Status pill colors. Fixed palette so panels stay visually consistent
/// across plugins. Unknown values decode to `nil`.
enum PanelStatus: String, Codable, Equatable {
    case ok
    case warn
    case error
    case gray
}

/// Render-tree node. Slice 1 supports `section` and `row`. Unknown `type`
/// values decode to `.unknown(typeName)` and render as a placeholder, so a
/// panel emitting v2 widgets against an old Flight degrades gracefully.
indirect enum PanelNode: Equatable {
    case section(id: String?, title: String?, children: [PanelNode])
    case row(id: String?, title: String, subtitle: String?, status: PanelStatus?)
    case unknown(typeName: String)

    var id: String? {
        switch self {
        case .section(let id, _, _): return id
        case .row(let id, _, _, _): return id
        case .unknown: return nil
        }
    }
}

extension PanelNode: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, id, title, subtitle, status, children
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let id = try c.decodeIfPresent(String.self, forKey: .id)
        switch type {
        case "section":
            let title = try c.decodeIfPresent(String.self, forKey: .title)
            let children = try c.decodeIfPresent([PanelNode].self, forKey: .children) ?? []
            self = .section(id: id, title: title, children: children)
        case "row":
            let title = try c.decode(String.self, forKey: .title)
            let subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
            let status = try c.decodeIfPresent(PanelStatus.self, forKey: .status)
            self = .row(id: id, title: title, subtitle: subtitle, status: status)
        default:
            self = .unknown(typeName: type)
        }
    }
}

/// One NDJSON event from a panel script. Slice 1 supports `replace`,
/// `title`, `error`, `clear_error`. Unknown ops decode to `.unknown`.
enum PanelEvent: Equatable {
    case replace(PanelNode)
    case title(String)
    case error(String)
    case clearError
    case unknown(op: String)
}

extension PanelEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case op, tree, text, message
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let op = try c.decode(String.self, forKey: .op)
        switch op {
        case "replace":
            let tree = try c.decode(PanelNode.self, forKey: .tree)
            self = .replace(tree)
        case "title":
            let text = try c.decode(String.self, forKey: .text)
            self = .title(text)
        case "error":
            let msg = try c.decode(String.self, forKey: .message)
            self = .error(msg)
        case "clear_error":
            self = .clearError
        default:
            self = .unknown(op: op)
        }
    }
}
