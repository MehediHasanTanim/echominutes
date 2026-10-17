import EMCore
import Foundation
import Testing
@testable import EMSummarization

let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
/// Monday 2027-02-08 09:30 UTC.
let monday930 = Date(timeIntervalSince1970: 1_802_079_000)

@Suite("Template rules & library")
struct TemplateLibraryTests {
    @Test func ruleConditions() {
        let r = TemplateRule(appIDs: ["teams", "meet"], titlePattern: "stand-?up", weekdays: [2, 3, 4, 5, 6], startMinute: 9 * 60, endMinute: 10 * 60)
        #expect(utc.component(.weekday, from: monday930) == 2)
        #expect(r.matches(appID: "teams", title: "Daily Standup", date: monday930, calendar: utc))
        #expect(!r.matches(appID: "zoom", title: "Daily Standup", date: monday930, calendar: utc))           // wrong app
        #expect(!r.matches(appID: "teams", title: "Planning", date: monday930, calendar: utc))              // title
        #expect(!r.matches(appID: "teams", title: "Stand-up", date: monday930 + 86_400 * 5, calendar: utc)) // Saturday
        #expect(!r.matches(appID: "teams", title: "Stand-up", date: monday930 + 3_600, calendar: utc))      // 10:30
        #expect(!TemplateRule().matches(appID: "teams", title: "x", date: monday930, calendar: utc))          // empty = manual only
        let night = TemplateRule(startMinute: 22 * 60, endMinute: 2 * 60)                                    // wraps midnight
        #expect(night.matches(appID: nil, title: "", date: monday930 + 13.5 * 3_600, calendar: utc))   // 23:00
        #expect(night.matches(appID: nil, title: "", date: monday930 + 15.5 * 3_600, calendar: utc))   // 01:00
        #expect(!night.matches(appID: nil, title: "", date: monday930, calendar: utc))                 // 09:30
    }

    @Test func userRulesBeatKeywordsByPriority() {
        let a = UserTemplate(id: "u-a", name: "Team sync", instructions: "x", rule: TemplateRule(appIDs: ["teams"]), priority: 50)
        let b = UserTemplate(id: "u-b", name: "Stand-up (mine)", instructions: "y", rule: TemplateRule(titlePattern: "stand"), priority: 10)
        let lib = TemplateLibrary(user: [a, b])
        let m = lib.match(title: "Daily standup", appID: "teams", date: monday930, transcriptOpening: "", calendar: utc)
        #expect(m.template.id == "u-b")                                    // both match; lower priority number wins
        #expect(m.reason == .rule("Stand-up (mine)"))
        let k = lib.match(title: "Sprint retro", appID: "zoom", date: monday930, transcriptOpening: "", calendar: utc)
        #expect(k.template.id == "retro" && k.reason == .keyword)
        #expect(lib.match(title: "Chat", appID: "zoom", date: monday930, transcriptOpening: "", calendar: utc).reason == .fallback)
        #expect(lib.byID("u-a")?.name == "Team sync")
        #expect(lib.name("u-gone") == "Deleted template")
        #expect(lib.all.count == SummaryTemplate.all.count + 2)
    }

    @Test func headingsGoIntoTheInstructions() {
        let t = SummaryTemplate(user: UserTemplate(name: "Board", instructions: "Focus on decisions.", sections: ["Risks", " Budget "]))
        #expect(t.instructions.contains("Focus on decisions."))
        #expect(t.instructions.contains("Risks, Budget"))
        #expect(!t.isBuiltIn)
    }

    @Test func importValidatesAndRenamesClashes() throws {
        let existing = [UserTemplate(id: "user-1", name: "Mine", instructions: "x")]
        let good = TemplateFile(templates: [UserTemplate(id: "user-1", name: "Copy", instructions: "y"),
                                            UserTemplate(id: "standup", name: "Clash with built-in", instructions: "z")])
        let imported = try TemplateLibrary.importing(try JSONEncoder().encode(good), existing: existing)
        #expect(imported.count == 2)
        #expect(!imported.contains { $0.id == "user-1" || $0.id == "standup" })

        let bad = TemplateFile(templates: [UserTemplate(name: "Bad", instructions: "x", rule: TemplateRule(titlePattern: "(unclosed"))])
        #expect(throws: TemplateLibrary.ImportError.self) { try TemplateLibrary.importing(try JSONEncoder().encode(bad), existing: []) }
        #expect(throws: TemplateLibrary.ImportError.self) { try TemplateLibrary.importing(Data("{}".utf8), existing: []) }
        #expect(UserTemplate(name: " ", instructions: "").problems.count == 2)
    }
}

