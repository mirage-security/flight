import Foundation
import SwiftUI
import os.log

private let ciLog = Logger(subsystem: "flight", category: "checkCI")

@Observable
final class AppState {
    var projects: [Project] = []
    var selectedProjectID: String?
    var selectedWorktreeID: String?

    // Dialogs
    var showingAddRepo = false
    var showingRemotePrompt = false
    var remoteInitialPrompt = ""
    var errorMessage: String?
    var showingError = false

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
                    ConfigService.deleteAllChatHistory(for: wt)
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

        // Fetch PR/CI status immediately for all worktrees with PRs
        Task {
            for worktree in allWorktrees where worktree.prNumber != nil {
                await checkCI(for: worktree)
            }
        }
    }

    var hasRemoteMode: Bool {
        (selectedProject ?? projects.first)?.hasRemoteMode ?? false
    }

    // MARK: - Project Management

    func addProject(path: String) {
        guard !projects.contains(where: { $0.path == path }) else { return }
        let project = Project(path: path)
        projects.append(project)
        selectedProjectID = project.id
        saveConfig()

        // Auto-detect forge from git remote
        Task {
            await detectForge(for: project)
        }
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
                repoPath: project.path,
                branch: branch,
                worktreePath: wtPath
            )

            saveConfig()

            // Run worktree setup script (settings field or .flight/worktree-setup)
            // before the agent ever spawns, so dependencies are deterministic and
            // the agent's sandbox can keep rejecting dynamic installs.
            if let resolved = WorktreeSetupService.resolveScript(project: project, worktreePath: wtPath) {
                conversation.messages.append(
                    AgentMessage(role: .system, content: .setupLog("Running setup script..."))
                )
                do {
                    try await WorktreeSetupService.run(
                        scriptContent: resolved.content,
                        in: wtPath
                    ) { [weak conversation] line in
                        let msg = AgentMessage(role: .system, content: .setupLog(line))
                        conversation?.messages.append(msg)
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

    func listRunningWorkspaces() async -> [String] {
        guard let project = selectedProject ?? projects.first,
              let resolved = RemoteScriptsService.resolve(.list, project: project) else { return [] }
        guard let output = try? await ShellService.run(
            resolved.command,
            in: resolved.workingDirectory,
            environment: resolved.environment
        ) else { return [] }
        return output.components(separatedBy: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    func attachToWorkspace(workspaceName: String, initialPrompt: String) {
        guard let project = selectedProject ?? projects.first else { return }
        guard let resolvedConnect = RemoteScriptsService.resolve(
            .connect, project: project, workspace: workspaceName
        ) else {
            showError("Remote mode not configured for this project.")
            return
        }

        // Generate a unique branch name for this session on the workspace
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()
        let branch = "\(workspaceName)/\(suffix)"

        let worktree = Worktree(
            branch: branch, path: workspaceName,
            status: .idle, isRemote: true, workspaceName: workspaceName
        )
        let conversation = worktree.ensureConversation()
        project.worktrees.append(worktree)
        selectedWorktreeID = worktree.id

        saveConfig()

        let connMsg = AgentMessage(role: .system, content: .text("Connecting to \(workspaceName)..."))
        conversation.messages.append(connMsg)

        do {
            try startAgent(for: worktree, conversation: conversation, remoteConnect: resolvedConnect)
            conversation.agent?.send(message: initialPrompt)
        } catch {
            showError("Failed to connect: \(error.localizedDescription)")
        }
    }

    func createRemoteWorktree(initialPrompt: String) {
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

        // Add a system message showing provisioning

        let worktreeID = worktree.id
        provisioningTasks[worktreeID] = Task {
            do {
                // 1. Provision: run the provision command, stream output as progress
                guard let resolvedProvision = RemoteScriptsService.resolve(
                    .provision, project: project, branch: branch
                ) else {
                    throw ShellError.failed(command: "provision", exitCode: -1, stderr: "Remote provision not configured")
                }
                let workspaceName = try await ShellService.runStreaming(
                    resolvedProvision.command,
                    in: resolvedProvision.workingDirectory ?? project.path,
                    environment: resolvedProvision.environment
                ) { [weak conversation] line in
                    let msg = AgentMessage(role: .system, content: .provisionLog(line))
                    conversation?.messages.append(msg)
                }.components(separatedBy: "\n").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

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
                let connMsg = AgentMessage(role: .system, content: .text("Workspace \(workspaceName) ready. Connecting agent..."))
                conversation.messages.append(connMsg)

                // 4. Start agent with connect wrapper and send initial prompt
                try startAgent(for: worktree, conversation: conversation, remoteConnect: resolvedConnect)

                // Notify when first response arrives
                let previousHandler = conversation.agent?.onBusyChanged
                conversation.agent?.onBusyChanged = { [weak conversation] busy in
                    previousHandler?(busy)
                    if !busy {
                        NotificationService.send(
                            title: "Remote Workspace Ready",
                            body: "\(workspaceName) — first response received"
                        )
                        // Restore original handler so we only notify once
                        conversation?.agent?.onBusyChanged = previousHandler
                    }
                }

                conversation.agent?.send(message: initialPrompt)
                NotificationService.send(
                    title: "Workspace Online",
                    body: "\(workspaceName) — prompt sent"
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
                _ = try? await ShellService.run(
                    resolved.command,
                    in: resolved.workingDirectory,
                    environment: resolved.environment
                )
            }
        } else {
            do {
                try await GitService.removeWorktree(
                    repoPath: project.path,
                    worktreePath: worktree.path,
                    branch: worktree.branch
                )
            } catch {
                showError(error.localizedDescription)
            }
        }

        ConfigService.deleteAllChatHistory(for: worktree)
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
        ConfigService.deleteChatHistory(conversationID: conversation.id)
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
        agent.onMessage = { [weak conversation] message in
            guard let conversation else { return }
            if case .toolUse(let name, _) = message.content {
                if name == "EnterPlanMode" { conversation.planMode = true }
                else if name == "ExitPlanMode" { conversation.planMode = false }
            }
            conversation.messages.append(message)
            ConfigService.saveMessages(conversation.messages, conversationID: conversation.id)
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
        conversation.agent?.interrupt()
        let msg = AgentMessage(role: .system, content: .text("Interrupted"))
        conversation.messages.append(msg)
        ConfigService.saveMessages(conversation.messages, conversationID: conversation.id)
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
        guard let agent = conversation.agent, agent.isRunning else {
            // Auto-start agent if not running
            do {
                try startAgent(for: worktree, conversation: conversation)
                conversation.agent?.send(message: text, images: images)
            } catch {
                showError(error.localizedDescription)
            }
            return
        }
        agent.send(message: text, images: images)
    }

    func clearChat(for conversation: Conversation) {
        conversation.messages.removeAll()
        ConfigService.saveMessages([], conversationID: conversation.id)
    }

    // MARK: - Forge Integration (PRs, CI)

    func createPR(for worktree: Worktree) async {
        guard let project = projectForWorktree(worktree),
              let forge = project.forgeProvider else {
            showError(ForgeError.noForgeConfigured.localizedDescription)
            return
        }

        do {
            let prNumber = try await forge.createPR(
                in: worktree.path,
                branch: worktree.branch
            )
            worktree.prNumber = prNumber
            saveConfig()

            // Immediately check CI
            await checkCI(for: worktree)
        } catch {
            showError(error.localizedDescription)
        }
    }

    func checkCI(for worktree: Worktree) async {
        guard let prNumber = worktree.prNumber,
              let project = projectForWorktree(worktree),
              let forge = project.forgeProvider else {
            ciLog.info("[checkCI] skipped for \(worktree.branch): prNumber=\(worktree.prNumber ?? -1), project=\(self.projectForWorktree(worktree)?.name ?? "nil"), hasForge=\(self.projectForWorktree(worktree)?.forgeProvider != nil)")
            return
        }

        ciLog.info("[checkCI] running for PR #\(prNumber) on \(project.name) (path: \(project.path))")

        do {
            let checks = try await forge.getChecks(
                prNumber: prNumber,
                repoPath: project.path
            )
            worktree.ciStatus = CIStatus(checks: checks)
            ciLog.info("[checkCI] checks: \(checks.count) results")

            // If checks are failing and we don't already have logs, pre-fetch
            if worktree.ciStatus?.overall == .failure,
               worktree.ciLogsPaths.isEmpty,
               !worktree.ciLogsFetching {
                worktree.ciLogsFetching = true
                Task {
                    defer { Task { @MainActor in worktree.ciLogsFetching = false } }
                    await fetchCILogs(for: worktree, prNumber: prNumber, repoPath: project.path, forge: forge)
                }
            }
        } catch {
            ciLog.info("[checkCI] getChecks failed: \(error)")
        }

        do {
            let status = try await forge.getPRStatus(
                prNumber: prNumber,
                repoPath: project.path
            )
            worktree.prStatus = status
            ciLog.info("[checkCI] prStatus: decision=\(status.reviewDecision ?? "nil"), reviews=\(status.reviews.count)")
        } catch {
            ciLog.info("[checkCI] getPRStatus failed: \(error)")
        }
    }

    private func fetchCILogs(for worktree: Worktree, prNumber: Int, repoPath: String, forge: ForgeProvider) async {
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
                        let logs = try await ShellService.run(
                            "timeout 15 gh api repos/\(owner)/\(repo)/actions/jobs/\(jobId)/logs",
                            in: repoPath
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
            let logs = try await forge.getFailedLogs(
                prNumber: prNumber,
                repoPath: project.path
            )
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

        let conversation = worktree.activeConversation

        var claudeArgs = "claude"
        if let sessionID = conversation?.sessionID {
            claudeArgs += " --resume \(sessionID)"
        }

        // Use tmux to give claude a real PTY so it stays alive as an
        // interactive session visible in the Claude Code mobile app.
        let tmuxSession = "flight-\(worktree.branch.replacingOccurrences(of: "/", with: "-"))"
        let tmuxCmd = "tmux new-session -d -s \(tmuxSession) '\(claudeArgs)'"

        if let conversation {
            let msg = AgentMessage(role: .system, content: .text("Starting remote session on \(workspaceName)..."))
            conversation.messages.append(msg)
        }

        Task {
            do {
                try await ShellService.run(
                    resolved.command,
                    in: resolved.workingDirectory,
                    environment: resolved.environment,
                    extraArgs: [tmuxCmd]
                )
                if let conversation {
                    conversation.remoteSessionActive = true
                    conversation.handoffMessageCount = conversation.messages.count
                    let msg = AgentMessage(role: .system, content: .text("Remote session started — available in Claude Code mobile app"))
                    conversation.messages.append(msg)
                    ConfigService.saveMessages(conversation.messages, conversationID: conversation.id)
                    saveConfig()
                }
            } catch {
                showError("Failed to start remote session: \(error.localizedDescription)")
            }
        }
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

                let separator = AgentMessage(
                    role: .system,
                    content: .text("Synced \(newMsgs.count) message\(newMsgs.count == 1 ? "" : "s") from remote session")
                )
                conversation.messages.append(separator)

                for msg in newMsgs {
                    conversation.messages.append(
                        AgentMessage(role: msg.role, content: .text(msg.text))
                    )
                }
            }
        } catch {
            let msg = AgentMessage(
                role: .system,
                content: .text("Could not sync remote session — continuing from last known state")
            )
            conversation.messages.append(msg)
        }

        conversation.remoteSessionActive = false
        conversation.handoffMessageCount = nil
        ConfigService.saveMessages(conversation.messages, conversationID: conversation.id)
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

    private func detectForge(for project: Project) async {
        if let detected = await ForgeType.detect(inRepo: project.path) {
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
        if let number = await forge.getPRNumber(branch: worktree.branch, repoPath: worktree.path) {
            worktree.prNumber = number
            saveConfig()
            await checkCI(for: worktree)
        }
    }

    deinit {
        ciPollingTimer?.invalidate()
    }
}
