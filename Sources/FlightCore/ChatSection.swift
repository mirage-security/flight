import Foundation

// Groups consecutive messages into display sections
public enum ChatSection: Identifiable {
    case message(AgentMessage)
    case toolGroup(id: UUID, tools: [AgentMessage])
    case thinkingGroup(id: UUID, thoughts: [AgentMessage])
    case provisionGroup(id: UUID, logs: [AgentMessage])
    case setupGroup(id: UUID, logs: [AgentMessage])
    case plan(AgentMessage)
    case system(AgentMessage)

    public var id: UUID {
        switch self {
        case .message(let m): return m.id
        case .toolGroup(let id, _): return id
        case .thinkingGroup(let id, _): return id
        case .provisionGroup(let id, _): return id
        case .setupGroup(let id, _): return id
        case .plan(let m): return m.id
        case .system(let m): return m.id
        }
    }

    public static func build(from messages: [AgentMessage]) -> [ChatSection] {
        var sections: [ChatSection] = []
        var currentTools: [AgentMessage] = []
        var currentThoughts: [AgentMessage] = []
        var currentProvisionLogs: [AgentMessage] = []
        var currentSetupLogs: [AgentMessage] = []

        func flushTools() {
            if !currentTools.isEmpty {
                // Separate ExitPlanMode from regular tools (single pass
                // to avoid repeated planContent JSON parsing)
                var planMessage: AgentMessage?
                var otherTools: [AgentMessage] = []
                for tool in currentTools {
                    if planMessage == nil && tool.planContent != nil {
                        planMessage = tool
                    } else {
                        otherTools.append(tool)
                    }
                }
                if !otherTools.isEmpty {
                    sections.append(.toolGroup(id: otherTools[0].id, tools: otherTools))
                }
                if let planMessage {
                    sections.append(.plan(planMessage))
                }
                currentTools = []
            }
        }

        func flushThoughts() {
            if !currentThoughts.isEmpty {
                sections.append(.thinkingGroup(id: currentThoughts[0].id, thoughts: currentThoughts))
                currentThoughts = []
            }
        }

        func flushProvisionLogs() {
            if !currentProvisionLogs.isEmpty {
                sections.append(.provisionGroup(id: currentProvisionLogs[0].id, logs: currentProvisionLogs))
                currentProvisionLogs = []
            }
        }

        func flushSetupLogs() {
            if !currentSetupLogs.isEmpty {
                sections.append(.setupGroup(id: currentSetupLogs[0].id, logs: currentSetupLogs))
                currentSetupLogs = []
            }
        }

        for message in messages {
            if message.isProvisionLog {
                flushTools()
                flushThoughts()
                flushSetupLogs()
                currentProvisionLogs.append(message)
            } else if message.isSetupLog {
                flushTools()
                flushThoughts()
                flushProvisionLogs()
                currentSetupLogs.append(message)
            } else if message.role == .system {
                flushTools()
                flushThoughts()
                flushProvisionLogs()
                flushSetupLogs()
                sections.append(.system(message))
            } else if message.isThinking {
                flushTools()
                flushProvisionLogs()
                flushSetupLogs()
                currentThoughts.append(message)
            } else if message.isToolUse || message.isToolResult {
                flushThoughts()
                flushProvisionLogs()
                flushSetupLogs()
                currentTools.append(message)
            } else {
                flushTools()
                flushThoughts()
                flushProvisionLogs()
                flushSetupLogs()
                sections.append(.message(message))
            }
        }
        flushTools()
        flushThoughts()
        flushProvisionLogs()
        flushSetupLogs()
        return sections
    }
}
