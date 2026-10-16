import EMCore
import EMStorage
import EMSummarization
import Foundation

/// `summarize` job (EM-114/115/117): transcript → provider → validated summary + action items, auto-title, cost.
/// Errors the user must fix (bad key, quota, missing model) fail permanently with a clear message; rate limits,
/// network and server errors go back to the queue with backoff. The transcript is never touched.
public struct SummarizeJobHandler: JobHandler {
    public struct Config: Sendable {
        public var provider: ProviderSettings?
        /// Why no provider can be used (e.g. local-only app without Ollama).
        public var blockedReason: String?
        public var language: String
        public var myName: String
        public var pricing: Pricing
        /// nil = pick automatically from the title / opening of the transcript.
        public var defaultTemplateID: String?
        public init(provider: ProviderSettings?, blockedReason: String? = nil, language: String = "", myName: String = "",
                    pricing: Pricing = .defaults, defaultTemplateID: String? = nil) {
            self.provider = provider; self.blockedReason = blockedReason; self.language = language; self.myName = myName
            self.pricing = pricing; self.defaultTemplateID = defaultTemplateID
        }
    }

    let db: AppDatabase
    let config: @Sendable (Session) -> Config
    let makeProvider: @Sendable (ProviderSettings) throws -> LLMProvider

    public init(db: AppDatabase, config: @escaping @Sendable (Session) -> Config,
                makeProvider: @escaping @Sendable (ProviderSettings) throws -> LLMProvider = { try ProviderFactory.make($0) }) {
        self.db = db; self.config = config; self.makeProvider = makeProvider
    }

    public func run(_ job: Job, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let sessions = SessionRepository(db)
        guard let sid = job.sessionID, let session = try sessions.fetch(sid) else { throw JobFailure.permanent("Session not found") }
        let transcript = TranscriptRepository(db)
        let segments = try transcript.segments(sid)
        guard !segments.isEmpty else { throw JobFailure.permanent("No transcript yet — transcribe the meeting first.") }
        let speakers = Dictionary(uniqueKeysWithValues: try transcript.speakers(sid).map { ($0.id, $0) })

        let cfg = config(session)
        guard let settings = cfg.provider else {
            throw JobFailure.permanent(cfg.blockedReason ?? "Choose an AI provider for summaries in Settings ▸ Providers.")
        }
        let model = (settings.provider == .azureOpenAI ? settings.azureDeployment : settings.model) ?? ""
        guard !model.isEmpty else { throw JobFailure.permanent("Pick a model for \(settings.provider.displayName) in Settings ▸ Providers.") }

        let lines = segments.map { s in
            PromptLine(startMs: s.startMs, speaker: s.speakerID.flatMap { speakers[$0]?.name } ?? (s.track == .mic ? "Me" : "Others"), text: s.text)
        }
        let opening = lines.prefix { $0.startMs < 180_000 }.map(\.text).joined(separator: " ")
        let template = SummaryTemplate.byID(session.templateID) ?? SummaryTemplate.byID(cfg.defaultTemplateID)
            ?? SummaryTemplate.match(title: session.title, transcriptOpening: opening)
        let participants = Array(NSOrderedSet(array: lines.map(\.speaker))) as? [String] ?? []
        let meta = MeetingMetadata(title: session.title, app: session.sourceAppID ?? "call", date: session.startedAt,
                                   durationMinutes: Int(((session.duration ?? Double(segments.last?.endMs ?? 0) / 1000) / 60).rounded()),
                                   participants: participants, myName: cfg.myName)

        let previous = session.status
        try sessions.setStatus(sid, .summarizing)
        do {
            let provider = try makeProvider(settings)
            let out = try await Summarizer(provider: provider, model: model, language: cfg.language)
                .summarize(meta: meta, lines: lines, template: template, progress: progress)

            var summary = Summary(sessionID: sid, templateID: template.id, provider: settings.provider, model: out.model,
                                  content: out.content, markdown: out.markdown)
            summary.tokensIn = out.inputTokens
            summary.tokensOut = out.outputTokens
            summary.costUSD = cfg.pricing.cost(model: out.model, provider: settings.provider, inputTokens: out.inputTokens, outputTokens: out.outputTokens)
            let actions = (out.content?.actionItems ?? []).map { a in
                ActionItem(sessionID: sid, summaryID: summary.id, text: a.task, owner: a.owner, due: a.due,
                           timestampMs: SummaryMarkdown.ms(fromTimestamp: a.timestamp))
            }
            try SummaryRepository(db).save(summary, actionItems: actions)

            var s = try sessions.fetch(sid) ?? session
            if !s.titleIsUserEdited, let t = out.content?.title, !t.isEmpty { s.title = t }
            s.llmProvider = settings.provider
            s.llmModel = out.model
            s.status = .ready
            try sessions.update(s)
            Log.info(.llm, "Summary for \(sid): \(template.id), \(out.chunks) chunk(s), \(out.inputTokens)+\(out.outputTokens) tokens"
                     + (summary.costUSD.map { String(format: ", $%.4f", $0) } ?? "") + (out.content == nil ? " (Markdown fallback)" : ""))
        } catch {
            try? sessions.setStatus(sid, previous == .summarizing ? .ready : previous)
            if Task.isCancelled { throw CancellationError() }
            if let e = error as? LLMError, !e.isTransient { throw JobFailure.permanent(e.localizedDescription) }
            throw error
        }
    }
}
