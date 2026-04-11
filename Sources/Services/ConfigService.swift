import Foundation

/// Settings-level override of the `.flight/<lifecycle>` scripts in a
/// repo. Each field is a shell command string (not a template — no
/// placeholder substitution). Commands run via `zsh -l -c` with env
/// vars set: `FLIGHT_BRANCH` for provision, `FLIGHT_WORKSPACE` for
/// connect/teardown. Connect additionally receives the remote command
/// as `"$@"`.
struct RemoteModeConfig: Codable {
    var provision: String
    var connect: String
    var teardown: String
    var list: String?
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

    // Trailing-edge debounced save, off the main thread. Safe to call at
    // streaming rates — only the latest snapshot within the debounce window
    // is persisted. Callers keep the hot path free of JSON encode + disk I/O.
    nonisolated(unsafe) private static var pendingSaveWorkItems: [UUID: DispatchWorkItem] = [:]
    private static let pendingSaveLock = NSLock()
    private static let saveQueue = DispatchQueue(label: "flight.configservice.saves", qos: .utility)

    static func scheduleSaveMessages(_ messages: [AgentMessage], conversationID: UUID) {
        let snapshot = messages
        pendingSaveLock.lock()
        pendingSaveWorkItems[conversationID]?.cancel()
        let item = DispatchWorkItem {
            saveMessages(snapshot, conversationID: conversationID)
            pendingSaveLock.lock()
            pendingSaveWorkItems[conversationID] = nil
            pendingSaveLock.unlock()
        }
        pendingSaveWorkItems[conversationID] = item
        pendingSaveLock.unlock()
        saveQueue.asyncAfter(deadline: .now() + 0.4, execute: item)
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
