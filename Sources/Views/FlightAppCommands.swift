import SwiftUI
import AppKit

/// All keyboard-driven menu commands that the @main executable installs
/// on the Scene. Lives in the FlightApp library (rather than alongside
/// @main) so unit tests and tooling can `import FlightApp` without
/// pulling in the executable target — and so the executable shim is
/// tiny and free of the menu-wiring detail.
public struct FlightAppCommands: Commands {
    @Bindable var state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesMenuItem(controller: .shared)
        }

        // Cmd+N — New worktree (replaces default New Window)
        CommandGroup(replacing: .newItem) {
            Button("New Worktree") {
                state.presentProjectPicker(
                    title: "New Worktree",
                    candidates: state.projectsWithLocalClone
                ) { project in
                    state.selectedProjectID = project.id
                    Task { await state.createWorktreeWithRandomName() }
                }
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(state.projectsWithLocalClone.isEmpty)

            Button("New Remote Worktree") {
                state.presentProjectPicker(
                    title: "New Remote Worktree",
                    candidates: state.projectsWithRemoteMode
                ) { project in
                    state.selectedProjectID = project.id
                    state.createRemoteWorktree()
                }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(state.projectsWithRemoteMode.isEmpty)

            // Cmd+T — New tab in current worktree
            Button("New Tab") {
                if let wt = state.selectedWorktree {
                    state.addConversation(to: wt)
                }
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(state.selectedWorktree == nil)
        }

        // Cmd+F / Cmd+G / Cmd+Shift+G — Find in conversation
        CommandGroup(after: .textEditing) {
            Button("Find…") {
                if let conv = state.selectedWorktree?.activeConversation {
                    conv.searchActive = true
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(state.selectedWorktree?.activeConversation == nil)

            Button("Find Next") {
                if let conv = state.selectedWorktree?.activeConversation, conv.searchActive {
                    let matches = SearchScanner.scan(query: conv.searchQuery, sections: conv.sections)
                    guard !matches.isEmpty else { return }
                    conv.currentSearchMatchIndex = (conv.currentSearchMatchIndex + 1) % matches.count
                }
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(state.selectedWorktree?.activeConversation?.searchActive != true)

            Button("Find Previous") {
                if let conv = state.selectedWorktree?.activeConversation, conv.searchActive {
                    let matches = SearchScanner.scan(query: conv.searchQuery, sections: conv.sections)
                    guard !matches.isEmpty else { return }
                    let count = matches.count
                    conv.currentSearchMatchIndex = ((conv.currentSearchMatchIndex - 1) % count + count) % count
                }
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(state.selectedWorktree?.activeConversation?.searchActive != true)
        }

        // Custom commands
        CommandMenu("Worktree") {
            // Cmd+W — Close tab if multiple, otherwise close window
            Button("Close Tab") {
                if let wt = state.selectedWorktree, wt.conversations.count > 1,
                   let conv = wt.activeConversation {
                    state.removeConversation(conv, from: wt)
                } else {
                    NSApplication.shared.keyWindow?.close()
                }
            }
            .keyboardShortcut("w", modifiers: .command)

            Button("Remove Worktree") {
                if let wt = state.selectedWorktree {
                    Task { await state.removeWorktree(wt) }
                }
            }
            .disabled(state.selectedWorktree == nil)

            Divider()

            // Cmd+Enter — Restart agent
            Button("Restart Agent") {
                if let wt = state.selectedWorktree, let conv = wt.activeConversation {
                    state.restartAgent(for: wt, conversation: conv)
                }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(state.selectedWorktree == nil)

            // Cmd+. — Kill agent
            Button("Stop Agent") {
                if let wt = state.selectedWorktree, let conv = wt.activeConversation {
                    state.stopAgent(for: conv, in: wt)
                }
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(state.selectedWorktree == nil)

            // Cmd+K — Clear chat
            Button("Clear Chat") {
                if let wt = state.selectedWorktree, let conv = wt.activeConversation {
                    state.clearChat(for: conv)
                }
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(state.selectedWorktree == nil)

            // Cmd+Shift+R — Open interactive remote session in Terminal
            Button("Open Remote Session") {
                if let wt = state.selectedWorktree {
                    state.openRemoteSession(for: wt)
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(state.selectedWorktree?.isRemote != true)

            Divider()

            // Cmd+1-9 — Switch worktrees
            ForEach(0..<9, id: \.self) { index in
                Button("Worktree \(index + 1)") {
                    state.selectWorktreeByIndex(index)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
    }
}
