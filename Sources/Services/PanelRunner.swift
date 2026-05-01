import Foundation

/// Long-running subprocess that streams a `PanelNode` tree to the right-hand
/// pane. One per worktree (when a `.flight/panels/<name>` script exists).
///
/// Lifecycle:
/// - `start()` spawns `/bin/zsh -l -c '<scriptPath>'` with the panel
///    environment. Reads NDJSON from stdout; each line decodes to a
///    `PanelEvent` that mutates `tree` / `title` / `errorBanner`.
/// - `stop()` SIGTERMs the process and cancels the reader tasks.
/// - `reload()` is `stop()` + `start()` plus a tree clear for immediate
///    feedback.
///
/// Slice 1 is read-only: stdin is closed, no callbacks. Stderr is buffered
/// so a future "view stderr" affordance can surface it; for now it's
/// available via `stderrLog`.
@Observable
final class PanelRunner {
    let scriptPath: String
    let workingDirectory: String
    let environment: [String: String]

    private(set) var tree: PanelNode?
    private(set) var title: String?
    private(set) var errorBanner: String?
    private(set) var isRunning: Bool = false
    private(set) var stderrLog: String = ""

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var readTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?

    init(scriptPath: String, workingDirectory: String, environment: [String: String]) {
        self.scriptPath = scriptPath
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    func start() {
        guard !isRunning else { return }

        let proc = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", shellQuote(scriptPath)]
        proc.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        proc.environment = EnvironmentService.baseEnvironment(overrides: environment)
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = stdout
        proc.standardError = stderr

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRunning = false
                self.process = nil
            }
        }

        self.process = proc
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        do {
            try proc.run()
        } catch {
            errorBanner = "Failed to start panel: \(error.localizedDescription)"
            self.process = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
            return
        }

        isRunning = true
        startStdoutReader()
        startStderrReader()
    }

    func stop() {
        readTask?.cancel()
        stderrTask?.cancel()
        readTask = nil
        stderrTask = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        isRunning = false
    }

    func reload() {
        stop()
        tree = nil
        title = nil
        errorBanner = nil
        stderrLog = ""
        start()
    }

    deinit {
        stop()
    }

    // MARK: - Readers

    private func startStdoutReader() {
        guard let pipe = stdoutPipe else { return }
        let fileHandle = pipe.fileHandleForReading

        readTask = Task.detached { [weak self] in
            var lineBuffer = Data()
            let decoder = JSONDecoder()

            while !Task.isCancelled {
                let data = fileHandle.availableData
                if data.isEmpty { break }
                lineBuffer.append(data)

                var batch: [PanelEvent] = []
                while let nl = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = lineBuffer[lineBuffer.startIndex..<nl]
                    lineBuffer = Data(lineBuffer[lineBuffer.index(after: nl)...])
                    guard !lineData.isEmpty else { continue }
                    if let event = try? decoder.decode(PanelEvent.self, from: Data(lineData)) {
                        batch.append(event)
                    }
                    // Non-JSON lines (set -x noise, accidental echoes) are
                    // silently dropped — same forgiving contract the doc
                    // promises so panels don't crash on stray output.
                }

                if batch.isEmpty { continue }
                let events = batch
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    for event in events { self.apply(event) }
                }
            }
        }
    }

    private func startStderrReader() {
        guard let pipe = stderrPipe else { return }
        let fileHandle = pipe.fileHandleForReading

        stderrTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                let data = fileHandle.availableData
                if data.isEmpty { break }
                guard let chunk = String(data: data, encoding: .utf8) else { continue }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // Cap at ~16KB so a chatty panel doesn't grow unbounded.
                    self.stderrLog.append(chunk)
                    if self.stderrLog.count > 16_384 {
                        let overflow = self.stderrLog.count - 16_384
                        self.stderrLog.removeFirst(overflow)
                    }
                }
            }
        }
    }

    private func apply(_ event: PanelEvent) {
        switch event {
        case .replace(let node):
            tree = node
        case .title(let text):
            title = text
        case .error(let message):
            errorBanner = message
        case .clearError:
            errorBanner = nil
        case .unknown:
            // Forward-compat: ignore unknown ops. Will surface in a future
            // debug log drawer.
            break
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
