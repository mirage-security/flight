import Foundation

enum GitService {
    static func createWorktree(repoPath: String, branch: String, worktreePath: String) async throws {
        // Create the worktree with a new branch
        try await ShellService.run(
            "git -C \(quoted(repoPath)) worktree add \(quoted(worktreePath)) -b \(quoted(branch))"
        )

        // Copy .context/ directory if it exists in the repo root
        let contextSource = URL(fileURLWithPath: repoPath).appendingPathComponent(".context").path
        let contextDest = URL(fileURLWithPath: worktreePath).appendingPathComponent(".context").path
        if FileManager.default.fileExists(atPath: contextSource) {
            try? FileManager.default.copyItem(atPath: contextSource, toPath: contextDest)
        }
    }

    static func removeWorktree(repoPath: String, worktreePath: String, branch: String) async throws {
        // Remove the worktree
        try await ShellService.run(
            "git -C \(quoted(repoPath)) worktree remove \(quoted(worktreePath)) --force"
        )

        // Delete the branch
        _ = try? await ShellService.run(
            "git -C \(quoted(repoPath)) branch -d \(quoted(branch))"
        )
    }

    private static func quoted(_ s: String) -> String {
        "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
