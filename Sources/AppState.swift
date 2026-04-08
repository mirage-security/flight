import Foundation
import SwiftUI

@Observable
final class AppState {
    var projects: [Project] = []
    var selectedProjectID: UUID?
    var selectedWorktreeID: UUID?

    // Dialogs
    var showingAddRepo = false
    var errorMessage: String?
    var showingError = false

    private var ciPollingTimer: Timer?

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
        startCIPolling()
    }

    // MARK: - Project Management

    func addProject(path: String) {
        guard !projects.contains(where: { $0.path == path }) else { return }
        let project = Project(path: path)
        projects.append(project)
        selectedProjectID = project.id
        saveConfig()
    }

    func removeProject(_ project: Project) {
        // Stop all agents in this project
        for worktree in project.worktrees {
            worktree.agent?.stop()
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
            try startAgent(for: worktree)
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

    func removeWorktree(_ worktree: Worktree) async {
        guard let project = projectForWorktree(worktree) else { return }

        worktree.agent?.stop()

        do {
            try await GitService.removeWorktree(
                repoPath: project.path,
                worktreePath: worktree.path,
                branch: worktree.branch
            )
        } catch {
            // Still remove from UI even if git cleanup fails
            showError(error.localizedDescription)
        }

        ConfigService.deleteChatHistory(worktreeID: worktree.id)
        project.worktrees.removeAll { $0.id == worktree.id }
        if selectedWorktreeID == worktree.id {
            selectedWorktreeID = project.worktrees.first?.id
        }
        saveConfig()
    }

    // MARK: - Agent Management

    func startAgent(for worktree: Worktree) throws {
        worktree.agent?.stop()

        let project = projectForWorktree(worktree)
        let logFile = project.map {
            ConfigService.logFileURL(repoName: $0.name, branch: worktree.branch)
        }

        let agent = ClaudeAgent()
        agent.onMessage = { [weak worktree] message in
            guard let worktree else { return }
            worktree.messages.append(message)
            ConfigService.saveMessages(worktree.messages, worktreeID: worktree.id)
        }
        agent.onSessionID = { [weak self, weak worktree] sessionID in
            worktree?.sessionID = sessionID
            self?.saveConfig()
        }
        agent.onBusyChanged = { [weak worktree] busy in
            worktree?.agentBusy = busy
        }

        try agent.start(in: worktree.path, resumeSessionID: worktree.sessionID, logFile: logFile)
        worktree.agent = agent
        worktree.status = .running
    }

    func respondToPermission(worktree: Worktree, requestID: String, allow: Bool) {
        worktree.agent?.respondToControlRequest(requestID: requestID, allow: allow)
    }

    func interruptAgent(for worktree: Worktree) {
        worktree.agent?.interrupt()
        let msg = AgentMessage(role: .system, content: .text("Interrupted"))
        worktree.messages.append(msg)
        ConfigService.saveMessages(worktree.messages, worktreeID: worktree.id)
    }

    func stopAgent(for worktree: Worktree) {
        worktree.agent?.stop()
        worktree.agent = nil
        worktree.status = .idle
    }

    func stopAllAgents() {
        for worktree in allWorktrees {
            worktree.agent?.stop()
        }
    }

    func restartAgent(for worktree: Worktree) {
        stopAgent(for: worktree)
        do {
            try startAgent(for: worktree)
        } catch {
            worktree.status = .error
            showError(error.localizedDescription)
        }
    }

    func sendMessage(_ text: String, to worktree: Worktree) {
        guard let agent = worktree.agent, agent.isRunning else {
            // Auto-start agent if not running
            do {
                try startAgent(for: worktree)
                worktree.agent?.send(message: text)
            } catch {
                showError(error.localizedDescription)
            }
            return
        }
        agent.send(message: text)
    }

    func clearChat(for worktree: Worktree) {
        worktree.messages.removeAll()
        ConfigService.saveMessages([], worktreeID: worktree.id)
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
              let project = projectForWorktree(worktree) else { return }

        do {
            let logs = try await GitHubService.getFailedLogs(
                prNumber: prNumber,
                repoPath: project.path
            )
            let message = "CI failed with these errors:\n\n\(logs)\n\nPlease fix."
            sendMessage(message, to: worktree)
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
        let config = FlightConfig(projects: projects.map { ProjectConfig(from: $0) })
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
