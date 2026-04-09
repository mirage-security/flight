import Foundation
import SwiftUI

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
        // Reload remote mode and forge configs per project
        for projectConfig in config.projects {
            if let project = projects.first(where: { $0.name == projectConfig.name }) {
                project.remoteMode = projectConfig.remoteMode
                project.forgeConfig = projectConfig.forgeConfig
            }
        }
    }

    func updateRemoteMode(_ config: RemoteModeConfig?, for project: Project) {
        project.remoteMode = config
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

        // Optimistic: show worktree immediately with "creating" status
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
              let listCmd = project.remoteMode?.list else { return [] }
        guard let output = try? await ShellService.run(listCmd) else { return [] }
        return output.components(separatedBy: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    func attachToWorkspace(workspaceName: String, initialPrompt: String) {
        guard let project = selectedProject ?? projects.first else { return }
        guard let remote = project.remoteMode else {
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

        let connectCmd = remote.connect.replacingOccurrences(of: "{workspace}", with: workspaceName)
        let connectPrefix = connectCmd.components(separatedBy: " ")

        saveConfig()

        let connMsg = AgentMessage(role: .system, content: .text("Connecting to \(workspaceName)..."))
        conversation.messages.append(connMsg)

        do {
            try startAgent(for: worktree, conversation: conversation, commandPrefix: connectPrefix)
            conversation.agent?.send(message: initialPrompt)
        } catch {
            showError("Failed to connect: \(error.localizedDescription)")
        }
    }

    func createRemoteWorktree(initialPrompt: String) {
        guard let project = selectedProject ?? projects.first else { return }
        guard let remote = project.remoteMode else {
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
                let provisionCmd = remote.provision.replacingOccurrences(of: "{branch}", with: branch)
                let workspaceName = try await ShellService.runStreaming(
                    provisionCmd,
                    in: project.path
                ) { [weak conversation] line in
                    let msg = AgentMessage(role: .system, content: .provisionLog(line))
                    conversation?.messages.append(msg)
                }.components(separatedBy: "\n").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                try Task.checkCancellation()

                worktree.workspaceName = workspaceName
                worktree.path = workspaceName // use workspace name as identifier

                // 2. Build connect prefix
                let connectCmd = remote.connect.replacingOccurrences(of: "{workspace}", with: workspaceName)
                let connectPrefix = connectCmd.components(separatedBy: " ")

                saveConfig()

                // 3. Connected!
                let connMsg = AgentMessage(role: .system, content: .text("Workspace \(workspaceName) ready. Connecting agent..."))
                conversation.messages.append(connMsg)

                // 4. Start agent with connect prefix and send initial prompt
                try startAgent(for: worktree, conversation: conversation, commandPrefix: connectPrefix)

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

        if worktree.isRemote, let workspaceName = worktree.workspaceName, let remote = project.remoteMode {
            // Only teardown if no other worktrees use this workspace
            let othersOnSameWorkspace = allWorktrees.contains {
                $0.id != worktree.id && $0.workspaceName == workspaceName
            }
            if !othersOnSameWorkspace {
                let teardownCmd = remote.teardown.replacingOccurrences(of: "{workspace}", with: workspaceName)
                _ = try? await ShellService.run(teardownCmd)
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

    func startAgent(for worktree: Worktree, conversation: Conversation, commandPrefix: [String]? = nil) throws {
        conversation.agent?.stop()

        let project = projectForWorktree(worktree)
        let logFile = project.map {
            ConfigService.logFileURL(repoName: $0.name, branch: worktree.branch)
        }

        // Build connect prefix for remote worktrees
        var prefix = commandPrefix ?? []
        if prefix.isEmpty, worktree.isRemote,
           let workspaceName = worktree.workspaceName,
           let remote = projectForWorktree(worktree)?.remoteMode {
            let connectCmd = remote.connect.replacingOccurrences(of: "{workspace}", with: workspaceName)
            prefix = connectCmd.components(separatedBy: " ")
        }

        let agent = ClaudeAgent()
        agent.onMessage = { [weak conversation] message in
            guard let conversation else { return }
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
            commandPrefix: prefix
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
              let forge = project.forgeProvider else { return }

        do {
            let checks = try await forge.getChecks(
                prNumber: prNumber,
                repoPath: project.path
            )
            worktree.ciStatus = CIStatus(checks: checks)
        } catch {
            // Silently fail CI checks — they'll retry on next poll
        }

        do {
            let status = try await forge.getPRStatus(
                prNumber: prNumber,
                repoPath: project.path
            )
            worktree.prStatus = status
        } catch {
            // Silently fail — retries on next poll
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
              let remote = projectForWorktree(worktree)?.remoteMode else {
            showError("Remote session is only available for remote worktrees.")
            return
        }

        let conversation = worktree.activeConversation
        let connectCmd = remote.connect.replacingOccurrences(of: "{workspace}", with: workspaceName)

        var claudeArgs = "claude"
        if let sessionID = conversation?.sessionID {
            claudeArgs += " --resume \(sessionID)"
        }

        // Use tmux to give claude a real PTY so it stays alive as an
        // interactive session visible in the Claude Code mobile app.
        let tmuxSession = "flight-\(worktree.branch.replacingOccurrences(of: "/", with: "-"))"
        let command = "\(connectCmd) \"tmux new-session -d -s \(tmuxSession) '\(claudeArgs)'\""

        if let conversation {
            let msg = AgentMessage(role: .system, content: .text("Starting remote session on \(workspaceName)..."))
            conversation.messages.append(msg)
        }

        Task {
            do {
                try await ShellService.run(command)
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
              let remote = projectForWorktree(worktree)?.remoteMode else { return }

        let connectCmd = remote.connect.replacingOccurrences(of: "{workspace}", with: workspaceName)

        // `claude export` dumps the session transcript as JSONL.
        // Adjust this command if the CLI surface changes.
        let fetchCmd = "\(connectCmd) \"claude export --session \(sessionID) --format jsonl\""

        do {
            let output = try await ShellService.run(fetchCmd)
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

    private func projectForWorktree(_ worktree: Worktree) -> Project? {
        projects.first { $0.worktrees.contains { $0.id == worktree.id } }
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
            guard let self else { return }
            Task { @MainActor in
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
