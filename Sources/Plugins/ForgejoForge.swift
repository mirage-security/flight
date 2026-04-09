import Foundation

/// Forgejo/Gitea forge provider using the REST API.
///
/// Authentication: reads the API token from the environment variable
/// specified by `tokenEnvVar` (defaults to FORGEJO_TOKEN).
///
/// The base URL should point to your Forgejo instance root
/// (e.g. "https://git.example.com" or "http://localhost:3000").
struct ForgejoForge: ForgeProvider {
    let displayName = "Forgejo"
    let baseURL: String
    let tokenEnvVar: String

    init(baseURL: String, tokenEnvVar: String? = nil) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.tokenEnvVar = tokenEnvVar ?? "FORGEJO_TOKEN"
    }

    // MARK: - ForgeProvider

    func createPR(in worktreePath: String, branch: String) async throws -> Int {
        let (owner, repo) = try await parseRemote(in: worktreePath)
        let defaultBranch = try await getDefaultBranch(in: worktreePath)

        let body: [String: Any] = [
            "title": branch,
            "head": branch,
            "base": defaultBranch
        ]

        let result: [String: Any] = try await apiRequest(
            method: "POST",
            path: "/api/v1/repos/\(owner)/\(repo)/pulls",
            body: body
        )

        guard let number = result["number"] as? Int else {
            throw ForgeError.couldNotParsePRNumber(String(describing: result))
        }
        return number
    }

    func getChecks(prNumber: Int, repoPath: String) async throws -> [CICheck] {
        let (owner, repo) = try await parseRemote(in: repoPath)

        // Get the PR to find the head SHA
        let pr: [String: Any] = try await apiRequest(
            method: "GET",
            path: "/api/v1/repos/\(owner)/\(repo)/pulls/\(prNumber)"
        )

        guard let head = pr["head"] as? [String: Any],
              let sha = head["sha"] as? String else {
            return []
        }

        // Get commit statuses (Forgejo Actions / Woodpecker / Drone report here)
        let statuses: [[String: Any]] = try await apiRequest(
            method: "GET",
            path: "/api/v1/repos/\(owner)/\(repo)/statuses/\(sha)"
        )

        return statuses.compactMap { status in
            guard let name = status["context"] as? String,
                  let state = status["status"] as? String else { return nil }
            // Map Forgejo states (pending/success/error/failure/warning) to our model
            let conclusion: String? = switch state {
            case "success": "success"
            case "failure", "error": "failure"
            case "warning": "neutral"
            default: nil  // pending
            }
            let ciState = (conclusion != nil) ? "completed" : "pending"
            return CICheck(name: name, state: ciState, conclusion: conclusion)
        }
    }

    func getFailedLogs(prNumber: Int, repoPath: String) async throws -> String {
        let (owner, repo) = try await parseRemote(in: repoPath)

        // Get action runs for this repo and find failures
        let runs: [String: Any] = try await apiRequest(
            method: "GET",
            path: "/api/v1/repos/\(owner)/\(repo)/actions/runs"
        )

        guard let workflows = runs["workflow_runs"] as? [[String: Any]] else {
            return "No CI runs found."
        }

        let failed = workflows.filter { ($0["conclusion"] as? String) == "failure" }
        guard let latest = failed.first,
              let runID = latest["id"] as? Int else {
            return "No failed runs found."
        }

        // Get the jobs for this run
        let jobs: [String: Any] = try await apiRequest(
            method: "GET",
            path: "/api/v1/repos/\(owner)/\(repo)/actions/runs/\(runID)/jobs"
        )

        guard let jobList = jobs["jobs"] as? [[String: Any]] else {
            return "No jobs found for run \(runID)."
        }

        var logOutput = ""
        for job in jobList {
            guard (job["conclusion"] as? String) == "failure",
                  let jobID = job["id"] as? Int,
                  let jobName = job["name"] as? String else { continue }

            // Fetch logs for this job
            let logText = try await rawAPIRequest(
                method: "GET",
                path: "/api/v1/repos/\(owner)/\(repo)/actions/runs/\(runID)/jobs/\(jobID)/logs"
            )
            logOutput += "=== \(jobName) ===\n\(logText)\n\n"
        }

        return logOutput.isEmpty ? "No failed job logs found." : logOutput
    }

    // MARK: - Helpers

    private func parseRemote(in path: String) async throws -> (owner: String, repo: String) {
        let output = try await ShellService.run("git remote get-url origin", in: path)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle SSH (git@host:owner/repo.git) and HTTP (https://host/owner/repo.git)
        let cleaned: String
        if trimmed.contains("@") {
            // SSH format: git@host:owner/repo.git
            cleaned = trimmed.components(separatedBy: ":").last ?? trimmed
        } else {
            // HTTP format: extract path after host
            cleaned = URL(string: trimmed)?.pathComponents
                .suffix(2).joined(separator: "/") ?? trimmed
        }

        let parts = cleaned
            .replacingOccurrences(of: ".git", with: "")
            .components(separatedBy: "/")
            .filter { !$0.isEmpty }

        guard parts.count >= 2 else {
            throw ForgeError.apiError("Could not parse owner/repo from remote: \(trimmed)")
        }
        return (parts[parts.count - 2], parts[parts.count - 1])
    }

    private func getDefaultBranch(in path: String) async throws -> String {
        let output = try await ShellService.run(
            "git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || echo refs/remotes/origin/main",
            in: path
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "refs/remotes/origin/", with: "")
    }

    private var token: String? {
        ProcessInfo.processInfo.environment[tokenEnvVar]
    }

    private func apiRequest<T>(method: String, path: String, body: [String: Any]? = nil) async throws -> T {
        let raw = try await rawAPIRequest(method: method, path: path, body: body)
        guard let data = raw.data(using: .utf8) else {
            throw ForgeError.apiError("Empty response")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? T else {
            throw ForgeError.apiError("Unexpected response format")
        }
        return json
    }

    private func rawAPIRequest(method: String, path: String, body: [String: Any]? = nil) async throws -> String {
        var curlCmd = "curl -s -X \(method)"

        if let token {
            curlCmd += " -H 'Authorization: token \(token)'"
        }

        if let body {
            let bodyData = try JSONSerialization.data(withJSONObject: body)
            let bodyStr = String(data: bodyData, encoding: .utf8) ?? "{}"
            curlCmd += " -H 'Content-Type: application/json' -d '\(bodyStr)'"
        }

        curlCmd += " '\(baseURL)\(path)'"
        return try await ShellService.run(curlCmd)
    }
}
