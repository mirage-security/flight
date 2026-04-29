import Foundation

/// Downloads `.flight/` scripts from a remote repo into a local cache so
/// that `RemoteScriptsService` can invoke them the same way it invokes
/// on-disk scripts for locally cloned repos. Used exclusively by
/// remote-only projects — local projects read scripts from their own
/// worktree as before.
enum RemoteScriptFetcher {
    /// Cache root. Each project gets a subdirectory by name.
    static var cacheBaseURL: URL {
        ConfigService.flightHomeURL.appendingPathComponent("remote-scripts")
    }

    static func cacheDirectory(for projectName: String) -> URL {
        cacheBaseURL.appendingPathComponent(projectName)
    }

    /// Downloads each lifecycle script from the repo specified by `forge`
    /// into the project's cache dir. Throws if required scripts are
    /// missing or unreadable. Optional scripts are silently skipped if the
    /// repo doesn't have them.
    static func fetchAll(forge: ForgeConfig, projectName: String) async throws {
        guard let owner = forge.owner, let repo = forge.repo else {
            throw ForgeError.apiError("Forge config missing owner/repo")
        }
        let dir = cacheDirectory(for: projectName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for lifecycle in RemoteLifecycle.allCases {
            let required = lifecycle.isRequiredForRemoteOnlyFetch
            do {
                let content = try await fetchFile(
                    forge: forge,
                    owner: owner,
                    repo: repo,
                    path: ".flight/\(lifecycle.rawValue)"
                )
                let dest = dir.appendingPathComponent(lifecycle.rawValue)
                try content.write(to: dest, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: dest.path
                )
            } catch {
                if required {
                    throw ForgeError.apiError(
                        "Couldn't fetch .flight/\(lifecycle.rawValue) from \(owner)/\(repo): \(error.localizedDescription)"
                    )
                }
                // Optional lifecycle — silently ignore
            }
        }
    }

    /// Re-fetches all lifecycle scripts from the forge API and updates the
    /// cache. Returns `true` if any script's content changed compared to
    /// what was previously cached (i.e. the remote repo has newer scripts).
    /// Swallows network/API errors and returns `false` — a failed refresh
    /// just means we keep using whatever's cached.
    static func refreshAll(forge: ForgeConfig, projectName: String) async -> Bool {
        guard let owner = forge.owner, let repo = forge.repo else { return false }
        let dir = cacheDirectory(for: projectName)

        var changed = false
        for lifecycle in RemoteLifecycle.allCases {
            do {
                let content = try await fetchFile(
                    forge: forge, owner: owner, repo: repo,
                    path: ".flight/\(lifecycle.rawValue)"
                )
                let dest = dir.appendingPathComponent(lifecycle.rawValue)
                let existing = try? String(contentsOf: dest, encoding: .utf8)
                if existing != content {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try content.write(to: dest, atomically: true, encoding: .utf8)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o755], ofItemAtPath: dest.path
                    )
                    changed = true
                }
            } catch {
                // Optional scripts (list) or network failures — skip silently.
            }
        }
        return changed
    }

    /// Fetches a single file from the forge at HEAD. Uses the forge's
    /// native CLI/API surface (gh for GitHub, REST for Forgejo).
    private static func fetchFile(
        forge: ForgeConfig,
        owner: String,
        repo: String,
        path: String
    ) async throws -> String {
        switch forge.type {
        case .github:
            return try await ShellService.run(
                "gh api repos/\(owner)/\(repo)/contents/\(path) -H 'Accept: application/vnd.github.raw'"
            )
        case .forgejo:
            let base = (forge.baseURL ?? "http://localhost:3000")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let tokenVar = forge.tokenEnvVar ?? "FORGEJO_TOKEN"
            var curl = "curl -sfL"
            if let token = ProcessInfo.processInfo.environment[tokenVar] {
                curl += " -H 'Authorization: token \(token)'"
            }
            curl += " '\(base)/api/v1/repos/\(owner)/\(repo)/raw/\(path)'"
            return try await ShellService.run(curl)
        }
    }
}
