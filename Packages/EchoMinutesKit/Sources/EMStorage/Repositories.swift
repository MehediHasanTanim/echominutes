import EMCore
import Foundation
import GRDB

// EM-024 — repositories. Synchronous API (GRDB serialises writes); callers on actors call them directly.

// MARK: - Sessions

public struct SessionRepository: Sendable {
    let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    public func insert(_ s: Session) throws { try db.writer.write { try SessionRow(s).insert($0) } }

    public func update(_ s: Session) throws {
        var s = s; s.updatedAt = Date()
        let row = SessionRow(s)
        try db.writer.write { try row.update($0) }
    }

    public func fetch(_ id: SessionID) throws -> Session? {
        try db.writer.read { try SessionRow.fetchOne($0, key: id.description)?.model }
    }

    /// Newest first.
    public func recent(limit: Int = 100, appID: String? = nil) throws -> [Session] {
        try db.writer.read { db in
            var sql = "SELECT * FROM sessions"
            var args: StatementArguments = []
            if let appID { sql += " WHERE source_app_id = ?"; args += [appID] }
            sql += " ORDER BY started_at DESC LIMIT ?"; args += [limit]
            return try SessionRow.fetchAll(db, sql: sql, arguments: args).map(\.model)
        }
    }

    public func setStatus(_ id: SessionID, _ status: SessionStatus) throws {
        try db.writer.write {
            try $0.execute(sql: "UPDATE sessions SET status = ?, updated_at = ? WHERE id = ?", arguments: [status.rawValue, Date(), id.description])
        }
    }

    /// Sessions a crash left in recording/paused/finalizing (EM-056).
    public func needingRecovery() throws -> [Session] {
        let states = SessionStatus.allCases.filter(\.needsRecovery).map(\.rawValue)
        return try db.writer.read { db in
            try SessionRow.fetchAll(db, sql: "SELECT * FROM sessions WHERE status IN (\(states.map { _ in "?" }.joined(separator: ",")))",
                                    arguments: StatementArguments(states)).map(\.model)
        }
    }

    /// Deletes the session and everything that references it (cascade) plus its search entries.
    public func delete(_ id: SessionID) throws {
        try db.writer.write { db in
            try db.execute(sql: "DELETE FROM search_fts WHERE session_id = ?", arguments: [id.description])
            _ = try SessionRow.deleteOne(db, key: id.description)
        }
    }

    public func setNotes(_ id: SessionID, _ notes: String) throws {
        try db.writer.write { db in
            try db.execute(sql: "UPDATE sessions SET notes_md = ?, updated_at = ? WHERE id = ?", arguments: [notes, Date(), id.description])
            try SearchIndex.replace(db, sessionID: id, kind: "notes", entries: [(ref: id.description, startMs: nil, body: notes)])
        }
    }

    /// Replaces the finalized audio files of a session (EM-054).
    public func saveTracks(_ id: SessionID, _ tracks: [AudioTrack]) throws {
        try db.writer.write { db in
            try db.execute(sql: "DELETE FROM audio_tracks WHERE session_id = ?", arguments: [id.description])
            for t in tracks {
                try db.execute(sql: """
                    INSERT INTO audio_tracks (id, session_id, kind, path, codec, sample_rate, duration_ms, size_bytes)
                    VALUES (?, ?, ?, ?, 'aac', 48000, ?, ?)
                    """, arguments: [UUID().uuidString, id.description, t.kind.rawValue, t.fileName, t.durationMs, t.sizeBytes])
            }
        }
    }

