import Foundation

/// Append-only JSONL log of Flight's own events, keyed by conversation.
/// Single writer (Flight) → no race with claude's session jsonl.
///
/// File layout: `~/flight/flight-events/<conversationID>.jsonl`.
///
/// Writes are off-loaded to a serial background queue. During a tool-heavy
/// remote turn claude can stream dozens of events per second, and doing
/// open/seek/write/close on the main thread for each one starves SwiftUI's
/// rendering pipeline (blank-viewport-until-scroll jank). The queue
/// preserves ordering and keeps the hot path free of disk I/O.
enum FlightEventLog {
    static var baseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("flight")
            .appendingPathComponent("flight-events")
    }

    static func fileURL(conversationID: UUID) -> URL {
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        return baseURL.appendingPathComponent("\(conversationID.uuidString).jsonl")
    }

    private static let writeQueue = DispatchQueue(label: "flight.flighteventlog.writes", qos: .utility)

    /// Appends one event as a single JSONL line. Returns immediately; the
    /// encode + file write happen on a serial background queue so the order
    /// of appends is preserved while keeping the caller unblocked.
    static func append(_ event: FlightEvent, conversationID: UUID) {
        writeQueue.async {
            let url = fileURL(conversationID: conversationID)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard var data = try? encoder.encode(event) else { return }
            data.append(0x0A) // newline

            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    /// Blocking flush for code paths that need the on-disk log to reflect
    /// every prior `append` call before proceeding (e.g. hydrate running
    /// immediately after a migration backfill in the same tick).
    static func waitForPendingWrites() {
        writeQueue.sync { }
    }

    /// Reads all events for a conversation. Malformed lines are skipped —
    /// this is a best-effort log, not a transaction store.
    static func load(conversationID: UUID) -> [FlightEvent] {
        // Drain any in-flight writes so the read sees the full log.
        waitForPendingWrites()
        let url = fileURL(conversationID: conversationID)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var events: [FlightEvent] = []
        events.reserveCapacity(256)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8) else { continue }
            if let event = try? decoder.decode(FlightEvent.self, from: lineData) {
                events.append(event)
            }
        }
        return events
    }

    static func delete(conversationID: UUID) {
        // Serialize the delete behind any pending appends for this
        // conversation so we don't get a write/unlink race.
        writeQueue.async {
            let url = fileURL(conversationID: conversationID)
            try? FileManager.default.removeItem(at: url)
        }
    }
}
