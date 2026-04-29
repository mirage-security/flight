import SwiftUI

/// Modal shown when the user clicks "Add Project". Two modes:
///  - **Local**: pick a git repo directory on disk (existing flow).
///  - **Remote-only**: point at a forge repo (GitHub / Forgejo). Flight
///    downloads the repo's committed `.flight/` scripts into a local
///    cache and uses those for remote lifecycle commands. No overrides.
struct AddProjectSheet: View {
    @Bindable var state: AppState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable {
        case local
        case remoteOnly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .local: return "Local"
            case .remoteOnly: return "Remote"
            }
        }
    }

    @State private var mode: Mode = .local

    // Local form
    @State private var localPath: String = ""
    @State private var localName: String = ""
    @State private var showingFolderPicker = false

    // Remote-only form
    @State private var forgeType: ForgeType = .github
    @State private var repoInput: String = ""
    @State private var remoteName: String = ""
    @State private var remoteNameEdited: Bool = false
    @State private var forgeBaseURL: String = ""
    @State private var forgeTokenEnvVar: String = ""
    @State private var isAdding = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Project")
                .font(.headline)
                .foregroundStyle(theme.text)

            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { m in
                    Text(m.title).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .local:
                localBody
            case .remoteOnly:
                remoteOnlyBody
            }

            if let errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                    .disabled(isAdding)
                switch mode {
                case .local:
                    Button("Add") { submitLocal() }
                        .keyboardShortcut(.return)
                        .disabled(!localIsValid)
                case .remoteOnly:
                    Button(isAdding ? "Adding…" : "Add") {
                        Task { await submitRemoteOnly() }
                    }
                    .keyboardShortcut(.return)
                    .disabled(!remoteOnlyIsValid || isAdding)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(theme.background)
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                localPath = url.path
                localName = uniqueName(base: url.lastPathComponent)
                errorText = nil
            }
        }
    }

    private var localBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick a local git repository to add to Flight.")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)

            HStack {
                Button(localPath.isEmpty ? "Choose Folder…" : "Change…") {
                    showingFolderPicker = true
                }
                if !localPath.isEmpty {
                    Text(localPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if !localPath.isEmpty {
                field(title: "Name") {
                    TextField("mirage", text: $localName)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var remoteOnlyBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Flight will download the repo's committed .flight/ scripts and use them to provision remote workspaces. No local clone needed.")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Forge", selection: $forgeType) {
                ForEach(ForgeType.allCases) { t in
                    Text(t.displayName).tag(t)
                }
            }

            field(title: forgeType == .github ? "Repo (owner/name or GitHub URL)" : "Repo (owner/name)") {
                TextField("mirage-security/flight", text: $repoInput)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: repoInput) { _, newValue in
                        // Auto-populate the name from the parsed repo slug
                        // until the user manually edits it. Keeps the common
                        // case zero-friction and still allows rename for
                        // collisions.
                        guard !remoteNameEdited,
                              let parsed = parseRepo(newValue) else { return }
                        remoteName = uniqueName(base: parsed.repo)
                    }
            }

            field(title: "Name") {
                TextField("flight", text: $remoteName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: remoteName) { _, _ in
                        remoteNameEdited = true
                    }
            }

            if forgeType == .forgejo {
                field(title: "Base URL") {
                    TextField("https://git.example.com", text: $forgeBaseURL)
                        .textFieldStyle(.roundedBorder)
                }
                field(title: "Token env var") {
                    TextField("FORGEJO_TOKEN", text: $forgeTokenEnvVar)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private func field<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondaryText)
            content()
        }
    }

    private var localIsValid: Bool {
        !localPath.isEmpty && !localName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Suggests a non-colliding name by appending `-2`, `-3`, ... if the
    /// basename is already in use. Keeps the common case (no collision)
    /// zero-friction while still letting the user edit before submit.
    private func uniqueName(base: String) -> String {
        let existing = Set(state.projects.map(\.name))
        guard existing.contains(base) else { return base }
        var i = 2
        while existing.contains("\(base)-\(i)") { i += 1 }
        return "\(base)-\(i)"
    }

    private func submitLocal() {
        let name = localName.trimmingCharacters(in: .whitespaces)
        do {
            try state.addProject(path: localPath, name: name)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private var remoteOnlyIsValid: Bool {
        guard parseRepo(repoInput) != nil else { return false }
        guard !remoteName.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if forgeType == .forgejo {
            guard !forgeBaseURL.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        }
        return true
    }

    /// Accepts `owner/repo`, `github.com/owner/repo`, or full URLs like
    /// `https://github.com/owner/repo(.git)`. Returns the parsed pair, or
    /// nil if the input doesn't look like a repo reference.
    private func parseRepo(_ raw: String) -> (owner: String, repo: String)? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        if let range = s.range(of: "://") { s = String(s[range.upperBound...]) }
        // Drop the host if present (github.com/, git.example.com/)
        if let slash = s.firstIndex(of: "/"),
           s[..<slash].contains(".") {
            s = String(s[s.index(after: slash)...])
        }
        let parts = s.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1])
    }

    private func submitRemoteOnly() async {
        guard let (owner, repo) = parseRepo(repoInput) else { return }
        let name = remoteName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        isAdding = true
        errorText = nil
        defer { isAdding = false }

        let base = forgeBaseURL.trimmingCharacters(in: .whitespaces)
        let tokenVar = forgeTokenEnvVar.trimmingCharacters(in: .whitespaces)
        let forge = ForgeConfig(
            type: forgeType,
            baseURL: base.isEmpty ? nil : base,
            tokenEnvVar: tokenVar.isEmpty ? nil : tokenVar,
            owner: owner,
            repo: repo
        )

        do {
            try await state.addRemoteOnlyProject(name: name, forge: forge)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
