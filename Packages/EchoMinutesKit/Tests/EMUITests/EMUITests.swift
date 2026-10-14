import EMCore
import EMStorage
import Foundation
import Testing
@testable import EMUI

@Suite("SessionGrouping")
struct SessionGroupingTests {
    let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Dhaka")!; return c }()
    let now = ISO8601DateFormatter().date(from: "2026-10-15T10:00:00+06:00")!

    func s(_ hoursAgo: Double) -> Session {
        Session(title: "\(hoursAgo)", sourceAppID: "teams", startedAt: now.addingTimeInterval(-hoursAgo * 3600), status: .ready)
    }

    @Test func groupsByRecency() {
        let groups = SessionGrouping.group([s(200), s(1), s(30), s(5), s(80)], now: now, calendar: cal)
        #expect(groups.map(\.title) == ["Today", "Yesterday", "This week", "Earlier"])
        #expect(groups[0].sessions.map(\.title) == ["1.0", "5.0"])         // newest first
        #expect(groups[1].sessions.map(\.title) == ["30.0"])
        #expect(groups[3].sessions.map(\.title) == ["200.0"])
    }

    @Test func emptyGroupsAreOmitted() {
        #expect(SessionGrouping.group([s(1)], now: now, calendar: cal).map(\.title) == ["Today"])
        #expect(SessionGrouping.group([], now: now, calendar: cal).isEmpty)
    }

    @Test func durationText() {
        var x = s(1)
        #expect(SessionGrouping.durationText(x) == "—")
        x.endedAt = x.startedAt.addingTimeInterval(12 * 60 + 30); #expect(SessionGrouping.durationText(x) == "12 min")
        x.endedAt = x.startedAt.addingTimeInterval(65 * 60); #expect(SessionGrouping.durationText(x) == "1 h 05 min")
    }

    @Test func appNames() {
        #expect(SessionGrouping.appDisplayName("whatsapp") == "WhatsApp")
        #expect(SessionGrouping.appDisplayName(nil) == "Unknown app")
    }
}

@Suite("AppState")
@MainActor
struct AppStateTests {
    @Test func loadsSamplesSelectsAndDeletes() throws {
        let state = AppState(paths: nil, database: try AppDatabase.inMemory())
        #expect(state.sessions.isEmpty && state.status == .idle)
        for _ in 0..<7 { state.addSampleSession() }
        #expect(state.sessions.count == 7)
        #expect(state.recentSessions.count == 5)
        let selected = try #require(state.selectedSessionID)
        #expect(state.session(selected) != nil)
        state.deleteSession(selected)
        #expect(state.sessions.count == 6 && state.selectedSessionID == nil)
    }

    @Test func survivesMissingDatabase() {
        let state = AppState(paths: nil, database: nil, startupError: "boom")
        state.addSampleSession()
        #expect(state.sessions.isEmpty && state.startupError == "boom")
    }

    @Test func statusSymbols() {
        #expect(AppStatus.recording(appName: "Zoom", since: Date()).symbolName == "record.circle.fill")
        #expect(AppStatus.idle.label.contains("Idle"))
    }
}
