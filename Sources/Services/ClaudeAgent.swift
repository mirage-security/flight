import Foundation

@Observable
final class ClaudeAgent {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var readTask: Task<Void, Never>?
    private var logHandle: FileHandle?
    private var directory: String = ""
    private var logFile: URL?
    private var pendingMessages: [String] = []
    private var commandPrefix: [String] = [] // e.g. ["coder", "ssh", "workspace", "--"]

    private(set) var isRunning = false
    private(set) var isBusy = false
    private(set) var sessionID: String?
    var onMessage: ((AgentMessage) -> Void)?
    var onSessionID: ((String) -> Void)?
    var onBusyChanged: ((Bool) -> Void)?

    func start(
        in directory: String,
        resumeSessionID: String? = nil,
        logFile: URL? = nil,
        commandPrefix: [String] = []
    ) throws {
        self.directory = directory
        self.logFile = logFile
        self.sessionID = resumeSessionID
        self.commandPrefix = commandPrefix

        if logHandle == nil, let logFile {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
            logHandle = try FileHandle(forWritingTo: logFile)
            logHandle?.seekToEndOfFile()
        }

        log("=== Flight agent started at \(Date()) ===")
        log("=== directory: \(directory) ===")

        isRunning = true
    }

    func send(message: String, images: [Data] = []) {
        // Add user message to the chat locally immediately
        let displayText = images.isEmpty ? message : "\(message)\n[📎 \(images.count) image\(images.count == 1 ? "" : "s") attached]"
        let userMessage = AgentMessage(role: .user, content: .text(displayText))
        onMessage?(userMessage)

        if isBusy {
            // Queue it — will fire when current turn completes
            log("=== QUEUED message (agent busy): \(message) ===")
            pendingMessages.append(message)
            return
        }

        spawnTurn(message: message, images: images)
    }

    func interrupt() {
        guard let process, process.isRunning else { return }
        log("=== SIGINT sent ===")
        process.interrupt()
    }

    func respondToControlRequest(requestID: String, allow: Bool) {
        guard let stdinPipe else { return }

        let response: [String: Any] = [
            "type": "control_response",
            "request_id": requestID,
            "response": [
                "allowed": allow
            ]
        ]

        if let data = try? JSONSerialization.data(withJSONObject: response),
           var jsonString = String(data: data, encoding: .utf8) {
            jsonString += "\n"
            if let messageData = jsonString.data(using: .utf8) {
                log(">>> STDIN (control_response): \(jsonString.trimmingCharacters(in: .newlines))")
                stdinPipe.fileHandleForWriting.write(messageData)
            }
        }
    }

    func stop() {
        readTask?.cancel()
        readTask = nil
        pendingMessages.removeAll()
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
        isBusy = false
    }

    // MARK: - Private

    private func spawnTurn(message: String, images: [Data] = []) {
        // Clean up previous process
        readTask?.cancel()
        readTask = nil
        process = nil
        stdinPipe = nil
        stdoutPipe = nil

        let proc = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        var claudeArgs = [
            "claude",
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose",
            "--dangerously-skip-permissions",
            "--settings", "{\"sandbox\":{\"enabled\":true,\"network\":{\"allowedDomains\":[\"github.com\",\"api.github.com\"]}}}"
        ]

        if let sessionID {
            claudeArgs += ["--resume", sessionID]
        }

        // Remote mode: prefix with connect command (e.g. coder ssh workspace --)
        let fullArgs = commandPrefix + claudeArgs

        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = fullArgs

        // Only set cwd for local mode
        if commandPrefix.isEmpty {
            proc.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.onTurnComplete()
            }
        }

        do {
            try proc.run()
        } catch {
            log("=== Failed to spawn turn: \(error) ===")
            isBusy = false
            return
        }

        isBusy = true
        onBusyChanged?(true)
        startReading()

        // Build message content — plain string for text-only, array for multimodal
        let content: Any
        if images.isEmpty {
            content = message
        } else {
            var blocks: [[String: Any]] = images.map { imageData in
                [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/png",
                        "data": imageData.base64EncodedString()
                    ]
                ]
            }
            blocks.append(["type": "text", "text": message])
            content = blocks
        }

        let payload: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": content
            ]
        ]

        if let data = try? JSONSerialization.data(withJSONObject: payload),
           var jsonString = String(data: data, encoding: .utf8) {
            jsonString += "\n"
            if let messageData = jsonString.data(using: .utf8) {
                log(">>> STDIN: \(jsonString.trimmingCharacters(in: .newlines))")
                stdin.fileHandleForWriting.write(messageData)
            }
        }
    }

    private func onTurnComplete() {
        guard isBusy else { return }
        isBusy = false
        onBusyChanged?(false)

        // Process queued messages
        if !pendingMessages.isEmpty {
            let next = pendingMessages.removeFirst()
            log("=== Dequeuing pending message: \(next) ===")
            spawnTurn(message: next)
        }
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
            var lineBuffer = Data()

            while !Task.isCancelled {
                let data = fileHandle.availableData
                if data.isEmpty { break } // EOF

                lineBuffer.append(data)

                while let newlineIndex = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = lineBuffer[lineBuffer.startIndex..<newlineIndex]
                    lineBuffer = Data(lineBuffer[lineBuffer.index(after: newlineIndex)...])

                    guard !lineData.isEmpty else { continue }

                    let lineStr = String(data: Data(lineData), encoding: .utf8) ?? "<binary>"
                    await MainActor.run { [weak self] in
                        self?.log("<<< STDOUT: \(lineStr)")
                    }

                    if let event = try? JSONDecoder().decode(StreamEvent.self, from: Data(lineData)) {
                        if event.type == "system", let sid = event.sessionID {
                            await MainActor.run { [weak self] in
                                self?.sessionID = sid
                                self?.onSessionID?(sid)
                            }
                        }

                        // Result event means the turn is done
                        if event.type == "result" {
                            await MainActor.run { [weak self] in
                                self?.onTurnComplete()
                            }
                        }

                        // Auto-approve sandbox permission requests
                        // (we use --dangerously-skip-permissions so these auto-resolve,
                        // but responding immediately avoids any timeout delay)
                        if event.type == "control_request",
                           let reqID = event.requestID {
                            await MainActor.run { [weak self] in
                                self?.respondToControlRequest(requestID: reqID, allow: true)
                                self?.log("=== Auto-approved control_request \(reqID) ===")
                            }
                        }

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
