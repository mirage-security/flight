import Foundation

@Observable
final class Conversation: Identifiable {
    let id: UUID
    var name: String
    var messages: [AgentMessage]
    var sessionID: String?
    var agentBusy: Bool = false
    var agent: ClaudeAgent?

    /// True while the session has been handed off to an interactive remote
    /// `claude` process (visible in the mobile app). Flight should sync the
    /// transcript before resuming its own `-p` turns.
    var remoteSessionActive: Bool = false

    /// Number of local messages at the moment the remote session was opened.
    /// Used to detect which messages in the remote transcript are "new".
    var handoffMessageCount: Int?

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
}

struct ConversationConfig: Codable {
    let id: UUID
    var name: String
    var sessionID: String?
    var remoteSessionActive: Bool?
    var handoffMessageCount: Int?

    init(from conversation: Conversation) {
        self.id = conversation.id
        self.name = conversation.name
        self.sessionID = conversation.sessionID
        self.remoteSessionActive = conversation.remoteSessionActive ? true : nil
        self.handoffMessageCount = conversation.handoffMessageCount
    }

    func toConversation() -> Conversation {
        let conv = Conversation(id: id, name: name, sessionID: sessionID)
        conv.messages = ConfigService.loadMessages(conversationID: id)
        conv.remoteSessionActive = remoteSessionActive ?? false
        conv.handoffMessageCount = handoffMessageCount
        return conv
    }
}
