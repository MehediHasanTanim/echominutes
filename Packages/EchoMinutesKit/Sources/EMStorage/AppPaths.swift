import EMCore
import Foundation

/// File-system layout (Technical Design §11.1). EM-025.
///
///     <root>/echominutes.sqlite
///     <root>/Sessions/<session-uuid>/chunks/{mic,system}/…  mic.m4a system.m4a mixed.m4a waveform.bin manifest.json
///     <root>/Models/      <root>/Logs/
public struct AppPaths: Sendable {
    public let root: URL

    /// Default: ~/Library/Application Support/EchoMinutes
    public static func `default`() throws -> AppPaths {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try AppPaths(root: base.appendingPathComponent("EchoMinutes", isDirectory: true))
    }

    /// Creates root, Sessions, Models and Logs with owner-only permissions (0700).
    public init(root: URL) throws {
        self.root = root
        for dir in [root, sessionsDir, modelsDir, logsDir] { try Self.makePrivateDirectory(dir) }
    }

    public var databaseURL: URL { root.appendingPathComponent("echominutes.sqlite") }
    public var sessionsDir: URL { root.appendingPathComponent("Sessions", isDirectory: true) }
    public var modelsDir: URL { root.appendingPathComponent("Models", isDirectory: true) }
    public var logsDir: URL { root.appendingPathComponent("Logs", isDirectory: true) }

    public func sessionDir(_ id: SessionID) -> URL { sessionsDir.appendingPathComponent(id.description, isDirectory: true) }
    public func chunksDir(_ id: SessionID, track: TrackKind) -> URL {
        sessionDir(id).appendingPathComponent("chunks", isDirectory: true).appendingPathComponent(track.rawValue, isDirectory: true)
    }
    public func trackURL(_ id: SessionID, track: TrackKind) -> URL { sessionDir(id).appendingPathComponent("\(track.rawValue).m4a") }
    public func manifestURL(_ id: SessionID) -> URL { sessionDir(id).appendingPathComponent("manifest.json") }
    public func waveformURL(_ id: SessionID) -> URL { sessionDir(id).appendingPathComponent("waveform.bin") }

    /// Creates the session folder and both chunk folders.
    @discardableResult
    public func createSessionDirectories(_ id: SessionID) throws -> URL {
        try Self.makePrivateDirectory(sessionDir(id))
        for t in [TrackKind.mic, .system] { try Self.makePrivateDirectory(chunksDir(id, track: t)) }
        return sessionDir(id)
    }

    public func deleteSession(_ id: SessionID) throws {
        let dir = sessionDir(id)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
    }

    /// Bytes available for important usage on the volume holding `root` (disk guard, EM-057).
    public func availableBytes() -> Int64 {
        let v = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Total size of a session folder in bytes.
    public func sizeOfSession(_ id: SessionID) -> Int64 {
        guard let e = FileManager.default.enumerator(at: sessionDir(id), includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    static func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
