import Foundation

@Observable
final class Project: Identifiable {
    let id: UUID
    var name: String
    var path: String
    var worktrees: [Worktree]

    init(id: UUID = UUID(), path: String, worktrees: [Worktree] = []) {
        self.id = id
        self.path = path
        self.name = URL(fileURLWithPath: path).lastPathComponent
        self.worktrees = worktrees
    }
}

struct ProjectConfig: Codable {
    let id: UUID
    let path: String
    var worktreeConfigs: [WorktreeConfig]

    init(from project: Project) {
        self.id = project.id
        self.path = project.path
        self.worktreeConfigs = project.worktrees.map { WorktreeConfig(from: $0) }
    }

    func toProject() -> Project {
        let project = Project(id: id, path: path)
        project.worktrees = worktreeConfigs.map { $0.toWorktree() }
        return project
    }
}
