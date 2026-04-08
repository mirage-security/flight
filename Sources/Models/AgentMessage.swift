import Foundation

enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

enum MessageContent: Codable {
    case text(String)
    case toolUse(name: String, input: String)
    case toolResult(content: String)
    case permissionRequest(requestID: String, description: String)
    case provisionLog(String)
}

struct AgentMessage: Identifiable, Codable {
    let id: UUID
    let role: MessageRole
    let content: MessageContent
    let timestamp: Date

    init(
        id: UUID = UUID(),
        role: MessageRole,
        content: MessageContent,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }

    var textContent: String {
        switch content {
        case .text(let text):
            return text
        case .toolUse(let name, let input):
            return "[\(name)] \(input)"
        case .toolResult(let content):
            return content
        case .permissionRequest(_, let description):
            return description
        case .provisionLog(let line):
            return line
        }
    }

    var isToolUse: Bool {
        if case .toolUse = content { return true }
        return false
    }

    var isToolResult: Bool {
        if case .toolResult = content { return true }
        return false
    }

    var isPermissionRequest: Bool {
        if case .permissionRequest = content { return true }
        return false
    }

    var isProvisionLog: Bool {
        if case .provisionLog = content { return true }
        return false
    }

    var toolDescription: String? {
        guard case .toolUse(_, let input) = content,
              let data = input.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let desc = dict["description"] as? String else {
            return nil
        }
        return desc
    }
}

// MARK: - Stream JSON Parsing

struct StreamEvent: Decodable {
    let type: String
    let subtype: String?
    let message: StreamMessage?
    let result: String?
    let sessionID: String?
    let requestID: String?
    let request: ControlRequest?

    enum CodingKeys: String, CodingKey {
        case type, subtype, message, result, request
        case sessionID = "session_id"
        case requestID = "request_id"
    }

    struct ControlRequest: Decodable {
        let subtype: String?
        let toolName: String?
        let description: String?
        let input: [String: String]?

        enum CodingKeys: String, CodingKey {
            case subtype, description, input
            case toolName = "tool_name"
        }
    }

    struct StreamMessage: Decodable {
        let role: String?
        let content: StreamContent?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try container.decodeIfPresent(String.self, forKey: .role)
            // content can be a string or an array of content blocks
            if let contentString = try? container.decode(String.self, forKey: .content) {
                content = .text(contentString)
            } else if let blocks = try? container.decode([ContentBlock].self, forKey: .content) {
                content = .blocks(blocks)
            } else {
                content = nil
            }
        }

        enum CodingKeys: String, CodingKey {
            case role, content
        }
    }

    enum StreamContent {
        case text(String)
        case blocks([ContentBlock])
    }

    struct ContentBlock: Decodable {
        let type: String
        let text: String?
        let name: String?
        let input: AnyCodable?
        let content: String?
    }
}

// Lightweight wrapper to decode arbitrary JSON values
struct AnyCodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            value = str
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else if let arr = try? container.decode([AnyCodable].self) {
            value = arr.map { $0.value }
        } else if let num = try? container.decode(Double.self) {
            value = num
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else {
            value = "<unknown>"
        }
    }

    var jsonString: String {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return String(describing: value)
    }
}

extension StreamEvent {
    func toAgentMessages() -> [AgentMessage] {
        // Skip non-chat events
        if type == "system" || type == "rate_limit_event" || type == "result" { return [] }

        guard let message = message else { return [] }

        // Skip user messages from stream — we add those locally in send()
        if message.role == "user" || type == "user" { return [] }

        let role: MessageRole = .assistant

        guard let content = message.content else { return [] }

        switch content {
        case .text(let text):
            return [AgentMessage(role: role, content: .text(text))]
        case .blocks(let blocks):
            return blocks.compactMap { block in
                switch block.type {
                case "text":
                    guard let text = block.text, !text.isEmpty else { return nil }
                    return AgentMessage(role: role, content: .text(text))
                case "tool_use":
                    let name = block.name ?? "unknown"
                    let input = block.input?.jsonString ?? "{}"
                    return AgentMessage(role: role, content: .toolUse(name: name, input: input))
                case "tool_result":
                    let resultContent = block.content ?? block.text ?? ""
                    return AgentMessage(role: role, content: .toolResult(content: resultContent))
                default:
                    return nil
                }
            }
        }
    }
}
