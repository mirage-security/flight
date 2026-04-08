import SwiftUI

// Groups consecutive messages into display sections
enum ChatSection: Identifiable {
    case message(AgentMessage)
    case toolGroup(id: UUID, tools: [AgentMessage])
    case provisionGroup(id: UUID, logs: [AgentMessage])
    case system(AgentMessage)

    var id: UUID {
        switch self {
        case .message(let m): return m.id
        case .toolGroup(let id, _): return id
        case .provisionGroup(let id, _): return id
        case .system(let m): return m.id
        }
    }

    static func build(from messages: [AgentMessage]) -> [ChatSection] {
        var sections: [ChatSection] = []
        var currentTools: [AgentMessage] = []
        var currentProvisionLogs: [AgentMessage] = []

        func flushTools() {
            if !currentTools.isEmpty {
                sections.append(.toolGroup(id: currentTools[0].id, tools: currentTools))
                currentTools = []
            }
        }

        func flushProvisionLogs() {
            if !currentProvisionLogs.isEmpty {
                sections.append(.provisionGroup(id: currentProvisionLogs[0].id, logs: currentProvisionLogs))
                currentProvisionLogs = []
            }
        }

        for message in messages {
            if message.isProvisionLog {
                flushTools()
                currentProvisionLogs.append(message)
            } else if message.role == .system {
                flushTools()
                flushProvisionLogs()
                sections.append(.system(message))
            } else if message.isToolUse || message.isToolResult {
                flushProvisionLogs()
                currentTools.append(message)
            } else {
                flushTools()
                flushProvisionLogs()
                sections.append(.message(message))
            }
        }
        flushTools()
        flushProvisionLogs()
        return sections
    }
}

struct ChatView: View {
    @Bindable var state: AppState
    let worktree: Worktree
    @Environment(\.theme) private var theme

    private var conversation: Conversation? {
        worktree.activeConversation
    }

    private var isThinking: Bool {
        conversation?.agentBusy ?? false
    }

    private var sections: [ChatSection] {
        guard let conversation else { return [] }
        return ChatSection.build(from: conversation.messages)
    }

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
                .background(theme.headerBackground)

            if worktree.conversations.count > 1 {
                tabBar
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                            switch section {
                            case .message(let message):
                                MessageView(message: message)
                                    .id(section.id)
                            case .toolGroup(_, let tools):
                                let isLast = index == sections.count - 1
                                ToolGroupView(tools: tools, isActive: isLast && isThinking)
                                    .id(section.id)
                            case .provisionGroup(_, let logs):
                                let isLast = index == sections.count - 1
                                ProvisionGroupView(logs: logs, isActive: isLast && worktree.status == .creating)
                                    .id(section.id)
                            case .system(let message):
                                if message.isPermissionRequest, let conversation {
                                    PermissionRequestView(message: message, conversation: conversation, state: state)
                                        .id(section.id)
                                } else {
                                    SystemMessageView(message: message)
                                        .id(section.id)
                                }
                            }
                        }

