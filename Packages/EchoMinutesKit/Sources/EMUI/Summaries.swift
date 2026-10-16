import EMCore
import EMJobs
import EMStorage
import EMSummarization
import Foundation

/// Settings ▸ AI Summary values and the per-meeting job configuration (EM-114/116/117).
public enum SummaryPreferences {
    public static let autoKey = "llm.autoSummarize"
    public static let languageKey = "llm.summaryLanguage"           // "" = same as the meeting
    public static let templateKey = "llm.defaultTemplate"            // "" = automatic

    public static var autoSummarize: Bool { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
    public static var language: String { UserDefaults.standard.string(forKey: languageKey) ?? "" }
    public static var defaultTemplateID: String? { UserDefaults.standard.string(forKey: templateKey).flatMap { $0.isEmpty ? nil : $0 } }

    public static let languages = ["", "English", "Bengali", "Hindi", "Spanish", "French", "German", "Arabic"]

    public static func pricingURL(_ paths: AppPaths) -> URL { paths.root.appendingPathComponent("Pricing.json") }

    /// Which provider a meeting is summarised with. Order: the meeting's own choice (Regenerate…) → default.
    /// Apps marked local-only (Settings ▸ Detection) only ever use Ollama.
    static func config(for session: Session, db: AppDatabase, paths: AppPaths) -> SummarizeJobHandler.Config {
        let store = ProviderStore(db: db)
        let base = SummarizeJobHandler.Config(provider: nil, language: language,
                                              myName: UserDefaults.standard.string(forKey: TranscriptionPreferences.myNameKey) ?? "",
                                              pricing: Pricing.load(from: pricingURL(paths)), defaultTemplateID: defaultTemplateID)
        var cfg = base
        let localOnly = session.sourceAppID.flatMap { (try? SettingsRepository(db).rules())?[$0]?.localOnly } ?? false
        if localOnly {
            if store.readiness(.ollama) == nil { cfg.provider = store.settings(.ollama) }
            else { cfg.blockedReason = "This app is set to local-only summaries, and Ollama isn't set up (Settings ▸ Providers ▸ Ollama)." }
            return cfg
        }
        guard let p = session.llmProvider ?? LLMPreferences.summaryProvider else { return cfg }
        if let problem = store.readiness(p) {
            cfg.blockedReason = "\(p.displayName): \(problem). Fix it in Settings ▸ Providers."
            return cfg
        }
        var s = store.settings(p)
        if session.llmProvider == p, let m = session.llmModel, !m.isEmpty, p != .azureOpenAI { s.model = m }
        cfg.provider = s
        return cfg
    }
}

extension AppState {
    /// After a transcript is saved: summarise automatically when a provider is ready.
    func transcriptFinished(_ id: SessionID) {
        guard SummaryPreferences.autoSummarize else { return }
        guard summaryProviderProblem == nil else {
            summaryNotes[id] = summaryProviderProblem.map { "No summary: \($0)" }
            return
        }
        summarize(id)
    }

    /// Queue a (re)summary. `template` / `provider` override the defaults for this meeting.
    public func summarize(_ id: SessionID, template: String? = nil, provider: ProviderID? = nil) {
        guard let runner = jobRunner, let database else { return }
        if template != nil || provider != nil, var s = session(id) {
            if let template { s.templateID = template == "auto" ? nil : template }
            if let provider { s.llmProvider = provider; s.llmModel = providerConfig(provider).model }
            try? SessionRepository(database).update(s)
        }
        summaryNotes[id] = nil
        summaryProgress[id] = JobProgress(fraction: 0, message: "Waiting…")
        Task { await runner.enqueue(.summarize, sessionID: id) }
    }

    public func summaries(for id: SessionID) -> [Summary] {
        guard let database else { return [] }
        return (try? SummaryRepository(database).history(id)) ?? []
    }

    public func actionItems(for id: SessionID) -> [ActionItem] {
        guard let database else { return [] }
        return (try? SummaryRepository(database).actionItems(id)) ?? []
    }

    public func setActionItem(_ item: ActionItem, done: Bool) {
        guard let database else { return }
        try? SummaryRepository(database).setDone(item.id, done)
        summaryVersion += 1
    }

    public func makeSummaryCurrent(_ summary: Summary) {
        guard let database else { return }
        try? SummaryRepository(database).makeCurrent(summary.id, sessionID: summary.sessionID)
        summaryVersion += 1
    }

    /// Estimated API spend this calendar month.
    public var costThisMonth: Double {
        guard let database else { return 0 }
        let start = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
        return (try? SummaryRepository(database).totalCost(since: start)) ?? 0
    }

    /// Providers ready to use (for "Regenerate with…").
    public var readyProviders: [ProviderID] { ProviderID.allCases.filter { providerReadiness($0) == nil } }
}
