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
    /// When non-nil, the agent talks to a remote workspace by wrapping its
    /// per-turn invocation through this connect command (e.g. a
    /// `.flight/connect` script or a custom `coder ssh ...` template).
    private var remoteConnect: ResolvedRemoteCommand?

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
        remoteConnect: ResolvedRemoteCommand? = nil
    ) throws {
        self.directory = directory
        self.logFile = logFile
        self.sessionID = resumeSessionID
        self.remoteConnect = remoteConnect

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

        let isRemote = remoteConnect != nil

        var claudeArgs = [
            "claude",
            "-p",
            "--output-format", "stream-json",
            "--verbose",
        ]

        // Local: use stdin for input. Remote: pass message as prompt arg (stdin over SSH is unreliable)
        if !isRemote {
            claudeArgs += ["--input-format", "stream-json"]
            claudeArgs += ["--allowedTools", "Write,Edit,Read,Glob,Grep,Agent,Task,ToolSearch,Skill,EnterPlanMode,ExitPlanMode,EnterWorktree,ExitWorktree,NotebookEdit,WebSearch,WebFetch,TodoWrite,AskUserQuestion"]
            claudeArgs += ["--permission-mode", "auto"]
            // Sandbox: filesystem scoped to cwd (worktree), network domains approved
            // via control_request handler. allowUnsandboxedCommands=false makes the
            // CLI ignore dangerouslyDisableSandbox entirely — no escape hatch.
            let ciLogsDir = ConfigService.worktreesBaseURL.appendingPathComponent("ci-logs").path
            claudeArgs += ["--settings", "{\"sandbox\":{\"enabled\":true,\"autoAllow\":true,\"allowUnsandboxedCommands\":false,\"excludedCommands\":[\"git *\",\"gh *\"],\"filesystem\":{\"allowRead\":[\"\(ciLogsDir)\"]}}}"]
        } else {
            // Remote workspaces are their own isolation boundary (separate
            // VM), so the local sandbox doesn't apply. Skip permission
            // prompts entirely — there's no interactive channel to approve
            // them over anyway.
            claudeArgs += ["--dangerously-skip-permissions"]
        }

        if let sessionID {
            claudeArgs += ["--resume", sessionID]
        }

        if let remoteConnect {
            // Write message as base64 to a temp file on remote, then cat it into claude's prompt.
            // Format: claude -p "$(cat /tmp/...)" --flags...
            // NOTE: this string is passed as a single positional arg to the
            // connect wrapper — no outer shell re-parses it, so the $ / "
            // characters are NOT escaped. The remote shell parses them.
            let b64 = Data(message.utf8).base64EncodedString()
            let flags = claudeArgs.dropFirst(2).joined(separator: " ") // drop "claude" and "-p"
            let remoteCmd = "echo \(b64) | base64 -d > /tmp/flight-prompt.txt && claude -p \"$(cat /tmp/flight-prompt.txt)\" \(flags)"

            log("=== REMOTE CONNECT: \(remoteConnect.command) ===")
            log("=== REMOTE ARG: \(remoteCmd) ===")
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-l", "-c", remoteConnect.command, "_", remoteCmd]
            if let cwd = remoteConnect.workingDirectory {
                proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
            }
            if !remoteConnect.environment.isEmpty {
                var env = ProcessInfo.processInfo.environment
                for (key, value) in remoteConnect.environment { env[key] = value }
                proc.environment = env
            }
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = claudeArgs
            proc.currentDirectoryURL = URL(fileURLWithPath: directory)
        }

        proc.standardInput = isRemote ? nil : stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout

        let busyCallback = self.onBusyChanged
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                if let self {
                    self.onTurnComplete()
                } else {
                    // Agent was deallocated before process exited —
                    // clear busy state directly so the UI doesn't stick on "thinking"
                    busyCallback?(false)
                }
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

        // Remote: message already passed as CLI arg, skip stdin
        if !isRemote, let stdinPipe = self.stdinPipe {
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
                    stdinPipe.fileHandleForWriting.write(messageData)
                }
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

                        // Auto-approve tool permission requests, but DENY sandbox overrides.
                        // This keeps the agent sandboxed to its worktree directory.
                        if event.type == "control_request",
                           let reqID = event.requestID {
                            let isSandboxOverride = event.request?.input?["dangerouslyDisableSandbox"] != nil
                            let allow = !isSandboxOverride
                            await MainActor.run { [weak self] in
                                self?.respondToControlRequest(requestID: reqID, allow: allow)
                                self?.log("=== \(allow ? "Approved" : "DENIED (sandbox override)") control_request \(reqID) ===")
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
