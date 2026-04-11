import SwiftUI
import Textual

struct MarkdownText: View {
    let text: String
    let fontSize: Double
    @Environment(\.theme) private var theme

    init(_ text: String, fontSize: Double = 14) {
        self.text = text
        self.fontSize = fontSize
    }

    var body: some View {
        StructuredText(markdown: text)
            .font(.system(size: fontSize))
            .foregroundStyle(theme.text)
            .textual.textSelection(.enabled)
            .textual.inlineStyle(
                InlineStyle()
                    .code(.foregroundColor(theme.cyan), .font(.system(size: fontSize - 1, design: .monospaced)))
                    .strong(.foregroundColor(theme.text))
                    .emphasis(.foregroundColor(theme.text))
            )
            .textual.codeBlockStyle(FlightCodeBlockStyle(fontSize: fontSize, theme: theme))
            .tint(theme.accent)
    }
}

// MARK: - Code Block Style

private struct FlightCodeBlockStyle: StructuredText.CodeBlockStyle {
    let fontSize: Double
    let theme: ThemeColors

    func makeBody(configuration: Configuration) -> some View {
        FlightCodeBlockView(
            configuration: configuration,
            fontSize: fontSize,
            theme: theme
        )
    }
}

private struct FlightCodeBlockView: View {
    let configuration: StructuredText.CodeBlockStyleConfiguration
    let fontSize: Double
    let theme: ThemeColors
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let lang = configuration.languageHint, !lang.isEmpty {
                Text(lang)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
            }
            configuration.label
                .font(.system(size: fontSize - 1, design: .monospaced))
                .foregroundStyle(theme.text)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(theme.border, lineWidth: 1)
        )
        .overlay(alignment: .bottomTrailing) {
            CopyButton(theme: theme, visible: isHovered) {
                configuration.codeBlock.copyToPasteboard()
            }
            .padding(6)
        }
        .onHover { isHovered = $0 }
    }
}

// MARK: - Copy Button

struct CopyButton: View {
    let theme: ThemeColors
    var visible: Bool = true
    var text: String? = nil
    var onCopy: (() -> Void)? = nil
    @State private var copied = false

    init(text: String, theme: ThemeColors, visible: Bool = true) {
        self.text = text
        self.theme = theme
        self.visible = visible
    }

    init(theme: ThemeColors, visible: Bool = true, action: @escaping () -> Void) {
        self.theme = theme
        self.visible = visible
        self.onCopy = action
    }

    var body: some View {
        Button {
            if let onCopy {
                onCopy()
            } else if let text {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(copied ? theme.green : theme.secondaryText)
                .frame(width: 24, height: 24)
                .background(theme.background)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .opacity(visible || copied ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: visible)
        .animation(.easeInOut(duration: 0.15), value: copied)
    }
}
