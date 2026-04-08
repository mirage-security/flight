import SwiftUI

struct SidebarView: View {
    @Bindable var state: AppState

    var body: some View {
        List(selection: $state.selectedWorktreeID) {
            ForEach(state.projects) { project in
                Section {
                    ForEach(project.worktrees) { worktree in
                        WorktreeRow(worktree: worktree)
                            .tag(worktree.id)
                            .contextMenu {
                                worktreeContextMenu(worktree: worktree)
                            }
                    }
                } header: {
                    HStack {
                        Image(systemName: "folder")
                        Text(project.name)
                            .fontWeight(.semibold)
                        Spacer()
                    }
                    .contextMenu {
                        Button("Remove Project") {
                            state.removeProject(project)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button {
                    state.showingAddRepo = true
                } label: {
                    Label("Add Repo", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .onChange(of: state.selectedWorktreeID) { _, newID in
            if let newID {
                // Update selected project to match
                for project in state.projects {
                    if project.worktrees.contains(where: { $0.id == newID }) {
                        state.selectedProjectID = project.id
                        break
                    }
                }
            }
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

    var body: some View {
        HStack(spacing: 8) {
            Text(worktree.branch)
                .lineLimit(1)

            Spacer()

            if let ciStatus = worktree.ciStatus {
                CIBadge(conclusion: ciStatus.overall)
            }

            Text(statusLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(statusColor)
        }
    }

    private var statusLabel: String {
        if worktree.status == .creating { return "creating" }
        if worktree.agentBusy { return "working" }
        if worktree.agent?.isRunning == true { return "ready" }
        if worktree.status == .error { return "error" }
        return "idle"
    }

    private var statusColor: Color {
        if worktree.status == .creating { return .yellow }
        if worktree.agentBusy { return .orange }
        if worktree.agent?.isRunning == true { return .green }
        if worktree.status == .error { return .red }
        return .secondary
    }
}

struct CIBadge: View {
    let conclusion: CIConclusion

    var body: some View {
        Image(systemName: iconName)
            .foregroundColor(iconColor)
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
        case .success: return .green
        case .failure: return .red
        case .pending: return .yellow
        }
    }
}
