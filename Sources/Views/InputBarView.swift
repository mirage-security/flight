import SwiftUI

struct ImageAttachment: Identifiable {
    let id = UUID()
    let image: NSImage
    let pngData: Data
}

struct InputBarView: View {
    @Bindable var state: AppState
    let worktree: Worktree
    @AppStorage("flightFontSize") private var fontSize: Double = 14
    @Environment(\.theme) private var theme
    @State private var messageText = ""
    @State private var planMode = false
    @State private var attachedImages: [ImageAttachment] = []

    private var conversation: Conversation? {
        worktree.activeConversation
    }

    private var isAgentBusy: Bool {
        conversation?.agentBusy ?? false
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
                    .background(planMode ? theme.purple.opacity(0.15) : theme.inputBackground)
                    .foregroundStyle(planMode ? theme.purple : theme.secondaryText)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(planMode ? theme.purple.opacity(0.3) : theme.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Spacer()

                if isAgentBusy, let conversation {
                    Button {
                        state.interruptAgent(for: conversation, in: worktree)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 8))
                            Text("Stop")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(theme.red.opacity(0.15))
                        .foregroundStyle(theme.red)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 4)

            // Image attachment previews
            if !attachedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachedImages) { attachment in
                            ZStack(alignment: .topTrailing) {
                                Image(nsImage: attachment.image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 80)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(theme.border, lineWidth: 1)
                                    )

                                Button {
                                    attachedImages.removeAll { $0.id == attachment.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.white)
                                        .background(Circle().fill(.black.opacity(0.6)))
                                }
                                .buttonStyle(.plain)
                                .offset(x: 4, y: -4)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                }
            }

            // Input row
            HStack(spacing: 8) {
                PasteableTextView(
                    text: $messageText,
                    font: .systemFont(ofSize: CGFloat(fontSize)),
                    textColor: NSColor(theme.text),
                    onReturn: { sendMessage() },
                    onEscape: {
                        if isAgentBusy, let conversation {
                            state.interruptAgent(for: conversation, in: worktree)
                        }
                    },
                    onImagePaste: { image, data in
                        attachedImages.append(ImageAttachment(image: image, pngData: data))
                    }
                )
                .frame(minHeight: 40, maxHeight: 150)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(theme.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.border, lineWidth: 1)
                )
                .disabled(isRemoteSessionActive)
                .opacity(isRemoteSessionActive ? 0.4 : 1)

                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundColor(canSend ? theme.accent : theme.secondaryText)
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(theme.headerBackground)
    }

    private var isRemoteSessionActive: Bool {
        conversation?.remoteSessionActive ?? false
    }

    private var canSend: Bool {
        !isRemoteSessionActive &&
        (!messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedImages.isEmpty)
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedImages.isEmpty else { return }
        guard let conversation else { return }

        let images = attachedImages.map { $0.pngData }
        messageText = ""
        attachedImages.removeAll()

        let message = text.isEmpty ? "What's in this image?" : text

        if planMode {
            state.sendMessage("/plan \(message)", images: images, to: worktree, conversation: conversation)
        } else {
            state.sendMessage(message, images: images, to: worktree, conversation: conversation)
        }
    }
}
