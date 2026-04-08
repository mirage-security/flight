import Foundation

enum GitHubService {
    /// Creates a PR from the worktree directory. Returns the PR number.
    static func createPR(in worktreePath: String, branch: String) async throws -> Int {
        let output = try await ShellService.run(
            "gh pr create --head '\(branch)' --fill",
            in: worktreePath
        )
        // gh pr create prints the PR URL, extract the number from the end
        if let url = URL(string: output.trimmingCharacters(in: .whitespacesAndNewlines)),
           let numberStr = url.pathComponents.last,
           let number = Int(numberStr) {
            return number
        }
        throw GitHubError.couldNotParsePRNumber(output)
    }

    /// Gets CI check status for a PR.
    static func getChecks(prNumber: Int, repoPath: String) async throws -> [CICheck] {
        let output = try await ShellService.run(
            "gh pr checks \(prNumber) --json name,state,conclusion",
            in: repoPath
        )
        guard let data = output.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([CICheck].self, from: data)) ?? []
    }

    /// Gets failed CI logs for a PR's latest run.
    static func getFailedLogs(prNumber: Int, repoPath: String) async throws -> String {
        // Get the run ID from failed checks
        let checksOutput = try await ShellService.run(
            "gh pr checks \(prNumber) --json name,state,conclusion,detailsUrl --jq '.[] | select(.conclusion == \"failure\") | .detailsUrl'",
            in: repoPath
        )

        // Extract run ID from the URL
        // URLs look like: https://github.com/owner/repo/actions/runs/12345/job/67890
        let lines = checksOutput.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard let firstURL = lines.first,
              let url = URL(string: firstURL) else {
            return "No failed checks found."
        }

        // Find the run ID in the URL path
        let components = url.pathComponents
        if let runsIndex = components.firstIndex(of: "runs"),
           runsIndex + 1 < components.count {
            let runId = components[runsIndex + 1]
            let logs = try await ShellService.run(
                "gh run view \(runId) --log-failed",
                in: repoPath
            )
            return logs
        }

        return "Could not determine run ID from CI check URL."
    }
}

enum GitHubError: Error, LocalizedError {
    case couldNotParsePRNumber(String)

    var errorDescription: String? {
        switch self {
        case .couldNotParsePRNumber(let output):
            return "Could not parse PR number from gh output: \(output)"
        }
    }
}
