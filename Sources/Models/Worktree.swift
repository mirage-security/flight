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
    var displayName: String?
    var conversations: [Conversation]
    var activeConversationID: UUID?
    var prNumber: Int?
    var ciStatus: CIStatus?
    var prStatus: PRStatus?
    var ciLogsPaths: [String: String] = [:]  // check name -> log file path
    var ciLogsFetching = false
    var serviceMonitorVisible = false
    var serviceMonitorItems: [ServiceMonitorStatus] = []
    var serviceMonitorLoading = false
    var serviceMonitorError: String?
    var serviceMonitorUpdatedAt: Date?

    // Remote mode
    var isRemote: Bool
    var workspaceName: String?
    /// Optional browser URL for the remote workspace (e.g. a web IDE or
    /// dashboard). Populated from `FLIGHT_OUTPUT: url=...` lines the
    /// provision script emits on stdout.
    var remoteURL: String?
    /// Path to the repo checkout on the remote workspace, used to open
    /// the worktree in VS Code Remote-SSH. Populated from
    /// `FLIGHT_OUTPUT: repo_path=...`.
    var remoteRepoPath: String?
    /// SSH-Remote target string for VS Code Remote-SSH (the value that
    /// follows `--remote ssh-remote+`). For Coder this is typically
    /// `coder.<workspace>`; for raw SSH it might be `user@host`.
    /// Populated from `FLIGHT_OUTPUT: ssh_target=...`.
    var remoteSSHTarget: String?

    var activeConversation: Conversation? {
        conversations.first { $0.id == activeConversationID }
    }

    var anyAgentBusy: Bool {
        conversations.contains { $0.agentBusy }
    }

    var anyAgentRunning: Bool {
        conversations.contains { $0.agent?.isRunning == true }
    }

    var sidebarLabel: String {
        displayName ?? branch
    }

    init(
        branch: String,
        path: String,
        status: WorktreeStatus = .idle,
        displayName: String? = nil,
        prNumber: Int? = nil,
        isRemote: Bool = false,
        workspaceName: String? = nil
    ) {
        self.branch = branch
        self.path = path
        self.status = status
        self.displayName = displayName
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
    var displayName: String?
    var prNumber: Int?
    var isRemote: Bool?
    var workspaceName: String?
    var remoteURL: String?
    var remoteRepoPath: String?
    var remoteSSHTarget: String?
    var conversations: [ConversationConfig]?
    var activeConversationID: UUID?

    init(from worktree: Worktree) {
        self.branch = worktree.branch
        self.path = worktree.path
        self.displayName = worktree.displayName
        self.prNumber = worktree.prNumber
        self.isRemote = worktree.isRemote
        self.workspaceName = worktree.workspaceName
        self.remoteURL = worktree.remoteURL
        self.remoteRepoPath = worktree.remoteRepoPath
        self.remoteSSHTarget = worktree.remoteSSHTarget
        self.conversations = worktree.conversations.map { ConversationConfig(from: $0) }
        self.activeConversationID = worktree.activeConversationID
    }

    func toWorktree() -> Worktree {
        let wt = Worktree(
            branch: branch, path: path,
            displayName: displayName,
            prNumber: prNumber,
            isRemote: isRemote ?? false, workspaceName: workspaceName
        )
        wt.remoteURL = remoteURL
        wt.remoteRepoPath = remoteRepoPath
        wt.remoteSSHTarget = remoteSSHTarget

        if let convConfigs = conversations, !convConfigs.isEmpty {
            wt.conversations = convConfigs.map {
                $0.toConversation(worktreePath: path, isRemote: isRemote ?? false)
            }
            wt.activeConversationID = activeConversationID ?? wt.conversations.first?.id
        }

        return wt
    }
}
