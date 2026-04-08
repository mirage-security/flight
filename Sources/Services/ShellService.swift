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
    @discardableResult
    static func run(_ command: String, in directory: String? = nil) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]

        if let directory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }

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
        onLine: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]

        if let directory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }

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
}
