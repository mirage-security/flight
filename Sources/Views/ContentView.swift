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

    var body: some View {
        VStack(spacing: 16) {
            Text("New Remote Worktree")
                .font(.headline)
                .foregroundStyle(theme.text)

            Text("What should the agent work on?")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)

            TextEditor(text: $state.remoteInitialPrompt)
                .font(.system(size: 13))
                .foregroundStyle(theme.text)
                .scrollContentBackground(.hidden)
                .frame(width: 450, height: 120)
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

            HStack {
                Text("Cmd+Enter to launch")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .foregroundStyle(theme.secondaryText)
                Button {
                    launch()
                } label: {
                    Text("Launch")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(theme.accent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(state.remoteInitialPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .background(theme.background)
        .onAppear { isFocused = true }
    }

    private func launch() {
        let prompt = state.remoteInitialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        state.remoteInitialPrompt = ""
        dismiss()
        state.createRemoteWorktree(initialPrompt: prompt)
    }
}
