import EMCore
import EMStorage
import Foundation
import Testing
@testable import EMSession

@Suite("ManualRecorder recovery")
struct ManualRecorderTests {
    @Test func marksCrashLeftoversInterrupted() throws {
        let db = try AppDatabase.inMemory()
        let repo = SessionRepository(db)
        for st in SessionStatus.allCases { try repo.insert(Session(title: st.rawValue, sourceAppID: "zoom", startedAt: Date(), status: st)) }
        let ids = ManualRecorder.markInterrupted(db: db)
        #expect(ids.count == 3)
        let statuses = try repo.recent().map(\.status)
        #expect(!statuses.contains(.recording) && !statuses.contains(.paused) && !statuses.contains(.finalizing))
        #expect(statuses.filter { $0 == .interrupted }.count == 4)     // 3 marked + the one created as interrupted
    }

    @Test func idleStateHasNoInfo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("em-mr-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = ManualRecorder(paths: try AppPaths(root: root), db: try AppDatabase.inMemory())
        #expect(await r.state == .idle)
        #expect(await r.state.info == nil)
        await #expect(throws: EMError.self) { try await r.stop() }
    }
}
