import Foundation
import FlightCore

/// Effort level passed to `claude --effort`. `nil` case defers to the CLI default.
enum ConversationEffort: String, Codable, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case xhigh
    case max
    var id: String { rawValue }
    var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra High"
        case .max: return "Max"
        }
    }
}

/// A message the user submitted before the worktree finished provisioning.
/// Held on the conversation until the real (possibly remote) agent spawns,
/// then flushed through `agent.send`.
struct PendingSend {
    let text: String
    let images: [Data]
}

@Observable
final class Conversation: Identifiable {
    let id: UUID
    var name: String
    private(set) var messages: [AgentMessage]
    private(set) var sections: [ChatSection] = []
    var sessionID: String?
    var agentBusy: Bool = false
    var planMode: Bool = false
    /// Raw `claude --model` ID (e.g. "claude-opus-4-6[1m]"). `nil` = CLI default.
    var modelID: String?
    var effort: ConversationEffort?
    var agent: ClaudeAgent?
    var pendingSend: PendingSend?

    /// True while the session has been handed off to an interactive remote
    /// `claude` process (visible in the mobile app). Flight should sync the
    /// transcript before resuming its own `-p` turns.
    var remoteSessionActive: Bool = false

    /// Number of local messages at the moment the remote session was opened.
    /// Used to detect which messages in the remote transcript are "new".
    var handoffMessageCount: Int?

    // In-conversation search (session-only, not persisted).
    var searchActive: Bool = false
    var searchQuery: String = ""
    var currentSearchMatchIndex: Int = 0

    init(
        id: UUID = UUID(),
        name: String = "Chat",
        sessionID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.messages = []
        self.sessionID = sessionID
    }

    // MARK: - Message Mutation (always rebuilds sections)

    func appendMessage(_ message: AgentMessage) {
        messages.append(message)
        sections = ChatSection.build(from: messages)
    }

    func appendMessages(_ newMessages: [AgentMessage]) {
        messages.append(contentsOf: newMessages)
        sections = ChatSection.build(from: messages)
    }

    func setMessages(_ newMessages: [AgentMessage]) {
        messages = newMessages
        sections = ChatSection.build(from: messages)
    }

    func clearMessages() {
        messages.removeAll()
        sections = []
    }
}

struct ConversationConfig: Codable {
    let id: UUID
    var name: String
    var sessionID: String?
    var remoteSessionActive: Bool?
    var handoffMessageCount: Int?
    var modelID: String?
    var effort: ConversationEffort?

    init(from conversation: Conversation) {
        self.id = conversation.id
        self.name = conversation.name
        self.sessionID = conversation.sessionID
        self.remoteSessionActive = conversation.remoteSessionActive ? true : nil
        self.handoffMessageCount = conversation.handoffMessageCount
        self.modelID = conversation.modelID
        self.effort = conversation.effort
    }

    func toConversation(worktreePath: String, isRemote: Bool) -> Conversation {
        let conv = Conversation(id: id, name: name, sessionID: sessionID)
        conv.setMessages(ConversationHistory.hydrate(
            conversationID: id,
            worktreePath: worktreePath,
            sessionID: sessionID,
            isRemote: isRemote
        ))
        conv.remoteSessionActive = remoteSessionActive ?? false
        conv.handoffMessageCount = handoffMessageCount
        conv.modelID = modelID
        conv.effort = effort
        return conv
    }
}
