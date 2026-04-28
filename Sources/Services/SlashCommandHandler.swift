import Foundation

/// Intercepts Flight-native slash commands before they hit the agent.
///
/// `claude --input-format stream-json` does NOT interpret slash commands —
/// any `/foo` typed by the user is forwarded to the model as literal text.
/// So commands that map to in-app state (like changing the model) have to
/// be handled here. Commands the catalog still surfaces but isn't listed
/// below (e.g. `/init`, `/review`) intentionally pass through: Claude
/// recognizes those as skill triggers from the system prompt.
@MainActor
enum SlashCommandHandler {
    enum Result {
        /// Not a Flight-native command — let the caller forward it to the agent.
        case forward
        /// Handled locally; caller should clear the input.
        case handled
        /// User-facing error; caller should surface `message` and leave the input intact.
        case error(_ message: String)
    }

    static func handle(_ text: String, conversation: Conversation) -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return .forward }

        let body = trimmed.dropFirst()
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        guard let name = parts.first else { return .forward }
        let args = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""

        switch name {
        case "model":
            return handleModel(args, conversation: conversation)
        default:
            return .forward
        }
    }

    // MARK: - /model

    private static func handleModel(_ args: String, conversation: Conversation) -> Result {
        if args.isEmpty {
            conversation.modelID = nil
            return .handled
        }
        if let entry = resolveModel(args) {
            conversation.modelID = entry.id
            return .handled
        }
        return .error("Unknown model: \"\(args)\". Try: \(suggestedModelHints()).")
    }

    /// Resolves a free-form model argument against `ModelCatalog`. Tries, in
    /// order: exact id, case-insensitive id/label, family alias
    /// (`opus`/`sonnet`/`haiku`), then id suffix.
    static func resolveModel(_ query: String) -> ModelCatalog.Entry? {
        let raw = query.trimmingCharacters(in: .whitespaces)
        if let e = ModelCatalog.entry(forID: raw) { return e }

        let q = raw.lowercased()

        for family in ModelCatalog.families {
            for entry in family.entries {
                if entry.id.lowercased() == q || entry.label.lowercased() == q {
                    return entry
                }
            }
        }

        if let family = ModelCatalog.families.first(where: { $0.id == q || $0.label.lowercased() == q }) {
            return family.entries.first
        }

        for family in ModelCatalog.families {
            for entry in family.entries {
                if entry.id.lowercased().hasSuffix(q) { return entry }
            }
        }

        return nil
    }

    private static func suggestedModelHints() -> String {
        ModelCatalog.families.compactMap { $0.entries.first?.label }.joined(separator: ", ")
    }
}
