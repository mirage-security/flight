import SwiftUI

// MARK: - Base16 Scheme (universal theme format)
// https://github.com/tinted-theming/schemes
// 16 hex colors that map to UI roles. Hundreds of themes available.

struct Base16Scheme: Codable {
    let name: String?
    let author: String?
    let base00: String // Default Background
    let base01: String // Lighter Background (sidebar, status bar)
    let base02: String // Selection Background
    let base03: String // Comments, Invisibles, Line Highlighting
    let base04: String // Dark Foreground (status bars)
    let base05: String // Default Foreground
    let base06: String // Light Foreground
    let base07: String // Light Background
    let base08: String // Red
    let base09: String // Orange
    let base0A: String // Yellow
    let base0B: String // Green
    let base0C: String // Cyan
    let base0D: String // Blue
    let base0E: String // Purple
    let base0F: String // Brown

    enum CodingKeys: String, CodingKey {
        case name, author
        case base00, base01, base02, base03, base04, base05, base06, base07
        case base08, base09
        case base0A = "base0A"
        case base0B = "base0B"
        case base0C = "base0C"
        case base0D = "base0D"
        case base0E = "base0E"
        case base0F = "base0F"
    }

    func toThemeColors() -> ThemeColors {
        let bg = Color(hex: base00)
        let bgLight = Color(hex: base01)
        let fg = Color(hex: base05)
        let fgDim = Color(hex: base04)
        let blue = Color(hex: base0D)
        let border = Color(hex: base03)

        return ThemeColors(
            background: bg,
            sidebar: bgLight,
            inputBackground: bgLight,
            text: fg,
            secondaryText: fgDim,
            userBubble: blue.opacity(0.2),
            assistantBubble: bgLight,
            toolGroupBackground: bgLight.opacity(0.8),
            border: border.opacity(0.5),
            accent: blue,
            headerBackground: bgLight,
            red: Color(hex: base08),
            orange: Color(hex: base09),
            yellow: Color(hex: base0A),
            green: Color(hex: base0B),
            cyan: Color(hex: base0C),
            blue: blue,
            purple: Color(hex: base0E)
        )
    }

    var isDark: Bool {
        // Determine if dark by checking luminance of background
        let r, g, b: Double
        (r, g, b) = hexToRGB(base00)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance < 0.5
    }

    private func hexToRGB(_ hex: String) -> (Double, Double, Double) {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard clean.count == 6, let val = UInt64(clean, radix: 16) else {
            return (0, 0, 0)
        }
        return (
            Double((val >> 16) & 0xFF) / 255.0,
            Double((val >> 8) & 0xFF) / 255.0,
            Double(val & 0xFF) / 255.0
        )
    }

    // Built-in schemes
    static let solarizedDark = Base16Scheme(
        name: "Solarized Dark", author: "Ethan Schoonover",
        base00: "002b36", base01: "073642", base02: "586e75", base03: "657b83",
        base04: "839496", base05: "93a1a1", base06: "eee8d5", base07: "fdf6e3",
        base08: "dc322f", base09: "cb4b16", base0A: "b58900", base0B: "859900",
        base0C: "2aa198", base0D: "268bd2", base0E: "6c71c4", base0F: "d33682"
    )

    static let solarizedLight = Base16Scheme(
        name: "Solarized Light", author: "Ethan Schoonover",
        base00: "fdf6e3", base01: "eee8d5", base02: "93a1a1", base03: "839496",
        base04: "657b83", base05: "586e75", base06: "073642", base07: "002b36",
        base08: "dc322f", base09: "cb4b16", base0A: "b58900", base0B: "859900",
        base0C: "2aa198", base0D: "268bd2", base0E: "6c71c4", base0F: "d33682"
    )

    static let tokyoNight = Base16Scheme(
        name: "Tokyo Night", author: "Folke Lemaitre",
        base00: "1a1b26", base01: "16161e", base02: "2f3549", base03: "444b6a",
        base04: "787c99", base05: "a9b1d6", base06: "cbccd1", base07: "d5d6db",
        base08: "f7768e", base09: "ff9e64", base0A: "e0af68", base0B: "9ece6a",
        base0C: "449dab", base0D: "7aa2f7", base0E: "bb9af7", base0F: "d18616"
    )

    static let gruvboxDark = Base16Scheme(
        name: "Gruvbox Dark", author: "Pavel Pertsev",
        base00: "282828", base01: "3c3836", base02: "504945", base03: "665c54",
        base04: "bdae93", base05: "d5c4a1", base06: "ebdbb2", base07: "fbf1c7",
        base08: "fb4934", base09: "fe8019", base0A: "fabd2f", base0B: "b8bb26",
        base0C: "8ec07c", base0D: "83a598", base0E: "d3869b", base0F: "d65d0e"
    )

    static let catppuccinMocha = Base16Scheme(
        name: "Catppuccin Mocha", author: "Catppuccin",
        base00: "1e1e2e", base01: "181825", base02: "313244", base03: "45475a",
        base04: "585b70", base05: "cdd6f4", base06: "f5e0dc", base07: "b4befe",
        base08: "f38ba8", base09: "fab387", base0A: "f9e2af", base0B: "a6e3a1",
        base0C: "94e2d5", base0D: "89b4fa", base0E: "cba6f7", base0F: "f2cdcd"
    )

