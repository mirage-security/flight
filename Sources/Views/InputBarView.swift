import SwiftUI

struct InputBarView: View {
    @Bindable var state: AppState
    let worktree: Worktree
    @AppStorage("flightFontSize") private var fontSize: Double = 14
    @Environment(\.theme) private var theme
    @State private var messageText = ""
    @State private var planMode = false
    @FocusState private var isFocused: Bool

    private var isAgentBusy: Bool {
        worktree.agentBusy
    }

    var body: some View {
        VStack(spacing: 0) {
            // Plan mode bar
            HStack(spacing: 6) {
                Button {
                    planMode.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: planMode ? "map.fill" : "map")
                            .font(.system(size: 11))
                        Text(planMode ? "Plan" : "Code")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(planMode ? Color.purple.opacity(0.15) : theme.inputBackground)
                    .foregroundStyle(planMode ? .purple : theme.secondaryText)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(planMode ? Color.purple.opacity(0.3) : theme.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Spacer()

                if isAgentBusy {
                    Button {
                        state.interruptAgent(for: worktree)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 8))
                            Text("Stop")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.red.opacity(0.15))
                        .foregroundStyle(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)

            // Input row
            HStack(spacing: 8) {
                TextEditor(text: $messageText)
                    .font(.system(size: fontSize))
                    .foregroundStyle(theme.text)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 20, maxHeight: 100)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(theme.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(theme.border, lineWidth: 1)
                    )
                    .focused($isFocused)
                    .onKeyPress(.return) {
                        sendMessage()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        if isAgentBusy {
                            state.interruptAgent(for: worktree)
                            return .handled
                        }
                        return .ignored
                    }

                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundColor(messageText.isEmpty ? theme.secondaryText : theme.accent)
                .disabled(messageText.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(theme.headerBackground)
        .onAppear { isFocused = true }
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messageText = ""

        if planMode {
            state.sendMessage("/plan \(text)", to: worktree)
        } else {
            state.sendMessage(text, to: worktree)
        }
    }
}
