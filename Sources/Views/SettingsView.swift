import SwiftUI

struct SettingsView: View {
    @Bindable var state: AppState

    @AppStorage("flightFontSize") private var fontSize: Double = 14
    @AppStorage("flightTheme") private var selectedTheme: String = "System"
    @State private var showingImport = false
    @State private var themeNames: [String] = []

    @State private var selectedProjectID: String?
    @State private var provision: String = ""
    @State private var connect: String = ""
    @State private var teardown: String = ""
    @State private var list: String = ""

    @State private var worktreeProjectID: String?
    @State private var setupScript: String = ""

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            worktreeTab
                .tabItem { Label("Worktree", systemImage: "shippingbox") }

            remoteTab
                .tabItem { Label("Remote", systemImage: "cloud") }
        }
        .frame(width: 500, height: 480)
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
            teardown = remote.teardown
            list = remote.list ?? ""
        } else {
            provision = ""
            connect = ""
            teardown = ""
            list = ""
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
                VStack(alignment: .leading, spacing: 4) {
                    Text("Provision")
                        .font(.system(size: 12, weight: .medium))
                    TextEditor(text: $provision)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connect")
                        .font(.system(size: 12, weight: .medium))
                    TextEditor(text: $connect)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Teardown")
                        .font(.system(size: 12, weight: .medium))
                    TextEditor(text: $teardown)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("List (optional)")
                        .font(.system(size: 12, weight: .medium))
                    TextEditor(text: $list)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                }
            } footer: {
                Text("Use {branch} and {workspace} as placeholders. Provision prints workspace name to stdout. List prints one name per line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                if selectedRemoteProject?.hasRemoteMode == true {
                    Button("Remove") {
                        if let project = selectedRemoteProject {
                            state.updateRemoteMode(nil, for: project)
                        }
                        provision = ""
                        connect = ""
                        teardown = ""
                        list = ""
                    }
                }
                Button("Save") {
                    guard !provision.isEmpty, !connect.isEmpty, !teardown.isEmpty,
                          let project = selectedRemoteProject else { return }
                    state.updateRemoteMode(RemoteModeConfig(
                        provision: provision,
                        connect: connect,
                        teardown: teardown,
                        list: list.isEmpty ? nil : list
                    ), for: project)
                }
                .buttonStyle(.borderedProminent)
                .disabled(provision.isEmpty || connect.isEmpty || teardown.isEmpty)
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
