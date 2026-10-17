import EMCore
import EMJobs
import EMSession
import EMStorage
import EMTranscription
import Foundation

/// Settings ▸ Transcription values (UserDefaults).
public enum TranscriptionPreferences {
    public static let modelKey = "stt.model"
    public static let languageKey = "stt.language"
    public static let vocabularyKey = "stt.vocabulary"
    public static let autoKey = "stt.auto"
    public static let speakersKey = "stt.identifySpeakers"
    public static let myNameKey = "myName"
    public static let engineKey = "stt.engine"
    public static let appEnginesKey = "stt.appEngines"          // [appID: engine raw value]
    public static let openAIModelKey = "stt.openaiModel"
    public static let cloudConsentKey = "stt.cloudConsent"

    /// Per-app engine choices (absent = use the default).
    public static var appEngines: [String: STTEngineChoice] {
        get {
            let raw = UserDefaults.standard.dictionary(forKey: appEnginesKey) as? [String: String] ?? [:]
            return raw.compactMapValues { STTEngineChoice(rawValue: $0) }
        }
        set { UserDefaults.standard.set(newValue.mapValues(\.rawValue), forKey: appEnginesKey) }
    }

    /// API key for a cloud engine (Keychain), nil when missing.
    public static func apiKey(_ choice: STTEngineChoice) -> String? {
        choice.keychainAccount.flatMap { (try? KeychainStore().get(account: $0)) ?? nil }
    }

    public static var current: TranscriptionSettings {
        let d = UserDefaults.standard
        let vocab = (d.string(forKey: vocabularyKey) ?? "")
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return TranscriptionSettings(model: d.string(forKey: modelKey) ?? STTModelCatalog.defaultVariant,
                                     language: d.string(forKey: languageKey) ?? "en",
                                     vocabulary: vocab,
                                     autoTranscribe: d.object(forKey: autoKey) as? Bool ?? true,
                                     identifySpeakers: d.object(forKey: speakersKey) as? Bool ?? true,
                                     myName: d.string(forKey: myNameKey) ?? "",
                                     engine: d.string(forKey: engineKey).flatMap(STTEngineChoice.init(rawValue:)) ?? .local,
                                     appEngines: appEngines,
                                     openAIModel: d.string(forKey: openAIModelKey) ?? "whisper-1")
    }

    public static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("bn", "Bengali (বাংলা)"), ("hi", "Hindi"), ("ur", "Urdu"), ("ar", "Arabic"),
        ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("zh", "Chinese"), ("ja", "Japanese"),
    ]
}

/// Keeps one loaded engine per model variant (loading turbo takes seconds; the first time minutes).
final class EngineCache: @unchecked Sendable {
    private let lock = NSLock()
    private var engines: [String: WhisperKitEngine] = [:]
    let models: STTModelManager
    init(models: STTModelManager) { self.models = models }

    /// `key` from `TranscriptionSettings.engineKey`: a Whisper model, "deepgram", "assemblyai" or "openai:<model>".
    func engine(_ key: String) -> TranscriptionEngine {
        if key == STTEngineChoice.deepgram.rawValue {
            return DeepgramEngine(apiKey: { TranscriptionPreferences.apiKey(.deepgram) })
        }
        if key == STTEngineChoice.assemblyAI.rawValue {
            return AssemblyAIEngine(apiKey: { TranscriptionPreferences.apiKey(.assemblyAI) })
        }
        if key.hasPrefix("openai:") {
            return OpenAITranscriptionEngine(model: String(key.dropFirst("openai:".count)),
                                             apiKey: { TranscriptionPreferences.apiKey(.openAI) })
        }
        let variant = key
        return lock.withLock {
            if let e = engines[variant] { return e }
            let e = WhisperKitEngine(variant: variant, models: models)
            engines[variant] = e
            return e
        }
    }
}

extension AppState {
    public var modelManager: STTModelManager? { paths.map { STTModelManager(modelsDir: $0.modelsDir) } }

    func startJobs() {
        guard jobRunner == nil, let database, let paths else { return }
        let cache = EngineCache(models: STTModelManager(modelsDir: paths.modelsDir))
        let transcribe = TranscribeJobHandler(db: database, paths: paths,
                                              settings: { TranscriptionPreferences.current },
                                              engine: { cache.engine($0) },
                                              diarizer: CallSpeakerDiarizer(modelsDir: paths.modelsDir))
        let summarize = SummarizeJobHandler(db: database, config: { session in
            SummaryPreferences.config(for: session, db: database, paths: paths)
        })
        let runner = JobRunner(db: database, handlers: [.transcribe: transcribe, .summarize: summarize])
        jobRunner = runner
        let events = runner.events
        Task { [weak self] in
            for await e in events { self?.handleJobEvent(e) }
        }
        Task { await runner.start() }
    }

