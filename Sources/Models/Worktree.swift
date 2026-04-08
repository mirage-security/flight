import Foundation

enum WorktreeStatus: String {
    case creating
    case idle
    case running
    case error
    case done
}

@Observable
final class Worktree: Identifiable {
    let id: UUID
    var branch: String
    var path: String
    var status: WorktreeStatus
    var messages: [AgentMessage]
    var prNumber: Int?
    var sessionID: String?
    var ciStatus: CIStatus?
    var agentBusy: Bool = false
    var agent: ClaudeAgent?

    init(
        id: UUID = UUID(),
        branch: String,
        path: String,
        status: WorktreeStatus = .idle,
        prNumber: Int? = nil,
        sessionID: String? = nil
    ) {
        self.id = id
        self.branch = branch
        self.path = path
        self.status = status
        self.messages = []
        self.prNumber = prNumber
        self.sessionID = sessionID
    }
}

struct WorktreeConfig: Codable {
    let id: UUID
    let branch: String
    let path: String
    var prNumber: Int?
    var sessionID: String?

    init(from worktree: Worktree) {
        self.id = worktree.id
        self.branch = worktree.branch
        self.path = worktree.path
        self.prNumber = worktree.prNumber
        self.sessionID = worktree.sessionID
    }

    func toWorktree() -> Worktree {
        let wt = Worktree(id: id, branch: branch, path: path, prNumber: prNumber, sessionID: sessionID)
        wt.messages = ConfigService.loadMessages(worktreeID: id)
        return wt
    }
}
