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
    @State private var attachedImages: [ImageAttachment] = []

    private var conversation: Conversation? {
        worktree.activeConversation
    }

    private var isAgentBusy: Bool {
        conversation?.agentBusy ?? false
    }

    private var planMode: Bool {
        conversation?.planMode ?? false
    }

    private var selectedModelID: String? {
        conversation?.modelID
    }

    private var selectedModelLabel: String? {
        guard let id = selectedModelID else { return nil }
        return ModelCatalog.label(forID: id)
    }

    private var selectedEffort: ConversationEffort? {
        conversation?.effort
    }

    var body: some View {
        VStack(spacing: 0) {
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

            // Input container: text area on top, controls row underneath.
            // Keeping the controls in a dedicated row (not overlaid) means a
            // growing message can never visually intersect them.
            VStack(alignment: .leading, spacing: 6) {
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

                HStack(spacing: 6) {
                    planModeButton
                    modelMenu
                    effortMenu

                    Spacer()

                    if isAgentBusy {
                        stopButton
                    } else {
                        sendButton
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(theme.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(theme.border, lineWidth: 1)
            )
            .disabled(isRemoteSessionActive)
            .opacity(isRemoteSessionActive ? 0.4 : 1)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 8)
        }
        .background(theme.headerBackground)
    }

    private var planModeButton: some View {
        Button {
            conversation?.planMode.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: planMode ? "map.fill" : "map")
                    .font(.system(size: 12))
                Text(planMode ? "Plan" : "Code")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(planMode ? theme.purple.opacity(0.15) : Color.clear)
            .foregroundStyle(planMode ? theme.purple : theme.secondaryText)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(planMode ? theme.purple.opacity(0.3) : theme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var sendButton: some View {
        Button {
            sendMessage()
        } label: {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 22))
        }
        .buttonStyle(.plain)
        .foregroundColor(canSend ? theme.accent : theme.secondaryText)
        .disabled(!canSend)
        .frame(width: 28, height: 28)
    }

    private var stopButton: some View {
        Button {
            if let conversation {
                state.interruptAgent(for: conversation, in: worktree)
            }
        } label: {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 22))
        }
        .buttonStyle(.plain)
        .foregroundColor(theme.red)
        .frame(width: 28, height: 28)
    }

    private var isRemoteSessionActive: Bool {
        conversation?.remoteSessionActive ?? false
    }

    private var modelMenu: some View {
        Menu {
            Button {
                conversation?.modelID = nil
            } label: {
                if selectedModelID == nil {
                    Label("Default", systemImage: "checkmark")
                } else {
                    Text("Default")
                }
            }
            Divider()
            ForEach(ModelCatalog.families) { family in
                Menu(family.label) {
                    ForEach(family.entries) { entry in
                        Button {
                            conversation?.modelID = entry.id
                        } label: {
                            if selectedModelID == entry.id {
                                Label(entry.label, systemImage: "checkmark")
                            } else {
                                Text(entry.label)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.system(size: 12))
                Text(selectedModelLabel ?? "Model")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(selectedModelID == nil ? theme.secondaryText : theme.text)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(theme.border, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var effortMenu: some View {
        Menu {
            Button {
                conversation?.effort = nil
            } label: {
                if selectedEffort == nil {
                    Label("Default", systemImage: "checkmark")
                } else {
                    Text("Default")
                }
            }
            Divider()
            ForEach(ConversationEffort.allCases) { level in
                Button {
                    conversation?.effort = level
                } label: {
                    if selectedEffort == level {
                        Label(level.label, systemImage: "checkmark")
                    } else {
                        Text(level.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .font(.system(size: 12))
                Text(selectedEffort?.label ?? "Effort")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(selectedEffort == nil ? theme.secondaryText : theme.text)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(theme.border, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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

        state.sendMessage(message, images: images, to: worktree, conversation: conversation)
    }
}
