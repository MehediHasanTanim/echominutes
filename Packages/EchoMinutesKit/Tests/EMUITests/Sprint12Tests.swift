import EMCore
import EMStorage
import Foundation
import Testing
@testable import EMUI

@Suite("Retention & library filters", .serialized)
@MainActor
struct RetentionTests {
    @Test func retentionDeletesOldAudioButKeepsText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("em-ret-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppPaths(root: root)
        let db = try AppDatabase.inMemory()
        let now = Date()
        var old = Session(title: "Old call", sourceAppID: "zoom", startedAt: now.addingTimeInterval(-40 * 86_400), status: .ready)
        old.notesMarkdown = "keep me"
        let fresh = Session(title: "New call", sourceAppID: "teams", startedAt: now.addingTimeInterval(-2 * 86_400), status: .ready)
        for s in [old, fresh] {
            try SessionRepository(db).insert(s)
            let dir = try paths.createSessionDirectories(s.id)
            try Data([1, 2, 3]).write(to: dir.appendingPathComponent("mixed.m4a"))
        }
        let state = AppState(paths: paths, database: db)
        let key = PrivacyPreferences.audioRetentionDaysKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }

        UserDefaults.standard.set(0, forKey: key)
        #expect(state.applyRetention(now: now) == 0)                   // "Never" deletes nothing

        UserDefaults.standard.set(30, forKey: key)
        #expect(state.applyRetention(now: now) == 1)
        #expect(!state.hasAudio(old.id))
        #expect(state.hasAudio(fresh.id))
        #expect(try SessionRepository(db).fetch(old.id)?.notesMarkdown == "keep me")
    }

    @Test func libraryFilters() throws {
        let db = try AppDatabase.inMemory()
        let now = Date()
        let a = Session(title: "A", sourceAppID: "zoom", startedAt: now.addingTimeInterval(-3600), status: .ready)
        let b = Session(title: "B", sourceAppID: "teams", startedAt: now.addingTimeInterval(-10 * 86_400), status: .ready)
        try SessionRepository(db).insert(a); try SessionRepository(db).insert(b)
        let summary = Summary(sessionID: b.id, content: nil, markdown: "x")
        try SummaryRepository(db).save(summary, actionItems: [ActionItem(sessionID: b.id, summaryID: summary.id, text: "Do it")])
        let state = AppState(paths: nil, database: db)

        var f = LibraryFilter()
        #expect(state.filteredSessions(f, now: now).count == 2)
        f.appID = "zoom"; #expect(state.filteredSessions(f, now: now).map(\.title) == ["A"])
        f = LibraryFilter(); f.range = .week; #expect(state.filteredSessions(f, now: now).map(\.title) == ["A"])
        f = LibraryFilter(); f.openActionsOnly = true; #expect(state.filteredSessions(f, now: now).map(\.title) == ["B"])
        #expect(Set(state.libraryApps) == ["teams", "zoom"])
    }
}
