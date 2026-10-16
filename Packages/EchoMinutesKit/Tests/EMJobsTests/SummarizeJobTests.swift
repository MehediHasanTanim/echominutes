import EMCore
import EMStorage
import EMSummarization
import Foundation
import Testing
@testable import EMJobs

struct CannedProvider: LLMProvider {
    let id: ProviderID = .anthropic
    let result: Result<String, LLMError>
    func listModels() async throws -> [String] { [] }
    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        LLMResponse(text: try result.get(), model: "claude-sonnet-4-5", inputTokens: 2_000, outputTokens: 300)
    }
}

let goodSummary = """
{"title":"Q1 budget review","tldr":"Budget approved.","key_points":["Costs up"],"decisions":["Approve"],
 "action_items":[{"task":"Send the sheet","owner":"Rahim","due":"Friday","timestamp":"00:12"}],"open_questions":[],"next_steps":[]}
"""

@Suite("SummarizeJobHandler", .serialized)
struct SummarizeJobTests {
    func seeded(titleEdited: Bool = false) throws -> (AppDatabase, Session) {
        let db = try AppDatabase.inMemory()
        var s = Session(title: "Zoom call", sourceAppID: "zoom", startedAt: Date(), status: .ready)
        s.titleIsUserEdited = titleEdited
        s.endedAt = s.startedAt.addingTimeInterval(1_800)
        try SessionRepository(db).insert(s)
        let me = Speaker(sessionID: s.id, label: "Me", displayName: "Tanim", isMe: true)
        let other = Speaker(sessionID: s.id, label: "Speaker 1", displayName: "Rahim")
        try TranscriptRepository(db).replace(s.id, speakers: [me, other], segments: [
            TranscriptSegment(sessionID: s.id, speakerID: me.id, track: .mic, startMs: 1_000, endMs: 4_000, text: "Let's review the budget."),
            TranscriptSegment(sessionID: s.id, speakerID: other.id, track: .system, startMs: 12_000, endMs: 15_000, text: "I'll send the sheet by Friday."),
        ])
        return (db, s)
    }

    func job(_ s: Session) -> Job { Job(id: UUID().uuidString, sessionID: s.id, kind: .summarize, status: .running, attempts: 1, lastError: nil, notBefore: nil) }
    let settings = ProviderSettings(provider: .anthropic, apiKey: "k", model: "claude-sonnet-4-5")

    @Test func savesSummaryActionItemsTitleAndCost() async throws {
        let (db, s) = try seeded()
        let h = SummarizeJobHandler(db: db, config: { _ in .init(provider: settings) }, makeProvider: { _ in CannedProvider(result: .success(goodSummary)) })
        try await h.run(job(s)) { _, _ in }

        let summary = try #require(try SummaryRepository(db).current(s.id))
        #expect(summary.content?.decisions == ["Approve"])
        #expect(summary.tokensIn == 2_000)
        let expectedCost: Double = (2_000.0 * 3 + 300.0 * 15) / 1_000_000             // sonnet: $3 in / $15 out per 1M
        #expect(abs((summary.costUSD ?? -1) - expectedCost) < 1e-9, "cost \(String(describing: summary.costUSD))")
        let items = try SummaryRepository(db).actionItems(s.id)
        #expect(items.map(\.text) == ["Send the sheet"])
        #expect(items.first?.timestampMs == 12_000)
        let after = try #require(try SessionRepository(db).fetch(s.id))
        #expect(after.title == "Q1 budget review")                          // auto-title
        #expect(after.status == .ready)
        #expect(after.llmProvider == .anthropic)
        #expect(try SearchRepository(db).search("approve").contains { $0.kind == "summary" })
    }

    @Test func keepsTitleTheUserEdited() async throws {
        let (db, s) = try seeded(titleEdited: true)
        let h = SummarizeJobHandler(db: db, config: { _ in .init(provider: settings) }, makeProvider: { _ in CannedProvider(result: .success(goodSummary)) })
        try await h.run(job(s)) { _, _ in }
        #expect(try SessionRepository(db).fetch(s.id)?.title == "Zoom call")
    }

    @Test func badKeyIsPermanentRateLimitIsRetried() async throws {
        let (db, s) = try seeded()
        let bad = SummarizeJobHandler(db: db, config: { _ in .init(provider: settings) }, makeProvider: { _ in CannedProvider(result: .failure(.invalidKey(nil))) })
        await #expect(throws: JobFailure.self) { try await bad.run(job(s)) { _, _ in } }
        let busy = SummarizeJobHandler(db: db, config: { _ in .init(provider: settings) }, makeProvider: { _ in CannedProvider(result: .failure(.rateLimited(retryAfter: 5))) })
        await #expect(throws: LLMError.rateLimited(retryAfter: 5)) { try await busy.run(job(s)) { _, _ in } }
        #expect(try SessionRepository(db).fetch(s.id)?.status == .ready)    // status restored, transcript untouched
        #expect(try TranscriptRepository(db).segments(s.id).count == 2)
        #expect(try SummaryRepository(db).current(s.id) == nil)
    }

    @Test func noProviderOrLocalOnlyBlockIsExplained() async throws {
        let (db, s) = try seeded()
        let h = SummarizeJobHandler(db: db, config: { _ in .init(provider: nil, blockedReason: "Local-only app, Ollama isn't set up") })
        do { try await h.run(job(s)) { _, _ in }; Issue.record("should fail") }
        catch let JobFailure.permanent(m) { #expect(m.contains("Ollama")) }
    }
}
