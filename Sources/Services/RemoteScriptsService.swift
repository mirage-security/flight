import Foundation

enum RemoteLifecycle: String, CaseIterable {
    case provision
    case connect
    case teardown
    case list
}

struct ResolvedRemoteCommand {
    /// Ready-to-run shell command, suitable for `ShellService.run`.
    let command: String
    /// Direct exec form: used when the command is passed as a process
    /// argv (e.g. as a prefix for the `claude` agent). For settings
    /// templates this is the substituted string split on spaces —
    /// matching the original behavior. For `.flight/` scripts this is
    /// `[scriptPath, ?argument]`.
    let argv: [String]
    /// Working directory to run the command in. `nil` means inherit the
    /// parent process's cwd (preserves legacy behavior for settings
    /// templates). `.flight/` scripts always run in the repo root.
    let workingDirectory: String?
}

/// Resolves the shell command to run for a remote-mode lifecycle stage.
///
/// Two sources are supported, in precedence order:
///   1. `project.remoteMode?.X` — a template string stored in settings,
///      with `{branch}` / `{workspace}` substituted (original behavior).
///   2. `<project.path>/.flight/<lifecycle>` — an executable script in the
///      repo. The argument (branch for provision, workspace for
///      connect/teardown) is passed as `$1`. `list` takes no argument.
///
/// Settings wins so users can prototype or override locally without
/// committing changes to the repo (matching `WorktreeSetupService`).
enum RemoteScriptsService {
    static func resolve(
        _ lifecycle: RemoteLifecycle,
        project: Project,
        argument: String?
    ) -> ResolvedRemoteCommand? {
        if let template = settingsTemplate(lifecycle, project: project) {
            let substituted = applySubstitutions(template, lifecycle: lifecycle, argument: argument)
            return ResolvedRemoteCommand(
                command: substituted,
                argv: substituted.components(separatedBy: " "),
                workingDirectory: nil
            )
        }
        if let scriptPath = flightScriptPath(lifecycle, project: project) {
            var argv = [scriptPath]
            if let argument, !argument.isEmpty, lifecycle != .list {
                argv.append(argument)
            }
            let command = argv.map(shellQuote).joined(separator: " ")
            return ResolvedRemoteCommand(
                command: command,
                argv: argv,
                workingDirectory: project.path
            )
        }
        return nil
    }

    static func isAvailable(_ lifecycle: RemoteLifecycle, project: Project) -> Bool {
        if settingsTemplate(lifecycle, project: project) != nil { return true }
        return flightScriptPath(lifecycle, project: project) != nil
    }

    static func hasAnyScript(project: Project) -> Bool {
        RemoteLifecycle.allCases.contains { isAvailable($0, project: project) }
    }

    // MARK: - Private

    private static func settingsTemplate(
        _ lifecycle: RemoteLifecycle,
        project: Project
    ) -> String? {
        guard let remote = project.remoteMode else { return nil }
        let value: String?
        switch lifecycle {
        case .provision: value = remote.provision
        case .connect:   value = remote.connect
        case .teardown:  value = remote.teardown
        case .list:      value = remote.list
        }
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        return value
    }

    private static func flightScriptPath(
        _ lifecycle: RemoteLifecycle,
        project: Project
    ) -> String? {
        let path = URL(fileURLWithPath: project.path)
            .appendingPathComponent(".flight")
            .appendingPathComponent(lifecycle.rawValue)
            .path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private static func applySubstitutions(
        _ template: String,
        lifecycle: RemoteLifecycle,
        argument: String?
    ) -> String {
        guard let argument else { return template }
        switch lifecycle {
        case .provision:
            return template.replacingOccurrences(of: "{branch}", with: argument)
        case .connect, .teardown:
            return template.replacingOccurrences(of: "{workspace}", with: argument)
        case .list:
            return template
        }
    }

    /// POSIX-safe single-quote escape: wraps the value in single quotes and
    /// escapes any embedded single quotes as `'\''`.
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
