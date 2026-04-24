import Foundation
import FlightCore

/// Reads claude's own session jsonl (`~/.claude/projects/<cwd-dashed>/<sessionID>.jsonl`)
/// and maps the subset of event types Flight renders into AgentMessages with
/// their original timestamps preserved. Best-effort: unknown types are skipped,
/// malformed lines are ignored.
enum ClaudeSessionReader {
    /// Claude uses the working-dir path with `/` replaced by `-` as the
    /// project folder name.
    static func projectDirName(forWorktreePath path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
    }

    static func sessionFileURL(worktreePath: String, sessionID: String) -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
            .appendingPathComponent(projectDirName(forWorktreePath: worktreePath))
        return base.appendingPathComponent("\(sessionID).jsonl")
    }

    static func readMessages(worktreePath: String, sessionID: String) -> [AgentMessage] {
        let url = sessionFileURL(worktreePath: worktreePath, sessionID: sessionID)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        let decoder = JSONDecoder()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        var messages: [AgentMessage] = []
        messages.reserveCapacity(512)

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8) else { continue }
            guard let entry = try? decoder.decode(Entry.self, from: lineData) else { continue }

            let timestamp: Date = {
                guard let raw = entry.timestamp else { return Date.distantPast }
                return iso.date(from: raw) ?? isoNoFrac.date(from: raw) ?? Date.distantPast
            }()

            switch entry.type {
            case "user":
                guard let msg = entry.message else { continue }
                switch msg.content {
                case .some(.text(let t)):
                    guard !t.isEmpty else { continue }
                    if isSystemInjectedUserText(t) { continue }
                    messages.append(AgentMessage(role: .user, content: .text(t), timestamp: timestamp))
                case .some(.blocks(let blocks)):
                    // A user event with content blocks is almost always a
                    // tool_result echo from the model's perspective. Emit
                    // each block in its rendered form; skip everything else.
                    for block in blocks {
                        if block.type == "tool_result" {
                            let c = block.content ?? block.text ?? ""
                            messages.append(AgentMessage(role: .assistant, content: .toolResult(content: c), timestamp: timestamp))
                        } else if block.type == "text", let t = block.text, !t.isEmpty {
                            messages.append(AgentMessage(role: .user, content: .text(t), timestamp: timestamp))
                        }
                    }
                case .none:
                    continue
                }

            case "assistant":
                guard let msg = entry.message,
                      case .blocks(let blocks) = msg.content else { continue }
                for block in blocks {
                    switch block.type {
                    case "text":
                        if let t = block.text, !t.isEmpty {
                            messages.append(AgentMessage(role: .assistant, content: .text(t), timestamp: timestamp))
                        }
                    case "thinking":
                        if let t = block.thinking ?? block.text, !t.isEmpty {
                            messages.append(AgentMessage(role: .assistant, content: .thinking(t), timestamp: timestamp))
                        }
                    case "tool_use":
                        let name = block.name ?? "unknown"
                        let input = block.input?.jsonString ?? "{}"
                        messages.append(AgentMessage(role: .assistant, content: .toolUse(name: name, input: input), timestamp: timestamp))
                    case "tool_result":
                        let c = block.content ?? block.text ?? ""
                        messages.append(AgentMessage(role: .assistant, content: .toolResult(content: c), timestamp: timestamp))
                    default:
                        continue
                    }
                }

            default:
                continue
            }
        }

        return messages
    }

    /// Claude injects certain out-of-band notifications into the transcript
    /// as `user`-role text events (e.g. `<task-notification>` for background
    /// task completion). The live stream reader skips all user events, but
    /// hydration does need to surface real user messages — so filter by
    /// known system tags instead.
    private static let systemInjectedUserPrefixes: [String] = [
        "<task-notification>",
        "<system-reminder>",
        "<command-name>",
        "<local-command-stdout>",
        "<local-command-stderr>",
    ]

    private static func isSystemInjectedUserText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return systemInjectedUserPrefixes.contains { trimmed.hasPrefix($0) }
    }

    // MARK: - JSONL schema (subset)

    private struct Entry: Decodable {
        let type: String
        let timestamp: String?
        let message: Msg?

        enum CodingKeys: String, CodingKey { case type, timestamp, message }

        struct Msg: Decodable {
            let role: String?
            let content: Content?

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                role = try c.decodeIfPresent(String.self, forKey: .role)
                if let s = try? c.decode(String.self, forKey: .content) {
                    content = .text(s)
                } else if let blocks = try? c.decode([Block].self, forKey: .content) {
                    content = .blocks(blocks)
                } else {
                    content = nil
                }
            }

            enum CodingKeys: String, CodingKey { case role, content }
        }

        enum Content {
            case text(String)
            case blocks([Block])
        }

        struct Block: Decodable {
            let type: String
            let text: String?
            let thinking: String?
            let name: String?
            let input: AnyCodable?
            let content: String?
        }
    }
}
