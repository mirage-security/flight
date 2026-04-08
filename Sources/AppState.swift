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
    }

    func reloadConfig() {
        let config = ConfigService.load()
        // Reload remote mode configs per project
        for projectConfig in config.projects {
            if let project = projects.first(where: { $0.name == projectConfig.name }) {
                project.remoteMode = projectConfig.remoteMode
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
        let provMsg = AgentMessage(role: .system, content: .text("Provisioning remote workspace..."))
        conversation.messages.append(provMsg)

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
                conversation.agent?.send(message: initialPrompt)
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

    // MARK: - GitHub Integration

    func createPR(for worktree: Worktree) async {
        do {
            let prNumber = try await GitHubService.createPR(
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
              let project = projectForWorktree(worktree) else { return }

        do {
            let checks = try await GitHubService.getChecks(
                prNumber: prNumber,
                repoPath: project.path
            )
            worktree.ciStatus = CIStatus(checks: checks)
        } catch {
            // Silently fail CI checks — they'll retry on next poll
        }
    }

    func fixCI(for worktree: Worktree) async {
        guard let prNumber = worktree.prNumber,
              let project = projectForWorktree(worktree),
              let conversation = worktree.activeConversation else { return }

        do {
            let logs = try await GitHubService.getFailedLogs(
                prNumber: prNumber,
                repoPath: project.path
            )
            let message = "CI failed with these errors:\n\n\(logs)\n\nPlease fix."
            sendMessage(message, to: worktree, conversation: conversation)
        } catch {
            showError(error.localizedDescription)
        }
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
                for worktree in self.allWorktrees where worktree.prNumber != nil {
                    await self.checkCI(for: worktree)
                }
            }
        }
    }

    deinit {
        ciPollingTimer?.invalidate()
    }
}
