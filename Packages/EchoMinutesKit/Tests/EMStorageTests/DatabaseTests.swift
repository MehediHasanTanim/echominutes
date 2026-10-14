import EMCore
import Foundation
import GRDB
import Testing
@testable import EMStorage

private func makeSession(_ title: String = "Stand-up", app: String = "teams", started: TimeInterval = 1_800_000_000,
                         status: SessionStatus = .ready) -> Session {
    Session(title: title, sourceAppID: app, startedAt: Date(timeIntervalSince1970: started), status: status)
}

@Suite("Database & migrations")
struct MigrationTests {
    @Test func migratesFreshDatabase() throws {
        let db = try AppDatabase.inMemory()
        let tables = try db.writer.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type IN ('table') ORDER BY name") }
        for t in ["sessions", "audio_tracks", "speakers", "transcript_segments", "summaries", "action_items",
                  "bookmarks", "templates", "app_rules", "provider_configs", "jobs", "search_fts"] {
            #expect(tables.contains(t), "missing table \(t)")
        }
    }

    @Test func onDiskDatabaseIsReopenable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("em-db-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try AppPaths(root: root)
        let s = makeSession()
        do { try SessionRepository(AppDatabase.onDisk(paths)).insert(s) }
        #expect(try SessionRepository(AppDatabase.onDisk(paths)).fetch(s.id)?.title == "Stand-up")   // migrations idempotent
    }
}

@Suite("SessionRepository")
struct SessionRepositoryTests {
    @Test func insertFetchUpdateList() throws {
        let db = try AppDatabase.inMemory(); let repo = SessionRepository(db)
        var a = makeSession("A", started: 100); a.tags = ["client", "q4"]; a.llmProvider = .anthropic
        let b = makeSession("B", app: "zoom", started: 200)
        try repo.insert(a); try repo.insert(b)

        let fetched = try #require(try repo.fetch(a.id))
        #expect(fetched.tags == ["client", "q4"] && fetched.llmProvider == .anthropic && fetched.sourceAppID == "teams")
        #expect(try repo.recent().map(\.title) == ["B", "A"])          // newest first
        #expect(try repo.recent(appID: "zoom").map(\.title) == ["B"])

        var edited = fetched; edited.title = "A (renamed)"; edited.titleIsUserEdited = true
        try repo.update(edited)
        #expect(try repo.fetch(a.id)?.title == "A (renamed)")
        try repo.setStatus(a.id, .failed)
        #expect(try repo.fetch(a.id)?.status == .failed)
    }

    @Test func recoveryListsInterruptedStates() throws {
        let db = try AppDatabase.inMemory(); let repo = SessionRepository(db)
        for st in SessionStatus.allCases { try repo.insert(makeSession(st.rawValue, status: st)) }
        #expect(Set(try repo.needingRecovery().map(\.status)) == [.recording, .paused, .finalizing])
    }

    @Test func deleteCascadesAndCleansSearch() throws {
        let db = try AppDatabase.inMemory()
        let s = makeSession(); try SessionRepository(db).insert(s)
        try TranscriptRepository(db).replace(s.id, speakers: [Speaker(sessionID: s.id, label: "Me", isMe: true)],
                                             segments: [TranscriptSegment(sessionID: s.id, speakerID: nil, track: .mic, startMs: 0, endMs: 900, text: "kickoff budget")])
        try SessionRepository(db).addBookmark(Bookmark(sessionID: s.id, atMs: 500, note: "important"))
        #expect(try SearchRepository(db).search("budget").count == 1)
        try SessionRepository(db).delete(s.id)
        #expect(try SessionRepository(db).fetch(s.id) == nil)
        #expect(try TranscriptRepository(db).segments(s.id).isEmpty)
        #expect(try SessionRepository(db).bookmarks(s.id).isEmpty)
        #expect(try SearchRepository(db).search("budget").isEmpty)
    }
}

@Suite("TranscriptRepository & search")
struct TranscriptTests {
    @Test func replaceRenameEditSearch() throws {
        let db = try AppDatabase.inMemory()
        let s = makeSession(); try SessionRepository(db).insert(s)
        let me = Speaker(sessionID: s.id, label: "Me", isMe: true)
        let other = Speaker(sessionID: s.id, label: "Speaker 1")
        let segs = [
            TranscriptSegment(sessionID: s.id, speakerID: other.id, track: .system, startMs: 5_000, endMs: 8_000, text: "Can we ship the adapter fix by Friday?"),
            TranscriptSegment(sessionID: s.id, speakerID: me.id, track: .mic, startMs: 1_000, endMs: 4_000, text: "Let's review the PBX integration"),
        ]
        let repo = TranscriptRepository(db)
        try repo.replace(s.id, speakers: [me, other], segments: segs)
        let stored = try repo.segments(s.id)
        #expect(stored.map(\.startMs) == [1_000, 5_000])                 // ordered by time
        #expect(stored.allSatisfy { $0.id != nil })

        try repo.renameSpeaker(other.id, to: "Rahim")
        #expect(try repo.speakers(s.id).first { !$0.isMe }?.name == "Rahim")

        let hits = try SearchRepository(db).search("adapter fri")       // prefix match on last word
        #expect(hits.count == 1)
        #expect(hits[0].startMs == 5_000 && hits[0].snippet.contains("[adapter]"))

        try repo.editSegment(id: stored[1].id!, text: "Can we ship the hotfix by Friday?")
        #expect(try SearchRepository(db).search("adapter").isEmpty)
        #expect(try SearchRepository(db).search("hotfix").count == 1)
        #expect(try repo.segments(s.id)[1].isEdited)

        try repo.replace(s.id, speakers: [me], segments: [])           // replace clears old rows + index
        #expect(try repo.segments(s.id).isEmpty && SearchRepository(db).search("PBX").isEmpty)
    }

