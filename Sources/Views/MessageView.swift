import SwiftUI

struct MessageView: View {
    let message: AgentMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if message.isToolUse {
                    toolUseView
                } else if message.isToolResult {
                    toolResultView
                } else {
                    textView
                }
            }

            if message.role == .assistant { Spacer(minLength: 60) }
        }
    }

    private var textView: some View {
        Text(message.textContent)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                message.role == .user
                    ? Color.accentColor.opacity(0.15)
                    : Color(nsColor: .controlBackgroundColor)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var toolUseView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if case .toolUse(let name, _) = message.content {
                HStack(spacing: 4) {
                    Image(systemName: "wrench")
                        .font(.caption2)
                    Text(name)
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundStyle(.secondary)
            }
            Text(message.textContent)
                .font(.caption)
                .textSelection(.enabled)
                .lineLimit(6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var toolResultView: some View {
        Text(message.textContent)
            .font(.caption)
            .textSelection(.enabled)
            .lineLimit(10)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.green.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
