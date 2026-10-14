import EMCore
import Foundation
import GRDB

// Row structs map 1:1 to tables; EMCore models stay free of GRDB.

struct SessionRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "sessions"
    var id: String
    var title: String
    var titleIsUserEdited: Bool
    var sourceAppId: String?
    var sourceBundleId: String?
    var startedAt: Date
    var endedAt: Date?
    var status: String
    var echoRisk: Bool
    var sttEngine: String?
    var llmProvider: String?
    var llmModel: String?
    var templateId: String?
    var notesMd: String?
    var tags: String
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title, status, tags
        case titleIsUserEdited = "title_is_user_edited", sourceAppId = "source_app_id", sourceBundleId = "source_bundle_id"
        case startedAt = "started_at", endedAt = "ended_at", echoRisk = "echo_risk", sttEngine = "stt_engine"
        case llmProvider = "llm_provider", llmModel = "llm_model", templateId = "template_id", notesMd = "notes_md"
        case createdAt = "created_at", updatedAt = "updated_at"
    }

    init(_ s: Session) {
        id = s.id.description; title = s.title; titleIsUserEdited = s.titleIsUserEdited
        sourceAppId = s.sourceAppID; sourceBundleId = s.sourceBundleID; startedAt = s.startedAt; endedAt = s.endedAt
        status = s.status.rawValue; echoRisk = s.echoRisk; sttEngine = s.sttEngine; llmProvider = s.llmProvider?.rawValue
        llmModel = s.llmModel; templateId = s.templateID; notesMd = s.notesMarkdown
        tags = (try? String(data: JSONEncoder().encode(s.tags), encoding: .utf8)) ?? "[]"
        createdAt = s.createdAt; updatedAt = s.updatedAt
    }

    var model: Session {
        var s = Session(id: SessionID(string: id) ?? SessionID(), title: title, sourceAppID: sourceAppId, sourceBundleID: sourceBundleId,
                        startedAt: startedAt, status: SessionStatus(rawValue: status) ?? .failed, now: createdAt)
        s.titleIsUserEdited = titleIsUserEdited; s.endedAt = endedAt; s.echoRisk = echoRisk; s.sttEngine = sttEngine
        s.llmProvider = llmProvider.flatMap(ProviderID.init(rawValue:)); s.llmModel = llmModel; s.templateID = templateId
        s.notesMarkdown = notesMd; s.tags = (try? JSONDecoder().decode([String].self, from: Data(tags.utf8))) ?? []
        s.updatedAt = updatedAt
        return s
    }
}

struct SpeakerRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "speakers"
    var id: String, sessionId: String, label: String, displayName: String?, isMe: Bool, color: String?
    enum CodingKeys: String, CodingKey { case id, label, color; case sessionId = "session_id", displayName = "display_name", isMe = "is_me" }
    init(_ s: Speaker) { id = s.id; sessionId = s.sessionID.description; label = s.label; displayName = s.displayName; isMe = s.isMe; color = s.color }
    var model: Speaker { Speaker(id: id, sessionID: SessionID(string: sessionId)!, label: label, displayName: displayName, isMe: isMe, color: color) }
}

struct SegmentRow: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "transcript_segments"
    var id: Int64?, sessionId: String, speakerId: String?, trackKind: String, startMs: Int, endMs: Int
    var text: String, confidence: Double?, isEdited: Bool
    enum CodingKeys: String, CodingKey {
        case id, text, confidence
        case sessionId = "session_id", speakerId = "speaker_id", trackKind = "track_kind", startMs = "start_ms", endMs = "end_ms", isEdited = "is_edited"
    }
    init(_ s: TranscriptSegment) {
        id = s.id; sessionId = s.sessionID.description; speakerId = s.speakerID; trackKind = s.track.rawValue
        startMs = s.startMs; endMs = s.endMs; text = s.text; confidence = s.confidence; isEdited = s.isEdited
    }
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
    var model: TranscriptSegment {
        TranscriptSegment(id: id, sessionID: SessionID(string: sessionId)!, speakerID: speakerId, track: TrackKind(rawValue: trackKind) ?? .mixed,
                          startMs: startMs, endMs: endMs, text: text, confidence: confidence, isEdited: isEdited)
    }
}

struct SummaryRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "summaries"
    var id: String, sessionId: String, templateId: String?, provider: String?, model: String?
    var json: String?, markdown: String, schemaValid: Bool, tokensIn: Int?, tokensOut: Int?, costUsd: Double?
    var isCurrent: Bool, createdAt: Date
    enum CodingKeys: String, CodingKey {
        case id, provider, model, json, markdown
        case sessionId = "session_id", templateId = "template_id", schemaValid = "schema_valid", tokensIn = "tokens_in"
        case tokensOut = "tokens_out", costUsd = "cost_usd", isCurrent = "is_current", createdAt = "created_at"
    }
    init(_ s: Summary) {
        id = s.id; sessionId = s.sessionID.description; templateId = s.templateID; provider = s.provider?.rawValue; model = s.model
        json = s.content.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) }
        markdown = s.markdown; schemaValid = s.schemaValid; tokensIn = s.tokensIn; tokensOut = s.tokensOut; costUsd = s.costUSD
        isCurrent = s.isCurrent; createdAt = s.createdAt
    }
    var modelValue: Summary {
        var s = Summary(id: id, sessionID: SessionID(string: sessionId)!, templateID: templateId, provider: provider.flatMap(ProviderID.init(rawValue:)),
                        model: model, content: json.flatMap { try? JSONDecoder().decode(SummaryContent.self, from: Data($0.utf8)) },
                        markdown: markdown, createdAt: createdAt)
        s.tokensIn = tokensIn; s.tokensOut = tokensOut; s.costUSD = costUsd; s.isCurrent = isCurrent
        return s
    }
}

struct ActionItemRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "action_items"
    var id: String, sessionId: String, summaryId: String?, text: String, owner: String?, due: String?, timestampMs: Int?, isDone: Bool
    enum CodingKeys: String, CodingKey {
        case id, text, owner, due
        case sessionId = "session_id", summaryId = "summary_id", timestampMs = "timestamp_ms", isDone = "is_done"
    }
    init(_ a: ActionItem) {
        id = a.id; sessionId = a.sessionID.description; summaryId = a.summaryID; text = a.text; owner = a.owner; due = a.due
        timestampMs = a.timestampMs; isDone = a.isDone
    }
    var model: ActionItem {
        ActionItem(id: id, sessionID: SessionID(string: sessionId)!, summaryID: summaryId, text: text, owner: owner, due: due,
                   timestampMs: timestampMs, isDone: isDone)
    }
}

struct BookmarkRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "bookmarks"
    var id: String, sessionId: String, atMs: Int, note: String?
    enum CodingKeys: String, CodingKey { case id, note; case sessionId = "session_id", atMs = "at_ms" }
    init(_ b: Bookmark) { id = b.id; sessionId = b.sessionID.description; atMs = b.atMs; note = b.note }
    var model: Bookmark { Bookmark(id: id, sessionID: SessionID(string: sessionId)!, atMs: atMs, note: note) }
}
