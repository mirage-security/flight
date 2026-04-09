import Foundation

// MARK: - Forge Provider Protocol

/// A forge is a git hosting platform that manages pull requests and CI.
/// Implementations wrap platform-specific CLIs or APIs (gh, tea, curl, etc.)
protocol ForgeProvider {
    /// Human-readable name for UI display (e.g. "GitHub", "Forgejo")
    var displayName: String { get }

    /// Creates a PR from the worktree directory. Returns the PR number.
    func createPR(in worktreePath: String, branch: String) async throws -> Int

    /// Gets CI check status for a PR.
    func getChecks(prNumber: Int, repoPath: String) async throws -> [CICheck]

    /// Gets failed CI logs for a PR's latest run.
    func getFailedLogs(prNumber: Int, repoPath: String) async throws -> String

    /// Looks up the PR number for a branch. Returns nil if no PR exists.
    func getPRNumber(branch: String, repoPath: String) async -> Int?
}

// MARK: - Forge Type

enum ForgeType: String, Codable, CaseIterable, Identifiable {
    case github
    case forgejo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .github: return "GitHub"
        case .forgejo: return "Forgejo"
        }
    }

    /// Creates the provider instance for this forge type.
    func makeProvider(config: ForgeConfig) -> ForgeProvider {
        switch self {
        case .github:
            return GitHubForge()
        case .forgejo:
            return ForgejoForge(
                baseURL: config.baseURL ?? "http://localhost:3000",
                tokenEnvVar: config.tokenEnvVar
            )
        }
    }

    /// Detect forge type from a git remote URL.
    /// Returns nil for unrecognized hosts (user must configure manually).
    static func detect(remoteURL: String) -> ForgeType? {
        let lower = remoteURL.lowercased()
        if lower.contains("github.com") { return .github }
        // Forgejo/Gitea instances vary by host — can't auto-detect.
        // User sets these explicitly via forgeConfig.
        return nil
    }

    /// Detect forge type by reading the origin remote of a repo.
    static func detect(inRepo path: String) async -> ForgeType? {
        guard let output = try? await ShellService.run("git remote get-url origin", in: path) else {
            return nil
        }
        return detect(remoteURL: output)
    }
}

// MARK: - Forge Config (persisted per-project)

struct ForgeConfig: Codable {
    var type: ForgeType

    // For self-hosted forges (Forgejo, GitLab, etc.)
    var baseURL: String?

    // Environment variable name that holds the API token (e.g. "FORGEJO_TOKEN")
    // Avoids storing secrets in the config file.
    var tokenEnvVar: String?
}

// MARK: - Errors

enum ForgeError: Error, LocalizedError {
    case couldNotParsePRNumber(String)
    case noForgeConfigured
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .couldNotParsePRNumber(let output):
            return "Could not parse PR number from output: \(output)"
        case .noForgeConfigured:
            return "No forge configured for this project. Set one in project settings."
        case .apiError(let message):
            return "Forge API error: \(message)"
        }
    }
}
