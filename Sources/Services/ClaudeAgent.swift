import Foundation
import FlightCore

@Observable
final class ClaudeAgent {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var readTask: Task<Void, Never>?
    private var stderrReadTask: Task<Void, Never>?
    private var logHandle: FileHandle?
    private var directory: String = ""
    private var logFile: URL?
    private var pendingMessages: [PendingTurn] = []
    /// When non-nil, the agent talks to a remote workspace by wrapping its
    /// per-turn invocation through this connect command (e.g. a
    /// `.flight/connect` script or a custom `coder ssh ...` template).
    private var remoteConnect: ResolvedRemoteCommand?

    private(set) var isRunning = false
    private(set) var isBusy = false
    private(set) var turnStartDate: Date?
    private(set) var sessionID: String?
    var onMessages: (([AgentMessage]) -> Void)?
    var onSessionID: ((String) -> Void)?
    var onBusyChanged: ((Bool) -> Void)?

    private struct PendingTurn {
        let message: String
        let images: [Data]
        let planMode: Bool
        let model: String?
        let effort: String?
    }

    private enum StdinMode {
        case none
        case claudeStreamJSON
    }

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

    func send(
        message: String,
        images: [Data] = [],
        planMode: Bool = false,
        model: String? = nil,
        effort: String? = nil
    ) {
        // Add user message to the chat locally immediately
        let displayText = images.isEmpty ? message : "\(message)\n[📎 \(images.count) image\(images.count == 1 ? "" : "s") attached]"
        let userMessage = AgentMessage(role: .user, content: .text(displayText))
        onMessages?([userMessage])

        if isBusy {
            // Queue it — will fire when current turn completes
            log("=== QUEUED message (agent busy): \(message) ===")
            pendingMessages.append(PendingTurn(
                message: message,
                images: images,
                planMode: planMode,
                model: model,
                effort: effort
            ))
            return
        }

        spawnTurn(message: message, images: images, planMode: planMode, model: model, effort: effort)
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
        pendingMessages.removeAll()
        teardownCurrentTurn()
        log("=== Agent stopped at \(Date()) ===")
        try? logHandle?.close()
        logHandle = nil
        isRunning = false
        isBusy = false
    }

    /// Stop and wait for any in-flight stdout batch to finish. The read task
    /// builds a batch on a background executor and dispatches it via
    /// `await MainActor.run { onMessages?(batch) }`. A plain `stop()` cancels
    /// the task but a queued MainActor block can still fire afterwards and
    /// mutate `Conversation.messages`/`sections`. Callers tearing down the
    /// owning Worktree must await the drain so those mutations don't race the
    /// SwiftUI view tree being rebuilt around the doomed conversation.
    func stopAndDrain() async {
        let task = readTask
        stop()
        _ = await task?.value
    }

    /// Kill the current turn's claude -p and release its pipes. Each turn
    /// is a fresh `claude -p --resume <sid>` invocation — cheap and coherent
    /// because the session state lives in the jsonl — but only if we
    /// actually terminate the old process. Dropping our Swift reference
    /// alone leaves it alive under launchd (we've seen a dozen pile up for
    /// one session), and clearing the terminationHandler first prevents its
    /// late-firing callback from flipping `isBusy` off on the *next* turn.
    private func teardownCurrentTurn() {
        readTask?.cancel()
        stderrReadTask?.cancel()
        if let process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
        }
        // Foundation keeps Pipe FileHandles alive past their local scope
        // through the dead Process. Without these explicit closes every
        // turn leaks the read ends — a streaming session piles up FDs
        // until `Process.run()` starts failing with EBADF.
        try? stdoutPipe?.fileHandleForReading.close()
        try? stderrPipe?.fileHandleForReading.close()
        readTask = nil
        stderrReadTask = nil
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    // MARK: - Private

