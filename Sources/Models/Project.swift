import Foundation

@Observable
final class Project: Identifiable {
    var id: String { name }
    var name: String
    var path: String
    var worktrees: [Worktree]
    var remoteMode: RemoteModeConfig?
    var forgeConfig: ForgeConfig?

    init(path: String, worktrees: [Worktree] = [], remoteMode: RemoteModeConfig? = nil, forgeConfig: ForgeConfig? = nil) {
        self.path = path
        self.name = URL(fileURLWithPath: path).lastPathComponent
        self.worktrees = worktrees
        self.remoteMode = remoteMode
        self.forgeConfig = forgeConfig
    }

    var hasRemoteMode: Bool {
        remoteMode != nil
    }

    /// Returns the forge provider for this project, or nil if none configured.
    var forgeProvider: ForgeProvider? {
        guard let config = forgeConfig else { return nil }
        return config.type.makeProvider(config: config)
    }
}

struct ProjectConfig: Codable {
    let name: String
    let path: String
    var worktreeConfigs: [WorktreeConfig]
    var remoteMode: RemoteModeConfig?
    var forgeConfig: ForgeConfig?

    init(from project: Project) {
        self.name = project.name
        self.path = project.path
        self.worktreeConfigs = project.worktrees.map { WorktreeConfig(from: $0) }
        self.remoteMode = project.remoteMode
        self.forgeConfig = project.forgeConfig
    }

    func toProject() -> Project {
        let project = Project(path: path, remoteMode: remoteMode, forgeConfig: forgeConfig)
        project.worktrees = worktreeConfigs.map { $0.toWorktree() }
        return project
    }
}
