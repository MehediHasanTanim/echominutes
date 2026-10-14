import EMCore
import Foundation
import Testing
@testable import EMStorage

@Suite("AppPaths")
struct AppPathsTests {
    func tempRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("em-tests-\(UUID().uuidString)") }

    @Test func createsPrivateLayout() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let p = try AppPaths(root: root)
        for dir in [p.root, p.sessionsDir, p.modelsDir, p.logsDir] {
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue)
            let perms = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
            #expect(perms?.intValue == 0o700)
        }
        #expect(p.databaseURL.lastPathComponent == "echominutes.sqlite")
    }

    @Test func sessionLifecycle() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let p = try AppPaths(root: root)
        let id = SessionID()
        try p.createSessionDirectories(id)
        #expect(FileManager.default.fileExists(atPath: p.chunksDir(id, track: .mic).path))
        #expect(FileManager.default.fileExists(atPath: p.chunksDir(id, track: .system).path))
        #expect(p.trackURL(id, track: .mixed).lastPathComponent == "mixed.m4a")
        try Data(repeating: 1, count: 1000).write(to: p.manifestURL(id))
        #expect(p.sizeOfSession(id) == 1000)
        try p.deleteSession(id)
        #expect(!FileManager.default.fileExists(atPath: p.sessionDir(id).path))
        try p.deleteSession(id)   // idempotent
    }

    @Test func reportsFreeSpace() throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(try AppPaths(root: root).availableBytes() > 0)
    }
}

@Suite("KeychainStore", .serialized)
struct KeychainStoreTests {
    @Test func roundTripUpdateDelete() throws {
        let store = KeychainStore(service: "com.tanimkabir.echominutes.tests.\(UUID().uuidString)")
        defer { for p in ProviderID.allCases { try? store.delete(p) } }

        #expect(try store.get(.anthropic) == nil)
        #expect(!store.hasKey(.anthropic))
        try store.set("sk-ant-first", for: .anthropic)
        #expect(try store.get(.anthropic) == "sk-ant-first")
        try store.set("sk-ant-second", for: .anthropic)          // update in place
        #expect(try store.get(.anthropic) == "sk-ant-second")
        #expect(try store.get(.openAI) == nil)                   // isolated per provider
        try store.delete(.anthropic)
        #expect(try store.get(.anthropic) == nil)
        try store.delete(.anthropic)                             // idempotent
    }
}
