import SwiftUI

// Groups consecutive messages into display sections
enum ChatSection: Identifiable {
    case message(AgentMessage)
    case toolGroup(id: UUID, tools: [AgentMessage])
    case system(AgentMessage)

    var id: UUID {
        switch self {
        case .message(let m): return m.id
        case .toolGroup(let id, _): return id
        case .system(let m): return m.id
        }
    }

    static func build(from messages: [AgentMessage]) -> [ChatSection] {
        var sections: [ChatSection] = []
        var currentTools: [AgentMessage] = []

        func flushTools() {
            if !currentTools.isEmpty {
                sections.append(.toolGroup(id: currentTools[0].id, tools: currentTools))
                currentTools = []
            }
        }

        for message in messages {
            if message.role == .system {
                flushTools()
                sections.append(.system(message))
            } else if message.isToolUse || message.isToolResult {
                currentTools.append(message)
            } else {
                flushTools()
                sections.append(.message(message))
            }
        }
        flushTools()
        return sections
    }
}

struct ChatView: View {
    @Bindable var state: AppState
    let worktree: Worktree

    private var isThinking: Bool {
        worktree.agentBusy
    }

    private var sections: [ChatSection] {
        ChatSection.build(from: worktree.messages)
    }

    var body: some View {
        VStack(spacing: 0) {
            chatHeader

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
                            case .system(let message):
                                if message.isPermissionRequest {
                                    PermissionRequestView(message: message, worktree: worktree, state: state)
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
                .onChange(of: worktree.messages.count) { _, _ in
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
                    .foregroundStyle(.secondary)
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
                .foregroundStyle(.red)
            Text("CI checks failed")
                .font(.callout)
            Spacer()
            Button("Fix CI") {
                Task { await state.fixCI(for: worktree) }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.red.opacity(0.1))
    }

    private var headerStatusLabel: String {
        if worktree.status == .creating { return "creating" }
        if worktree.agentBusy { return "working" }
        if worktree.agent?.isRunning == true { return "ready" }
        if worktree.status == .error { return "error" }
        return "idle"
    }

    private var headerStatusColor: Color {
        if worktree.status == .creating { return .yellow }
        if worktree.agentBusy { return .orange }
        if worktree.agent?.isRunning == true { return .green }
        if worktree.status == .error { return .red }
        return .secondary
    }

    private var statusColor: Color {
        headerStatusColor
    }
}

// MARK: - Tool Group (collapsed chain)

struct ToolGroupView: View {
    let tools: [AgentMessage]
    var isActive: Bool = false
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
                        .foregroundStyle(.secondary)
                        .frame(width: 12)

                    if isActive {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)

                    Text("\(toolUseCount) tool \(toolUseCount == 1 ? "call" : "calls")")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)

                    Text(toolNames)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
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
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - System Message (interrupts, etc.)

struct SystemMessageView: View {
    let message: AgentMessage

    var body: some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "stop.circle")
                    .font(.system(size: 12))
                Text(message.textContent)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.red)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.08))
            .clipShape(Capsule())
            Spacer()
        }
    }
}

// MARK: - Permission Request

struct PermissionRequestView: View {
    let message: AgentMessage
    let worktree: Worktree
    @Bindable var state: AppState
    @State private var responded = false

    var body: some View {
        if case .permissionRequest(let requestID, let description) = message.content {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 16))
                    .foregroundStyle(.yellow)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Permission Request")
                        .font(.system(size: 12, weight: .semibold))
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if responded {
                    Text("Allowed")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
                } else {
                    Button("Deny") {
                        state.respondToPermission(worktree: worktree, requestID: requestID, allow: false)
                        responded = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Allow Once") {
                        state.respondToPermission(worktree: worktree, requestID: requestID, allow: true)
                        responded = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.yellow.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.yellow.opacity(0.3), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - Thinking

struct ThinkingIndicator: View {
    @State private var dotCount = 0

    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("Thinking" + String(repeating: ".", count: dotCount + 1))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onReceive(timer) { _ in
            dotCount = (dotCount + 1) % 3
        }
    }
}
