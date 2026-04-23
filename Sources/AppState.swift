import Foundation
import SwiftUI
import FlightCore
import os.log

private let ciLog = Logger(subsystem: "flight", category: "checkCI")

@Observable
final class AppState {
    var projects: [Project] = []
    var selectedProjectID: String?
    var selectedWorktreeID: String?

    // Dialogs
    var showingAddProjectSheet = false
    var errorMessage: String?
    var showingError = false

    // Project picker — generic disambiguation modal used by Cmd+N / Cmd+Shift+N.
    var showingProjectPicker = false
    var projectPickerTitle = ""
    var projectPickerCandidates: [Project] = []
    var projectPickerOnSelect: ((Project) -> Void)?

    private var ciPollingTimer: Timer?
    private var ciPollingInProgress = false
    private var provisioningTasks: [String: Task<Void, Never>] = [:]

    var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
    }

    var selectedWorktree: Worktree? {
        for project in projects {
            if let wt = project.worktrees.first(where: { $0.id == selectedWorktreeID }) {
                return wt
            }
        }
        return nil
    }

    var allWorktrees: [Worktree] {
        projects.flatMap(\.worktrees)
    }

    init() {
        ConfigService.ensureDirectories()
        let config = ConfigService.load()
        self.projects = config.projects.map { $0.toProject() }

        // Remove stale remote worktrees that never finished provisioning
        // (remote worktrees with no workspace name were mid-provision when the app quit)
        var didClean = false
        for project in projects {
            let stale = project.worktrees.filter { $0.isRemote && $0.workspaceName == nil }
            if !stale.isEmpty {
                for wt in stale {
                    for conv in wt.conversations {
                        FlightEventLog.delete(conversationID: conv.id)
                    }
                }
                project.worktrees.removeAll { $0.isRemote && $0.workspaceName == nil }
                didClean = true
            }
        }
        if didClean { saveConfig() }

        startCIPolling()

        // Auto-detect forge for any projects that don't have one configured yet
        Task {
            for project in projects where project.forgeConfig == nil {
                await detectForge(for: project)
            }
        }

        // Fetch PR/CI status immediately so the bar isn't blank until the
        // 30s polling tick. Worktrees without a known prNumber get
        // `discoverPR`, which also scans the conversation history — that
        // catches PRs opened on a renamed branch (where the gh branch
        // lookup fails).
        Task {
            for worktree in allWorktrees {
                if worktree.prNumber != nil {
                    await checkCI(for: worktree)
                } else {
                    await discoverPR(for: worktree)
                }
            }
        }
    }

    var hasRemoteMode: Bool {
        (selectedProject ?? projects.first)?.hasRemoteMode ?? false
    }

    var projectsWithRemoteMode: [Project] {
        projects.filter(\.hasRemoteMode)
    }

    /// Projects with a local clone on this machine. Remote-only projects
    /// are excluded — they can't host local worktrees.
    var projectsWithLocalClone: [Project] {
        projects.filter { $0.path != nil }
    }

    /// Presents the generic project picker for disambiguation. When there
    /// are 0 candidates this is a no-op; when there is exactly 1 it skips
    /// the picker entirely and runs `onSelect` immediately so single-project
    /// users feel zero friction.
    func presentProjectPicker(
        title: String,
        candidates: [Project],
        onSelect: @escaping (Project) -> Void
    ) {
        guard !candidates.isEmpty else { return }
        if candidates.count == 1 {
            onSelect(candidates[0])
            return
        }
        projectPickerTitle = title
        projectPickerCandidates = candidates
        projectPickerOnSelect = onSelect
        showingProjectPicker = true
    }

    // MARK: - Project Management

    enum AddProjectError: LocalizedError {
        case nameTaken(String)
        var errorDescription: String? {
            switch self {
            case .nameTaken(let name):
                return "A project named \(name) already exists. Pick a different name."
            }
        }
    }

    /// Adds a local project at `path`. `name` defaults to the folder's
    /// basename; callers should pass an explicit name when the basename
    /// collides with an existing project (e.g. a local `mirage` alongside
    /// a remote-only `mirage`).
    func addProject(path: String, name: String? = nil) throws {
        let resolvedName = name ?? URL(fileURLWithPath: path).lastPathComponent
        guard !projects.contains(where: { $0.name == resolvedName }) else {
            throw AddProjectError.nameTaken(resolvedName)
        }
        let project = Project(name: resolvedName, path: path)
        projects.append(project)
        selectedProjectID = project.id
        saveConfig()

        // Auto-detect forge from git remote
        Task {
            await detectForge(for: project)
        }
    }

    /// Adds a project with no local clone. Fetches the repo's committed
    /// `.flight/` scripts via the forge API and caches them under
    /// `~/flight/remote-scripts/<name>/` — those are what Flight runs to
    /// provision/connect/teardown remote workspaces. Throws if the fetch
    /// fails (e.g. missing scripts, auth, network) so the user gets
    /// immediate feedback rather than a confusing failure later.
    func addRemoteOnlyProject(name: String, forge: ForgeConfig) async throws {
        guard !projects.contains(where: { $0.name == name }) else {
            throw ForgeError.apiError("A project named \(name) already exists.")
        }
        try await RemoteScriptFetcher.fetchAll(forge: forge, projectName: name)
        let project = Project(
            name: name,
            path: nil,
            forgeConfig: forge
        )
        projects.append(project)
        selectedProjectID = project.id
        saveConfig()
    }

    func reloadConfig() {
        let config = ConfigService.load()
        // Reload remote mode, forge config, and setup script per project
        for projectConfig in config.projects {
            if let project = projects.first(where: { $0.name == projectConfig.name }) {
                project.remoteMode = projectConfig.remoteMode
                project.forgeConfig = projectConfig.forgeConfig
                project.setupScript = projectConfig.setupScript
            }
        }
    }

    func updateRemoteMode(_ config: RemoteModeConfig?, for project: Project) {
        project.remoteMode = config
        saveConfig()
    }

    func updateSetupScript(_ script: String?, for project: Project) {
        project.setupScript = script
        saveConfig()
    }

    func removeProject(_ project: Project) {
        // Stop all agents in this project
        for worktree in project.worktrees {
            for conversation in worktree.conversations {
                conversation.agent?.stop()
            }
        }
        projects.removeAll { $0.id == project.id }
        if selectedProjectID == project.id {
            selectedProjectID = projects.first?.id
            selectedWorktreeID = nil
        }
        saveConfig()
    }

    // MARK: - Worktree Management

    func createWorktree(branch: String) async {
        guard let project = selectedProject ?? projects.first else { return }
        // Local worktrees are meaningless for remote-only projects — the UI
        // won't offer Cmd+N on them, but guard anyway so a stray call here
        // doesn't crash on the force-unwrap below.
        guard let projectPath = project.path else {
            showError("This project has no local clone — use a remote worktree (Cmd+Shift+N).")
            return
        }
        let wtPath = ConfigService.worktreePath(repoName: project.name, branch: branch)

        // Optimistic: show worktree immediately with "creating" status.
        // ChatMessageListView shows a setup placeholder while status == .creating
        // and a setup script is configured, so the user gets feedback during the
        // git create + npm-install-resolving silence.
        let worktree = Worktree(branch: branch, path: wtPath, status: .creating)
        let conversation = worktree.ensureConversation()
        project.worktrees.append(worktree)
        selectedWorktreeID = worktree.id

        do {
            try await GitService.createWorktree(
                repoPath: projectPath,
                branch: branch,
                worktreePath: wtPath
            )

            saveConfig()

            // Run worktree setup script (settings field or .flight/worktree-setup)
            // before the agent ever spawns, so dependencies are deterministic and
            // the agent's sandbox can keep rejecting dynamic installs.
            if let resolved = WorktreeSetupService.resolveScript(project: project, worktreePath: wtPath) {
                appendFlightEvent(.setupLog("Running setup script..."), to: conversation)
                do {
                    try await WorktreeSetupService.run(
                        scriptContent: resolved.content,
                        in: wtPath
                    ) { [weak self, weak conversation] line in
                        guard let self, let conversation else { return }
                        self.appendFlightEvent(.setupLog(line), to: conversation)
                    }
                } catch {
                    // Leave the worktree on disk so the user can inspect/retry.
                    showError("Worktree setup failed: \(error.localizedDescription)")
                    worktree.status = .error
                    return
                }
            }

            // Auto-start agent
            try startAgent(for: worktree, conversation: conversation)
            flushPendingSend(for: conversation)
        } catch {
            // Remove the optimistic worktree on failure
            project.worktrees.removeAll { $0.id == worktree.id }
            showError(error.localizedDescription)
        }
    }

    func createWorktreeWithRandomName() async {
        let adjectives = ["swift", "bold", "calm", "dark", "keen", "warm", "cool", "fast", "wild", "soft"]
        let nouns = ["fox", "oak", "elm", "owl", "jay", "bee", "ant", "ray", "fin", "gem"]
        let adj = adjectives.randomElement()!
        let noun = nouns.randomElement()!
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()
        await createWorktree(branch: "flight/\(adj)-\(noun)-\(suffix)")
    }

    func createRemoteWorktree() {
        guard let project = selectedProject ?? projects.first else { return }
        guard RemoteScriptsService.isAvailable(.provision, project: project),
              RemoteScriptsService.isAvailable(.connect, project: project) else {
            showError("Remote mode not configured for this project.")
            return
        }

        let adjectives = ["swift", "bold", "calm", "dark", "keen", "warm", "cool", "fast", "wild", "soft"]
        let nouns = ["fox", "oak", "elm", "owl", "jay", "bee", "ant", "ray", "fin", "gem"]
        let adj = adjectives.randomElement()!
        let noun = nouns.randomElement()!
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()
        let branch = "flight/\(adj)-\(noun)-\(suffix)"

        // Optimistic: show immediately
        let worktree = Worktree(branch: branch, path: "", status: .creating, isRemote: true)
        let conversation = worktree.ensureConversation()
        project.worktrees.append(worktree)
        selectedWorktreeID = worktree.id

        // Kick off immediate UI feedback — remote provision commands can
        // stay silent for a few seconds before their first stdout line, and
        // a blank chat looks like "nothing is happening" to the user.
        appendFlightEvent(
            .provisionLog("Provisioning \(branch)…"),
            to: conversation
        )

        let worktreeID = worktree.id
        provisioningTasks[worktreeID] = Task {
            do {
                // 1. Provision: run the provision command, stream output as progress
                guard let resolvedProvision = RemoteScriptsService.resolve(
                    .provision, project: project, branch: branch
                ) else {
                    throw ShellError.failed(command: "provision", exitCode: -1, stderr: "Remote provision not configured")
                }
                let output = try await ShellService.runStreaming(
                    resolvedProvision.command,
                    in: resolvedProvision.workingDirectory,
                    environment: resolvedProvision.environment
                ) { [weak self, weak conversation, weak worktree] line in
                    // Reserved `FLIGHT_OUTPUT: key=value` lines are metadata,
                    // not progress — apply them to the worktree and suppress
                    // them from the displayed log.
                    if let (key, value) = RemoteScriptsService.parseFlightOutput(line) {
                        if let worktree {
                            switch key {
                            case "url":        worktree.remoteURL = value
                            case "repo_path":  worktree.remoteRepoPath = value
                            case "ssh_target": worktree.remoteSSHTarget = value
                            default:           break
                            }
                        }
                        return
                    }
                    guard let self, let conversation else { return }
                    self.appendFlightEvent(.provisionLog(line), to: conversation)
                }

                // Workspace name is the last non-metadata, non-empty line.
                let workspaceName = output
                    .components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .last(where: { !$0.isEmpty && RemoteScriptsService.parseFlightOutput($0) == nil })
                    ?? ""

                try Task.checkCancellation()

                worktree.workspaceName = workspaceName
                worktree.path = workspaceName // use workspace name as identifier

                // 2. Resolve connect wrapper for the new workspace
                guard let resolvedConnect = RemoteScriptsService.resolve(
                    .connect, project: project, workspace: workspaceName
                ) else {
                    throw ShellError.failed(command: "connect", exitCode: -1, stderr: "Remote connect not configured")
                }

                saveConfig()

                // 3. Connected!
                appendFlightEvent(
                    .systemNote("Workspace \(workspaceName) ready. Connecting agent..."),
                    to: conversation
                )

                // 4. Start the agent with the connect wrapper. The user
                // supplies the first prompt from the regular chat input.
                try startAgent(for: worktree, conversation: conversation, remoteConnect: resolvedConnect)
                flushPendingSend(for: conversation)

                NotificationService.send(
                    title: "Workspace Online",
                    body: "\(workspaceName) — ready for input"
                )
            } catch is CancellationError {
                // Task was cancelled (app quitting) — remove the incomplete worktree
                project.worktrees.removeAll { $0.id == worktree.id }
                saveConfig()
            } catch {
                project.worktrees.removeAll { $0.id == worktree.id }
                showError("Remote provisioning failed: \(error.localizedDescription)")
            }
            provisioningTasks.removeValue(forKey: worktreeID)
        }
    }

    func removeWorktree(_ worktree: Worktree) async {
        guard let project = projectForWorktree(worktree) else { return }

        for conversation in worktree.conversations {
            conversation.agent?.stop()
        }

        worktree.status = .deleting

        if worktree.isRemote, let workspaceName = worktree.workspaceName {
            // Only teardown if no other worktrees use this workspace
            let othersOnSameWorkspace = allWorktrees.contains {
                $0.id != worktree.id && $0.workspaceName == workspaceName
            }
            if !othersOnSameWorkspace,
               let resolved = RemoteScriptsService.resolve(
                .teardown, project: project, workspace: workspaceName
               ) {
                do {
                    try await ShellService.run(
                        resolved.command,
                        in: resolved.workingDirectory,
                        environment: resolved.environment
                    )
                } catch {
                    // Surface the error so the user knows the remote
                    // workspace may be orphaned. Flight still removes the
                    // worktree from the UI so they aren't stuck — they
                    // can clean up via whatever the project's teardown
                    // tool is.
                    showError("Teardown failed for \(workspaceName): \(error.localizedDescription). The remote workspace may still exist on the host — verify and clean up manually if needed.")
                }
            }
        } else if let projectPath = project.path {
            do {
                try await GitService.removeWorktree(
                    repoPath: projectPath,
                    worktreePath: worktree.path,
                    branch: worktree.branch
                )
            } catch {
                showError(error.localizedDescription)
            }
        }

        for conv in worktree.conversations {
            FlightEventLog.delete(conversationID: conv.id)
        }
        project.worktrees.removeAll { $0.id == worktree.id }
        if selectedWorktreeID == worktree.id {
            selectedWorktreeID = project.worktrees.first?.id
        }
        saveConfig()
    }

    // MARK: - Conversation Management

    func addConversation(to worktree: Worktree) {
        let count = worktree.conversations.count + 1
        let conversation = Conversation(name: "Chat \(count)")
        worktree.conversations.append(conversation)
        worktree.activeConversationID = conversation.id
        saveConfig()
    }

    func removeConversation(_ conversation: Conversation, from worktree: Worktree) {
        conversation.agent?.stop()
        FlightEventLog.delete(conversationID: conversation.id)
        worktree.conversations.removeAll { $0.id == conversation.id }

        // Select another conversation or create a new one
        if worktree.activeConversationID == conversation.id {
            worktree.activeConversationID = worktree.conversations.first?.id
        }
        if worktree.conversations.isEmpty {
            worktree.ensureConversation()
        }
        saveConfig()
    }

    func selectConversation(_ conversation: Conversation, in worktree: Worktree) {
        worktree.activeConversationID = conversation.id
    }

    // MARK: - Agent Management

    func startAgent(
        for worktree: Worktree,
        conversation: Conversation,
        remoteConnect: ResolvedRemoteCommand? = nil
    ) throws {
        conversation.agent?.stop()

        let project = projectForWorktree(worktree)
        let logFile = project.map {
            ConfigService.logFileURL(repoName: $0.name, branch: worktree.branch)
        }

        // Auto-resolve the connect wrapper for remote worktrees when the
        // caller didn't pass one (e.g. resume-on-launch path).
        var connect = remoteConnect
        if connect == nil, worktree.isRemote,
           let workspaceName = worktree.workspaceName,
           let project {
            connect = RemoteScriptsService.resolve(
                .connect, project: project, workspace: workspaceName
            )
        }

        let agent = ClaudeAgent()
        let conversationIsRemote = worktree.isRemote
        agent.onMessages = { [weak self, weak conversation, weak worktree] messages in
            guard let conversation else { return }
            for message in messages {
                if case .toolUse(let name, _) = message.content {
                    if name == "EnterPlanMode" { conversation.planMode = true }
                    else if name == "ExitPlanMode" { conversation.planMode = false }
                }
            }
            conversation.appendMessages(messages)
            // Local sessions persist via claude's own session jsonl, which
            // ConversationHistory.hydrate merges on reload. Remote sessions
            // have no accessible local jsonl, so Flight captures each streamed
            // message into its own event log as a `remoteMessage`.
            if conversationIsRemote {
                for message in messages {
                    FlightEventLog.append(
                        .remoteMessage(role: message.role, content: message.content),
                        conversationID: conversation.id
                    )
                }
            }
            if let self, let worktree, worktree.prNumber == nil {
                let texts = messages.compactMap { msg -> String? in
                    guard msg.role == .assistant,
                          case .text(let t) = msg.content else { return nil }
                    return t
                }
                if !texts.isEmpty {
                    self.scanForPRURL(in: texts, worktree: worktree)
                }
            }
        }
        agent.onSessionID = { [weak self, weak conversation] sessionID in
            conversation?.sessionID = sessionID
            self?.saveConfig()
        }
        agent.onBusyChanged = { [weak conversation] busy in
            conversation?.agentBusy = busy
        }

        try agent.start(
            in: worktree.path,
            resumeSessionID: conversation.sessionID,
            logFile: logFile,
            remoteConnect: connect
        )
        conversation.agent = agent
        worktree.status = .running
    }

    func respondToPermission(conversation: Conversation, requestID: String, allow: Bool) {
        conversation.agent?.respondToControlRequest(requestID: requestID, allow: allow)
    }

    func interruptAgent(for conversation: Conversation, in worktree: Worktree) {
        // Persist the interrupt marker before firing SIGINT. Append-only, so
        // a late-arriving assistant message (claude finished the turn before
        // the signal landed) shows up after this marker on next hydrate —
        // no race, no lost content.
        appendFlightEvent(.interrupt(), to: conversation)
        conversation.agent?.interrupt()
    }

    func stopAgent(for conversation: Conversation, in worktree: Worktree) {
        conversation.agent?.stop()
        conversation.agent = nil
        // Only set idle if no other conversations are running
        if !worktree.anyAgentRunning {
            worktree.status = .idle
        }
    }

    func stopAllAgents() {
        // Cancel any in-progress provisioning tasks (terminates the shell process)
        for (_, task) in provisioningTasks {
            task.cancel()
        }
        provisioningTasks.removeAll()

        for worktree in allWorktrees {
            for conversation in worktree.conversations {
                conversation.agent?.stop()
            }
        }
    }

    func restartAgent(for worktree: Worktree, conversation: Conversation) {
        stopAgent(for: conversation, in: worktree)
        do {
            try startAgent(for: worktree, conversation: conversation)
        } catch {
            worktree.status = .error
            showError(error.localizedDescription)
        }
    }

    func sendMessage(_ text: String, images: [Data] = [], to worktree: Worktree, conversation: Conversation) {
        let planMode = conversation.planMode
        let model = conversation.modelID ?? {
            let fallback = UserDefaults.standard.string(forKey: "flightDefaultModel") ?? ""
            return fallback.isEmpty ? nil : fallback
        }()
        let effort = conversation.effort?.rawValue

        // Worktree still provisioning: queue the message. startAgent during
        // this window would spawn a *local* claude (remote workspaceName is
        // nil, so the connect wrapper can't resolve) and run it against a
        // blank cwd — exactly the bug we're guarding against. The create
        // task calls flushPendingSend after the real agent is up.
        //
        // We deliberately do NOT append a user bubble to `messages` here —
        // ChatSection.build would treat the user bubble as a divider and
        // split the provision log group around it. Instead, the UI shows
        // pendingSend as a dimmed preview below the provision block until
        // the agent spawns; flush then runs a normal `agent.send` which
        // echoes a real user bubble chronologically after provisioning.
        if worktree.status == .creating {
            conversation.pendingSend = PendingSend(text: text, images: images)
            return
        }

        guard let agent = conversation.agent, agent.isRunning else {
            // Auto-start agent if not running
            do {
                try startAgent(for: worktree, conversation: conversation)
                conversation.agent?.send(message: text, images: images, planMode: planMode, model: model, effort: effort)
            } catch {
                showError(error.localizedDescription)
            }
            return
        }
        agent.send(message: text, images: images, planMode: planMode, model: model, effort: effort)
    }

    /// Flush a message the user queued while the worktree was still
    /// provisioning. The normal send-time echo appends the real user bubble
    /// *after* the provision block, which is what we want visually.
    private func flushPendingSend(for conversation: Conversation) {
        guard let pending = conversation.pendingSend,
              let agent = conversation.agent else { return }
        conversation.pendingSend = nil
        agent.send(
            message: pending.text,
            images: pending.images,
            planMode: conversation.planMode,
            model: conversation.modelID,
            effort: conversation.effort?.rawValue
        )
    }

    func clearChat(for conversation: Conversation) {
        // Write a `clear` marker instead of truncating. Hydrate drops anything
        // (flight or claude) strictly before the latest marker.
        FlightEventLog.append(.clear(), conversationID: conversation.id)
        conversation.clearMessages()
    }

    // MARK: - Forge Integration (PRs, CI)

    func checkCI(for worktree: Worktree) async {
        guard let prNumber = worktree.prNumber,
              let project = projectForWorktree(worktree),
              let forge = project.forgeProvider else {
            ciLog.info("[checkCI] skipped for \(worktree.branch): prNumber=\(worktree.prNumber ?? -1), project=\(self.projectForWorktree(worktree)?.name ?? "nil"), hasForge=\(self.projectForWorktree(worktree)?.forgeProvider != nil)")
            return
        }

        ciLog.info("[checkCI] running for PR #\(prNumber) on \(project.name)")

        do {
            let checks = try await forge.getChecks(prNumber: prNumber)
            worktree.ciStatus = CIStatus(checks: checks)
            ciLog.info("[checkCI] checks: \(checks.count) results")

            // If checks are failing and we don't already have logs, pre-fetch
            if worktree.ciStatus?.overall == .failure,
               worktree.ciLogsPaths.isEmpty,
               !worktree.ciLogsFetching {
                worktree.ciLogsFetching = true
                Task {
                    defer { Task { @MainActor in worktree.ciLogsFetching = false } }
                    await fetchCILogs(for: worktree, prNumber: prNumber)
                }
            }
        } catch {
            ciLog.info("[checkCI] getChecks failed: \(error)")
        }

        do {
            let status = try await forge.getPRStatus(prNumber: prNumber)
            worktree.prStatus = status
            ciLog.info("[checkCI] prStatus: decision=\(status.reviewDecision ?? "nil"), reviews=\(status.reviews.count)")
        } catch {
            ciLog.info("[checkCI] getPRStatus failed: \(error)")
        }
    }

    private func fetchCILogs(for worktree: Worktree, prNumber: Int) async {
        let failedChecks = worktree.ciStatus?.checks.filter { $0.state == "FAILURE" } ?? []
        ciLog.info("[fetchCILogs] \(failedChecks.count) failed checks, links: \(failedChecks.map { "\($0.name): \($0.link ?? "nil")" })")
        guard !failedChecks.isEmpty else { return }

        let safeBranch = worktree.branch.replacingOccurrences(of: "/", with: "-")
        let dir = ConfigService.worktreesBaseURL
            .appendingPathComponent("ci-logs")
            .appendingPathComponent(safeBranch)

        // Clean previous logs
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let paths = await withTaskGroup(of: (String, String)?.self) { group in
            for check in failedChecks {
                guard let link = check.link,
                      let url = URL(string: link),
                      let jobIndex = url.pathComponents.firstIndex(of: "job"),
                      jobIndex + 1 < url.pathComponents.count else { continue }

                let jobId = url.pathComponents[jobIndex + 1]
                let owner = url.pathComponents[1]
                let repo = url.pathComponents[2]
                let checkName = check.name

                group.addTask {
                    ciLog.info("[fetchCILogs] fetching job \(jobId) for \(checkName)")
                    do {
                        // `gh api` with an explicit repo path doesn't need a
                        // cwd inside a checkout, so this works for both
                        // local and remote-only projects.
                        let logs = try await ShellService.run(
                            "timeout 15 gh api repos/\(owner)/\(repo)/actions/jobs/\(jobId)/logs"
                        )
                        let safeName = checkName.replacingOccurrences(of: " ", with: "-")
                            .replacingOccurrences(of: "/", with: "-")
                        let logFile = dir.appendingPathComponent("\(safeName).log")
                        try logs.write(to: logFile, atomically: true, encoding: .utf8)
                        ciLog.info("[fetchCILogs] wrote \(checkName) to \(logFile.path)")
                        return (checkName, logFile.path)
                    } catch {
                        ciLog.info("[fetchCILogs] failed for \(checkName): \(error)")
                        return nil
                    }
                }
            }

            var result: [String: String] = [:]
            for await pair in group {
                if let (name, path) = pair {
                    result[name] = path
                }
            }
            return result
        }

        if !paths.isEmpty {
            await MainActor.run {
                worktree.ciLogsPaths = paths
            }
        }
    }

    func fixCI(for worktree: Worktree) async {
        guard let prNumber = worktree.prNumber,
              let project = projectForWorktree(worktree),
              let forge = project.forgeProvider,
              let conversation = worktree.activeConversation else { return }

        do {
            let logs = try await forge.getFailedLogs(prNumber: prNumber)
            let message = "CI failed with these errors:\n\n\(logs)\n\nPlease fix."
            sendMessage(message, to: worktree, conversation: conversation)
        } catch {
            showError(error.localizedDescription)
        }
    }

    // MARK: - Remote Session

    /// Starts a detached interactive `claude` session on the remote workspace
    /// via SSH. Because it runs as a full (non `-p`) process it registers with
    /// the Anthropic backend and appears in the Claude Code mobile app.
    /// Opens the worktree in a fresh VS Code window. Local worktrees use
    /// the on-disk path; remote worktrees go through Remote-SSH using the
    /// `ssh_target` and `repo_path` emitted by provision via FLIGHT_OUTPUT.
    func openInVSCode(for worktree: Worktree) {
        let command: String
        if worktree.isRemote {
            guard let sshTarget = worktree.remoteSSHTarget,
                  let repoPath = worktree.remoteRepoPath else {
                showError("Can't open in VS Code: remote worktree is missing ssh_target or repo_path. Have your provision script emit `FLIGHT_OUTPUT: ssh_target=...` and `FLIGHT_OUTPUT: repo_path=...`.")
                return
            }
            let host = "ssh-remote+\(sshTarget)"
            command = "code --new-window --remote \(shellQuote(host)) \(shellQuote(repoPath))"
        } else {
            command = "code --new-window \(shellQuote(worktree.path))"
        }
        Task {
            do {
                try await ShellService.run(command)
            } catch {
                showError("Failed to open VS Code: \(error.localizedDescription)")
            }
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Opens an interactive remote shell in the user's default terminal
    /// app (whatever is registered as the `.command` file handler —
    /// Terminal.app by default, iTerm if the user has changed it). We
    /// write a short launcher script that runs the project's resolved
    /// connect command with no extra args, so the connect script opens
    /// an interactive SSH session on the workspace.
    func openRemoteSession(for worktree: Worktree) {
        guard worktree.isRemote,
              let workspaceName = worktree.workspaceName,
              let project = projectForWorktree(worktree),
              let resolved = RemoteScriptsService.resolve(
                .connect, project: project, workspace: workspaceName
              ) else {
            showError("Remote session is only available for remote worktrees.")
            return
        }

        var script = "#!/bin/zsh -l\n"
        script += "# Auto-generated by Flight — opens a remote shell on \(workspaceName).\n"
        if let cwd = resolved.workingDirectory {
            script += "cd \(shellQuote(cwd))\n"
        }
        for (key, value) in resolved.environment {
            script += "export \(key)=\(shellQuote(value))\n"
        }
        // The resolved command already ends in `"$@"` for `.flight/`
        // scripts — with no positional args that expands to nothing,
        // giving an interactive remote shell. Settings templates just
        // run as-is.
        script += resolved.command + "\n"

        let safeBranch = worktree.branch.replacingOccurrences(of: "/", with: "-")
        let filename = "flight-\(safeBranch)-\(UUID().uuidString.prefix(8)).command"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: url.path
            )
        } catch {
            showError("Failed to create terminal launcher: \(error.localizedDescription)")
            return
        }

        if let terminal = preferredTerminalAppURL() {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: config) { _, error in
                if let error {
                    Task { @MainActor in
                        self.showError("Failed to open terminal: \(error.localizedDescription)")
                    }
                }
            }
        } else if !NSWorkspace.shared.open(url) {
            showError("Couldn't launch terminal — no app is registered to open .command files.")
        }
    }

    /// macOS has no real "default terminal" concept — `.command` files are
    /// bound to Terminal.app via UTI, and users running iTerm/Warp/etc.
    /// rarely rebind that. Pick a third-party terminal if one is running
    /// (user's active choice) or installed (likely preference). Falling
    /// back to `nil` lets `NSWorkspace.open` route to the `.command` UTI
    /// handler, which is Terminal.app.
    private func preferredTerminalAppURL() -> URL? {
        let thirdParty = [
            "com.googlecode.iterm2",   // iTerm2
            "dev.warp.Warp-Stable",    // Warp
            "com.mitchellh.ghostty",   // Ghostty
            "net.kovidgoyal.kitty",    // kitty
            "com.github.wez.wezterm",  // WezTerm
            "co.zeit.hyper",           // Hyper
            "io.alacritty",            // Alacritty
        ]
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if let id = thirdParty.first(where: { running.contains($0) }),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return url
        }
        for id in thirdParty {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return url
            }
        }
        return nil
    }

    /// Fetches the session transcript from the remote workspace and backfills
    /// any messages that happened outside Flight (e.g. via the mobile app).
    func syncRemoteSession(for worktree: Worktree, conversation: Conversation) async {
        guard let sessionID = conversation.sessionID,
              worktree.isRemote,
              let workspaceName = worktree.workspaceName,
              let project = projectForWorktree(worktree),
              let resolved = RemoteScriptsService.resolve(
                .connect, project: project, workspace: workspaceName
              ) else { return }

        // `claude export` dumps the session transcript as JSONL.
        // Adjust this command if the CLI surface changes.
        let fetchCmd = "claude export --session \(sessionID) --format jsonl"

        do {
            let output = try await ShellService.run(
                resolved.command,
                in: resolved.workingDirectory,
                environment: resolved.environment,
                extraArgs: [fetchCmd]
            )
            let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }

            // Parse each line as a {role, content} object
            var remoteMsgs: [(role: MessageRole, text: String)] = []
            for line in lines {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let role = obj["role"] as? String else { continue }

                // content may be a plain string or an array of content blocks
                let text: String
                if let s = obj["content"] as? String {
                    text = s
                } else if let blocks = obj["content"] as? [[String: Any]] {
                    text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
                } else {
                    continue
                }
                guard !text.isEmpty else { continue }

                let msgRole: MessageRole = role == "user" ? .user : .assistant
                remoteMsgs.append((role: msgRole, text: text))
            }

            // Only backfill messages that occurred after the handoff
            let handoff = conversation.handoffMessageCount ?? 0
            if remoteMsgs.count > handoff {
                let newMsgs = Array(remoteMsgs[handoff...])

                appendFlightEvent(
                    .systemNote("Synced \(newMsgs.count) message\(newMsgs.count == 1 ? "" : "s") from remote session"),
                    to: conversation
                )
                for msg in newMsgs {
                    appendFlightEvent(
                        .remoteMessage(role: msg.role, content: .text(msg.text)),
                        to: conversation
                    )
                }
            }
        } catch {
            appendFlightEvent(
                .systemNote("Could not sync remote session — continuing from last known state"),
                to: conversation
            )
        }

        conversation.remoteSessionActive = false
        conversation.handoffMessageCount = nil
        saveConfig()
    }

    // MARK: - Keyboard Shortcut Actions

    func selectWorktreeByIndex(_ index: Int) {
        let all = allWorktrees
        guard index >= 0, index < all.count else { return }
        selectedWorktreeID = all[index].id
        if let project = projectForWorktree(all[index]) {
            selectedProjectID = project.id
        }
    }

    // MARK: - Private

    /// Persist a Flight-owned event and mirror it into the in-memory message
    /// list so the UI reflects it immediately. The on-disk flight.jsonl stays
    /// the source of truth on hydrate.
    private func appendFlightEvent(_ event: FlightEvent, to conversation: Conversation) {
        FlightEventLog.append(event, conversationID: conversation.id)
        if let msg = event.toAgentMessage() {
            conversation.appendMessage(msg)
        }
    }

    private func detectForge(for project: Project) async {
        // Auto-detection requires reading the `origin` remote from a local
        // checkout. Remote-only projects must set forgeConfig explicitly at
        // add-time.
        guard let projectPath = project.path else { return }
        if let detected = await ForgeType.detect(inRepo: projectPath) {
            project.forgeConfig = ForgeConfig(type: detected)
            saveConfig()
        }
    }

    func projectFor(worktree: Worktree) -> Project? {
        projects.first { $0.worktrees.contains { $0.id == worktree.id } }
    }

    private func projectForWorktree(_ worktree: Worktree) -> Project? {
        projectFor(worktree: worktree)
    }

    private func saveConfig() {
        let config = FlightConfig(
            projects: projects.map { ProjectConfig(from: $0) }
        )
        ConfigService.save(config)
    }

    private func showError(_ message: String) {
        errorMessage = message
        showingError = true
    }

    private func startCIPolling() {
        ciPollingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, !self.ciPollingInProgress else { return }
            Task { @MainActor in
                self.ciPollingInProgress = true
                defer { self.ciPollingInProgress = false }
                for worktree in self.allWorktrees {
                    if worktree.prNumber != nil {
                        await self.checkCI(for: worktree)
                    } else {
                        await self.discoverPR(for: worktree)
                    }
                }
            }
        }
    }

    private func discoverPR(for worktree: Worktree) async {
        guard let project = projectForWorktree(worktree),
              let forge = project.forgeProvider else { return }
        if let number = await forge.getPRNumber(branch: worktree.branch) {
            worktree.prNumber = number
            saveConfig()
            await checkCI(for: worktree)
            return
        }
        // Branch lookup can miss when the PR was opened from a different
        // head ref (e.g. the agent renamed the branch before `gh pr create`).
        // Fall back to scanning the conversation transcripts for a URL that
        // points at this project's repo.
        let texts = worktree.conversations.flatMap { conv in
            conv.messages.compactMap { msg -> String? in
                guard msg.role == .assistant,
                      case .text(let t) = msg.content else { return nil }
                return t
            }
        }
        for text in texts {
            if let number = await project.extractPRNumber(from: text) {
                worktree.prNumber = number
                saveConfig()
                await checkCI(for: worktree)
                return
            }
        }
    }

    /// Fires when new assistant text lands — if the worktree doesn't yet have
    /// a PR attached, try to pull one out of the text so the PR bar shows up
    /// as soon as the agent prints the URL.
    private func scanForPRURL(in texts: [String], worktree: Worktree) {
        Task { [weak self, weak worktree] in
            guard let self, let worktree, worktree.prNumber == nil,
                  let project = self.projectForWorktree(worktree) else { return }
            for text in texts {
                guard let number = await project.extractPRNumber(from: text) else { continue }
                await MainActor.run {
                    guard worktree.prNumber == nil else { return }
                    worktree.prNumber = number
                    self.saveConfig()
                }
                await self.checkCI(for: worktree)
                return
            }
        }
    }

    deinit {
        ciPollingTimer?.invalidate()
    }
}
