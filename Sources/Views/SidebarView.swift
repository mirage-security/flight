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
                        }
                        .foregroundStyle(theme.secondaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .padding(.top, 4)
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
        if worktree.prNumber == nil {
            Button("Create PR") {
                Task { await state.createPR(for: worktree) }
            }
        }
        if worktree.agent?.isRunning == true {
            Button("Stop Agent") {
                state.stopAgent(for: worktree)
            }
        } else {
            Button("Start Agent") {
                try? state.startAgent(for: worktree)
            }
        }
        Button("Restart Agent") {
            state.restartAgent(for: worktree)
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

            if let ciStatus = worktree.ciStatus {
                CIBadge(conclusion: ciStatus.overall)
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
        if worktree.status == .creating { return "creating" }
        if worktree.agentBusy { return "working" }
        if worktree.agent?.isRunning == true { return "ready" }
        if worktree.status == .error { return "error" }
        return "idle"
    }

    private var statusColor: Color {
        if worktree.status == .creating { return theme.yellow }
        if worktree.agentBusy { return theme.orange }
        if worktree.agent?.isRunning == true { return theme.green }
        if worktree.status == .error { return theme.red }
        return theme.secondaryText
    }
}

struct CIBadge: View {
    let conclusion: CIConclusion
    @Environment(\.theme) private var theme

    var body: some View {
        Image(systemName: iconName)
            .foregroundStyle(iconColor)
            .font(.caption)
    }

    private var iconName: String {
        switch conclusion {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        case .pending: return "circle.dotted"
        }
    }

    private var iconColor: Color {
        switch conclusion {
        case .success: return theme.green
        case .failure: return theme.red
        case .pending: return theme.yellow
        }
    }
}
