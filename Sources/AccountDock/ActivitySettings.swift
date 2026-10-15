import Foundation
import SQLite3

/// Only settings observed on an actual sampling request, never account-wide defaults.
struct ObservedActivitySettings: Sendable, Equatable {
    let turnID: String
    let serviceTier: String?
    let model: String?
    let effort: String?
    let sampledAt: Date?
}

enum ActivitySettingsReader {
    /// Logs are optional implementation details of Codex. Any unsupported schema, lock,
    /// malformed record, or unknown value leaves the setting unknown.
    static func settings(home: URL, threadID: String, turnID: String) -> ObservedActivitySettings? {
        guard UUID(uuidString: turnID) != nil else { return nil }
        return read(home: home, threadID: threadID, turnID: turnID, since: nil)
    }

    /// Use only after independent rollout evidence has established that the thread is
    /// active. This recovers metadata when a large turn began before the sampled tail.
    static func latestSettings(home: URL, threadID: String, since: Date) -> ObservedActivitySettings? {
        read(home: home, threadID: threadID, turnID: nil, since: since)
    }

    private static func read(home: URL, threadID: String, turnID: String?, since: Date?) -> ObservedActivitySettings? {
        guard let thread = UUID(uuidString: threadID) else { return nil }
        let path = home.appendingPathComponent("logs_2.sqlite").path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 25)
        // Abort pathological legacy/indexless scans after a small instruction budget.
        sqlite3_progress_handler(database, 20_000, { _ in 1 }, nil)

        // Codex supplies an index on (thread_id, ts DESC, ts_nanos DESC, id DESC).
        // Bound the work even when older formats have no matching sampling metadata.
        let query = """
            SELECT ts, ts_nanos, feedback_log_body FROM logs INDEXED BY idx_logs_thread_id_ts
            WHERE thread_id = ? AND target = 'feedback_tags' AND ts >= ?
            ORDER BY ts DESC, ts_nanos DESC, id DESC LIMIT 96
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let identifier = thread.uuidString.lowercased()
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, identifier, -1, transient) == SQLITE_OK else { return nil }
        let lowerBound = since.map { Int64(floor($0.timeIntervalSince1970)) } ?? 0
        guard sqlite3_bind_int64(statement, 2, lowerBound) == SQLITE_OK else { return nil }
        while sqlite3_step(statement) == SQLITE_ROW {
            let sampledAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 0))
                + Double(sqlite3_column_int64(statement, 1)) / 1_000_000_000)
            if let since, sampledAt < since { continue }
            let count = Int(sqlite3_column_bytes(statement, 2))
            guard count > 0, count <= 128 * 1024,
                  let bytes = sqlite3_column_text(statement, 2) else { continue }
            let body = String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
            if let result = parseSamplingRecord(body, turnID: turnID, sampledAt: sampledAt) { return result }
        }
        return nil
    }

    /// Read only the exact turn's sampling span and its allowlisted metadata field.
    /// The record body is neither returned, logged, nor persisted.
    static func parseSamplingRecord(_ body: String, turnID: String?, sampledAt: Date? = nil) -> ObservedActivitySettings? {
        if let turnID, UUID(uuidString: turnID) == nil { return nil }
        guard let split = body.range(of: " tags_json=", options: .backwards) else { return nil }
        let span = String(body[..<split.lowerBound])
        let pattern = #"(?:^|:)run_sampling_request\{turn_id=\"?([0-9a-fA-F-]{36})\"?(?:\s|\})"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: span, range: NSRange(span.startIndex..., in: span)),
              let range = Range(match.range(at: 1), in: span),
              let observedTurn = UUID(uuidString: String(span[range])) else { return nil }
        if let turnID, UUID(uuidString: turnID) != observedTurn { return nil }
        let data = Data(body[split.upperBound...].utf8)
        let tags = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let value = tags?["service_tier"] as? String
        let tier = value.flatMap { ["priority", "fast", "default", "standard", "ultrafast"].contains($0) ? $0 : nil }
        // Capture only known token-shaped metadata, excluding cwd and all free text.
        let samplingSpan = String(span[range.upperBound...].prefix(180))
        let model = capture(#"^\"?\s+model=\"?([A-Za-z0-9._:-]{1,100})(?:\"?\s|\})"#, from: samplingSpan)
        let effort = capture(#"(?:^|\s)effort=Some\((None|Minimal|Low|Medium|High|XHigh|Max|Ultra)\)(?:\s|$)"#, from: span)?.lowercased()
        return ObservedActivitySettings(turnID: observedTurn.uuidString.lowercased(), serviceTier: tier,
            model: model, effort: effort, sampledAt: sampledAt)
    }

    private static func capture(_ pattern: String, from text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