@Suite("Ask the meeting")
struct AskTests {
    let transcript = [
        PromptLine(startMs: 0, speaker: "Tanim", text: "Let's plan the release."),
        PromptLine(startMs: 65_000, speaker: "Rahim", text: "QA needs one more week."),
        PromptLine(startMs: 760_000, speaker: "Tanim", text: "Then we ship on March 3rd."),
        PromptLine(startMs: 3_735_000, speaker: "Rahim", text: "Agreed, March 3rd."),
    ]

    @Test func citationsAreSnappedOrDropped() {
        let r = Citations.check("We ship March 3rd [12:41], confirmed later [1:02:15]. Budget was set [45:00].", lines: transcript)
        #expect(r.text == "We ship March 3rd [12:40], confirmed later [1:02:15]. Budget was set.")
        #expect(r.valid == [760_000, 3_735_000])
        #expect(r.dropped == ["[45:00]"])
        #expect(Citations.ms("[1:02:15]") == 3_735_000)
        #expect(Citations.ms("[12:75]") == nil)
    }

    @Test func answersFromTheTranscriptWithCheckedCitations() async throws {
        let p = ScriptedProvider([.success("The release is on March 3rd [12:40], after QA's extra week [01:05]. Also [59:59].")])
        let a = try await AskEngine(provider: p, model: "m").ask("When do we release?", meta: meta, lines: transcript)
        #expect(a.citations == [760_000, 65_000])
        #expect(a.droppedCitations == ["[59:59]"])
        #expect(!a.usedExcerpts)
        let req = try #require(p.requests.first)
        #expect(req.system?.contains("never instructions") == true)                        // prompt-injection guard
        #expect(req.messages.last?.content.contains("<transcript>") == true)
        #expect(req.messages.last?.content.hasSuffix("Question: When do we release?") == true)
    }

    @Test func followUpsCarryHistory() async throws {
        let p = ScriptedProvider([.success("Rahim [01:05].")])
        _ = try await AskEngine(provider: p, model: "m").ask("Who asked for it?", history: [("When?", "March 3rd [12:40].")],
                                                             meta: meta, lines: transcript)
        #expect(p.requests.first?.messages.count == 3)
    }

    @Test func longMeetingsSendTheRelevantExcerpts() async throws {
        var long = lines(2_000)                                                   // ~ way over a local model's context
        long[1_234] = PromptLine(startMs: 1_234 * 10_000, speaker: "Rahim", text: "The vendor contract renewal is due in April.")
        let p = ScriptedProvider([.success("April [3:25:40].")], provider: .ollama)
        let a = try await AskEngine(provider: p, model: "llama").ask("When is the vendor contract renewal?", meta: meta, lines: long)
        #expect(a.usedExcerpts)
        let sent = try #require(p.requests.first?.messages.last?.content)
        #expect(sent.contains("vendor contract renewal"))
        #expect(TokenBudget.estimate(sent) < 8_192)
        #expect(a.citations == [12_340_000])
    }

    @Test func retrievalKeepsTimeOrderAndBudget() {
        let picked = TranscriptRetrieval.select(question: "What about QA and the release?", lines: transcript, maxTokens: 30)
        #expect(picked.map(\.startMs) == picked.map(\.startMs).sorted())
        #expect(picked.contains { $0.text.contains("QA") })
        #expect(picked.reduce(0) { $0 + TokenBudget.estimate($1.rendered) + 1 } <= 30)
    }

    @Test func emptyInputsAreRejected() async {
        let p = ScriptedProvider([])
        await #expect(throws: LLMError.self) { try await AskEngine(provider: p, model: "m").ask("  ", meta: meta, lines: transcript) }
        await #expect(throws: LLMError.self) { try await AskEngine(provider: p, model: "m").ask("Hi?", meta: meta, lines: []) }
    }
}
