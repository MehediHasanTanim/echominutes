import EMCore
import Foundation
import Testing
@testable import EMStorage

@Suite("Templates & Ask storage")
struct TemplateAskStorageTests {
    @Test func userTemplatesCRUD() throws {
        let db = try AppDatabase.inMemory()
        let repo = TemplateRepository(db)
        var t = UserTemplate(name: "Board meeting", instructions: "Decisions and risks.", sections: ["Risks"],
                             rule: TemplateRule(appIDs: ["teams"], titlePattern: "board"), priority: 20)
        try repo.save(t)
        try repo.save(UserTemplate(name: "Another", instructions: "x", priority: 5))
        #expect(try repo.all().map(\.name) == ["Another", "Board meeting"])          // by priority
        t.name = "Board"
        try repo.save(t)                                                             // update in place
        #expect(try repo.all().first { $0.id == t.id } == t)
        try repo.delete(t.id)
        #expect(try repo.all().count == 1)
    }

    @Test func askHistoryCostAndCascade() throws {
        let db = try AppDatabase.inMemory()
        let s = Session(title: "Release sync", sourceAppID: "zoom", startedAt: Date(), status: .ready)
        try SessionRepository(db).insert(s)
        let repo = AskRepository(db)
        try repo.append(AskMessage(sessionID: s.id, role: .user, text: "When do we ship?"))
        try repo.append(AskMessage(sessionID: s.id, role: .assistant, text: "March 3rd [12:40].", provider: .anthropic,
                                   model: "claude-sonnet", tokensIn: 900, tokensOut: 40, costUSD: 0.0033))
        let m = try repo.messages(s.id)
        #expect(m.map(\.role) == [.user, .assistant])
        #expect(m[1].provider == .anthropic && m[1].tokensIn == 900)
        #expect(abs(try repo.totalCost(since: Date().addingTimeInterval(-60)) - 0.0033) < 1e-9)
        try SessionRepository(db).delete(s.id)                                      // chat goes with the meeting
        #expect(try repo.messages(s.id).isEmpty)
    }
}
