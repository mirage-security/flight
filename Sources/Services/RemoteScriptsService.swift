import Foundation

enum RemoteLifecycle: String, CaseIterable {
    case provision
    case connect
    case teardown
    case list
    case monitor

    var isRequiredForRemoteOnlyFetch: Bool {
        switch self {
        case .provision, .connect:
            return true
        case .teardown, .list, .monitor:
            return false
        }
    }
}

struct ResolvedRemoteCommand: Sendable {
    /// Shell command string. Executed via `zsh -l -c`. For `.flight/`
    /// scripts this is `"<scriptPath>" "$@"` so the script receives any
    /// trailing args (e.g. the remote command for `connect`). For
    /// settings templates this is the user-supplied string verbatim.
    let command: String
    /// Environment overrides to layer on top of the process env.
    /// `FLIGHT_BRANCH` for `provision`, `FLIGHT_WORKSPACE` for
    /// `connect`/`teardown`/`monitor`, empty for `list`.
    let environment: [String: String]
    /// Working directory to run in. Always the repo root — so `.flight/`
    /// scripts and settings templates can reference the repo consistently.
    let workingDirectory: String?
}

/// Resolves the shell command to run for a remote-mode lifecycle stage.
///
/// Script sources vary by project type:
///
/// **Local projects** (have a local clone):
///   1. `project.remoteMode?.X` — a settings-level template string
///      (prototype locally without committing to the repo).
///   2. `<project.path>/.flight/<lifecycle>` — an executable script
///      committed to the repo.
///
/// **Remote-only projects** (no local clone):
///   - `~/flight/remote-scripts/<name>/<lifecycle>` — cached from the
///     repo's `.flight/` directory. The cache is refreshed in the
///     background on app launch; if scripts change upstream, a
///     notification alerts the user. No settings overrides: the source
///     of truth is whatever the repo ships.
///
/// All variants are invoked through `/bin/zsh -l -c` with this contract:
///
/// - `provision`: `FLIGHT_BRANCH` is set. Streams progress to stdout;
///    the last non-metadata line is the workspace name.
/// - `connect`: `FLIGHT_WORKSPACE` is set. Wrapper that runs `$@` on the
///    remote workspace (ssh-like). Flight appends the remote command as
///    positional args when invoking.
/// - `teardown`: `FLIGHT_WORKSPACE` is set. No `$@`.
/// - `list`: no env vars, no `$@`. Prints one workspace name per line.
/// - `monitor`: `FLIGHT_WORKSPACE` is set for remote worktrees. Prints a
///    JSON service monitor payload.
enum RemoteScriptsService {
    static func resolve(
        _ lifecycle: RemoteLifecycle,
        project: Project,
        branch: String? = nil,
        workspace: String? = nil
    ) -> ResolvedRemoteCommand? {
        let env = environment(for: lifecycle, branch: branch, workspace: workspace)
        // Remote-only projects have no local path, so we fall back to a
        // stable cwd under ~/flight. Scripts there must not assume they're
        // running inside a repo.
        let cwd = project.path ?? ConfigService.flightHomeURL.path

        // Remote-only: use the fetched scripts under
        // ~/flight/remote-scripts/<name>/. No settings overrides — the
        // repo is the source of truth.
        if project.isRemoteOnly {
            if let scriptPath = cachedScriptPath(lifecycle, projectName: project.name) {
                return ResolvedRemoteCommand(
                    command: "\(shellQuote(scriptPath)) \"$@\"",
                    environment: env,
                    workingDirectory: cwd
                )
            }
            return nil
        }

        // Local: settings template wins over committed .flight/<lifecycle>.
        if let template = settingsTemplate(lifecycle, project: project) {
            return ResolvedRemoteCommand(
                command: template,
                environment: env,
                workingDirectory: cwd
            )
        }
        if let scriptPath = flightScriptPath(lifecycle, project: project) {
            return ResolvedRemoteCommand(
                command: "\(shellQuote(scriptPath)) \"$@\"",
                environment: env,
                workingDirectory: cwd
            )
        }
        return nil
    }

    private static func cachedScriptPath(
        _ lifecycle: RemoteLifecycle,
        projectName: String
    ) -> String? {
        let path = RemoteScriptFetcher.cacheDirectory(for: projectName)
            .appendingPathComponent(lifecycle.rawValue)
            .path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    static func isAvailable(_ lifecycle: RemoteLifecycle, project: Project) -> Bool {
        if project.isRemoteOnly {
            return cachedScriptPath(lifecycle, projectName: project.name) != nil
        }
        if settingsTemplate(lifecycle, project: project) != nil { return true }
        return flightScriptPath(lifecycle, project: project) != nil
    }

    static func hasRequiredRemoteScripts(project: Project) -> Bool {
        isAvailable(.provision, project: project)
            && isAvailable(.connect, project: project)
    }

    /// True when a `.flight/<lifecycle>` file exists in the repo, regardless
    /// of whether the settings field is also set. Useful for surfacing in
    /// the Settings UI.
    static func hasFile(_ lifecycle: RemoteLifecycle, project: Project) -> Bool {
        flightScriptPath(lifecycle, project: project) != nil
    }

    /// Parses a single provision stdout line looking for the reserved
    /// metadata prefix `FLIGHT_OUTPUT: key=value`. Returns the parsed
    /// key/value pair when matched, or `nil` for regular progress output.
    /// Caller should suppress matched lines from the UI stream.
    static func parseFlightOutput(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("FLIGHT_OUTPUT:") else { return nil }
        let body = trimmed.dropFirst("FLIGHT_OUTPUT:".count).trimmingCharacters(in: .whitespaces)
        guard let eq = body.firstIndex(of: "=") else { return nil }
        let key = body[..<eq].trimmingCharacters(in: .whitespaces)
        let value = String(body[body.index(after: eq)...])
        guard !key.isEmpty else { return nil }
        return (String(key), value)
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
        case .connect, .teardown, .monitor:
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
        case .monitor:   value = remote.monitor
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
        // No local clone → no `.flight/` directory to look in.
        guard let projectPath = project.path else { return nil }
        let path = URL(fileURLWithPath: projectPath)
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
