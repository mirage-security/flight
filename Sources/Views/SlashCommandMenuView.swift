import SwiftUI

struct SlashCommandMenuView: View {
    let commands: [SlashCommand]
    let selectedIndex: Int
    /// Bumped by the parent on keyboard navigation. The menu auto-scrolls
    /// to the selected row when this changes — but NOT when the selection
    /// changes from hover, which would create a scroll/hover feedback loop
    /// (scroll moves a new row under the cursor, hover updates selection,
    /// scroll again, ad infinitum).
    let keyboardNonce: Int
    let onSelect: (SlashCommand) -> Void
    let onHover: (Int) -> Void

    @Environment(\.theme) private var theme

    /// Caps the popup height so it doesn't eat the whole window. Roughly
    /// 8 rows tall before the rest scrolls.
    private let maxHeight: CGFloat = 240

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        row(for: command, isSelected: index == selectedIndex)
                            .id(command.id)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(command) }
                            .onHover { hovering in
                                if hovering { onHover(index) }
                            }
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: maxHeight)
            .onChange(of: keyboardNonce) { _, _ in
                guard commands.indices.contains(selectedIndex) else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(commands[selectedIndex].id, anchor: .center)
                }
            }
        }
        .background(theme.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
    }

    private func row(for command: SlashCommand, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Text(command.trigger)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.text)
            Text(command.description)
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isSelected ? theme.accent.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
