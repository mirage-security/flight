import Foundation

/// Captures the user's login-shell PATH once at app launch so spawned
/// subprocesses (claude, pnpm, brew-installed tools) resolve the same way
/// they would in the user's terminal. GUI-launched apps inherit launchd's
/// stripped PATH (`/usr/bin:/bin:/usr/sbin:/sbin`) — without this fix,
/// `/usr/bin/env claude` exits 127 the moment Flight is opened from
/// Finder/Sparkle instead of `swift run`.
public enum EnvironmentService {
    private static let fallbackPath = [
        "\(NSHomeDirectory())/.local/bin",
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ].joined(separator: ":")

    private static let resolvedPath: String = {
        captureLoginShellPath() ?? fallbackPath
    }()

    /// Touch this from app startup to pre-warm the (lazy, ~50–200ms) capture
    /// before the first subprocess spawn.
    public static var path: String { resolvedPath }

    /// Current process environment with PATH replaced by the captured
    /// login-shell value. Per-call `overrides` are merged in last so a
    /// caller setting e.g. `FLIGHT_*` vars wins over PATH itself if they want.
    public static func baseEnvironment(overrides: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = resolvedPath
        for (key, value) in overrides { env[key] = value }
        return env
    }

    private static func captureLoginShellPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        // `-ilc` = interactive + login. `-l` alone misses ~/.zshrc, which is
        // where most macOS users (and our own dev box) actually add things
        // like ~/.local/bin and language-version managers (fnm, pyenv, rye).
        // `-i` may print prompt-setup noise on stderr — that's why we
        // discard it via the unread Pipe below.
        proc.arguments = ["-ilc", "printf %s \"$PATH\""]
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }
}
