import Foundation

struct RemoteModeConfig: Codable {
    var provision: String   // e.g. "my-wrapper provision {branch}"
    var connect: String     // e.g. "coder ssh {workspace} --"
    var teardown: String    // e.g. "my-wrapper teardown {workspace}"
    var list: String?       // e.g. "my-wrapper list" — prints one workspace name per line
}

struct FlightConfig: Codable {
    var projects: [ProjectConfig]

    static let empty = FlightConfig(projects: [])
}

enum ConfigService {
    private static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("flight")
            .appendingPathComponent("config.json")
    }

    static var worktreesBaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("flight")
            .appendingPathComponent("worktrees")
    }

    private static var logsBaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("flight")
            .appendingPathComponent("logs")
    }

    static func ensureDirectories() {
        let fm = FileManager.default
        let flightDir = configURL.deletingLastPathComponent()
        try? fm.createDirectory(at: flightDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: worktreesBaseURL, withIntermediateDirectories: true)
        try? fm.createDirectory(at: logsBaseURL, withIntermediateDirectories: true)
    }

    static func logFileURL(repoName: String, branch: String) -> URL {
        let repoDir = logsBaseURL.appendingPathComponent(repoName)
        try? FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        let safeBranch = branch.replacingOccurrences(of: "/", with: "-")
        return repoDir.appendingPathComponent("\(safeBranch).log")
    }

    static func load() -> FlightConfig {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(FlightConfig.self, from: data) else {
            return .empty
        }
        return config
    }

    static func save(_ config: FlightConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: configURL, options: .atomic)
    }

    static func worktreePath(repoName: String, branch: String) -> String {
        worktreesBaseURL
            .appendingPathComponent(repoName)
            .appendingPathComponent(branch)
            .path
    }

    // MARK: - Chat History

    private static var chatBaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("flight")
            .appendingPathComponent("chat")
    }

    static func chatFileURL(conversationID: UUID) -> URL {
        try? FileManager.default.createDirectory(at: chatBaseURL, withIntermediateDirectories: true)
        return chatBaseURL.appendingPathComponent("\(conversationID.uuidString).json")
    }

    static func loadMessages(conversationID: UUID) -> [AgentMessage] {
        let url = chatFileURL(conversationID: conversationID)
        guard let data = try? Data(contentsOf: url),
              let messages = try? JSONDecoder().decode([AgentMessage].self, from: data) else {
            return []
        }
        return messages
    }

    static func saveMessages(_ messages: [AgentMessage], conversationID: UUID) {
        let url = chatFileURL(conversationID: conversationID)
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(messages) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func deleteChatHistory(conversationID: UUID) {
        let url = chatFileURL(conversationID: conversationID)
        try? FileManager.default.removeItem(at: url)
    }

    static func deleteAllChatHistory(for worktree: Worktree) {
        for conversation in worktree.conversations {
            deleteChatHistory(conversationID: conversation.id)
        }
    }
}
