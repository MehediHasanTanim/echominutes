import Foundation

// MARK: - Identifiers

/// Strongly typed session identifier (UUID; string form used in DB and folder names).
public struct SessionID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public init?(string: String) { guard let u = UUID(uuidString: string) else { return nil }; rawValue = u }
    public var description: String { rawValue.uuidString }
}

// MARK: - Session

public enum SessionStatus: String, Codable, Sendable, CaseIterable {
    case recording, paused, finalizing, transcribing, summarizing, ready, failed, interrupted

    /// States in which audio capture is (or was, before a crash) active.
    public var isCapturing: Bool { self == .recording || self == .paused }
    /// States a crash can leave behind that need recovery at launch.
    public var needsRecovery: Bool { self == .recording || self == .paused || self == .finalizing }
}

public struct Session: Identifiable, Codable, Sendable, Equatable {
    public var id: SessionID
    public var title: String
    public var titleIsUserEdited: Bool
    public var sourceAppID: String?          // "teams" | "zoom" | "whatsapp" | "manual" …
    public var sourceBundleID: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var status: SessionStatus
    public var echoRisk: Bool
    public var sttEngine: String?
    public var llmProvider: ProviderID?
    public var llmModel: String?
    public var templateID: String?
    public var notesMarkdown: String?
    public var tags: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: SessionID = SessionID(), title: String, sourceAppID: String?, sourceBundleID: String? = nil,
                startedAt: Date, status: SessionStatus = .recording, now: Date = Date()) {
        self.id = id; self.title = title; self.titleIsUserEdited = false
        self.sourceAppID = sourceAppID; self.sourceBundleID = sourceBundleID
        self.startedAt = startedAt; self.endedAt = nil; self.status = status; self.echoRisk = false
        self.sttEngine = nil; self.llmProvider = nil; self.llmModel = nil; self.templateID = nil
        self.notesMarkdown = nil; self.tags = []; self.createdAt = now; self.updatedAt = now
    }

    public var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
}

// MARK: - Audio & transcript

public enum TrackKind: String, Codable, Sendable, CaseIterable { case mic, system, mixed }

public struct Speaker: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var sessionID: SessionID
    public var label: String                 // "Me", "Speaker 1", "Others"
    public var displayName: String?
    public var isMe: Bool
    public var color: String?
    public init(id: String = UUID().uuidString, sessionID: SessionID, label: String, displayName: String? = nil, isMe: Bool = false, color: String? = nil) {
        self.id = id; self.sessionID = sessionID; self.label = label; self.displayName = displayName; self.isMe = isMe; self.color = color
    }
    /// Name shown in the UI and in prompts.
    public var name: String { displayName?.isEmpty == false ? displayName! : label }
}