                        if isThinking && !(sections.last.map { if case .toolGroup = $0 { true } else { false } } ?? false) {
                            ThinkingIndicator()
                                .id("thinking")
                        }
                    }
                    .padding()
                }
                .onChange(of: conversation?.messages.count) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: isThinking) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onAppear {
                    scrollToBottom(proxy: proxy)
                }
            }

            if worktree.ciStatus?.overall == .failure {
                fixCIBar
            }

            Divider()

            InputBarView(state: state, worktree: worktree)
        }
        .background(theme.background)
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if isThinking {
                proxy.scrollTo("thinking", anchor: .bottom)
            } else if let last = sections.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(worktree.conversations) { conv in
                    tabButton(for: conv)
                }

                Button {
                    state.addConversation(to: worktree)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(theme.headerBackground)
    }

    private func tabButton(for conv: Conversation) -> some View {
        let isActive = conv.id == worktree.activeConversationID

        return HStack(spacing: 4) {
            if conv.agentBusy {
                Circle()
                    .fill(theme.orange)
                    .frame(width: 6, height: 6)
            }

            Text(conv.name)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? theme.text : theme.secondaryText)
                .lineLimit(1)

            if worktree.conversations.count > 1 {
                Button {
                    state.removeConversation(conv, from: worktree)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.secondaryText.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? theme.inputBackground : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? theme.border : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            state.selectConversation(conv, in: worktree)
        }
    }

    // MARK: - Header

    private var chatHeader: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(worktree.branch)
                .font(.headline)
            Spacer()
            if let prNumber = worktree.prNumber {
                Label("PR #\(prNumber)", systemImage: "arrow.triangle.pull")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
            Text(headerStatusLabel)
                .font(.caption)
                .foregroundStyle(headerStatusColor)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var fixCIBar: some View {
        HStack {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(theme.red)
            Text("CI checks failed")
                .font(.callout)
                .foregroundStyle(theme.text)
            Spacer()
            Button("Fix CI") {
                Task { await state.fixCI(for: worktree) }
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.red)
            .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(theme.red.opacity(0.1))
    }

    private var headerStatusLabel: String {
        if worktree.status == .creating { return "creating" }
        if let conv = conversation {
            if conv.agentBusy { return "working" }
            if conv.agent?.isRunning == true { return "ready" }
        }
        if worktree.status == .error { return "error" }
        return "idle"
    }

    private var headerStatusColor: Color {
        if worktree.status == .creating { return theme.yellow }
        if let conv = conversation {
            if conv.agentBusy { return theme.orange }
            if conv.agent?.isRunning == true { return theme.green }
        }
        if worktree.status == .error { return theme.red }
        return theme.secondaryText
    }

    private var statusColor: Color {
        headerStatusColor
    }
}

// MARK: - Tool Group (collapsed chain)

struct ToolGroupView: View {
    let tools: [AgentMessage]
    var isActive: Bool = false
    @Environment(\.theme) private var theme
    @State private var isExpanded = false

    private var toolNames: String {
        let names = tools.compactMap { msg -> String? in
            if case .toolUse(let name, _) = msg.content { return name }
            return nil
        }
        // Deduplicate preserving order
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        return unique.joined(separator: ", ")
    }

    private var toolUseCount: Int {
        tools.filter(\.isToolUse).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 12)

                    if isActive {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.orange)

                    Text("\(toolUseCount) tool \(toolUseCount == 1 ? "call" : "calls")")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.text)

                    Text(toolNames)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(tools) { tool in
                        ToolCallRow(message: tool)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
        .background(theme.toolGroupBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.border.opacity(0.5), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Provision Group (collapsed log output)

struct ProvisionGroupView: View {
    let logs: [AgentMessage]
    var isActive: Bool = false
    @Environment(\.theme) private var theme
    @State private var isExpanded = false

    private var lastLine: String {
        logs.last?.textContent ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 12)

                    if isActive {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Image(systemName: "cloud.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(isActive ? theme.yellow : theme.green)

                    Text(isActive ? "Provisioning..." : "Provisioned")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.text)

                    Text("\(logs.count) \(logs.count == 1 ? "line" : "lines")")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)

                    if !isExpanded {
                        Text(lastLine)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if isExpanded {
                ScrollView {
                    Text(logs.map(\.textContent).joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .background(theme.toolGroupBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.border.opacity(0.5), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - System Message (interrupts, etc.)

struct SystemMessageView: View {
    let message: AgentMessage
    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "stop.circle")
                    .font(.system(size: 12))
                Text(message.textContent)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(theme.red)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(theme.red.opacity(0.08))
            .clipShape(Capsule())
            Spacer()
        }
    }
}

// MARK: - Permission Request

struct PermissionRequestView: View {
    let message: AgentMessage
    let conversation: Conversation
    @Bindable var state: AppState
    @Environment(\.theme) private var theme
    @State private var responded = false

    var body: some View {
        if case .permissionRequest(let requestID, let description) = message.content {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 16))
                    .foregroundStyle(theme.yellow)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Permission Request")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.text)
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                }

                Spacer()

                if responded {
                    Text("Allowed")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.green)
                } else {
                    Button("Deny") {
                        state.respondToPermission(conversation: conversation, requestID: requestID, allow: false)
                        responded = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Allow Once") {
                        state.respondToPermission(conversation: conversation, requestID: requestID, allow: true)
                        responded = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.accent)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(theme.yellow.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(theme.yellow.opacity(0.3), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - Thinking

struct ThinkingIndicator: View {
    @Environment(\.theme) private var theme
    @State private var dotCount = 0

    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("Thinking" + String(repeating: ".", count: dotCount + 1))
                .font(.system(size: 13))
                .foregroundStyle(theme.secondaryText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.assistantBubble)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onReceive(timer) { _ in
            dotCount = (dotCount + 1) % 3
        }
    }
}
