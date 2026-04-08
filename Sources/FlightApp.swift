import SwiftUI
import AppKit

@main
struct FlightApp: App {
    @State private var state = AppState()

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [state] _ in
            state.stopAllAgents()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
        }
        .commands {
            // Cmd+N — New worktree (replaces default New Window)
            CommandGroup(replacing: .newItem) {
                Button("New Worktree") {
                    Task { await state.createWorktreeWithRandomName() }
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(state.projects.isEmpty)
            }

            // Custom commands
            CommandMenu("Worktree") {
                // Cmd+W — Remove current worktree
                Button("Remove Worktree") {
                    if let wt = state.selectedWorktree {
                        Task { await state.removeWorktree(wt) }
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(state.selectedWorktree == nil)

                Divider()

                // Cmd+Enter — Restart agent
                Button("Restart Agent") {
                    if let wt = state.selectedWorktree {
                        state.restartAgent(for: wt)
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(state.selectedWorktree == nil)

                // Cmd+. — Kill agent
                Button("Stop Agent") {
                    if let wt = state.selectedWorktree {
                        state.stopAgent(for: wt)
                    }
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(state.selectedWorktree == nil)

                // Cmd+K — Clear chat
                Button("Clear Chat") {
                    if let wt = state.selectedWorktree {
                        state.clearChat(for: wt)
                    }
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(state.selectedWorktree == nil)

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
}
