import SwiftUI
import FlightCore

struct SearchMatch: Identifiable, Equatable {
    let id: String
    let sectionID: UUID
    let messageID: UUID
    let utf16Start: Int
    let utf16Length: Int
}

enum SearchScanner {
    /// Scans `sections` for case-insensitive occurrences of `query`. Only
    /// regular `.message` text is searched — tool/provision/setup groups
    /// are collapsed by default and plan/system bubbles render through
    /// custom views that don't participate in the highlight pipeline.
    static func scan(query: String, sections: [ChatSection]) -> [SearchMatch] {
        let trimmed = query
        guard !trimmed.isEmpty else { return [] }
        let lowerQuery = trimmed.lowercased()

        var matches: [SearchMatch] = []
        for section in sections {
            guard case .message(let message) = section else { continue }
            let text = message.textContent
            guard !text.isEmpty else { continue }
            let lowered = text.lowercased()
            var cursor = lowered.startIndex
            while cursor < lowered.endIndex,
                  let range = lowered.range(of: lowerQuery, range: cursor..<lowered.endIndex) {
                let ns = NSRange(range, in: lowered)
                matches.append(SearchMatch(
                    id: "\(message.id)-\(ns.location)",
                    sectionID: section.id,
                    messageID: message.id,
                    utf16Start: ns.location,
                    utf16Length: ns.length
                ))
                cursor = range.upperBound
            }
        }
        return matches
    }
}

struct SearchBar: View {
    @Bindable var conversation: Conversation
    let matchCount: Int
    let onNext: () -> Void
    let onPrev: () -> Void
    let onClose: () -> Void
    @Environment(\.theme) private var theme
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)

            TextField("Find in conversation", text: $conversation.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(theme.text)
                .focused($isFocused)
                .onSubmit { onNext() }
                .onKeyPress(.escape) {
                    onClose()
                    return .handled
                }

            if !conversation.searchQuery.isEmpty {
                Text(matchCount == 0 ? "No results" : "\(conversation.currentSearchMatchIndex + 1) of \(matchCount)")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                    .monospacedDigit()
            }

            Button(action: onPrev) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(matchCount == 0 ? theme.secondaryText.opacity(0.35) : theme.secondaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(matchCount == 0)
            .tooltip("Previous match (⇧⌘G)")

            Button(action: onNext) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(matchCount == 0 ? theme.secondaryText.opacity(0.35) : theme.secondaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(matchCount == 0)
            .tooltip("Next match (⌘G)")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tooltip("Close (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(theme.headerBackground)
        .onAppear { isFocused = true }
    }
}
