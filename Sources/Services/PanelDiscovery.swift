import Foundation

/// Slice 1: surface the first executable script in `<worktree>/.flight/panels/`.
/// Multi-panel discovery (and tabs) come in slice 2.
enum PanelDiscovery {
    static func firstPanel(in worktreePath: String) -> String? {
        let dir = URL(fileURLWithPath: worktreePath)
            .appendingPathComponent(".flight")
            .appendingPathComponent("panels")

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isExecutableKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let executables = entries
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isExecutableKey, .isRegularFileKey])
                return (values?.isRegularFile ?? false) && (values?.isExecutable ?? false)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return executables.first?.path
    }

    static func panelName(for scriptPath: String) -> String {
        URL(fileURLWithPath: scriptPath).lastPathComponent
    }
}