    public func tracks(_ id: SessionID) throws -> [AudioTrack] {
        try db.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM audio_tracks WHERE session_id = ? ORDER BY kind", arguments: [id.description]).compactMap { r in
                guard let kind = TrackKind(rawValue: r["kind"]) else { return nil }
                return AudioTrack(sessionID: id, kind: kind, fileName: r["path"], durationMs: r["duration_ms"] ?? 0, sizeBytes: r["size_bytes"] ?? 0)
            }
        }
    }

    public func addBookmark(_ b: Bookmark) throws { try db.writer.write { try BookmarkRow(b).insert($0) } }
    public func bookmarks(_ id: SessionID) throws -> [Bookmark] {
        try db.writer.read { try BookmarkRow.fetchAll($0, sql: "SELECT * FROM bookmarks WHERE session_id = ? ORDER BY at_ms", arguments: [id.description]).map(\.model) }
    }
}

// MARK: - Transcript

public struct TranscriptRepository: Sendable {
    let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    /// Replaces speakers + segments of a session in one transaction and re-indexes them for search.
    public func replace(_ sessionID: SessionID, speakers: [Speaker], segments: [TranscriptSegment]) throws {
        try db.writer.write { db in
            let sid = sessionID.description
            try db.execute(sql: "DELETE FROM transcript_segments WHERE session_id = ?", arguments: [sid])
            try db.execute(sql: "DELETE FROM speakers WHERE session_id = ?", arguments: [sid])
            for s in speakers { try SpeakerRow(s).insert(db) }
            var entries: [(ref: String, startMs: Int?, body: String)] = []
            for seg in segments {
                var row = SegmentRow(seg); row.id = nil
                try row.insert(db)
                entries.append((ref: String(row.id ?? 0), startMs: seg.startMs, body: seg.text))
            }
            try SearchIndex.replace(db, sessionID: sessionID, kind: "segment", entries: entries)
        }
    }

    public func segments(_ sessionID: SessionID) throws -> [TranscriptSegment] {
        try db.writer.read {
            try SegmentRow.fetchAll($0, sql: "SELECT * FROM transcript_segments WHERE session_id = ? ORDER BY start_ms, id",
                                    arguments: [sessionID.description]).map(\.model)
        }
    }

    public func speakers(_ sessionID: SessionID) throws -> [Speaker] {
        try db.writer.read {
            try SpeakerRow.fetchAll($0, sql: "SELECT * FROM speakers WHERE session_id = ? ORDER BY is_me DESC, label",
                                    arguments: [sessionID.description]).map(\.model)
        }
    }

    /// `nil` clears the custom name (back to "Me" / "Speaker 2").
    public func renameSpeaker(_ speakerID: String, to name: String?) throws {
        try db.writer.write { try $0.execute(sql: "UPDATE speakers SET display_name = ? WHERE id = ?", arguments: [name, speakerID]) }
    }

    /// Inline edit of one segment's text (keeps search in sync).
    public func editSegment(id: Int64, text: String) throws {
        try db.writer.write { db in
            try db.execute(sql: "UPDATE transcript_segments SET text = ?, is_edited = 1 WHERE id = ?", arguments: [text, id])
            try db.execute(sql: "UPDATE search_fts SET body = ? WHERE kind = 'segment' AND ref_id = ?", arguments: [text, String(id)])
        }
    }
}

// MARK: - Summaries & action items

public struct SummaryRepository: Sendable {
    let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    /// Saves a new current summary (older ones kept as history) and replaces its action items.
    public func save(_ summary: Summary, actionItems: [ActionItem]) throws {
        try db.writer.write { db in
            let sid = summary.sessionID.description
            try db.execute(sql: "UPDATE summaries SET is_current = 0 WHERE session_id = ?", arguments: [sid])
            var s = summary; s.isCurrent = true
            try SummaryRow(s).insert(db)
            try db.execute(sql: "DELETE FROM action_items WHERE session_id = ?", arguments: [sid])
            for a in actionItems { try ActionItemRow(a).insert(db) }
            try SearchIndex.replace(db, sessionID: summary.sessionID, kind: "summary", entries: [(ref: summary.id, startMs: nil, body: summary.markdown)])
        }
    }