    static let nord = Base16Scheme(
        name: "Nord", author: "Arctic Ice Studio",
        base00: "2e3440", base01: "3b4252", base02: "434c5e", base03: "4c566a",
        base04: "d8dee9", base05: "e5e9f0", base06: "eceff4", base07: "8fbcbb",
        base08: "bf616a", base09: "d08770", base0A: "ebcb8b", base0B: "a3be8c",
        base0C: "88c0d0", base0D: "81a1c1", base0E: "b48ead", base0F: "5e81ac"
    )

    static let builtIn: [Base16Scheme] = [
        solarizedDark, solarizedLight, tokyoNight, gruvboxDark, catppuccinMocha, nord
    ]
}

// MARK: - Color hex init

extension Color {
    init(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard clean.count == 6, let val = UInt64(clean, radix: 16) else {
            self = .clear
            return
        }
        self.init(
            red: Double((val >> 16) & 0xFF) / 255.0,
            green: Double((val >> 8) & 0xFF) / 255.0,
            blue: Double(val & 0xFF) / 255.0
        )
    }
}

// MARK: - Theme Colors

struct ThemeColors {
    let background: Color
    let sidebar: Color
    let inputBackground: Color
    let text: Color
    let secondaryText: Color
    let userBubble: Color
    let assistantBubble: Color
    let toolGroupBackground: Color
    let border: Color
    let accent: Color
    let headerBackground: Color

    // Semantic colors (mapped from Base16)
    let red: Color       // base08 — errors, stop, CI failure
    let orange: Color    // base09 — tool calls, working status
    let yellow: Color    // base0A — warnings, creating status, permissions
    let green: Color     // base0B — success, ready status, CI pass
    let cyan: Color      // base0C — info
    let blue: Color      // base0D — accent, links (same as accent)
    let purple: Color    // base0E — plan mode

    static let system = ThemeColors(
        background: Color(nsColor: .windowBackgroundColor),
        sidebar: Color(nsColor: .windowBackgroundColor),
        inputBackground: Color(nsColor: .controlBackgroundColor),
        text: Color(nsColor: .labelColor),
        secondaryText: Color(nsColor: .secondaryLabelColor),
        userBubble: Color.accentColor.opacity(0.12),
        assistantBubble: Color(nsColor: .controlBackgroundColor),
        toolGroupBackground: Color(nsColor: .controlBackgroundColor).opacity(0.5),
        border: Color(nsColor: .separatorColor),
        accent: Color.accentColor,
        headerBackground: Color(nsColor: .windowBackgroundColor),
        red: .red,
        orange: .orange,
        yellow: .yellow,
        green: .green,
        cyan: .cyan,
        blue: Color.accentColor,
        purple: .purple
    )
}

// MARK: - Theme Manager

@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    var currentColors: ThemeColors = .system
    var currentColorScheme: ColorScheme? = nil

    private init() {
        load()
    }

    func load() {
        let name = UserDefaults.standard.string(forKey: "flightTheme") ?? "System"
        apply(name: name)
    }

    func apply(name: String) {
        UserDefaults.standard.set(name, forKey: "flightTheme")

        if name == "System" {
            currentColors = .system
            currentColorScheme = nil
            return
        }

        // Check built-in schemes
        if let scheme = Base16Scheme.builtIn.first(where: { $0.name == name }) {
            currentColors = scheme.toThemeColors()
            currentColorScheme = scheme.isDark ? .dark : .light
            return
        }

        // Check imported schemes
        if let scheme = loadImportedScheme(name: name) {
            currentColors = scheme.toThemeColors()
            currentColorScheme = scheme.isDark ? .dark : .light
            return
        }

        currentColors = .system
        currentColorScheme = nil
    }

    // MARK: - Import

    static var importedThemesDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("flight")
            .appendingPathComponent("themes")
    }

    func importTheme(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let scheme = try JSONDecoder().decode(Base16Scheme.self, from: data)
        let name = scheme.name ?? url.deletingPathExtension().lastPathComponent

        // Save to themes dir
        let dir = Self.importedThemesDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(name).json")
        try data.write(to: dest)

        return name
    }

    func availableThemeNames() -> [String] {
        var names = ["System"]
        names += Base16Scheme.builtIn.compactMap(\.name)
        names += importedThemeNames()
        return names
    }

    private func importedThemeNames() -> [String] {
        let dir = Self.importedThemesDir
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> String? in
                guard let data = try? Data(contentsOf: url),
                      let scheme = try? JSONDecoder().decode(Base16Scheme.self, from: data) else { return nil }
                return scheme.name ?? url.deletingPathExtension().lastPathComponent
            }
    }

    private func loadImportedScheme(name: String) -> Base16Scheme? {
        let dir = Self.importedThemesDir
        let file = dir.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: file),
              let scheme = try? JSONDecoder().decode(Base16Scheme.self, from: data) else { return nil }
        return scheme
    }
}

// MARK: - Environment Key

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: ThemeColors = .system
}

extension EnvironmentValues {
    var theme: ThemeColors {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
