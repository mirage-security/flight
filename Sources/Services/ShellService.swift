import Foundation

enum ShellError: Error, LocalizedError {
    case failed(command: String, exitCode: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .failed(let command, let exitCode, let stderr):
            return "Command '\(command)' failed (exit \(exitCode)): \(stderr)"
        }
    }
}

enum ShellService {
    /// Merges `overrides` into a base environment whose PATH matches the
    /// user's login shell. Without the EnvironmentService PATH override,
    /// GUI-launched Flight inherits launchd's stripped PATH and can't find
    /// `pnpm`, `claude`, or other tooling installed under `/opt/homebrew`
    /// or `~/.local/bin`. Critical for `runScriptStreaming` since `zsh -s`
    /// doesn't load rc files; harmless for `zsh -l` paths since they
    /// re-derive PATH from rc files anyway.
    private static func mergedEnvironment(_ overrides: [String: String]) -> [String: String] {
        EnvironmentService.baseEnvironment(overrides: overrides)
    }

    /// Builds the argv for `/bin/zsh` given a shell command string and
    /// optional positional args. When `extraArgs` is non-empty, `_` is
    /// inserted as `$0` so the first extra arg becomes `$1` inside the
    /// command — letting the command reference `$@`/`$1` naturally.
    private static func zshArgs(command: String, extraArgs: [String]) -> [String] {
        var args = ["-l", "-c", command]
        if !extraArgs.isEmpty {
            args.append("_")
            args.append(contentsOf: extraArgs)
        }
        return args
    }

    @discardableResult
    static func run(
        _ command: String,
        in directory: String? = nil,
        environment: [String: String] = [:],
        extraArgs: [String] = []
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = zshArgs(command: command, extraArgs: extraArgs)

        if let directory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }

        process.environment = mergedEnvironment(environment)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if process.terminationStatus != 0 {
                    continuation.resume(throwing: ShellError.failed(
                        command: command,
                        exitCode: process.terminationStatus,
                        stderr: stderr
                    ))
                } else {
                    continuation.resume(returning: stdout)
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Run a command and stream stdout lines via a callback. Returns the full stdout on completion.
    /// Supports Swift Task cancellation — the process is terminated if the calling task is cancelled.
    @discardableResult
    static func runStreaming(
        _ command: String,
        in directory: String? = nil,
        environment: [String: String] = [:],
        extraArgs: [String] = [],
        onLine: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = zshArgs(command: command, extraArgs: extraArgs)

        if let directory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }

        process.environment = mergedEnvironment(environment)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let fileHandle = stdoutPipe.fileHandleForReading
        // Use a sendable wrapper to accumulate output across actor boundaries
        final class OutputAccumulator: @unchecked Sendable {
            var value = ""
        }
        let output = OutputAccumulator()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task.detached {
                    var lineBuffer = Data()

                    while true {
                        let data = fileHandle.availableData
                        if data.isEmpty { break }

                        lineBuffer.append(data)

                        while let newlineIndex = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                            let lineData = lineBuffer[lineBuffer.startIndex..<newlineIndex]
                            lineBuffer = Data(lineBuffer[lineBuffer.index(after: newlineIndex)...])
                            if let line = String(data: Data(lineData), encoding: .utf8), !line.isEmpty {
                                output.value += line + "\n"
                                await MainActor.run { onLine(line) }
                            }
                        }
                    }

                    // Remaining partial line
                    if !lineBuffer.isEmpty, let line = String(data: lineBuffer, encoding: .utf8), !line.isEmpty {
                        output.value += line
                        await MainActor.run { onLine(line) }
                    }

                    process.waitUntilExit()

                    if process.terminationStatus != 0 {
                        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                        continuation.resume(throwing: ShellError.failed(
                            command: command,
                            exitCode: process.terminationStatus,
                            stderr: stderr
                        ))
                    } else {
                        continuation.resume(returning: output.value.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
            }
        } onCancel: {
            process.terminate()
        }
    }

    /// Run a script by piping its content to `/bin/zsh -s` on stdin. Streams
    /// merged stdout+stderr lines via the callback. Useful when the script
    /// content lives in memory (e.g. a settings field) rather than on disk.
    @discardableResult
    static func runScriptStreaming(
        scriptContent: String,
        in directory: String,
        onLine: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-s"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        // `zsh -s` does NOT load login/rc files, so without this PATH
        // override the script can't find `pnpm`, `mise`, or anything else
        // installed under /opt/homebrew or ~/.local/bin.
        process.environment = mergedEnvironment([:])

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stdoutPipe

        try process.run()

        // `exec 2>&1` ensures any later redirects in the script still merge
        // stderr into the same stream we're reading.
        let wrapped = "exec 2>&1\n" + scriptContent
        if let data = wrapped.data(using: .utf8) {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
        }
        try? stdinPipe.fileHandleForWriting.close()

        let fileHandle = stdoutPipe.fileHandleForReading
        final class OutputAccumulator: @unchecked Sendable {
            var value = ""
        }
        let output = OutputAccumulator()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task.detached {
                    var lineBuffer = Data()

                    while true {
                        let data = fileHandle.availableData
                        if data.isEmpty { break }

                        lineBuffer.append(data)

                        while let newlineIndex = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                            let lineData = lineBuffer[lineBuffer.startIndex..<newlineIndex]
                            lineBuffer = Data(lineBuffer[lineBuffer.index(after: newlineIndex)...])
                            if let line = String(data: Data(lineData), encoding: .utf8), !line.isEmpty {
                                output.value += line + "\n"
                                await MainActor.run { onLine(line) }
                            }
                        }
                    }

                    if !lineBuffer.isEmpty, let line = String(data: lineBuffer, encoding: .utf8), !line.isEmpty {
                        output.value += line
                        await MainActor.run { onLine(line) }
                    }

                    process.waitUntilExit()

                    if process.terminationStatus != 0 {
                        continuation.resume(throwing: ShellError.failed(
                            command: "worktree-setup",
                            exitCode: process.terminationStatus,
                            stderr: output.value
                        ))
                    } else {
                        continuation.resume(returning: output.value.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
            }
        } onCancel: {
            process.terminate()
        }
    }
}
