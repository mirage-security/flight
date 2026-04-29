import Foundation

@Observable
final class Project: Identifiable {
    var id: String { name }
    var name: String
    /// Filesystem path to the local clone. `nil` for remote-only projects
    /// that have no checkout on this machine — those projects only support
    /// remote worktrees and skip every code path that touches a local repo.
    var path: String?
    var worktrees: [Worktree]
    var remoteMode: RemoteModeConfig?
    var forgeConfig: ForgeConfig?
    var setupScript: String?

    init(
        name: String,
        path: String?,
        worktrees: [Worktree] = [],
        remoteMode: RemoteModeConfig? = nil,
        forgeConfig: ForgeConfig? = nil,
        setupScript: String? = nil
    ) {
        self.name = name
        self.path = path
        self.worktrees = worktrees
        self.remoteMode = remoteMode
        self.forgeConfig = forgeConfig
        self.setupScript = setupScript
    }

    /// Convenience for the common local-add case where the name is just
    /// the last path component.
    convenience init(path: String) {
        self.init(
            name: URL(fileURLWithPath: path).lastPathComponent,
            path: path
        )
    }

    var isRemoteOnly: Bool { path == nil }

    var hasRemoteMode: Bool {
        remoteMode != nil || RemoteScriptsService.hasRequiredRemoteScripts(project: self)
    }

    /// Returns the forge provider for this project, or nil if none configured.
    /// Local projects get a path-backed provider; remote-only projects get
    /// one that talks directly to `owner/repo` via the forge API.
    var forgeProvider: ForgeProvider? {
        guard let config = forgeConfig else { return nil }
        if let path {
            return config.type.makeLocalProvider(config: config, repoPath: path)
        }
        return config.type.makeRemoteProvider(config: config)
    }

    @ObservationIgnored private var _cachedOwnerRepo: (owner: String, repo: String)?
    @ObservationIgnored private var _ownerRepoResolveAttempted = false

    /// Resolves this project's `(owner, repo)` pair — from `forgeConfig` when
    /// set, otherwise by shelling out `git remote get-url origin` in the local
    /// checkout. Cached after first resolve; returns nil when no forge is
    /// configured or parsing fails.
    func resolvedOwnerRepo() async -> (owner: String, repo: String)? {
        if let cached = _cachedOwnerRepo { return cached }
        if let config = forgeConfig,
           let owner = config.owner,
           let repo = config.repo {
            let pair = (owner, repo)
            _cachedOwnerRepo = pair
            return pair
        }
        if _ownerRepoResolveAttempted { return nil }
        _ownerRepoResolveAttempted = true
        guard let path,
              let output = try? await ShellService.run("git remote get-url origin", in: path) else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned: String
        if trimmed.contains("@") {
            cleaned = trimmed.components(separatedBy: ":").last ?? trimmed
        } else {
            cleaned = URL(string: trimmed)?.pathComponents.suffix(2).joined(separator: "/") ?? trimmed
        }
        let parts = cleaned
            .replacingOccurrences(of: ".git", with: "")
            .components(separatedBy: "/")
            .filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        let pair = (parts[parts.count - 2], parts[parts.count - 1])
        _cachedOwnerRepo = pair
        return pair
    }

    /// Returns the first PR number referenced in `text` that points at this
    /// project's forge repo. Lets Flight attach a PR created on a renamed
    /// branch — `gh pr view '<branch>'` can't find those, but the agent
    /// usually prints the URL in its reply.
    func extractPRNumber(from text: String) async -> Int? {
        guard let config = forgeConfig else { return nil }
        guard let (owner, repo) = await resolvedOwnerRepo() else { return nil }

        let hostPattern: String
        let pullSegment: String
        switch config.type {
        case .github:
            hostPattern = #"github\.com"#
            pullSegment = "pull"
        case .forgejo:
            guard let baseURL = config.baseURL,
                  let host = URL(string: baseURL)?.host else { return nil }
            hostPattern = NSRegularExpression.escapedPattern(for: host)
            pullSegment = "pulls"
        }

        let ownerRe = NSRegularExpression.escapedPattern(for: owner)
        let repoRe = NSRegularExpression.escapedPattern(for: repo)
        let pattern = "https?://\(hostPattern)/\(ownerRe)/\(repoRe)/\(pullSegment)/(\\d+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let numRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[numRange])
    }
}

struct ProjectConfig: Codable {
    let name: String
    let path: String?
    var worktreeConfigs: [WorktreeConfig]
    var remoteMode: RemoteModeConfig?
    var forgeConfig: ForgeConfig?
    var setupScript: String?

    init(from project: Project) {
        self.name = project.name
        self.path = project.path
        self.worktreeConfigs = project.worktrees.map { WorktreeConfig(from: $0) }
        self.remoteMode = project.remoteMode
        self.forgeConfig = project.forgeConfig
        self.setupScript = project.setupScript
    }

    func toProject() -> Project {
        let project = Project(
            name: name,
            path: path,
            remoteMode: remoteMode,
            forgeConfig: forgeConfig,
            setupScript: setupScript
        )
        project.worktrees = worktreeConfigs.map { $0.toWorktree() }
        return project
    }
}
