import SwiftUI

struct SettingsView: View {
    @Bindable var state: AppState

    @AppStorage("flightFontSize") private var fontSize: Double = 14
    @AppStorage("flightTheme") private var selectedTheme: String = "System"
    @State private var showingImport = false
    @State private var themeNames: [String] = []

    @State private var provision: String = ""
    @State private var connect: String = ""
    @State private var teardown: String = ""

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            remoteTab
                .tabItem { Label("Remote", systemImage: "cloud") }
        }
        .frame(width: 500, height: 380)
        .onAppear {
            themeNames = ThemeManager.shared.availableThemeNames()
            state.reloadConfig()
            if let remote = state.remoteMode {
                provision = remote.provision
                connect = remote.connect
                teardown = remote.teardown
            }
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

    private var remoteTab: some View {
        Form {
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
            } header: {
                Text("Remote Mode")
            } footer: {
                Text("Use {branch} and {workspace} as placeholders. Provision must print the workspace name to stdout.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                if state.hasRemoteMode {
                    Button("Remove") {
                        state.updateRemoteMode(nil)
                        provision = ""
                        connect = ""
                        teardown = ""
                    }
                }
                Button("Save") {
                    guard !provision.isEmpty, !connect.isEmpty, !teardown.isEmpty else { return }
                    state.updateRemoteMode(RemoteModeConfig(
                        provision: provision,
                        connect: connect,
                        teardown: teardown
                    ))
                }
                .buttonStyle(.borderedProminent)
                .disabled(provision.isEmpty || connect.isEmpty || teardown.isEmpty)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            // Reload in case config was edited externally
            if let remote = state.remoteMode {
                provision = remote.provision
                connect = remote.connect
                teardown = remote.teardown
            }
        }
    }
}
