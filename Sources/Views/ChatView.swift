import SwiftUI

// Groups consecutive messages into display sections
enum ChatSection: Identifiable {
    case message(AgentMessage)
    case toolGroup(id: UUID, tools: [AgentMessage])
    case provisionGroup(id: UUID, logs: [AgentMessage])
    case setupGroup(id: UUID, logs: [AgentMessage])
    case plan(AgentMessage)
    case system(AgentMessage)

    var id: UUID {
        switch self {
        case .message(let m): return m.id
        case .toolGroup(let id, _): return id
        case .provisionGroup(let id, _): return id
        case .setupGroup(let id, _): return id
        case .plan(let m): return m.id
        case .system(let m): return m.id
        }
    }

    static func build(from messages: [AgentMessage]) -> [ChatSection] {
        var sections: [ChatSection] = []
        var currentTools: [AgentMessage] = []
        var currentProvisionLogs: [AgentMessage] = []
        var currentSetupLogs: [AgentMessage] = []

        func flushTools() {
            if !currentTools.isEmpty {
                // Separate ExitPlanMode from regular tools
                let planMessage = currentTools.first { $0.planContent != nil }
                let otherTools = currentTools.filter { $0.planContent == nil }
                if !otherTools.isEmpty {
                    sections.append(.toolGroup(id: otherTools[0].id, tools: otherTools))
                }
                if let planMessage {
                    sections.append(.plan(planMessage))
                }
                currentTools = []
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
                flushSetupLogs()
                currentProvisionLogs.append(message)
            } else if message.isSetupLog {
                flushTools()
                flushProvisionLogs()
                currentSetupLogs.append(message)
            } else if message.role == .system {
                flushTools()
                flushProvisionLogs()
                flushSetupLogs()
                sections.append(.system(message))
            } else if message.isToolUse || message.isToolResult {
                flushProvisionLogs()
                flushSetupLogs()
                currentTools.append(message)
            } else {
                flushTools()
                flushProvisionLogs()
                flushSetupLogs()
                sections.append(.message(message))
            }
        }
        flushTools()
        flushProvisionLogs()
        flushSetupLogs()
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

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
                .background(theme.headerBackground)

            if worktree.conversations.count > 1 {
                tabBar
            }

            Divider()

            ChatMessageListView(
                state: state,
                worktree: worktree
            )

            if conversation?.remoteSessionActive == true {
                remoteSessionBar
            }

            if worktree.prNumber != nil {
                PRStatusStripView(worktree: worktree, state: state)
            }

            Divider()

            InputBarView(state: state, worktree: worktree)
        }
        .background(theme.background)
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
            if worktree.isRemote && worktree.workspaceName != nil {
                Button {
                    state.openRemoteSession(for: worktree)
                } label: {
                    Image(systemName: "terminal")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Open remote session in Terminal (Cmd+Shift+R)")
            }
            Spacer()
            Text(headerStatusLabel)
                .font(.caption)
                .foregroundStyle(headerStatusColor)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var remoteSessionBar: some View {
        HStack {
            Image(systemName: "iphone.and.arrow.forward")
                .foregroundStyle(theme.accent)
            Text("Session continued remotely")
                .font(.callout)
                .foregroundStyle(theme.text)
            Spacer()
            Button("Sync") {
                if let conv = conversation {
                    Task { await state.syncRemoteSession(for: worktree, conversation: conv) }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)
            .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(theme.accent.opacity(0.1))
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

// MARK: - Chat Message List (isolated observation scope)

/// Separate struct so that message-list layout is only invalidated when
/// conversation messages change, NOT when CI/PR status updates arrive.
struct ChatMessageListView: View {
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

    /// True while the worktree is being created and a setup script is
    /// configured but no real setup output has streamed in yet. We render a
    /// placeholder ProvisionGroupView in this state so the user gets immediate
    /// feedback during git create + npm install's silent dep-resolution phase.
    private var showingSetupPlaceholder: Bool {
        guard worktree.status == .creating else { return false }
        let hasSetupSection = sections.contains { section in
            if case .setupGroup = section { return true }
            return false
        }
        if hasSetupSection { return false }
        guard let project = state.projectFor(worktree: worktree) else { return false }
        return WorktreeSetupService.willRunSetup(project: project)
    }

    private static let placeholderSetupLogs: [AgentMessage] = [
        AgentMessage(role: .system, content: .setupLog("Creating worktree..."))
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if showingSetupPlaceholder {
                        ProvisionGroupView(
                            logs: Self.placeholderSetupLogs,
                            isActive: true,
                            kind: .worktreeSetup
                        )
                        .id("setup-placeholder")
                    }

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
                            ProvisionGroupView(
                                logs: logs,
                                isActive: isLast && worktree.status == .creating,
                                kind: .remoteProvision
                            )
                                .id(section.id)
                        case .setupGroup(_, let logs):
                            let isLast = index == sections.count - 1
                            ProvisionGroupView(
                                logs: logs,
                                isActive: isLast && worktree.status == .creating,
                                kind: .worktreeSetup
                            )
                                .id(section.id)
                        case .plan(let message):
                            PlanView(message: message, state: state, worktree: worktree)
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
}

// MARK: - PR Status Strip (isolated observation scope)

/// Separate struct so that CI/PR status changes only invalidate this strip,
/// not the entire chat message list above.
struct PRStatusStripView: View {
    let worktree: Worktree
    @Bindable var state: AppState
    @Environment(\.theme) private var theme

    @State private var showingCIPopover = false
    @State private var showingCommentsPopover = false

    private var conversation: Conversation? {
        worktree.activeConversation
    }

    var body: some View {
        HStack(spacing: 8) {
            if let prNumber = worktree.prNumber {
                Button {
                    if let urlStr = worktree.prStatus?.url, let url = URL(string: urlStr) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.pull")
                            .font(.system(size: 10))
                        Text(verbatim: "PR #\(prNumber)")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
                .help(worktree.prStatus?.url ?? "")
            }

            ciChicklet
            commentsChicklet
            reviewPill

            Spacer()

            if worktree.prStatus?.reviewDecision == "APPROVED",
               worktree.ciStatus?.overall == .success {
                Button {
                    if let urlStr = worktree.prStatus?.url, let url = URL(string: urlStr) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                        Text("Ready to Merge")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.green)
                .controlSize(.small)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var ciChicklet: some View {
        let ci = worktree.ciStatus
        if let ci {
            let failed = ci.failedCheckNames
            let color: Color = switch ci.overall {
            case .success: theme.green
            case .failure: theme.red
            case .pending: theme.yellow
            }
            let icon: String = switch ci.overall {
            case .success: "checkmark.circle.fill"
            case .failure: "xmark.circle.fill"
            case .pending: "circle.dotted"
            }
            let label: String = switch ci.overall {
            case .success: "\(ci.passedCount) Checks Passing"
            case .failure: "\(failed.count) Checks Failing"
            case .pending: "CI Running"
            }

            HStack(spacing: 0) {
                Button { showingCIPopover.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: icon)
                            .font(.system(size: 10))
                        Text(label)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingCIPopover, arrowEdge: .bottom) {
                    ciPopoverContent
                }

                if ci.overall == .failure {
                    Divider()
                        .frame(height: 14)
                        .padding(.horizontal, 2)
                    if worktree.ciLogsFetching {
                        ProgressView()
                            .controlSize(.mini)
                            .padding(.horizontal, 6)
                    } else {
                        Button { resolveCI() } label: {
                            Text("Resolve")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(color)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .background(color.opacity(0.1))
            .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private var commentsChicklet: some View {
        let comments = worktree.prStatus?.inlineComments ?? []
        if !comments.isEmpty {
            let color = theme.accent

            HStack(spacing: 0) {
                Button { showingCommentsPopover.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 10))
                        Text("\(comments.count) Comment\(comments.count == 1 ? "" : "s")")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingCommentsPopover, arrowEdge: .bottom) {
                    commentsPopoverContent
                }

                Divider()
                    .frame(height: 14)
                    .padding(.horizontal, 2)
                Button { resolveComments() } label: {
                    Text("Resolve")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
            }
            .background(color.opacity(0.1))
            .clipShape(Capsule())
        }
    }

    private var reviewPill: some View {
        let status = worktree.prStatus
        let icon: String
        let label: String
        let color: Color

        if let decision = status?.reviewDecision {
            switch decision {
            case "APPROVED":
                icon = "checkmark.circle.fill"
                label = "Approved"
                color = theme.green
            case "CHANGES_REQUESTED":
                icon = "exclamationmark.triangle.fill"
                label = "Changes Requested"
                color = theme.orange
            case "REVIEW_REQUIRED":
                icon = "eye.fill"
                label = "Review Required"
                color = theme.yellow
            default:
                icon = "eye.fill"
                label = "Pending"
                color = theme.secondaryText
            }
        } else {
            return AnyView(EmptyView())
        }

        return AnyView(
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.1))
            .clipShape(Capsule())
        )
    }

    private var ciPopoverContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CI Checks")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.text)
            Divider()
            if let checks = worktree.ciStatus?.checks {
                ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                    HStack(spacing: 6) {
                        Image(systemName: check.state == "SUCCESS" ? "checkmark.circle.fill" :
                                check.state == "FAILURE" ? "xmark.circle.fill" :
                                check.state == "SKIPPED" ? "forward.fill" : "circle.dotted")
                            .font(.system(size: 10))
                            .foregroundStyle(check.state == "SUCCESS" ? theme.green :
                                check.state == "FAILURE" ? theme.red :
                                check.state == "SKIPPED" ? theme.secondaryText : theme.yellow)
                        Text(check.name)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.text)
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 200)
    }

    private var commentsPopoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Review Comments")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.text)
            Divider()
            if let comments = worktree.prStatus?.inlineComments {
                ForEach(Array(comments.enumerated()), id: \.offset) { _, comment in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(comment.author)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(theme.text)
                            if let path = comment.path {
                                Text(URL(fileURLWithPath: path).lastPathComponent + (comment.line.map { ":\($0)" } ?? ""))
                                    .font(.system(size: 10))
                                    .foregroundStyle(theme.secondaryText)
                            }
                        }
                        Text(comment.body)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                    if comment.body != comments.last?.body {
                        Divider()
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 450)
    }

    private func resolveCI() {
        let failedChecks = worktree.ciStatus?.checks.filter { $0.state == "FAILURE" } ?? []
        var message = "Please address these failing CI checks:\n\n"
        for check in failedChecks {
            message += "- **\(check.name)**"
            if let path = worktree.ciLogsPaths[check.name] {
                message += " — logs: `\(path)`"
            }
            message += "\n"
        }
        if let conv = conversation {
            state.sendMessage(message, to: worktree, conversation: conv)
        }
    }

    private func resolveComments() {
        var message = "Please address the PR review feedback:\n\n"
        if let comments = worktree.prStatus?.inlineComments {
            for c in comments {
                let location = [c.path, c.line.map { ":\($0)" }].compactMap { $0 }.joined()
                message += "- **\(c.author)** on `\(location)`: \(c.body)\n\n"
            }
        }
        if let conv = conversation {
            state.sendMessage(message, to: worktree, conversation: conv)
        }
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

enum ProvisionGroupKind {
    case remoteProvision
    case worktreeSetup

    var icon: String {
        switch self {
        case .remoteProvision: return "cloud.fill"
        case .worktreeSetup: return "shippingbox.fill"
        }
    }

    var activeLabel: String {
        switch self {
        case .remoteProvision: return "Provisioning..."
        case .worktreeSetup: return "Setting up worktree..."
        }
    }

    var doneLabel: String {
        switch self {
        case .remoteProvision: return "Provisioned"
        case .worktreeSetup: return "Worktree ready"
        }
    }
}

struct ProvisionGroupView: View {
    let logs: [AgentMessage]
    var isActive: Bool = false
    var kind: ProvisionGroupKind = .remoteProvision
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

                    Image(systemName: kind.icon)
                        .font(.system(size: 11))
                        .foregroundStyle(isActive ? theme.yellow : theme.green)

                    Text(isActive ? kind.activeLabel : kind.doneLabel)
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

// MARK: - Plan View

struct PlanView: View {
    let message: AgentMessage
    @Bindable var state: AppState
    let worktree: Worktree
    @AppStorage("flightFontSize") private var fontSize: Double = 14
    @Environment(\.theme) private var theme

    @State private var comments: [Int: String] = [:]  // item index -> comment text
    @State private var commentingOn: Int? = nil        // which item has comment field open
    @State private var hoveredItem: Int? = nil
    @State private var resolved = false

    private var conversation: Conversation? {
        worktree.activeConversation
    }

    private var items: [PlanItem] {
        guard let plan = message.planContent else { return [] }
        return PlanItem.parse(plan)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "map.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.purple)
                Text("Plan")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.purple)
                Spacer()
                if resolved {
                    Text("Approved")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.green)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()
                .overlay(theme.purple.opacity(0.2))

            // Plan items
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    planItemRow(item: item, index: index)
                }
            }
            .padding(.vertical, 4)

            // Action buttons
            if !resolved {
                Divider()
                    .overlay(theme.purple.opacity(0.2))

                HStack(spacing: 8) {
                    Spacer()

                    let hasComments = !comments.values.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).isEmpty

                    if hasComments {
                        Button { requestChanges() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "bubble.left")
                                    .font(.system(size: 10))
                                Text("Request Changes (\(activeCommentCount))")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(theme.orange.opacity(0.15))
                            .foregroundStyle(theme.orange)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }

                    Button { approve() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                            Text("Approve Plan")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(theme.green.opacity(0.15))
                        .foregroundStyle(theme.green)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .background(theme.purple.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(theme.purple.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func planItemRow(item: PlanItem, index: Int) -> some View {
        let hasComment = comments[index]?.isEmpty == false
        let isHovered = hoveredItem == index
        let showButton = !resolved && (isHovered || hasComment || commentingOn == index)

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                // Floating comment button (Notion-style, left gutter)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        commentingOn = commentingOn == index ? nil : index
                    }
                } label: {
                    Image(systemName: hasComment ? "bubble.left.fill" : "bubble.left")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(hasComment ? theme.orange : theme.secondaryText)
                        .frame(width: 22, height: 22)
                        .background(showButton ? theme.inputBackground : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .opacity(showButton ? 1 : 0)
                .animation(.easeInOut(duration: 0.1), value: showButton)

                // Item label (number/bullet only — no label for plain paragraphs)
                if item.label != "\u{00B6}" {
                    Text(item.label)
                        .font(.system(size: fontSize - 1, weight: .medium))
                        .foregroundStyle(theme.purple.opacity(0.6))
                        .padding(.trailing, 6)
                }

                // Item text
                MarkdownText(item.text, fontSize: fontSize)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onHover { hoveredItem = $0 ? index : (hoveredItem == index ? nil : hoveredItem) }

            // Inline comment field
            if commentingOn == index {
                TextField("Leave a comment...", text: Binding(
                    get: { comments[index] ?? "" },
                    set: { comments[index] = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: fontSize - 1))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(theme.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.orange.opacity(0.4), lineWidth: 1)
                )
                .padding(.leading, 28)
                .padding(.trailing, 14)
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var activeCommentCount: Int {
        comments.values.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    private func approve() {
        guard let conversation else { return }
        resolved = true
        state.sendMessage("The plan looks good. Proceed with the implementation.", to: worktree, conversation: conversation)
    }

    private func requestChanges() {
        guard let conversation else { return }
        let activeComments = comments
            .sorted(by: { $0.key < $1.key })
            .filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }

        var feedback = "I have some feedback on the plan:\n\n"
        for (index, comment) in activeComments {
            let item = items[index]
            feedback += "- **\(item.label) \(item.text.prefix(60))\(item.text.count > 60 ? "..." : "")**: \(comment)\n"
        }
        feedback += "\nPlease revise the plan to address these comments."

        resolved = true
        state.sendMessage(feedback, to: worktree, conversation: conversation)
    }
}

// MARK: - Plan Item Parsing

struct PlanItem {
    let label: String  // "1.", "2.", "•", "-"
    let text: String

    static func parse(_ plan: String) -> [PlanItem] {
        var items: [PlanItem] = []
        let lines = plan.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Numbered list: "1. text" or "1) text"
            if let match = trimmed.range(of: #"^(\d+[.\)])\s+"#, options: .regularExpression) {
                let label = String(trimmed[match].trimmingCharacters(in: .whitespaces))
                    .replacingOccurrences(of: ")", with: ".")
                let numLabel = label.hasSuffix(".") ? label : label + "."
                var text = String(trimmed[match.upperBound...])
                // Collect continuation lines
                i += 1
                while i < lines.count {
                    let next = lines[i].trimmingCharacters(in: .whitespaces)
                    if next.isEmpty || next.range(of: #"^(\d+[.\)])\s+"#, options: .regularExpression) != nil
                        || next.hasPrefix("- ") || next.hasPrefix("* ") || next.hasPrefix("```") {
                        break
                    }
                    text += " " + next
                    i += 1
                }
                items.append(PlanItem(label: numLabel, text: text))
                continue
            }

            // Bullet list: "- text" or "* text"
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                var text = String(trimmed.dropFirst(2))
                i += 1
                while i < lines.count {
                    let next = lines[i].trimmingCharacters(in: .whitespaces)
                    if next.isEmpty || next.hasPrefix("- ") || next.hasPrefix("* ")
                        || next.range(of: #"^(\d+[.\)])\s+"#, options: .regularExpression) != nil
                        || next.hasPrefix("```") {
                        break
                    }
                    text += " " + next
                    i += 1
                }
                items.append(PlanItem(label: "\u{2022}", text: text))
                continue
            }

            // Non-empty paragraph lines become their own item
            if !trimmed.isEmpty && !trimmed.hasPrefix("```") {
                var text = trimmed
                i += 1
                while i < lines.count {
                    let next = lines[i].trimmingCharacters(in: .whitespaces)
                    if next.isEmpty || next.hasPrefix("- ") || next.hasPrefix("* ")
                        || next.range(of: #"^(\d+[.\)])\s+"#, options: .regularExpression) != nil
                        || next.hasPrefix("```") {
                        break
                    }
                    text += " " + next
                    i += 1
                }
                items.append(PlanItem(label: "\u{00B6}", text: text))
                continue
            }

            i += 1
        }
        return items
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
