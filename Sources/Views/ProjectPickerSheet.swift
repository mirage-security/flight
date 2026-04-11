import SwiftUI

/// Command-palette style modal for picking which project to act on.
/// Used by Cmd+N (new local worktree) and Cmd+Shift+N (new remote worktree)
/// when more than one project is a valid target. Single-candidate cases are
/// short-circuited by `AppState.presentProjectPicker` and never reach here.
struct ProjectPickerSheet: View {
    @Bindable var state: AppState
    @Environment(\.theme) private var theme

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var fieldFocused: Bool

    private var filtered: [Project] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return state.projectPickerCandidates }
        return state.projectPickerCandidates.filter { project in
            project.name.lowercased().contains(trimmed)
                || project.path.lowercased().contains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.projectPickerTitle)
                .font(.headline)
                .foregroundStyle(theme.text)

            TextField("Search projects…", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { commit() }
                .onChange(of: query) { _, _ in
                    selectedIndex = 0
                }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, project in
                            row(for: project, index: index)
                                .id(project.id)
                                .onTapGesture {
                                    selectedIndex = index
                                    commit()
                                }
                        }
                        if filtered.isEmpty {
                            Text("No matching projects")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                        }
                    }
                }
                .frame(height: 240)
                .onChange(of: selectedIndex) { _, newValue in
                    guard filtered.indices.contains(newValue) else { return }
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(filtered[newValue].id, anchor: .center)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 460)
        .background(theme.background)
        .onAppear {
            fieldFocused = true
            // Pre-highlight the currently selected project (if it's in the
            // candidate list) so Enter without typing means "use what I'm
            // already looking at."
            if let id = state.selectedProjectID,
               let idx = state.projectPickerCandidates.firstIndex(where: { $0.id == id }) {
                selectedIndex = idx
            }
        }
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 {
                selectedIndex -= 1
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < filtered.count - 1 {
                selectedIndex += 1
            }
            return .handled
        }
        .onKeyPress(.escape) {
            cancel()
            return .handled
        }
    }

    private func row(for project: Project, index: Int) -> some View {
        let isSelected = index == selectedIndex
        return VStack(alignment: .leading, spacing: 2) {
            Text(project.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : theme.text)
            Text(project.path)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Color.white.opacity(0.8) : theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? theme.accent : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    private func commit() {
        guard filtered.indices.contains(selectedIndex) else { return }
        let picked = filtered[selectedIndex]
        let onSelect = state.projectPickerOnSelect
        closePicker()
        // Defer to next runloop so the sheet fully dismisses before any
        // follow-up sheet (e.g. RemotePromptSheet) tries to present.
        DispatchQueue.main.async {
            onSelect?(picked)
        }
    }

    private func cancel() {
        closePicker()
    }

    private func closePicker() {
        state.showingProjectPicker = false
        state.projectPickerOnSelect = nil
        state.projectPickerCandidates = []
        state.projectPickerTitle = ""
    }
}
