import Foundation

/// Persists most-recently-used slash commands in UserDefaults.
@MainActor
final class SlashCommandHistory {
    static let shared = SlashCommandHistory()

    private let key = "flightRecentSlashCommands"
    private let maxStored = 16
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns up to `limit` recent commands, padded with `defaultRecents` if
    /// the user's history is shorter.
    func recent(limit: Int = 8) -> [SlashCommand] {
        let stored = defaults.stringArray(forKey: key) ?? []
        var result: [SlashCommand] = stored.compactMap { SlashCommandCatalog.command(named: $0) }

        if result.count < limit {
            for name in SlashCommandCatalog.defaultRecents {
                if result.contains(where: { $0.name == name }) { continue }
                if let cmd = SlashCommandCatalog.command(named: name) {
                    result.append(cmd)
                    if result.count >= limit { break }
                }
            }
        }

        return Array(result.prefix(limit))
    }

    /// Returns recents (capped at `recentsLimit`) followed by the rest of the
    /// catalog in declaration order. Used to populate the menu when the user
    /// has typed only `/` — recents on top, full list scrollable below.
    func recentsThenAll(recentsLimit: Int = 8) -> [SlashCommand] {
        let recents = recent(limit: recentsLimit)
        let recentNames = Set(recents.map { $0.name })
        let rest = SlashCommandCatalog.all.filter { !recentNames.contains($0.name) }
        return recents + rest
    }

    func record(_ name: String) {
        guard SlashCommandCatalog.command(named: name) != nil else { return }
        var stored = defaults.stringArray(forKey: key) ?? []
        stored.removeAll { $0 == name }
        stored.insert(name, at: 0)
        if stored.count > maxStored { stored = Array(stored.prefix(maxStored)) }
        defaults.set(stored, forKey: key)
    }
}

/// Subsequence-based fuzzy match. Returns nil when `query` is not a
/// subsequence of `name`. Higher score = better match. Word-boundary hits
/// (start of string, after `-`) and consecutive runs are favored.
enum SlashCommandFuzzy {
    static func score(query: String, in name: String) -> Int? {
        if query.isEmpty { return 0 }
        let q = Array(query.lowercased())
        let n = Array(name.lowercased())

        var qi = 0
        var score = 0
        var prevMatch = -2
        var consecutive = 0

        for (i, ch) in n.enumerated() where qi < q.count {
            if ch == q[qi] {
                score += 10
                if i == prevMatch + 1 {
                    consecutive += 1
                    score += 5 * consecutive
                } else {
                    consecutive = 0
                }
                let atWordBoundary = i == 0 || n[i - 1] == "-"
                if atWordBoundary { score += 8 }
                prevMatch = i
                qi += 1
            }
        }

        return qi == q.count ? score : nil
    }

    static func filter(_ commands: [SlashCommand], query: String) -> [SlashCommand] {
        if query.isEmpty { return commands }

        let scored: [(SlashCommand, Int)] = commands.compactMap { cmd in
            guard let s = score(query: query, in: cmd.name) else { return nil }
            return (cmd, s)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.name.count < rhs.0.name.count
            }
            .map { $0.0 }
    }
}