    /// Called whenever a recording has been saved (manual, auto, recovered).
    func recordingSaved(_ id: SessionID) {
        guard TranscriptionPreferences.current.autoTranscribe else { return }
        transcribe(id)
    }

    /// Queue (or re-run) transcription. `now` ignores the battery / Low Power deferral.
    public func transcribe(_ id: SessionID, now: Bool = false) {
        guard let runner = jobRunner else { lastError = "Transcription unavailable"; return }
        jobNotes[id] = nil
        jobProgress[id] = JobProgress(fraction: 0, message: "Waiting to transcribe…")
        Task {
            if let db = database, let j = try? JobRepository(db).latest(.transcribe, sessionID: id), j.status == .queued {
                if now { await runner.force(id) } else { await runner.kick() }
                return
            }
            await runner.enqueue(.transcribe, sessionID: id, force: now)
        }
    }

    public func cancelTranscription(_ id: SessionID) {
        guard let runner = jobRunner else { return }
        Task { await runner.cancel(sessionID: id) }
        jobProgress[id] = nil
        jobNotes[id] = "Transcription cancelled"
    }

    public func transcript(for id: SessionID) -> (segments: [TranscriptSegment], speakers: [Speaker]) {
        guard let database else { return ([], []) }
        let r = TranscriptRepository(database)
        return ((try? r.segments(id)) ?? [], (try? r.speakers(id)) ?? [])
    }

    /// Rename a speaker in one meeting (EM-095). Empty name restores the default label.
    public func renameSpeaker(_ speaker: Speaker, to name: String) {
        guard let database else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        do {
            try TranscriptRepository(database).renameSpeaker(speaker.id, to: trimmed.isEmpty ? nil : trimmed)
            transcriptVersion += 1
        } catch { lastError = "Rename failed: \(error.localizedDescription)" }
    }

    /// Jump the meeting's player to a moment (transcript line, bookmark, search hit) and play.
    public func play(_ id: SessionID, atMs ms: Int) {
        selectedSessionID = id
        playRequest = PlayRequest(sessionID: id, ms: ms, nonce: (playRequest?.nonce ?? 0) + 1)
    }

    /// Full-text search over transcripts (FTS5, prefix match on the last word).
    public func search(_ text: String) -> [SearchHit] {
        guard let database else { return [] }
        return (try? SearchRepository(database).search(text, limit: 100)) ?? []
    }

    func handleJobEvent(_ e: JobEvent) {
        let isSummary: (Job) -> Bool = { $0.kind == .summarize }
        switch e {
        case .started(let j):
            if let s = j.sessionID {
                if isSummary(j) { summaryProgress[s] = JobProgress(fraction: 0, message: "Writing summary…"); summaryNotes[s] = nil }
                else { jobProgress[s] = JobProgress(fraction: 0, message: "Starting…"); jobNotes[s] = nil }
            }
            reloadSessions()
        case .progress(_, let s?, let kind, let f, let m):
            if kind == .summarize { summaryProgress[s] = JobProgress(fraction: f, message: m) }
            else { jobProgress[s] = JobProgress(fraction: f, message: m) }
        case .progress:
            break
        case .finished(let j):
            guard let s = j.sessionID else { break }
            if isSummary(j) {
                summaryProgress[s] = nil; summaryNotes[s] = nil
                summaryVersion += 1
                reloadSessions()
                if let session = session(s) { notifier.summaryReady(sessionID: s, title: session.title) }
            } else {
                jobProgress[s] = nil; jobNotes[s] = nil
                transcriptVersion += 1
                reloadSessions()
                if let session = session(s) { notifier.transcriptReady(sessionID: s, title: session.title) }
                transcriptFinished(s)                       // EM-081: transcribe → summarize
            }
        case .failed(let j, let error, let willRetry):
            if let s = j.sessionID {
                let what = isSummary(j) ? "Summary" : "Transcription"
                let note = willRetry ? "\(what) failed, retrying soon: \(error)" : "\(what) failed: \(error)"
                if isSummary(j) { summaryProgress[s] = nil; summaryNotes[s] = note } else { jobProgress[s] = nil; jobNotes[s] = note }
            }
            reloadSessions()
        case .deferred(let j, let reason):
            if let s = j.sessionID {
                jobProgress[s] = nil
                jobNotes[s] = "Transcription waits (\(reason)). Use “Transcribe now” to run it anyway."
            }
            reloadSessions()
        }
    }

}
