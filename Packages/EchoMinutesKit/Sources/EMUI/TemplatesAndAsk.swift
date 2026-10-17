import EMCore
import EMJobs
import EMStorage
import EMSummarization
import Foundation

// MARK: - User templates (EM-170…173)

extension AppState {
    public var userTemplates: [UserTemplate] {
        _ = templatesVersion
        guard let database else { return [] }
        return (try? TemplateRepository(database).all()) ?? []
    }

    public var templateLibrary: TemplateLibrary { TemplateLibrary(user: userTemplates) }

    public func saveTemplate(_ t: UserTemplate) throws {
        guard let database else { return }
        let problems = t.problems
        guard problems.isEmpty else { throw TemplateLibrary.ImportError.problems(problems) }
        try TemplateRepository(database).save(t)
        templatesVersion += 1
    }

    public func deleteTemplate(_ id: String) {
        guard let database else { return }
        try? TemplateRepository(database).delete(id)
        if SummaryPreferences.defaultTemplateID == id { UserDefaults.standard.set("", forKey: SummaryPreferences.templateKey) }
        templatesVersion += 1
    }

    /// A user copy of any template, ready to edit.
    public func duplicateTemplate(_ t: SummaryTemplate) -> UserTemplate {
        if let u = userTemplates.first(where: { $0.id == t.id }) {
            return UserTemplate(name: u.name + " copy", instructions: u.instructions, sections: u.sections, rule: u.rule,
                                priority: u.priority, basedOn: u.basedOn)
        }
        return UserTemplate(name: t.name + " (mine)", instructions: t.instructions, basedOn: t.id)
    }

    public func exportTemplates(to url: URL) throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(TemplateFile(templates: userTemplates)).write(to: url)
    }

    /// Returns how many templates were imported.
    @discardableResult
    public func importTemplates(from url: URL) throws -> Int {
        guard let database else { return 0 }
        let imported = try TemplateLibrary.importing(try Data(contentsOf: url), existing: userTemplates)
        for t in imported { try TemplateRepository(database).save(t) }
        templatesVersion += 1
        return imported.count
    }

    /// Which template each of the last meetings would get with `templates` as the user templates (EM-172).
    public func testTemplateRules(_ templates: [UserTemplate], limit: Int = 20) -> [(session: Session, template: String, reason: TemplateLibrary.Reason)] {
        let lib = TemplateLibrary(user: templates)
        return sessions.prefix(limit).map { s in
            let opening = transcript(for: s.id).segments.prefix { $0.startMs < 180_000 }.map(\.text).joined(separator: " ")
            let m = lib.match(title: s.title, appID: s.sourceAppID, date: s.startedAt, transcriptOpening: opening)
            return (s, m.template.name, m.reason)
        }
    }

    /// Runs a draft template on a past meeting without saving anything (EM-171). Returns Markdown.
    public func previewSummary(_ template: UserTemplate, on sessionID: SessionID) async throws -> String {
        let (provider, model, _, meta, lines) = try llmInput(for: sessionID)
        let out = try await Summarizer(provider: provider, model: model, language: SummaryPreferences.language)
            .summarize(meta: meta, lines: lines, template: SummaryTemplate(user: template))
        return out.markdown
    }

    /// Provider + transcript for an LLM call on one meeting. Honours "Local only" (Ollama only) like summaries do.
    func llmInput(for sessionID: SessionID) throws -> (LLMProvider, String, SummarizeJobHandler.Config, MeetingMetadata, [PromptLine]) {
        guard let database, let paths, let session = session(sessionID) else { throw LLMError.notConfigured("Library unavailable") }
        let cfg = SummaryPreferences.config(for: session, db: database, paths: paths)
        guard let settings = cfg.provider else {
            throw LLMError.notConfigured(cfg.blockedReason ?? "Choose an AI provider in Settings ▸ Providers.")
        }
        let model = (settings.provider == .azureOpenAI ? settings.azureDeployment : settings.model) ?? ""
        guard !model.isEmpty else { throw LLMError.notConfigured("Pick a model for \(settings.provider.displayName) in Settings ▸ Providers.") }
        let t = transcript(for: sessionID)
        let speakers = Dictionary(uniqueKeysWithValues: t.speakers.map { ($0.id, $0) })
        let (meta, lines) = SummarizeJobHandler.promptInput(session: session, segments: t.segments, speakers: speakers, myName: cfg.myName)
        return (try ProviderFactory.make(settings), model, cfg, meta, lines)
    }
}

// MARK: - Ask the meeting (EM-174…177)

extension AppState {
    public func askMessages(_ id: SessionID) -> [AskMessage] {
        _ = askVersion
        guard let database else { return [] }
        return (try? AskRepository(database).messages(id)) ?? []
    }

    public func clearAsk(_ id: SessionID) {
        guard let database else { return }
        try? AskRepository(database).clear(id)
        askVersion += 1
    }

    public func ask(_ question: String, about id: SessionID) async {
        guard let database, !askBusy.contains(id) else { return }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let repo = AskRepository(database)
        // Earlier successful turns, for follow-up questions.
        var history: [(question: String, answer: String)] = []
        var pending: String?
        for m in askMessages(id) {
            switch m.role {
            case .user: pending = m.text
            case .assistant: if let p = pending { history.append((p, m.text)); pending = nil }
            case .error: pending = nil
            }
        }
        try? repo.append(AskMessage(sessionID: id, role: .user, text: q))
        askBusy.insert(id); askVersion += 1
        defer { askBusy.remove(id); askVersion += 1 }
        do {
            let (provider, model, cfg, meta, lines) = try llmInput(for: id)
            let answer = try await AskEngine(provider: provider, model: model).ask(q, history: history, meta: meta, lines: lines)
            var text = answer.text
            if answer.usedExcerpts { text += "\n\n_Based on the parts of the meeting most related to the question._" }
            let cost = cfg.pricing.cost(model: answer.model, provider: provider.id, inputTokens: answer.inputTokens, outputTokens: answer.outputTokens)
            try? repo.append(AskMessage(sessionID: id, role: .assistant, text: text, provider: provider.id, model: answer.model,
                                        tokensIn: answer.inputTokens, tokensOut: answer.outputTokens, costUSD: cost))
            Log.info(.llm, "Ask \(id): \(answer.citations.count) citation(s), \(answer.inputTokens)+\(answer.outputTokens) tokens"
                     + (cost.map { String(format: ", $%.4f", $0) } ?? ""))
        } catch {
            try? repo.append(AskMessage(sessionID: id, role: .error, text: error.localizedDescription))
        }
    }

    /// Starter questions for an empty chat (EM-175).
    public func suggestedQuestions(_ id: SessionID) -> [String] {
        let others = Set(transcript(for: id).speakers.filter { !$0.isMe }.map(\.name)).sorted()
        var q = ["What was decided?", "What are my action items?", "Which questions are still open?"]
        if let first = others.first(where: { $0 != "Others" }) { q.append("What did \(first) say?") }
        q.append("Summarise the last 10 minutes")
        return q
    }
}
