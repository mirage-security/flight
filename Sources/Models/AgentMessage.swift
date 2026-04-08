import Foundation

enum MessageRole: String {
    case user
    case assistant
}

enum MessageContent {
    case text(String)
    case toolUse(name: String, input: String)
    case toolResult(content: String)
}

struct AgentMessage: Identifiable {
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
}

// MARK: - Stream JSON Parsing

struct StreamEvent: Decodable {
    let type: String
    let subtype: String?
    let message: StreamMessage?
    let result: String?

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
        // Skip system/init and result events — they're not chat messages
        if type == "system" || type == "rate_limit_event" { return [] }

        guard let message = message else { return [] }

        let role: MessageRole = (message.role == "user" || type == "user") ? .user : .assistant

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
