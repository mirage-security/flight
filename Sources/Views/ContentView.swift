import SwiftUI

struct ContentView: View {
    @Bindable var state: AppState
    @Environment(\.theme) private var theme

    private var selectedWorktree: Worktree? {
        guard let id = state.selectedWorktreeID else { return nil }
        for project in state.projects {
            if let wt = project.worktrees.first(where: { $0.id == id }) {
                return wt
            }
        }
        return nil
    }

    var body: some View {
        HSplitView {
            SidebarView(state: state)
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
                .background(theme.sidebar)

            Group {
                if let worktree = selectedWorktree {
                    ChatView(state: state, worktree: worktree)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 40))
                            .foregroundStyle(theme.secondaryText)
                        Text("No Worktree Selected")
                            .font(.title2)
                            .foregroundStyle(theme.text)
                        Text("Add a repo and create a worktree to get started.")
                            .font(.callout)
                            .foregroundStyle(theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.background)
                }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .alert("Error", isPresented: $state.showingError) {
            Button("OK") {}
        } message: {
            Text(state.errorMessage ?? "An unknown error occurred.")
        }
        .fileImporter(
            isPresented: $state.showingAddRepo,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                state.addProject(path: url.path)
            }
        }
        .sheet(isPresented: $state.showingRemotePrompt) {
            RemotePromptSheet(state: state)
                .environment(\.theme, theme)
        }
    }
}

struct RemotePromptSheet: View {
    @Bindable var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @FocusState private var isFocused: Bool
    @State private var runningWorkspaces: [String] = []
    @State private var selectedWorkspace: String? = nil
    @State private var loadingWorkspaces = true

    private var promptIsEmpty: Bool {
        state.remoteInitialPrompt.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Remote Worktree")
                .font(.headline)
                .foregroundStyle(theme.text)

            // Running workspaces section
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Workspace")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                    Spacer()
                    if loadingWorkspaces {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }

                HStack(spacing: 6) {
                    // "New" option
                    workspaceChip(label: "New", isSelected: selectedWorkspace == nil) {
                        selectedWorkspace = nil
                    }

                    ForEach(runningWorkspaces, id: \.self) { ws in
                        workspaceChip(label: ws, isSelected: selectedWorkspace == ws) {
                            selectedWorkspace = ws
                        }
                    }
                }
            }
            .frame(width: 450, alignment: .leading)

            // Prompt
            VStack(alignment: .leading, spacing: 4) {
                Text("What should the agent work on?")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondaryText)

                TextEditor(text: $state.remoteInitialPrompt)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.text)
                    .scrollContentBackground(.hidden)
                    .frame(width: 450, height: 100)
                    .padding(8)
                    .background(theme.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.border, lineWidth: 1)
                    )
                    .focused($isFocused)
                    .onKeyPress(.return, phases: .down) { keyPress in
                        if keyPress.modifiers.contains(.command) {
                            launch()
                            return .handled
                        }
                        return .ignored
                    }
            }

            HStack {
                Text("Cmd+Enter to \(selectedWorkspace == nil ? "launch" : "connect")")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .foregroundStyle(theme.secondaryText)
                Button {
                    launch()
                } label: {
                    Text(selectedWorkspace == nil ? "Launch" : "Connect")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(theme.accent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(promptIsEmpty)
            }
        }
        .padding(24)
        .background(theme.background)
        .onAppear {
            isFocused = true
            Task {
                runningWorkspaces = await state.listRunningWorkspaces()
                loadingWorkspaces = false
            }
        }
    }

    private func workspaceChip(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : theme.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? theme.accent : theme.inputBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.clear : theme.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func launch() {
        let prompt = state.remoteInitialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        state.remoteInitialPrompt = ""
        dismiss()

        if let workspace = selectedWorkspace {
            state.attachToWorkspace(workspaceName: workspace, initialPrompt: prompt)
        } else {
            state.createRemoteWorktree(initialPrompt: prompt)
        }
    }
}
