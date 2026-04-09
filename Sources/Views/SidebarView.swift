import SwiftUI

struct SidebarView: View {
    @Bindable var state: AppState
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(state.projects) { project in
                        // Project header
                        HStack {
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                            Text(project.name)
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(theme.secondaryText)
                                .onTapGesture {
                                    state.selectedProjectID = project.id
                                    if NSEvent.modifierFlags.contains(.shift) && project.hasRemoteMode {
                                        state.showingRemotePrompt = true
                                    } else {
                                        Task { await state.createWorktreeWithRandomName() }
                                    }
                                }
                        }
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .padding(.top, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            state.selectedProjectID = project.id
                        }
                        .contextMenu {
                            Button("Remove Project") {
                                state.removeProject(project)
                            }
                        }

                        // Worktrees
                        ForEach(project.worktrees) { worktree in
                            WorktreeRow(worktree: worktree, isSelected: worktree.id == state.selectedWorktreeID)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    state.selectedWorktreeID = worktree.id
                                    state.selectedProjectID = project.id
                                    if worktree.prNumber != nil {
                                        Task { await state.checkCI(for: worktree) }
                                    }
                                }
                                .contextMenu {
                                    worktreeContextMenu(worktree: worktree)
                                }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()

            Button {
                state.showingAddRepo = true
            } label: {
                Label("Add Repo", systemImage: "plus")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func worktreeContextMenu(worktree: Worktree) -> some View {
        if worktree.prNumber == nil,
           let project = state.projects.first(where: { $0.worktrees.contains { $0.id == worktree.id } }),
           project.forgeConfig != nil {
            Button("Create PR") {
                Task { await state.createPR(for: worktree) }
            }
        }
        if let conv = worktree.activeConversation {
            if conv.agent?.isRunning == true {
                Button("Stop Agent") {
                    state.stopAgent(for: conv, in: worktree)
                }
            } else {
                Button("Start Agent") {
                    try? state.startAgent(for: worktree, conversation: conv)
                }
            }
            Button("Restart Agent") {
                state.restartAgent(for: worktree, conversation: conv)
            }
        }
        if worktree.isRemote && worktree.workspaceName != nil {
            Button("Open Remote Session") {
                state.openRemoteSession(for: worktree)
            }
        }
        Divider()
        Button("New Tab") {
            state.addConversation(to: worktree)
        }
        Divider()
        Button("Remove Worktree", role: .destructive) {
            Task { await state.removeWorktree(worktree) }
        }
    }
}

struct WorktreeRow: View {
    let worktree: Worktree
    var isSelected: Bool = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            if worktree.isRemote {
                Image(systemName: "cloud")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.secondaryText)
            }

            Text(worktree.branch)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? .white : theme.text)
                .lineLimit(1)

            Spacer()

            if worktree.prNumber != nil {
                prBadge
            }

            Text(statusLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isSelected ? .white.opacity(0.7) : statusColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            isSelected
                ? RoundedRectangle(cornerRadius: 6).fill(theme.accent)
                : RoundedRectangle(cornerRadius: 6).fill(Color.clear)
        )
        .padding(.horizontal, 4)
    }

    private var statusLabel: String {
        if worktree.status == .deleting { return "deleting" }
        if worktree.status == .creating { return "creating" }
        if worktree.anyAgentBusy { return "working" }
        if worktree.anyAgentRunning { return "ready" }
        if worktree.status == .error { return "error" }
        return "idle"
    }

    private var statusColor: Color {
        if worktree.status == .deleting { return theme.red }
        if worktree.status == .creating { return theme.yellow }
        if worktree.anyAgentBusy { return theme.orange }
        if worktree.anyAgentRunning { return theme.green }
        if worktree.status == .error { return theme.red }
        return theme.secondaryText
    }

    /// Single compact badge in the sidebar showing the worst PR status
    private var prBadge: some View {
        let icon: String
        let color: Color
        let tooltip: String

        // Priority: CI failure > changes requested > review required > CI pending > all good
        if worktree.ciStatus?.overall == .failure {
            let names = worktree.ciStatus?.failedCheckNames ?? []
            icon = "xmark.circle.fill"
            color = theme.red
            tooltip = "CI failing: \(names.joined(separator: ", "))"
        } else if worktree.prStatus?.reviewDecision == "CHANGES_REQUESTED" {
            let names = worktree.prStatus?.changesRequestedBy ?? []
            icon = "exclamationmark.triangle.fill"
            color = theme.orange
            tooltip = "Changes requested by \(names.joined(separator: ", "))"
        } else if worktree.prStatus?.reviewDecision == "REVIEW_REQUIRED" {
            icon = "eye.fill"
            color = theme.yellow
            tooltip = "Review required"
        } else if worktree.ciStatus?.overall == .pending {
            icon = "circle.dotted"
            color = theme.yellow
            tooltip = "CI running"
        } else if worktree.ciStatus?.overall == .success,
                  worktree.prStatus?.reviewDecision == "APPROVED" {
            icon = "checkmark.circle.fill"
            color = theme.green
            tooltip = "Ready to merge"
        } else if worktree.ciStatus?.overall == .success {
            icon = "checkmark.circle.fill"
            color = theme.green
            tooltip = "CI passing"
        } else {
            icon = "circle.dotted"
            color = theme.secondaryText
            tooltip = "PR #\(worktree.prNumber ?? 0)"
        }

        return Image(systemName: icon)
            .foregroundStyle(color)
            .font(.caption)
            .help(tooltip)
    }
}
