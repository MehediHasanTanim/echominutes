import EMCore
import Foundation

/// Transcript → validated summary (EM-113/114): single pass when it fits the model's context, otherwise
/// map-reduce over overlapping chunks; one schema-repair retry; Markdown fallback when the schema still fails.
public struct Summarizer: Sendable {
    public struct Output: Sendable, Equatable {
        public var content: SummaryContent?
        public var markdown: String
        public var inputTokens: Int
        public var outputTokens: Int
        public var model: String
        public var chunks: Int
    }

    let provider: LLMProvider
    let model: String
    let language: String
    /// Fraction of the context window the transcript may use in one call.
    let budgetShare: Double
    let maxOutputTokens: Int

    public init(provider: LLMProvider, model: String, language: String = "", budgetShare: Double = 0.7, maxOutputTokens: Int = 4096) {
        self.provider = provider; self.model = model; self.language = language
        self.budgetShare = budgetShare; self.maxOutputTokens = maxOutputTokens
    }

    public func summarize(meta: MeetingMetadata, lines: [PromptLine], template: SummaryTemplate,
                          progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) async throws -> Output {
        guard !lines.isEmpty else { throw LLMError.badRequest("The transcript is empty — nothing to summarise.") }
        let system = PromptBuilder.system(template: template, language: language)
        let window = TokenBudget.contextWindow(provider: provider.id, model: model)
        let budget = Int(Double(window) * budgetShare) - TokenBudget.estimate(system) - maxOutputTokens
        let full = PromptBuilder.user(meta: meta, lines: lines)
        var usage = (input: 0, output: 0)

        if TokenBudget.estimate(full) <= budget {
            progress(0.1, "Writing summary…")
            let (content, md) = try await structured(system: system, user: full, usage: &usage)
            progress(1, "Summary ready")
            return Output(content: content, markdown: md, inputTokens: usage.input, outputTokens: usage.output, model: model, chunks: 1)
        }

        // Map-reduce for long meetings.
        let chunkTokens = max(1_000, min(budget, 8_000))
        let parts = TokenBudget.chunks(lines, maxTokens: chunkTokens)
        Log.info(.llm, "Long transcript: \(parts.count) chunks of ≤ \(chunkTokens) tokens (window \(window))")
        var partials: [SummaryContent] = []
        for (i, part) in parts.enumerated() {
            try Task.checkCancellation()
            progress(Double(i) / Double(parts.count + 1), "Summarising part \(i + 1) of \(parts.count)…")
            let user = PromptBuilder.user(meta: meta, lines: part, part: (i + 1, parts.count))
            let (content, _) = try await structured(system: system, user: user, usage: &usage, allowMarkdown: false)
            if let content { partials.append(content) }
        }
        guard !partials.isEmpty else { throw LLMError.badResponse("no part of the meeting could be summarised") }
        progress(Double(parts.count) / Double(parts.count + 1), "Combining parts…")
        let (content, md) = try await structured(system: system, user: PromptBuilder.reduce(meta: meta, partials: partials), usage: &usage)
        progress(1, "Summary ready")
        return Output(content: content, markdown: md, inputTokens: usage.input, outputTokens: usage.output, model: model, chunks: parts.count)
    }

    /// Schema call → validate → one repair retry → (optionally) Markdown fallback.
    private func structured(system: String, user: String, usage: inout (input: Int, output: Int),
                            allowMarkdown: Bool = true) async throws -> (SummaryContent?, String) {
        var messages = [LLMMessage(.user, user)]
        var lastProblems: [String] = []
        for attempt in 0..<2 {
            let r = try await provider.complete(LLMRequest(model: model, system: system, messages: messages, jsonSchema: SummarySchema.json,
                                                           schemaName: SummarySchema.name, maxOutputTokens: maxOutputTokens, temperature: 0.2))
            usage.input += r.inputTokens ?? TokenBudget.estimate(system + user)
            usage.output += r.outputTokens ?? TokenBudget.estimate(r.text)
            do {
                let content = try SummaryValidator.validate(r.text)
                return (content, SummaryMarkdown.render(content))
            } catch let e as SummaryValidator.Invalid {
                lastProblems = e.problems
                Log.error(.llm, "Summary attempt \(attempt + 1) invalid: \(e.problems.joined(separator: "; "))")
                messages += [LLMMessage(.assistant, r.text), LLMMessage(.user, PromptBuilder.retry(problems: e.problems))]
            }
        }
        guard allowMarkdown else { return (nil, "") }
        // Fallback: plain Markdown minutes (stored with schema_valid = 0).
        let r = try await provider.complete(LLMRequest(model: model, system: system.replacingOccurrences(of: "Return only the JSON object for the schema.",
                                                                                                   with: "Return Markdown minutes with sections: TL;DR, Key points, Decisions, Action items, Open questions, Next steps."),
                                                       messages: [LLMMessage(.user, user)], maxOutputTokens: maxOutputTokens))
        usage.input += r.inputTokens ?? TokenBudget.estimate(system + user)
        usage.output += r.outputTokens ?? TokenBudget.estimate(r.text)
        Log.info(.llm, "Stored Markdown fallback after schema problems: \(lastProblems.joined(separator: "; "))")
        return (nil, r.text)
    }
}