    public func current(_ sessionID: SessionID) throws -> Summary? {
        try db.writer.read {
            try SummaryRow.fetchOne($0, sql: "SELECT * FROM summaries WHERE session_id = ? AND is_current = 1 ORDER BY created_at DESC LIMIT 1",
                                    arguments: [sessionID.description])?.modelValue
        }
    }

    public func history(_ sessionID: SessionID) throws -> [Summary] {
        try db.writer.read {
            try SummaryRow.fetchAll($0, sql: "SELECT * FROM summaries WHERE session_id = ? ORDER BY created_at DESC",
                                    arguments: [sessionID.description]).map(\.modelValue)
        }
    }

    public func actionItems(_ sessionID: SessionID) throws -> [ActionItem] {
        try db.writer.read {
            try ActionItemRow.fetchAll($0, sql: "SELECT * FROM action_items WHERE session_id = ? ORDER BY COALESCE(timestamp_ms, 0), rowid",
                                       arguments: [sessionID.description]).map(\.model)
        }
    }

    public func setDone(_ actionItemID: String, _ done: Bool) throws {
        try db.writer.write { try $0.execute(sql: "UPDATE action_items SET is_done = ? WHERE id = ?", arguments: [done, actionItemID]) }
    }

    /// Open action items across all meetings (newest meetings first).
    public func openActionItems(limit: Int = 200) throws -> [ActionItem] {
        try db.writer.read {
            try ActionItemRow.fetchAll($0, sql: """
                SELECT a.* FROM action_items a JOIN sessions s ON s.id = a.session_id
                WHERE a.is_done = 0 ORDER BY s.started_at DESC LIMIT ?
                """, arguments: [limit]).map(\.model)
        }
    }
}

// MARK: - Jobs (persistent queue, EM-080 uses this)

public struct Job: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable { case finalizeAudio, transcribe, summarize, export }
    public enum Status: String, Sendable { case queued, running, done, failed }
    public var id: String
    public var sessionID: SessionID?
    public var kind: Kind
    public var status: Status
    public var attempts: Int
    public var lastError: String?
    public var notBefore: Date?

    public init(id: String, sessionID: SessionID?, kind: Kind, status: Status, attempts: Int, lastError: String?, notBefore: Date?) {
        self.id = id; self.sessionID = sessionID; self.kind = kind; self.status = status
        self.attempts = attempts; self.lastError = lastError; self.notBefore = notBefore
    }
}

public struct JobRepository: Sendable {
    let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    @discardableResult
    public func enqueue(_ kind: Job.Kind, sessionID: SessionID?, notBefore: Date? = nil, now: Date = Date()) throws -> String {
        let id = UUID().uuidString
        try db.writer.write {
            try $0.execute(sql: """
                INSERT INTO jobs (id, session_id, type, status, attempts, not_before, created_at, updated_at)
                VALUES (?, ?, ?, 'queued', 0, ?, ?, ?)
                """, arguments: [id, sessionID?.description, kind.rawValue, notBefore, now, now])
        }
        return id
    }

