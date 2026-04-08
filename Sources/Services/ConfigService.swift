import Foundation

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

    private static var worktreesBaseURL: URL {
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

    static func chatFileURL(worktreeID: UUID) -> URL {
        try? FileManager.default.createDirectory(at: chatBaseURL, withIntermediateDirectories: true)
        return chatBaseURL.appendingPathComponent("\(worktreeID.uuidString).json")
    }

    static func loadMessages(worktreeID: UUID) -> [AgentMessage] {
        let url = chatFileURL(worktreeID: worktreeID)
        guard let data = try? Data(contentsOf: url),
              let messages = try? JSONDecoder().decode([AgentMessage].self, from: data) else {
            return []
        }
        return messages
    }

    static func saveMessages(_ messages: [AgentMessage], worktreeID: UUID) {
        let url = chatFileURL(worktreeID: worktreeID)
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(messages) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func deleteChatHistory(worktreeID: UUID) {
        let url = chatFileURL(worktreeID: worktreeID)
        try? FileManager.default.removeItem(at: url)
    }
}
