import SwiftUI

public struct SettingsView: View {
    @Bindable var state: AppState

    @AppStorage("flightFontSize") private var fontSize: Double = 14
    @AppStorage("flightTheme") private var selectedTheme: String = "System"
    @AppStorage("flightDefaultModel") private var defaultModel: String = ""
    @State private var showingImport = false
    @State private var themeNames: [String] = []

    @State private var selectedProjectID: String?
    @State private var provision: String = ""
    @State private var connect: String = ""
    @State private var teardown: String = ""
    @State private var list: String = ""
    @State private var monitor: String = ""

    @State private var worktreeProjectID: String?
    @State private var setupScript: String = ""

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            worktreeTab
                .tabItem { Label("Worktree", systemImage: "shippingbox") }

            remoteTab
                .tabItem { Label("Remote", systemImage: "cloud") }
        }
        .frame(width: 500, height: 540)
        .onAppear {
            themeNames = ThemeManager.shared.availableThemeNames()
        }
    }

    private var generalTab: some View {
        Form {
            Picker("Theme", selection: $selectedTheme) {
                ForEach(themeNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .onChange(of: selectedTheme) { _, newValue in
                ThemeManager.shared.apply(name: newValue)
            }

            Picker("Default Model", selection: $defaultModel) {
                Text("CLI Default").tag("")
                ForEach(ModelCatalog.families) { family in
                    Section(family.label) {
                        ForEach(family.entries) { entry in
                            Text(entry.label).tag(entry.id)
                        }
                    }
                }
            }

            HStack {
                Button("Import Base16 Theme...") {
                    showingImport = true
                }
                .fileImporter(
                    isPresented: $showingImport,
                    allowedContentTypes: [.json]
                ) { result in
                    if case .success(let url) = result {
                        do {
                            let name = try ThemeManager.shared.importTheme(from: url)
                            themeNames = ThemeManager.shared.availableThemeNames()
                            selectedTheme = name
                            ThemeManager.shared.apply(name: name)
                        } catch {
                            state.errorMessage = "Failed to import theme: \(error.localizedDescription)"
                            state.showingError = true
                        }
                    }
                }

                Spacer()

                Text("~/flight/themes/")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Font Size")
                Slider(value: $fontSize, in: 11...20, step: 1) {
                    Text("Font Size")
                }
                Text("\(Int(fontSize))pt")
                    .monospacedDigit()
                    .frame(width: 35)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var selectedRemoteProject: Project? {
        guard let id = selectedProjectID else { return state.projects.first }
        return state.projects.first { $0.id == id }
    }

    private var selectedWorktreeProject: Project? {
        guard let id = worktreeProjectID else { return state.projects.first }
        return state.projects.first { $0.id == id }
    }

    private func loadWorktreeFields() {
        setupScript = selectedWorktreeProject?.setupScript ?? ""
    }

    private var worktreeTab: some View {
        Form {
            Picker("Project", selection: $worktreeProjectID) {
                ForEach(state.projects) { project in
                    Text(project.name).tag(Optional(project.id))
                }
            }
            .onChange(of: worktreeProjectID) { _, _ in
                loadWorktreeFields()
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Setup script")
                        .font(.system(size: 12, weight: .medium))
                    TextEditor(text: $setupScript)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                }
            } footer: {
                Text("Runs once after each new worktree is created, with cwd set to the worktree. Use it to install dependencies so the agent doesn't have to. When this field is set, it overrides any committed .flight/worktree-setup file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                if selectedWorktreeProject?.setupScript?.isEmpty == false {
                    Button("Clear") {
                        if let project = selectedWorktreeProject {
                            state.updateSetupScript(nil, for: project)
                        }
                        setupScript = ""
                    }
                }
                Button("Save") {
                    guard let project = selectedWorktreeProject else { return }
                    let trimmed = setupScript.trimmingCharacters(in: .whitespacesAndNewlines)
                    state.updateSetupScript(trimmed.isEmpty ? nil : setupScript, for: project)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            worktreeProjectID = state.projects.first?.id
            state.reloadConfig()
            loadWorktreeFields()
        }
    }

    private func loadRemoteFields() {
        if let remote = selectedRemoteProject?.remoteMode {
            provision = remote.provision
            connect = remote.connect
            teardown = remote.teardown ?? ""
            list = remote.list ?? ""
            monitor = remote.monitor ?? ""
        } else {
            provision = ""
            connect = ""
            teardown = ""
            list = ""
            monitor = ""
        }
    }

    private var remoteAllEmpty: Bool {
        provision.isEmpty && connect.isEmpty && teardown.isEmpty && list.isEmpty && monitor.isEmpty
    }

    private var remoteRequiredFilled: Bool {
        !provision.isEmpty && !connect.isEmpty
    }

    private func remoteFieldEditor(
        title: String,
        lifecycle: RemoteLifecycle,
        text: Binding<String>
    ) -> some View {
        let fileExists = selectedRemoteProject.map {
            RemoteScriptsService.hasFile(lifecycle, project: $0)
        } ?? false
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                if fileExists {
                    Text(text.wrappedValue.isEmpty
                        ? "using .flight/\(lifecycle.rawValue)"
                        : "overrides .flight/\(lifecycle.rawValue)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                Spacer()
            }
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
        }
    }

    private var remoteTab: some View {
        Form {
            Picker("Project", selection: $selectedProjectID) {
                ForEach(state.projects) { project in
                    Text(project.name).tag(Optional(project.id))
                }
            }
            .onChange(of: selectedProjectID) { _, _ in
                loadRemoteFields()
            }

            Section {
                remoteFieldEditor(title: "Provision", lifecycle: .provision, text: $provision)
                remoteFieldEditor(title: "Connect", lifecycle: .connect, text: $connect)
                remoteFieldEditor(title: "Teardown (optional)", lifecycle: .teardown, text: $teardown)
                remoteFieldEditor(title: "List (optional)", lifecycle: .list, text: $list)
                remoteFieldEditor(title: "Monitor (optional)", lifecycle: .monitor, text: $monitor)
            } footer: {
                Text("Each command runs via zsh with these env vars: provision sees $FLIGHT_BRANCH and prints the workspace name on its last stdout line. connect is a wrapper that runs \"$@\" on the workspace (Flight appends the remote command). connect/teardown/monitor see $FLIGHT_WORKSPACE. list prints one workspace name per line. monitor prints JSON for the Services rail. Empty fields fall back to .flight/<name> scripts in the repo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Save") {
                    guard let project = selectedRemoteProject else { return }
                    if remoteAllEmpty {
                        state.updateRemoteMode(nil, for: project)
                    } else {
                        state.updateRemoteMode(RemoteModeConfig(
                            provision: provision,
                            connect: connect,
                            teardown: teardown.isEmpty ? nil : teardown,
                            list: list.isEmpty ? nil : list,
                            monitor: monitor.isEmpty ? nil : monitor
                        ), for: project)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!remoteAllEmpty && !remoteRequiredFilled)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            selectedProjectID = state.projects.first?.id
            state.reloadConfig()
            loadRemoteFields()
        }
    }
}