    private func spawnTurn(
        message: String,
        images: [Data] = [],
        planMode: Bool = false,
        model: String? = nil,
        effort: String? = nil
    ) {
        teardownCurrentTurn()

        let proc = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        let isRemote = remoteConnect != nil
        let stdinMode: StdinMode = isRemote ? .none : .claudeStreamJSON
        let usesStreamJSONInput = stdinMode == .claudeStreamJSON
        let writesToStdin = stdinMode != .none

        var claudeArgs = [
            "claude",
            "-p",
            "--output-format", "stream-json",
            "--verbose",
        ]

        if usesStreamJSONInput {
            claudeArgs += ["--input-format", "stream-json"]
        }

        // Local: use Claude Code's stream-json stdin protocol. Remote text
        // turns keep the historical prompt-arg path because some SSH wrappers
        // mishandle stdin. Remote image turns embed a base64 JSON payload in
        // the remote command, decode it to temp PNG files, then prompt Claude
        // with file paths; this avoids both stdin/TTY hangs and a Claude Code
        // resume + stream-json input failure on remote sessions.
        if !isRemote {
            claudeArgs += ["--allowedTools", "Write,Edit,Read,Glob,Grep,Agent,Task,ToolSearch,Skill,EnterPlanMode,ExitPlanMode,EnterWorktree,ExitWorktree,NotebookEdit,WebSearch,WebFetch,TodoWrite,AskUserQuestion,Bash(gh *),Bash(git *)"]
            claudeArgs += ["--permission-mode", planMode ? "plan" : "auto"]
            // Sandbox: filesystem scoped to cwd (worktree), network domains approved
            // via control_request handler. allowUnsandboxedCommands=false makes the
            // CLI ignore dangerouslyDisableSandbox entirely — no escape hatch.
            let ciLogsDir = ConfigService.worktreesBaseURL.appendingPathComponent("ci-logs").path
            claudeArgs += ["--settings", "{\"sandbox\":{\"enabled\":true,\"autoAllow\":true,\"allowUnsandboxedCommands\":false,\"excludedCommands\":[\"git *\",\"gh *\"],\"filesystem\":{\"allowRead\":[\"\(ciLogsDir)\"]}}}"]
        } else if planMode {
            // Plan mode is itself a permission gate — prefer it over skip-permissions.
            claudeArgs += ["--permission-mode", "plan"]
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

        if let model, !model.isEmpty {
            claudeArgs += ["--model", model]
        }
        if let effort, !effort.isEmpty {
            claudeArgs += ["--effort", effort]
        }

        if let remoteConnect {
            let remoteCmd = Self.makeRemoteCommand(
                message: message,
                images: images,
                claudeArgs: claudeArgs,
                uploadsImages: !images.isEmpty
            )

            log("=== REMOTE CONNECT: \(remoteConnect.command) ===")
            if images.isEmpty {
                log("=== REMOTE ARG: \(remoteCmd) ===")
            } else {
                let byteCount = images.reduce(0) { $0 + $1.count }
                log("=== REMOTE ARG: <remote image upload command: \(images.count) image(s), \(byteCount) bytes> ===")
            }
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-l", "-c", remoteConnect.command, "_", remoteCmd]
            if let cwd = remoteConnect.workingDirectory {
                proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
            }
            proc.environment = EnvironmentService.baseEnvironment(overrides: remoteConnect.environment)
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = claudeArgs
            proc.currentDirectoryURL = URL(fileURLWithPath: directory)
            // GUI launches inherit launchd's stripped PATH; without this
            // override `/usr/bin/env claude` exits 127 on every turn.
            proc.environment = EnvironmentService.baseEnvironment()
        }

        proc.standardInput = writesToStdin ? stdin : nil
        proc.standardOutput = stdout
        proc.standardError = stderr

        self.process = proc
        self.stdinPipe = writesToStdin ? stdin : nil
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        let busyCallback = self.onBusyChanged
        proc.terminationHandler = { [weak self] proc in
            let exitCode = proc.terminationStatus
            let reason = proc.terminationReason
            Task { @MainActor in
                if let self {
                    // Capture clean non-zero exits (e.g. `/usr/bin/env`
                    // returning 127 because `claude` isn't on PATH). Skip
                    // .uncaughtSignal — that's user-pressed-stop (SIGINT)
                    // or our own teardown (SIGTERM), neither is a bug.
                    if reason == .exit && exitCode != 0 {
                        self.log("=== Subprocess exited with status \(exitCode) ===")
                        SentryService.captureSubprocessFailure(
                            command: "claude",
                            exitCode: exitCode,
                            logFile: self.logFile
                        )
                    }
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
        turnStartDate = Date()
        onBusyChanged?(true)
        startReading()
        startStderrReading()

        if let stdinPipe = self.stdinPipe {
            switch stdinMode {
            case .claudeStreamJSON:
                if let jsonString = Self.makeStreamJSONInputLine(message: message, images: images),
                   let messageData = jsonString.data(using: .utf8) {
                    log(">>> STDIN: \(Self.redactedStreamJSONInputLine(jsonString))")
                    stdinPipe.fileHandleForWriting.write(messageData)
                }
            case .none:
                break
            }
        }
    }

    private func onTurnComplete() {
        guard isBusy else { return }
        isBusy = false
        turnStartDate = nil
        onBusyChanged?(false)

        // Process queued messages
        if !pendingMessages.isEmpty {
            let next = pendingMessages.removeFirst()
            log("=== Dequeuing pending message: \(next.message) ===")
            spawnTurn(
                message: next.message,
                images: next.images,
                planMode: next.planMode,
                model: next.model,
                effort: next.effort
            )
        }
    }

    static func makeStreamJSONInputLine(message: String, images: [Data]) -> String? {
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

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: data, encoding: .utf8) else {
            return nil
        }
        return jsonString + "\n"
    }

    static func makeRemoteCommand(
        message: String,
        images: [Data] = [],
        claudeArgs: [String],
        uploadsImages: Bool
    ) -> String {
        let flags = shellJoin(claudeArgs.dropFirst(2)) // drop "claude" and "-p"
        if uploadsImages {
            let payloadB64 = makeRemoteAttachmentUploadPayload(message: message, images: images)
            let script = """
            import base64, json, os, re, sys
            payload = json.loads(base64.b64decode(sys.argv[2]).decode("utf-8"))
            out_dir = sys.argv[1]
            os.makedirs(out_dir, exist_ok=True)
            paths = []
            for index, image in enumerate(payload.get("images", []), 1):
                raw_name = image.get("filename") or ("image-%d.png" % index)
                name = re.sub(r"[^A-Za-z0-9._-]", "_", raw_name)
                path = os.path.join(out_dir, name)
                with open(path, "wb") as handle:
                    handle.write(base64.b64decode(image["data"]))
                paths.append(path)
            message = payload.get("message") or "What's in this image?"
            if paths:
                lines = "\\n".join("%d. %s" % (i, path) for i, path in enumerate(paths, 1))
                prompt = "%s\\n\\nAttached image file(s):\\n%s\\n\\nUse the Read tool to inspect the attached image file(s) before answering any image-specific question." % (message, lines)
            else:
                prompt = message
            prompt_path = os.path.join(out_dir, "prompt.txt")
            with open(prompt_path, "w", encoding="utf-8") as handle:
                handle.write(prompt)
            print(prompt_path)
            """
            return """
            flight_dir="${TMPDIR:-/tmp}/flight-attachments-$(date +%s)-$$"; mkdir -p "$flight_dir"; prompt_file=$(python3 -c \(shellQuote(script)) "$flight_dir" \(shellQuote(payloadB64))) || exit $?; claude -p "$(cat "$prompt_file")" \(flags); status=$?; rm -rf "$flight_dir"; exit $status
            """
        }

        // Write message as base64 to a temp file on remote, then cat it into
        // claude's prompt. This command is passed as a single positional arg
        // to the connect wrapper; the remote shell does the command parsing.
        let b64 = Data(message.utf8).base64EncodedString()
        return "printf %s \(shellQuote(b64)) | base64 -d > /tmp/flight-prompt.txt && claude -p \"$(cat /tmp/flight-prompt.txt)\" \(flags)"
    }

    static func makeRemoteAttachmentUploadLine(message: String, images: [Data]) -> String? {
        let imagePayloads: [[String: Any]] = images.enumerated().map { index, data in
            [
                "filename": "image-\(index + 1).png",
                "media_type": "image/png",
                "data": data.base64EncodedString()
            ]
        }
        let payload: [String: Any] = [
            "message": message,
            "images": imagePayloads
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: data, encoding: .utf8) else {
            return nil
        }
        return jsonString + "\n"
    }

    private static func makeRemoteAttachmentUploadPayload(message: String, images: [Data]) -> String {
        guard let jsonString = makeRemoteAttachmentUploadLine(message: message, images: images) else {
            return ""
        }
        return Data(jsonString.utf8).base64EncodedString()
    }

    private static func shellJoin<S: Sequence>(_ values: S) -> String where S.Element == String {
        values.map(shellQuote).joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func redactedStreamJSONInputLine(_ line: String) -> String {
        let data = Data(line.utf8)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["message"] as? [String: Any],
              var content = message["content"] as? [[String: Any]] else {
            return line.trimmingCharacters(in: .newlines)
        }

        for index in content.indices where content[index]["type"] as? String == "image" {
            guard var source = content[index]["source"] as? [String: Any] else { continue }
            let original = source["data"] as? String ?? ""
            source["data"] = "<base64 image: \(original.count) chars>"
            content[index]["source"] = source
        }

        var redactedMessage = message
        redactedMessage["content"] = content
        var redactedObj = obj
        redactedObj["message"] = redactedMessage

        guard let redactedData = try? JSONSerialization.data(withJSONObject: redactedObj),
              let redacted = String(data: redactedData, encoding: .utf8) else {
            return line.trimmingCharacters(in: .newlines)
        }
        return redacted
    }

    private func log(_ line: String) {
        guard let logHandle else { return }
        if let data = "\(line)\n".data(using: .utf8) {
            logHandle.write(data)
        }
    }

    /// Drains the subprocess's stderr into the local log. Without this,
    /// errors like `env: claude: No such file or directory` (the bug that
    /// prompted this whole subsystem) sit in an undrained pipe and we
    /// have no signal beyond "the agent stopped responding."
    private func startStderrReading() {
        guard let stderrPipe else { return }
        let fileHandle = stderrPipe.fileHandleForReading

        stderrReadTask = Task.detached { [weak self] in
            var lineBuffer = Data()

            while !Task.isCancelled {
                let data = fileHandle.availableData
                if data.isEmpty { break }

                lineBuffer.append(data)

                var batch: [String] = []
                while let newlineIndex = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = lineBuffer[lineBuffer.startIndex..<newlineIndex]
                    lineBuffer = Data(lineBuffer[lineBuffer.index(after: newlineIndex)...])
                    if let line = String(data: Data(lineData), encoding: .utf8), !line.isEmpty {
                        batch.append(line)
                    }
                }

                if batch.isEmpty { continue }
                let lines = batch
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    for line in lines { self.log("<<< STDERR: \(line)") }
                }
            }
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

                // Parse all complete lines from this read into a batch,
                // then dispatch once to MainActor. This collapses N per-line
                // hops into 1, keeping the main thread free during fast streaming.
                var batchMessages: [AgentMessage] = []
                var newSessionID: String?
                var turnDone = false
                var controlResponses: [(id: String, allow: Bool)] = []
                var logLines: [String] = []

                while let newlineIndex = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = lineBuffer[lineBuffer.startIndex..<newlineIndex]
                    lineBuffer = Data(lineBuffer[lineBuffer.index(after: newlineIndex)...])

                    guard !lineData.isEmpty else { continue }

                    let lineStr = String(data: Data(lineData), encoding: .utf8) ?? "<binary>"
                    logLines.append(lineStr)

                    guard let event = try? JSONDecoder().decode(StreamEvent.self, from: Data(lineData)) else { continue }

                    if event.type == "system", let sid = event.sessionID {
                        newSessionID = sid
                    }
                    if event.type == "result" {
                        turnDone = true
                    }
                    if event.type == "control_request", let reqID = event.requestID {
                        let allow = Self.shouldApproveControlRequest(event.request)
                        controlResponses.append((id: reqID, allow: allow))
                    }
                    batchMessages.append(contentsOf: event.toAgentMessages())
                }

                if logLines.isEmpty { continue }

                let messages = batchMessages
                let done = turnDone
                let lines = logLines
                let sid = newSessionID
                let crs = controlResponses
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    for line in lines { self.log("<<< STDOUT: \(line)") }
                    if let sid {
                        self.sessionID = sid
                        self.onSessionID?(sid)
                    }
                    for cr in crs {
                        self.respondToControlRequest(requestID: cr.id, allow: cr.allow)
                        self.log("=== \(cr.allow ? "Approved" : "DENIED") control_request \(cr.id) ===")
                    }
                    if !messages.isEmpty { self.onMessages?(messages) }
                    if done { self.onTurnComplete() }
                }
            }
        }
    }

    // Hardcoded allowlist of hosts we'll auto-approve SandboxNetworkAccess
    // for. Anything off this list gets denied so the agent can't silently
    // reach arbitrary endpoints. Revisit this as a user-editable setting
    // once the UI has a control_request prompt surface.
    //
    // Package registries (npm/yarn/pypi/…) are intentionally omitted:
    // dependencies should be installed by `.flight/worktree-setup` before
    // the agent ever spawns. At agent runtime, needing the registry means
    // "add a new package" — a decision worth a human confirming, and the
    // denial turns a compromised postinstall's exfil traffic into a loud
    // failure instead of a silent approval.
    private static let allowedNetworkHosts: Set<String> = [
        "api.github.com",
        "github.com",
        "raw.githubusercontent.com",
        "objects.githubusercontent.com",
        "codeload.github.com",
    ]

    private static func shouldApproveControlRequest(_ request: StreamEvent.ControlRequest?) -> Bool {
        guard let request else { return false }
        // Defense-in-depth: refuse any request that tries to disable the
        // sandbox outright. --settings already has allowUnsandboxedCommands=false
        // so the CLI shouldn't forward these, but deny regardless.
        if request.input?["dangerouslyDisableSandbox"] != nil { return false }

        // Network access is gated by host. Everything else (file system
        // access inside the sandbox, ad-hoc tool approvals) we approve —
        // the sandbox is the real containment boundary.
        if request.toolName == "SandboxNetworkAccess" {
            guard let host = request.input?["host"]?.value as? String else { return false }
            return allowedNetworkHosts.contains(host)
        }
        return true
    }

    deinit {
        stop()
    }
}
