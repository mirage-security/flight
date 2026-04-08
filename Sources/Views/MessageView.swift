import SwiftUI

struct MessageView: View {
    let message: AgentMessage

    private var isUserMessage: Bool {
        message.role == .user
    }

    var body: some View {
        HStack {
            if isUserMessage { Spacer(minLength: 80) }

            Text(message.textContent)
                .font(.system(size: 14))
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    isUserMessage
                        ? Color.accentColor.opacity(0.12)
                        : Color(nsColor: .controlBackgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            isUserMessage ? Color.clear : Color(nsColor: .separatorColor),
                            lineWidth: 1
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))

            if !isUserMessage { Spacer(minLength: 80) }
        }
    }
}

struct ToolCallRow: View {
    let message: AgentMessage
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
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)

                    if message.isToolUse {
                        if case .toolUse(let name, _) = message.content {
                            Text(name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.orange)
                            if let desc = message.toolDescription {
                                Text(desc)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                    } else {
                        Text("Result")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        if !isExpanded {
                            Text(resultPreview)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(message.textContent)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    .padding(.leading, 16)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
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
