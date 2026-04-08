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
}
