import Foundation

@Observable
final class ClaudeAgent {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var readTask: Task<Void, Never>?
    private var stderrReadTask: Task<Void, Never>?
    private var logHandle: FileHandle?

    private(set) var isRunning = false
    var onMessage: ((AgentMessage) -> Void)?

    func start(in directory: String, logFile: URL? = nil) throws {
        if let logFile {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
            logHandle = try FileHandle(forWritingTo: logFile)
            logHandle?.seekToEndOfFile()
            log("=== Flight agent started at \(Date()) ===")
            log("=== directory: \(directory) ===")
        }
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "claude",
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose",
            "--dangerously-skip-permissions",
            "--settings", "{\"sandbox\":{\"enabled\":true}}"
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.isRunning = false
            }
        }

        try process.run()
        isRunning = true

        startReading()
    }

    func send(message: String) {
        guard let stdinPipe, isRunning else { return }

        let payload: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": message
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var jsonString = String(data: data, encoding: .utf8) else { return }

        jsonString += "\n"

        if let messageData = jsonString.data(using: .utf8) {
            log(">>> STDIN: \(jsonString.trimmingCharacters(in: .newlines))")
            stdinPipe.fileHandleForWriting.write(messageData)
        }

        // Add user message to the chat locally
        let userMessage = AgentMessage(role: .user, content: .text(message))
        onMessage?(userMessage)
    }

    func stop() {
        readTask?.cancel()
        readTask = nil
        if let process, process.isRunning {
            process.terminate()
        }
        log("=== Agent stopped at \(Date()) ===")
        try? logHandle?.close()
        logHandle = nil
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        isRunning = false
    }

    private func log(_ line: String) {
        guard let logHandle else { return }
        if let data = "\(line)\n".data(using: .utf8) {
            logHandle.write(data)
        }
    }

    private func startReading() {
        guard let stdoutPipe else { return }

        let fileHandle = stdoutPipe.fileHandleForReading

        readTask = Task.detached { [weak self] in
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
            defer { buffer.deallocate() }

            var lineBuffer = Data()

            while !Task.isCancelled {
                let data = fileHandle.availableData
                if data.isEmpty { break } // EOF

                lineBuffer.append(data)

                // Process complete lines
                while let newlineIndex = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = lineBuffer[lineBuffer.startIndex..<newlineIndex]
                    lineBuffer = Data(lineBuffer[lineBuffer.index(after: newlineIndex)...])

                    guard !lineData.isEmpty else { continue }

                    let lineStr = String(data: Data(lineData), encoding: .utf8) ?? "<binary>"
                    await MainActor.run { [weak self] in
                        self?.log("<<< STDOUT: \(lineStr)")
                    }

                    // Parse JSON line
                    if let event = try? JSONDecoder().decode(StreamEvent.self, from: Data(lineData)) {
                        let messages = event.toAgentMessages()
                        for message in messages {
                            await MainActor.run { [weak self] in
                                self?.onMessage?(message)
                            }
                        }
                    }
                }
            }
        }
    }

    deinit {
        stop()
    }
}
