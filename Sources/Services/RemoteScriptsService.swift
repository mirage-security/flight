import Foundation

enum RemoteLifecycle: String, CaseIterable {
    case provision
    case connect
    case teardown
    case list
}

struct ResolvedRemoteCommand {
    /// Shell command string. Executed via `zsh -l -c`. For `.flight/`
    /// scripts this is `"<scriptPath>" "$@"` so the script receives any
    /// trailing args (e.g. the remote command for `connect`). For
    /// settings templates this is the user-supplied string verbatim.
    let command: String
    /// Environment overrides to layer on top of the process env.
    /// `FLIGHT_BRANCH` for `provision`, `FLIGHT_WORKSPACE` for
    /// `connect`/`teardown`, empty for `list`.
    let environment: [String: String]
    /// Working directory to run in. Always the repo root — so `.flight/`
    /// scripts and settings templates can reference the repo consistently.
    let workingDirectory: String?
}

/// Resolves the shell command to run for a remote-mode lifecycle stage.
///
/// Two sources are supported, in precedence order:
///   1. `project.remoteMode?.X` — a shell command string from settings.
///   2. `<project.path>/.flight/<lifecycle>` — an executable script in
///      the repo.
///
/// Both are invoked through `/bin/zsh -l -c` with the following contract:
///
/// - `provision`: `FLIGHT_BRANCH` is set in the env. The command is
///    expected to stream progress to stdout and print the created
///    workspace name as the last line.
/// - `connect`: `FLIGHT_WORKSPACE` is set. The command is a *wrapper*
///    that runs its `$@` on the remote workspace (think: `ssh`-like).
///    Flight appends the remote command as positional args when invoking.
/// - `teardown`: `FLIGHT_WORKSPACE` is set. No `$@`.
/// - `list`: no env vars, no `$@`. Prints one workspace name per line.
///
/// Settings wins over `.flight/` so users can prototype or override
/// locally without committing changes to the repo.
enum RemoteScriptsService {
    static func resolve(
        _ lifecycle: RemoteLifecycle,
        project: Project,
        branch: String? = nil,
        workspace: String? = nil
    ) -> ResolvedRemoteCommand? {
        let env = environment(for: lifecycle, branch: branch, workspace: workspace)
        if let template = settingsTemplate(lifecycle, project: project) {
            return ResolvedRemoteCommand(
                command: template,
                environment: env,
                workingDirectory: project.path
            )
        }
        if let scriptPath = flightScriptPath(lifecycle, project: project) {
            return ResolvedRemoteCommand(
                command: "\(shellQuote(scriptPath)) \"$@\"",
                environment: env,
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

    /// True when a `.flight/<lifecycle>` file exists in the repo, regardless
    /// of whether the settings field is also set. Useful for surfacing in
    /// the Settings UI.
    static func hasFile(_ lifecycle: RemoteLifecycle, project: Project) -> Bool {
        flightScriptPath(lifecycle, project: project) != nil
    }

    // MARK: - Private

    private static func environment(
        for lifecycle: RemoteLifecycle,
        branch: String?,
        workspace: String?
    ) -> [String: String] {
        var env: [String: String] = [:]
        switch lifecycle {
        case .provision:
            if let branch { env["FLIGHT_BRANCH"] = branch }
        case .connect, .teardown:
            if let workspace { env["FLIGHT_WORKSPACE"] = workspace }
        case .list:
            break
        }
        return env
    }

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

    /// POSIX-safe single-quote escape: wraps the value in single quotes and
    /// escapes any embedded single quotes as `'\''`.
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
