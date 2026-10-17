import EMCore
import Foundation
import Testing
@testable import EMStorage

@Suite("Library queries (Sprint 11)")
struct LibraryQueryTests {
    @Test func observationEmitsOnEveryChange() async throws {
        let db = try AppDatabase.inMemory()
        let repo = SessionRepository(db)
        let stream = repo.observeRecent()
        var it = stream.makeAsyncIterator()
        #expect(await it.next()?.isEmpty == true)                              // initial value
        var s = Session(title: "Zoom call", sourceAppID: "zoom", startedAt: Date(), status: .ready)
        try repo.insert(s)
        #expect(await it.next()?.map(\.title) == ["Zoom call"])
        s.title = "Budget review"
        try repo.update(s)
        #expect(await it.next()?.first?.title == "Budget review")              // e.g. auto-title from the summary
    }

    @Test func openActionItemsAndInlineEdits() throws {
        let db = try AppDatabase.inMemory()
        let a = Session(title: "A", sourceAppID: "teams", startedAt: Date(), status: .ready)
        let b = Session(title: "B", sourceAppID: "zoom", startedAt: Date(), status: .ready)
        try SessionRepository(db).insert(a); try SessionRepository(db).insert(b)
        let summary = Summary(sessionID: a.id, content: nil, markdown: "x")
        var item = ActionItem(sessionID: a.id, summaryID: summary.id, text: "Send sheet")
        let repo = SummaryRepository(db)
        try repo.save(summary, actionItems: [item])
        #expect(try repo.withOpenActionItems() == [a.id])

        item.text = "Send the updated sheet"; item.owner = "Rahim"; item.isDone = true
        try repo.updateActionItem(item)
        let saved = try #require(try repo.actionItems(a.id).first)
        #expect(saved.text == "Send the updated sheet" && saved.owner == "Rahim" && saved.isDone)
        #expect(try repo.withOpenActionItems().isEmpty)
    }
}
