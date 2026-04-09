import Foundation

/// GitHub forge provider using the `gh` CLI.
/// Requires `gh` to be installed and authenticated.
struct GitHubForge: ForgeProvider {
    let displayName = "GitHub"

    func createPR(in worktreePath: String, branch: String) async throws -> Int {
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
        throw ForgeError.couldNotParsePRNumber(output)
    }

    func getChecks(prNumber: Int, repoPath: String) async throws -> [CICheck] {
        let output = try await ShellService.run(
            "gh pr checks \(prNumber) --json name,state,conclusion",
            in: repoPath
        )
        guard let data = output.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([CICheck].self, from: data)) ?? []
    }

    func getFailedLogs(prNumber: Int, repoPath: String) async throws -> String {
        let checksOutput = try await ShellService.run(
            "gh pr checks \(prNumber) --json name,state,conclusion,detailsUrl --jq '.[] | select(.conclusion == \"failure\") | .detailsUrl'",
            in: repoPath
        )

        let lines = checksOutput.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard let firstURL = lines.first,
              let url = URL(string: firstURL) else {
            return "No failed checks found."
        }

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

    func getPRStatus(prNumber: Int, repoPath: String) async throws -> PRStatus {
        let output = try await ShellService.run(
            "gh pr view \(prNumber) --json latestReviews,reviewDecision",
            in: repoPath
        )
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return PRStatus(reviews: [], reviewDecision: nil)
        }

        var reviews: [PRReview] = []
        if let rawReviews = json["latestReviews"] as? [[String: Any]] {
            for r in rawReviews {
                let author = (r["author"] as? [String: Any])?["login"] as? String ?? "unknown"
                let state = r["state"] as? String ?? "PENDING"
                reviews.append(PRReview(author: author, state: state))
            }
        }

        let decision = json["reviewDecision"] as? String
        return PRStatus(reviews: reviews, reviewDecision: decision)
    }

    func getPRNumber(branch: String, repoPath: String) async -> Int? {
        guard let output = try? await ShellService.run(
            "gh pr view '\(branch)' --json number --jq .number",
            in: repoPath
        ) else { return nil }
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
