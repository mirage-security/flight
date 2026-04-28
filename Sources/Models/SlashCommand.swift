import Foundation

/// A Claude Code slash command surfaced in the input-bar autocomplete menu.
///
/// The list is hardcoded — the `claude` CLI doesn't expose a way to enumerate
/// available commands, and this catalog is small enough that a static list is
/// simpler than parsing help output. When commands change upstream, edit
/// `SlashCommandCatalog.all`.
struct SlashCommand: Identifiable, Hashable {
    let name: String
    let description: String

    var id: String { name }
    var trigger: String { "/" + name }
}

enum SlashCommandCatalog {
    static let all: [SlashCommand] = [
        SlashCommand(name: "help", description: "Show available commands"),
        SlashCommand(name: "clear", description: "Clear conversation history"),
        SlashCommand(name: "compact", description: "Compact conversation context"),
        SlashCommand(name: "cost", description: "Show token usage and cost"),
        SlashCommand(name: "model", description: "Change the active model (e.g. /model opus)"),
        SlashCommand(name: "init", description: "Initialize CLAUDE.md for this project"),
        SlashCommand(name: "review", description: "Review a pull request"),
        SlashCommand(name: "security-review", description: "Security review of pending changes"),
        SlashCommand(name: "status", description: "Show session status"),
        SlashCommand(name: "doctor", description: "Run diagnostics"),
        SlashCommand(name: "resume", description: "Resume a previous session"),
        SlashCommand(name: "config", description: "Open settings"),
        SlashCommand(name: "memory", description: "Edit memory files"),
        SlashCommand(name: "agents", description: "Manage subagents"),
        SlashCommand(name: "mcp", description: "Manage MCP servers"),
        SlashCommand(name: "permissions", description: "Manage permissions"),
        SlashCommand(name: "hooks", description: "Manage hooks"),
        SlashCommand(name: "pr-comments", description: "Show PR comments"),
        SlashCommand(name: "bug", description: "Report a bug"),
        SlashCommand(name: "release-notes", description: "Show release notes"),
        SlashCommand(name: "vim", description: "Toggle vim mode"),
        SlashCommand(name: "ide", description: "Manage IDE integration"),
        SlashCommand(name: "login", description: "Sign in to Claude"),
        SlashCommand(name: "logout", description: "Sign out of Claude"),
    ]

    /// Fallback recents when the user has no history yet.
    static let defaultRecents: [String] = [
        "help", "clear", "compact", "model", "review", "init", "cost", "status"
    ]

    static func command(named name: String) -> SlashCommand? {
        all.first { $0.name == name }
    }
}
