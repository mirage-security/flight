import SwiftUI

struct MarkdownText: View {
    let text: String
    let fontSize: Double
    @Environment(\.theme) private var theme

    init(_ text: String, fontSize: Double = 14) {
        self.text = text
        self.fontSize = fontSize
    }

    var body: some View {
        let blocks = parseBlocks(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    renderInline(text)
                case .codeBlock(let code, let lang):
                    codeBlockView(code: code, language: lang)
                case .bulletList(let items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\u{2022}")
                                    .foregroundStyle(theme.secondaryText)
                                renderInline(item)
                            }
                        }
                    }
                case .numberedList(let items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(i + 1).")
                                    .foregroundStyle(theme.secondaryText)
                                    .monospacedDigit()
                                renderInline(item)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Inline rendering

    private func renderInline(_ text: String) -> Text {
        let segments = parseInline(text)
        var result = Text("")
        for segment in segments {
            switch segment {
            case .plain(let str):
                result = result + Text(str)
                    .font(.system(size: fontSize))
                    .foregroundColor(theme.text)
            case .bold(let str):
                result = result + Text(str)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundColor(theme.text)
            case .code(let str):
                result = result + Text(str)
                    .font(.system(size: fontSize - 1, design: .monospaced))
                    .foregroundColor(theme.cyan)
            }
        }
        return result
    }

    // MARK: - Code block view

    private func codeBlockView(code: String, language: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let lang = language, !lang.isEmpty {
                Text(lang)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
            }
            Text(code)
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
    }

    // MARK: - Block parser

    enum Block {
        case paragraph(String)
        case codeBlock(String, String?) // code, language
        case bulletList([String])
        case numberedList([String])
    }

    private func parseBlocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Code block
            if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                i += 1 // skip closing ```
                blocks.append(.codeBlock(codeLines.joined(separator: "\n"), lang.isEmpty ? nil : lang))
                continue
            }

            // Bullet list
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                var items: [String] = []
                while i < lines.count && (lines[i].hasPrefix("- ") || lines[i].hasPrefix("* ")) {
                    items.append(String(lines[i].dropFirst(2)))
                    i += 1
                }
                blocks.append(.bulletList(items))
                continue
            }

            // Numbered list
            if let _ = line.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                var items: [String] = []
                while i < lines.count,
                      let range = lines[i].range(of: #"^\d+\.\s"#, options: .regularExpression) {
                    items.append(String(lines[i][range.upperBound...]))
                    i += 1
                }
                blocks.append(.numberedList(items))
                continue
            }

            // Empty line — skip
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                continue
            }

            // Paragraph — collect consecutive non-empty, non-special lines
            var paraLines: [String] = []
            while i < lines.count {
                let l = lines[i]
                if l.trimmingCharacters(in: .whitespaces).isEmpty ||
                   l.hasPrefix("```") ||
                   l.hasPrefix("- ") || l.hasPrefix("* ") ||
                   l.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                    break
                }
                paraLines.append(l)
                i += 1
            }
            if !paraLines.isEmpty {
                blocks.append(.paragraph(paraLines.joined(separator: " ")))
            }
        }

        return blocks
    }

    // MARK: - Inline parser

    enum InlineSegment {
        case plain(String)
        case bold(String)
        case code(String)
    }

    private func parseInline(_ text: String) -> [InlineSegment] {
        var segments: [InlineSegment] = []
        var remaining = text[...]

        while !remaining.isEmpty {
            // Inline code: `...`
            if remaining.hasPrefix("`") {
                let after = remaining.dropFirst()
                if let endIdx = after.firstIndex(of: "`") {
                    if !segments.isEmpty || remaining.startIndex != text.startIndex {
                        // flush nothing
                    }
                    let code = String(after[after.startIndex..<endIdx])
                    segments.append(.code(code))
                    remaining = after[after.index(after: endIdx)...]
                    continue
                }
            }

            // Bold: **...**
            if remaining.hasPrefix("**") {
                let after = remaining.dropFirst(2)
                if let range = after.range(of: "**") {
                    let bold = String(after[after.startIndex..<range.lowerBound])
                    segments.append(.bold(bold))
                    remaining = after[range.upperBound...]
                    continue
                }
            }

            // Plain text: consume until next ` or **
            var endIdx = remaining.endIndex
            for j in remaining.indices {
                if remaining[j] == "`" {
                    endIdx = j
                    break
                }
                if remaining[j] == "*",
                   remaining.index(after: j) < remaining.endIndex,
                   remaining[remaining.index(after: j)] == "*" {
                    endIdx = j
                    break
                }
            }
            let plain = String(remaining[remaining.startIndex..<endIdx])
            if !plain.isEmpty {
                segments.append(.plain(plain))
            }
            remaining = remaining[endIdx...]
        }

        return segments
    }
}
