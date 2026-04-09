import Foundation

enum WorktreeStatus: String {
    case creating
    case idle
    case running
    case error
    case done
    case deleting
}

@Observable
final class Worktree: Identifiable {
    var id: String { branch }
    var branch: String
    var path: String
    var status: WorktreeStatus
    var conversations: [Conversation]
    var activeConversationID: UUID?
    var prNumber: Int?
    var ciStatus: CIStatus?
    var prStatus: PRStatus?

    // Remote mode
    var isRemote: Bool
    var workspaceName: String?

    var activeConversation: Conversation? {
        conversations.first { $0.id == activeConversationID }
    }

    var anyAgentBusy: Bool {
        conversations.contains { $0.agentBusy }
    }

    var anyAgentRunning: Bool {
        conversations.contains { $0.agent?.isRunning == true }
    }

    init(
        branch: String,
        path: String,
        status: WorktreeStatus = .idle,
        prNumber: Int? = nil,
        isRemote: Bool = false,
        workspaceName: String? = nil
    ) {
        self.branch = branch
        self.path = path
        self.status = status
        self.conversations = []
        self.prNumber = prNumber
        self.isRemote = isRemote
        self.workspaceName = workspaceName
    }

    @discardableResult
    func ensureConversation() -> Conversation {
        if let active = activeConversation { return active }
        if let first = conversations.first {
            activeConversationID = first.id
            return first
        }
        let conv = Conversation()
        conversations.append(conv)
        activeConversationID = conv.id
        return conv
    }
}

struct WorktreeConfig: Codable {
    let branch: String
    let path: String
    var prNumber: Int?
    var isRemote: Bool?
    var workspaceName: String?
    var conversations: [ConversationConfig]?
    var activeConversationID: UUID?

    init(from worktree: Worktree) {
        self.branch = worktree.branch
        self.path = worktree.path
        self.prNumber = worktree.prNumber
        self.isRemote = worktree.isRemote
        self.workspaceName = worktree.workspaceName
        self.conversations = worktree.conversations.map { ConversationConfig(from: $0) }
        self.activeConversationID = worktree.activeConversationID
    }

    func toWorktree() -> Worktree {
        let wt = Worktree(
            branch: branch, path: path,
            prNumber: prNumber,
            isRemote: isRemote ?? false, workspaceName: workspaceName
        )

        if let convConfigs = conversations, !convConfigs.isEmpty {
            wt.conversations = convConfigs.map { $0.toConversation() }
            wt.activeConversationID = activeConversationID ?? wt.conversations.first?.id
        }

        return wt
    }
}