public struct TranscriptSegment: Codable, Sendable, Equatable {
    public var id: Int64?
    public var sessionID: SessionID
    public var speakerID: String?
    public var track: TrackKind
    public var startMs: Int
    public var endMs: Int
    public var text: String
    public var confidence: Double?
    public var isEdited: Bool
    public init(id: Int64? = nil, sessionID: SessionID, speakerID: String?, track: TrackKind, startMs: Int, endMs: Int,
                text: String, confidence: Double? = nil, isEdited: Bool = false) {
        self.id = id; self.sessionID = sessionID; self.speakerID = speakerID; self.track = track
        self.startMs = startMs; self.endMs = endMs; self.text = text; self.confidence = confidence; self.isEdited = isEdited
    }
    public var durationMs: Int { max(0, endMs - startMs) }
    /// Timestamp label "mm:ss" (or "h:mm:ss") used in transcripts and LLM prompts.
    public var timestamp: String { Self.format(ms: startMs) }
    public static func format(ms: Int) -> String {
        let s = max(0, ms) / 1000
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Summary

/// Structured summary produced by the LLM (Technical Design §10.3 schema).
public struct SummaryContent: Codable, Sendable, Equatable {
    public struct Action: Codable, Sendable, Equatable {
        public var task: String
        public var owner: String?
        public var due: String?
        public var timestamp: String?
        public init(task: String, owner: String? = nil, due: String? = nil, timestamp: String? = nil) {
            self.task = task; self.owner = owner; self.due = due; self.timestamp = timestamp
        }
    }
    public var title: String
    public var tldr: String
    public var keyPoints: [String]
    public var decisions: [String]
    public var actionItems: [Action]
    public var openQuestions: [String]
    public var nextSteps: [String]

    enum CodingKeys: String, CodingKey {
        case title, tldr, decisions
        case keyPoints = "key_points", actionItems = "action_items", openQuestions = "open_questions", nextSteps = "next_steps"
    }
    public init(title: String, tldr: String, keyPoints: [String] = [], decisions: [String] = [], actionItems: [Action] = [],
                openQuestions: [String] = [], nextSteps: [String] = []) {
        self.title = title; self.tldr = tldr; self.keyPoints = keyPoints; self.decisions = decisions
        self.actionItems = actionItems; self.openQuestions = openQuestions; self.nextSteps = nextSteps
    }
}

public struct Summary: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var sessionID: SessionID
    public var templateID: String?
    public var provider: ProviderID?
    public var model: String?
    public var content: SummaryContent?      // nil when the LLM output failed schema validation
    public var markdown: String
    public var tokensIn: Int?
    public var tokensOut: Int?
    public var costUSD: Double?
    public var isCurrent: Bool
    public var createdAt: Date
    public init(id: String = UUID().uuidString, sessionID: SessionID, templateID: String? = nil, provider: ProviderID? = nil,
                model: String? = nil, content: SummaryContent?, markdown: String, createdAt: Date = Date()) {
        self.id = id; self.sessionID = sessionID; self.templateID = templateID; self.provider = provider; self.model = model
        self.content = content; self.markdown = markdown; self.tokensIn = nil; self.tokensOut = nil; self.costUSD = nil
        self.isCurrent = true; self.createdAt = createdAt
    }
    public var schemaValid: Bool { content != nil }
}

public struct ActionItem: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var sessionID: SessionID
    public var summaryID: String?
    public var text: String
    public var owner: String?
    public var due: String?
    public var timestampMs: Int?
    public var isDone: Bool
    public init(id: String = UUID().uuidString, sessionID: SessionID, summaryID: String?, text: String,
                owner: String? = nil, due: String? = nil, timestampMs: Int? = nil, isDone: Bool = false) {
        self.id = id; self.sessionID = sessionID; self.summaryID = summaryID; self.text = text
        self.owner = owner; self.due = due; self.timestampMs = timestampMs; self.isDone = isDone
    }
}

public struct Bookmark: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var sessionID: SessionID
    public var atMs: Int
    public var note: String?
    public init(id: String = UUID().uuidString, sessionID: SessionID, atMs: Int, note: String? = nil) {
        self.id = id; self.sessionID = sessionID; self.atMs = atMs; self.note = note
    }
}

// MARK: - Settings-level models

public enum RecordingMode: String, Codable, Sendable, CaseIterable { case auto, ask, never }

public enum ProviderID: String, Codable, Sendable, CaseIterable, Identifiable {
    case anthropic, openAI = "openai", gemini, azureOpenAI = "azure-openai", openRouter = "openrouter",
         openAICompatible = "openai-compatible", ollama
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic (Claude)"
        case .openAI: "OpenAI"
        case .gemini: "Google Gemini"
        case .azureOpenAI: "Azure OpenAI"
        case .openRouter: "OpenRouter"
        case .openAICompatible: "OpenAI-compatible"
        case .ollama: "Ollama (local)"
        }
    }
    /// Providers that run on this Mac and need no API key.
    public var isLocal: Bool { self == .ollama }
    public var requiresAPIKey: Bool { !isLocal && self != .openAICompatible }
}
