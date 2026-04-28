import SwiftUI
import FlightCore

struct MessageView: View, Equatable {
    let message: AgentMessage
    var searchQuery: String = ""
    var currentMatchID: String? = nil
    @AppStorage("flightFontSize") private var fontSize: Double = 14
    @Environment(\.theme) private var theme

    static func == (lhs: MessageView, rhs: MessageView) -> Bool {
        lhs.message == rhs.message
            && lhs.searchQuery == rhs.searchQuery
            && lhs.currentMatchID == rhs.currentMatchID
    }

    private var isUserMessage: Bool {
        message.role == .user
    }

    private var hasMatches: Bool {
        guard !searchQuery.isEmpty else { return false }
        return message.textContent.range(of: searchQuery, options: .caseInsensitive) != nil
    }

    private var containsCurrentMatch: Bool {
        guard let id = currentMatchID else { return false }
        return id.hasPrefix("\(message.id)-")
    }

    @State private var isHovered = false

    var body: some View {
        HStack {
            if isUserMessage { Spacer(minLength: 40) }

            Group {
                if isUserMessage {
                    // The AttributedString path exists for search-highlight;
                    // when no search is active it allocates a fresh one each
                    // body call for nothing. Plain Text avoids the allocation
                    // and skips the SwiftUI _AppKitTextSelectionView witness
                    // value-copy that showed up in the layout-pass stackshots.
                    Group {
                        if searchQuery.isEmpty {
                            Text(message.textContent)
                        } else {
                            Text(displayedAttributedString)
                        }
                    }
                    .font(.system(size: fontSize))
                    .foregroundStyle(theme.text)
                    .textSelection(.enabled)
                } else if hasMatches {
                    Text(displayedAttributedString)
                        .font(.system(size: fontSize))
                        .foregroundStyle(theme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    MarkdownText(message.textContent, fontSize: fontSize)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isUserMessage ? theme.userBubble : theme.assistantBubble)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(bubbleStrokeColor, lineWidth: containsCurrentMatch ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .bottomTrailing) {
                if !isUserMessage {
                    CopyButton(text: message.textContent, theme: theme, visible: isHovered)
                        .padding(6)
                }
            }
            .frame(maxWidth: isUserMessage ? 520 : .infinity, alignment: isUserMessage ? .trailing : .leading)
        }
        .onHover { isHovered = $0 }
    }

    private var bubbleStrokeColor: Color {
        if containsCurrentMatch { return theme.orange }
        if isUserMessage { return .clear }
        return theme.border
    }

    /// Builds an `AttributedString` that highlights every case-insensitive
    /// occurrence of `searchQuery` in the message. The occurrence matching
    /// `currentMatchID` gets a stronger highlight than the rest. Falls back
    /// to plain text when no query is active.
    private var displayedAttributedString: AttributedString {
        var attr = AttributedString(message.textContent)
        guard !searchQuery.isEmpty else { return attr }

        let text = message.textContent
        let lowered = text.lowercased()
        let lowerQuery = searchQuery.lowercased()
        var cursor = lowered.startIndex
        while cursor < lowered.endIndex,
              let range = lowered.range(of: lowerQuery, range: cursor..<lowered.endIndex) {
            let ns = NSRange(range, in: lowered)
            let matchID = "\(message.id)-\(ns.location)"
            if let attrRange = Range(ns, in: attr) {
                let isCurrent = matchID == currentMatchID
                attr[attrRange].backgroundColor = isCurrent
                    ? Color.yellow
                    : Color.yellow.opacity(0.35)
                attr[attrRange].foregroundColor = Color.black
            }
            cursor = range.upperBound
        }
        return attr
    }
}

struct ToolCallRow: View {
    let message: AgentMessage
    @Environment(\.theme) private var theme
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 12)

                    if message.isToolUse {
                        if case .toolUse(let name, _) = message.content {
                            Text(name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(theme.orange)
                            if let preview = message.toolPreview, !preview.isEmpty {
                                Text(preview)
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                    } else {
                        Text("Result")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.secondaryText)
                        if !isExpanded {
                            Text(resultPreview)
                                .font(.system(size: 11))
                                .foregroundStyle(theme.secondaryText.opacity(0.6))
                                .lineLimit(1)
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(message.textContent)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    .padding(.leading, 16)
            }
        }
        .background(theme.toolGroupBackground.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var resultPreview: String {
        let text = message.textContent
        if text.count > 80 {
            return String(text.prefix(80)) + "..."
        }
        return text
    }
}
