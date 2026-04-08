import SwiftUI

struct InputBarView: View {
    @Bindable var state: AppState
    let worktree: Worktree
    @State private var messageText = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextEditor(text: $messageText)
                .font(.body)
                .frame(minHeight: 20, maxHeight: 100)
                .fixedSize(horizontal: false, vertical: true)
                .focused($isFocused)
                .onKeyPress(.return) {
                    sendMessage()
                    return .handled
                }

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundColor(messageText.isEmpty ? .gray : .accentColor)
            .disabled(messageText.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear { isFocused = true }
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messageText = ""
        state.sendMessage(text, to: worktree)
    }
}
