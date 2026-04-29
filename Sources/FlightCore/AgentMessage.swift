import Foundation

/// Holds an `Optional<String>` so `NSCache` (which requires `AnyObject`)
/// can cache the "no plan" result alongside the parsed string. The id of an
/// `AgentMessage` is immutable, and `planContent` only depends on `id`-keyed
/// content, so a single computation is reusable forever.
private final class CachedPlanContent {
    let value: String?
    init(_ value: String?) { self.value = value }
}

private let planContentCache: NSCache<NSUUID, CachedPlanContent> = {
    let cache = NSCache<NSUUID, CachedPlanContent>()
    cache.countLimit = 256
    return cache
}()

public enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

public enum MessageContent: Codable, Equatable {
    case text(String)
    case thinking(String)
    case toolUse(name: String, input: String)
    case toolResult(content: String)
    case permissionRequest(requestID: String, description: String)
    case provisionLog(String)
    case setupLog(String)
}

public struct AgentMessage: Identifiable, Codable, Equatable {
    public let id: UUID
    public let role: MessageRole
    public let content: MessageContent
    public let timestamp: Date

    public init(
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

    public var textContent: String {
        switch content {
        case .text(let text):
            return text
        case .thinking(let text):
            return text
        case .toolUse(let name, let input):
            return "[\(name)] \(input)"
        case .toolResult(let content):
            return content
        case .permissionRequest(_, let description):
            return description
        case .provisionLog(let line):
            return line
        case .setupLog(let line):
            return line
        }
    }

    public var isThinking: Bool {
        if case .thinking = content { return true }
        return false
    }

    public var isToolUse: Bool {
        if case .toolUse = content { return true }
        return false
    }

    public var isToolResult: Bool {
        if case .toolResult = content { return true }
        return false
    }

    public var isPermissionRequest: Bool {
        if case .permissionRequest = content { return true }
        return false
    }

    public var isProvisionLog: Bool {
        if case .provisionLog = content { return true }
        return false
    }

    public var isSetupLog: Bool {
        if case .setupLog = content { return true }
        return false
    }

    /// Parsed plan body extracted from the tool-input JSON, or `nil` if this
    /// isn't a plan-bearing tool call. Cached by `id` because the JSON parse
    /// is expensive (tool inputs can run 50KB+) and `PlanView.body` reads
    /// this on every SwiftUI invalidation — once per streamed token under
    /// load.
    public var planContent: String? {
        let key = id as NSUUID
        if let cached = planContentCache.object(forKey: key) {
            return cached.value
        }
        let parsed = computePlanContent()
        planContentCache.setObject(CachedPlanContent(parsed), forKey: key)
        return parsed
    }

    private func computePlanContent() -> String? {
        guard case .toolUse(let name, let input) = content else { return nil }
        guard let data = input.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // ExitPlanMode has "plan" field
        if name == "ExitPlanMode", let plan = dict["plan"] as? String {
            return plan
        }

        // Write to .claude/plans/ has "content" field
        if name == "Write",
           let path = dict["file_path"] as? String,
           path.contains(".claude/plans/"),
           let content = dict["content"] as? String {
            return content
        }

        return nil
    }

    public var toolName: String? {
        guard case .toolUse(let name, _) = content else { return nil }
        return name
    }

    public var toolDescription: String? {
        guard case .toolUse(_, let input) = content,
              let data = input.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let desc = dict["description"] as? String else {
            return nil
        }
        return desc
    }

    /// Best single-line preview for a tool call — picks the most meaningful
    /// parameter per tool type. Falls back to `description` for unknown tools.
    public var toolPreview: String? {
        guard case .toolUse(let name, let input) = content,
              let data = input.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        func str(_ key: String) -> String? { dict[key] as? String }
        func basename(_ path: String) -> String { (path as NSString).lastPathComponent }

        switch name {
        case "Bash":
            return str("description") ?? str("command")
        case "Read", "Edit", "MultiEdit", "Write", "NotebookEdit":
            return str("file_path").map(basename)
        case "Grep":
            guard let pattern = str("pattern") else { return nil }
            if let path = str("path") {
                return "\"\(pattern)\" in \(basename(path))"
            }
            return "\"\(pattern)\""
        case "Glob":
            return str("pattern")
        case "WebFetch":
            return str("url")
        case "WebSearch":
            return str("query")
        case "TodoWrite":
            guard let todos = dict["todos"] as? [[String: Any]] else { return nil }
            if let active = todos.first(where: { ($0["status"] as? String) == "in_progress" }),
               let content = active["content"] as? String {
                return content
            }
            return "\(todos.count) todo\(todos.count == 1 ? "" : "s")"
        case "Task", "Agent":
            return str("description") ?? str("subagent_type")
        default:
            return str("description") ?? str("query") ?? str("pattern")
        }
    }
}
