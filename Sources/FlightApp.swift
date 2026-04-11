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
        NotificationService.requestPermission()
    }

    @State private var themeManager = ThemeManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
                .environment(\.theme, themeManager.currentColors)
                .preferredColorScheme(themeManager.currentColorScheme)
        }

        Settings {
            SettingsView(state: state)
        }
        .commands {
            // Cmd+N — New worktree (replaces default New Window)
            CommandGroup(replacing: .newItem) {
                Button("New Worktree") {
                    state.presentProjectPicker(
                        title: "New Worktree",
                        candidates: state.projects
                    ) { project in
                        state.selectedProjectID = project.id
                        Task { await state.createWorktreeWithRandomName() }
                    }
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(state.projects.isEmpty)

                Button("New Remote Worktree...") {
                    state.presentProjectPicker(
                        title: "New Remote Worktree",
                        candidates: state.projectsWithRemoteMode
                    ) { project in
                        state.selectedProjectID = project.id
                        state.showingRemotePrompt = true
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

}