    /// Atomically claims the oldest runnable job of the given kinds (marks it running, attempts+1).
    public func claimNext(kinds: [Job.Kind] = Job.Kind.allCases, now: Date = Date()) throws -> Job? {
        try db.writer.write { db in
            let placeholders = kinds.map { _ in "?" }.joined(separator: ",")
            var args = StatementArguments(kinds.map(\.rawValue))
            args += [now]
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM jobs WHERE status = 'queued' AND type IN (\(placeholders))
                AND (not_before IS NULL OR not_before <= ?) ORDER BY created_at, rowid LIMIT 1
                """, arguments: args) else { return nil }
            let id: String = row["id"]
            try db.execute(sql: "UPDATE jobs SET status = 'running', attempts = attempts + 1, updated_at = ? WHERE id = ?", arguments: [now, id])
            return try Self.job(Row.fetchOne(db, sql: "SELECT * FROM jobs WHERE id = ?", arguments: [id])!)
        }
    }

    public func complete(_ id: String, now: Date = Date()) throws {
        try db.writer.write { try $0.execute(sql: "UPDATE jobs SET status = 'done', last_error = NULL, updated_at = ? WHERE id = ?", arguments: [now, id]) }
    }

    /// `retryAt` nil → permanently failed; otherwise re-queued with a not-before time (backoff).
    public func fail(_ id: String, error: String, retryAt: Date?, now: Date = Date()) throws {
        try db.writer.write {
            try $0.execute(sql: "UPDATE jobs SET status = ?, last_error = ?, not_before = ?, updated_at = ? WHERE id = ?",
                           arguments: [retryAt == nil ? "failed" : "queued", Redactor.redact(error), retryAt, now, id])
        }
    }

    /// A deferral (power saving) shouldn't use up one of the job's retry attempts.
    public func uncountAttempt(_ id: String) throws {
        try db.writer.write { try $0.execute(sql: "UPDATE jobs SET attempts = MAX(0, attempts - 1) WHERE id = ?", arguments: [id]) }
    }

    /// Latest job of a kind for a session (UI: "Transcribing…", "Failed: …").
    public func latest(_ kind: Job.Kind, sessionID: SessionID) throws -> Job? {
        try db.writer.read {
            try Row.fetchOne($0, sql: "SELECT * FROM jobs WHERE session_id = ? AND type = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
                             arguments: [sessionID.description, kind.rawValue]).map(Self.job)
        }
    }

    /// At launch: jobs left `running` by a crash go back to `queued`.
    @discardableResult
    public func requeueInterrupted(now: Date = Date()) throws -> Int {
        try db.writer.write { db in
            try db.execute(sql: "UPDATE jobs SET status = 'queued', updated_at = ? WHERE status = 'running'", arguments: [now])
            return db.changesCount
        }
    }

    public func jobs(for sessionID: SessionID) throws -> [Job] {
        try db.writer.read {
            try Row.fetchAll($0, sql: "SELECT * FROM jobs WHERE session_id = ? ORDER BY created_at, rowid", arguments: [sessionID.description]).map(Self.job)
        }
    }

    static func job(_ r: Row) -> Job {
        Job(id: r["id"], sessionID: (r["session_id"] as String?).flatMap(SessionID.init(string:)),
            kind: Job.Kind(rawValue: r["type"]) ?? .export, status: Job.Status(rawValue: r["status"]) ?? .failed,
            attempts: r["attempts"], lastError: r["last_error"], notBefore: r["not_before"])
    }
}

// MARK: - Settings (app rule overrides, provider configs)

public struct AppRuleOverride: Sendable, Equatable {
    public var appID: String
    public var mode: RecordingMode
    public var debounceSec: Double?
    public var graceSec: Double?
    public var localOnly: Bool
    public init(appID: String, mode: RecordingMode = .auto, debounceSec: Double? = nil, graceSec: Double? = nil, localOnly: Bool = false) {
        self.appID = appID; self.mode = mode; self.debounceSec = debounceSec; self.graceSec = graceSec; self.localOnly = localOnly
    }
}

/// Non-secret provider settings (the API key itself lives in KeychainStore).
public struct ProviderConfig: Sendable, Equatable {
    public var provider: ProviderID
    public var enabled: Bool
    public var model: String?
    public var baseURL: String?
    public var extraJSON: String?
    public init(provider: ProviderID, enabled: Bool = true, model: String? = nil, baseURL: String? = nil, extraJSON: String? = nil) {
        self.provider = provider; self.enabled = enabled; self.model = model; self.baseURL = baseURL; self.extraJSON = extraJSON
    }
}

public struct SettingsRepository: Sendable {
    let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    public func saveRule(_ r: AppRuleOverride) throws {
        try db.writer.write {
            try $0.execute(sql: """
                INSERT INTO app_rules (app_id, mode, debounce_sec, grace_sec, local_only) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(app_id) DO UPDATE SET mode = excluded.mode, debounce_sec = excluded.debounce_sec,
                  grace_sec = excluded.grace_sec, local_only = excluded.local_only
                """, arguments: [r.appID, r.mode.rawValue, r.debounceSec, r.graceSec, r.localOnly])
        }
    }

    public func rules() throws -> [String: AppRuleOverride] {
        try db.writer.read { db in
            var out: [String: AppRuleOverride] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT * FROM app_rules") {
                let o = AppRuleOverride(appID: r["app_id"], mode: RecordingMode(rawValue: r["mode"]) ?? .auto,
                                        debounceSec: r["debounce_sec"], graceSec: r["grace_sec"], localOnly: r["local_only"])
                out[o.appID] = o
            }
            return out
        }
    }

    public func saveProvider(_ c: ProviderConfig) throws {
        try db.writer.write {
            try $0.execute(sql: """
                INSERT INTO provider_configs (provider_id, enabled, model, base_url, extra_json) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(provider_id) DO UPDATE SET enabled = excluded.enabled, model = excluded.model,
                  base_url = excluded.base_url, extra_json = excluded.extra_json
                """, arguments: [c.provider.rawValue, c.enabled, c.model, c.baseURL, c.extraJSON])
        }
    }

    public func providers() throws -> [ProviderConfig] {
        try db.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM provider_configs ORDER BY provider_id").compactMap { r in
                guard let p = ProviderID(rawValue: r["provider_id"]) else { return nil }
                return ProviderConfig(provider: p, enabled: r["enabled"], model: r["model"], baseURL: r["base_url"], extraJSON: r["extra_json"])
            }
        }
    }
}

// MARK: - Full-text search

public struct SearchHit: Sendable, Equatable {
    public var sessionID: SessionID
    public var kind: String          // segment | summary | notes
    public var refID: String
    public var startMs: Int?
    public var snippet: String
}

enum SearchIndex {
    static func replace(_ db: Database, sessionID: SessionID, kind: String, entries: [(ref: String, startMs: Int?, body: String)]) throws {
        try db.execute(sql: "DELETE FROM search_fts WHERE session_id = ? AND kind = ?", arguments: [sessionID.description, kind])
        for e in entries where !e.body.isEmpty {
            try db.execute(sql: "INSERT INTO search_fts (session_id, kind, ref_id, start_ms, body) VALUES (?, ?, ?, ?, ?)",
                           arguments: [sessionID.description, kind, e.ref, e.startMs, e.body])
        }
    }

    /// Turns free user input into a safe FTS5 query: every word quoted, last word prefix-matched.
    static func ftsQuery(_ text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map { $0.replacingOccurrences(of: "\"", with: "") }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.enumerated().map { i, w in "\"\(w)\"" + (i == words.count - 1 ? "*" : "") }.joined(separator: " ")
    }
}

public struct SearchRepository: Sendable {
    let db: AppDatabase
    public init(_ db: AppDatabase) { self.db = db }

    /// Ranked hits with highlighted snippets ([match]).
    public func search(_ text: String, limit: Int = 50) throws -> [SearchHit] {
        guard let q = SearchIndex.ftsQuery(text) else { return [] }
        return try db.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT session_id, kind, ref_id, start_ms, snippet(search_fts, 4, '[', ']', '…', 12) AS snip
                FROM search_fts WHERE search_fts MATCH ? ORDER BY bm25(search_fts) LIMIT ?
                """, arguments: [q, limit]).compactMap { r in
                guard let sid = SessionID(string: r["session_id"]) else { return nil }
                let start: Int? = r["start_ms"]
                return SearchHit(sessionID: sid, kind: r["kind"], refID: r["ref_id"], startMs: start, snippet: r["snip"])
            }
        }
    }
}