    @Test(arguments: ["", "   ", "\"\"", "AND OR NOT", "foo\"bar", "(*)"])
    func searchNeverThrowsOnOddInput(q: String) throws {
        let db = try AppDatabase.inMemory()
        _ = try SearchRepository(db).search(q)
    }

    @Test func notesAreSearchable() throws {
        let db = try AppDatabase.inMemory()
        let s = makeSession(); try SessionRepository(db).insert(s)
        try SessionRepository(db).setNotes(s.id, "Follow up with John about Atlassian billing")
        #expect(try SearchRepository(db).search("atlassian").first?.kind == "notes")
    }
}

@Suite("SummaryRepository")
struct SummaryTests {
    @Test func currentSummaryHistoryAndActionItems() throws {
        let db = try AppDatabase.inMemory()
        let s = makeSession(); try SessionRepository(db).insert(s)
        let repo = SummaryRepository(db)
        let c1 = SummaryContent(title: "v1", tldr: "first", actionItems: [.init(task: "Draft spec")])
        let s1 = Summary(sessionID: s.id, provider: .anthropic, model: "claude", content: c1, markdown: "# v1", createdAt: Date(timeIntervalSince1970: 1))
        try repo.save(s1, actionItems: [ActionItem(sessionID: s.id, summaryID: s1.id, text: "Draft spec")])

        let s2 = Summary(sessionID: s.id, content: nil, markdown: "raw markdown fallback", createdAt: Date(timeIntervalSince1970: 2))
        let item = ActionItem(sessionID: s.id, summaryID: s2.id, text: "Send recap", owner: "Tanim", timestampMs: 60_000)
        try repo.save(s2, actionItems: [item])

        let current = try #require(try repo.current(s.id))
        #expect(current.id == s2.id && !current.schemaValid)
        #expect(try repo.history(s.id).count == 2)
        #expect(try repo.history(s.id).last?.content == c1)              // JSON round-trip
        #expect(try repo.actionItems(s.id).map(\.text) == ["Send recap"])

        try repo.setDone(item.id, true)
        #expect(try repo.actionItems(s.id).first?.isDone == true)
        #expect(try repo.openActionItems().isEmpty)
    }
}

@Suite("JobRepository")
struct JobTests {
    @Test func claimCompleteFailRetry() throws {
        let db = try AppDatabase.inMemory()
        let s = makeSession(); try SessionRepository(db).insert(s)
        let jobs = JobRepository(db)
        let t0 = Date(timeIntervalSince1970: 1_000)
        let a = try jobs.enqueue(.finalizeAudio, sessionID: s.id, now: t0)
        let b = try jobs.enqueue(.transcribe, sessionID: s.id, now: t0.addingTimeInterval(1))

        let first = try #require(try jobs.claimNext(now: t0.addingTimeInterval(2)))
        #expect(first.id == a && first.status == .running && first.attempts == 1)
        #expect(try jobs.claimNext(kinds: [.summarize], now: t0) == nil)       // kind filter

        try jobs.fail(a, error: "network down, key sk-proj-abcdefghijklmnop1234", retryAt: t0.addingTimeInterval(60))
        #expect(try jobs.claimNext(kinds: [.finalizeAudio], now: t0.addingTimeInterval(30)) == nil)  // backoff respected
        let retried = try #require(try jobs.claimNext(kinds: [.finalizeAudio], now: t0.addingTimeInterval(61)))
        #expect(retried.attempts == 2 && !(retried.lastError ?? "").contains("abcdefghijklmnop"))   // error redacted

        try jobs.complete(a)
        try jobs.fail(b, error: "invalid key", retryAt: nil)
        #expect(try jobs.jobs(for: s.id).map(\.status) == [.done, .failed])
    }

    @Test func requeuesJobsInterruptedByCrash() throws {
        let db = try AppDatabase.inMemory(); let jobs = JobRepository(db)
        try jobs.enqueue(.export, sessionID: nil)
        _ = try jobs.claimNext()
        #expect(try jobs.requeueInterrupted() == 1)
        #expect(try jobs.claimNext() != nil)
    }
}

@Suite("SettingsRepository")
struct SettingsTests {
    @Test func upsertRulesAndProviders() throws {
        let db = try AppDatabase.inMemory(); let repo = SettingsRepository(db)
        try repo.saveRule(AppRuleOverride(appID: "whatsapp", mode: .never))
        try repo.saveRule(AppRuleOverride(appID: "whatsapp", mode: .ask, debounceSec: 10, localOnly: true))
        let r = try #require(try repo.rules()["whatsapp"])
        #expect(r.mode == .ask && r.debounceSec == 10 && r.graceSec == nil && r.localOnly)

        try repo.saveProvider(ProviderConfig(provider: .ollama, model: "llama3", baseURL: "http://localhost:11434"))
        try repo.saveProvider(ProviderConfig(provider: .anthropic, enabled: false))
        #expect(try repo.providers().map(\.provider) == [.anthropic, .ollama])
        #expect(try repo.providers().first { $0.provider == .ollama }?.baseURL == "http://localhost:11434")
    }
}

@Suite("FTS query builder")
struct FTSQueryTests {
    @Test func quotesWordsAndPrefixesLast() {
        #expect(SearchIndex.ftsQuery("adapter fri") == "\"adapter\" \"fri\"*")
        #expect(SearchIndex.ftsQuery("  ") == nil)
        #expect(SearchIndex.ftsQuery("say \"hi\"") == "\"say\" \"hi\"*")
    }
}
