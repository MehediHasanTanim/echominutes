import EMAudio
import EMCore
import EMStorage
import Foundation

/// Manual Start / Pause / Stop / Discard recording of one app + mic (EM-055), plus crash recovery (EM-056).
/// Sprint 5–6 put the automatic SessionCoordinator on top of the same building blocks.
public actor ManualRecorder {
    public struct Info: Sendable, Equatable {
        public let sessionID: SessionID
        public let appName: String
        public let startedAt: Date
    }
    public enum State: Sendable, Equatable {
        case idle
        case recording(Info)
        case paused(Info)
        case finalizing(Info)
        public var info: Info? {
            switch self { case .idle: nil; case .recording(let i), .paused(let i), .finalizing(let i): i }
        }
    }

    private let paths: AppPaths
    private let db: AppDatabase
    private var capture: AggregateCapture?
    private var writer: ChunkWriter?
    private var session: Session?
    public private(set) var state: State = .idle

    public init(paths: AppPaths, db: AppDatabase) { self.paths = paths; self.db = db }

    @discardableResult
    public func start(app: DetectionRules.App, includeMic: Bool = true, now: Date = Date()) throws -> Session {
        guard case .idle = state else { throw EMError.invalidData("A recording is already in progress") }
        let procs = AudioProcesses.resolve(app, in: AudioProcesses.current())
        guard !procs.isEmpty else { throw AudioCaptureError.noTargetProcesses(app.name) }

        let s = Session(title: "\(app.name) call", sourceAppID: app.id, sourceBundleID: procs.first?.bundleID,
                        startedAt: now, status: .recording, now: now)
        let dir = try paths.createSessionDirectories(s.id)
        let cap = AggregateCapture(processObjectIDs: procs.map(\.objectID), includeMic: includeMic)
        do {
            try cap.start()
            let w = try ChunkWriter(source: cap, sessionDirectory: dir, startedAt: now, mode: .persisting)
            w.start()
            try SessionRepository(db).insert(s)
            capture = cap; writer = w; session = s
        } catch {
            cap.stop()
            try? paths.deleteSession(s.id)
            throw error
        }
        state = .recording(Info(sessionID: s.id, appName: app.name, startedAt: now))
        Log.info(.session, "Manual recording started: \(s.id) \(app.name)")
        return s
    }

    public func pause() throws {
        guard case .recording(let info) = state, let writer else { return }
        writer.setMode(.paused)
        try SessionRepository(db).setStatus(info.sessionID, .paused)
        state = .paused(info)
    }

    public func resume() throws {
        guard case .paused(let info) = state, let writer else { return }
        writer.setMode(.persisting)
        try SessionRepository(db).setStatus(info.sessionID, .recording)
        state = .recording(info)
    }

    /// Stops capture, finalizes audio and marks the session ready.
    @discardableResult
    public func stop(now: Date = Date()) async throws -> Session {
        guard let info = state.info, var s = session, let writer, let capture else { throw EMError.notFound("active recording") }
        state = .finalizing(info)
        writer.finish()
        capture.stop()
        self.writer = nil; self.capture = nil
        s.endedAt = now
        s.status = .finalizing
        try SessionRepository(db).update(s)
        defer { state = .idle; session = nil }
        return try await Self.finalize(s, paths: paths, db: db)
    }

    /// Stops and deletes everything of the current recording.
    public func discard() throws {
        guard let info = state.info else { return }
        writer?.finish(); capture?.stop()
        writer = nil; capture = nil; session = nil
        try SessionRepository(db).delete(info.sessionID)
        try paths.deleteSession(info.sessionID)
        state = .idle
        Log.info(.session, "Recording discarded: \(info.sessionID)")
    }

    // MARK: - Finalize & recovery

    /// Builds the final audio files off the actor, records tracks, sets status `ready` (or `failed`).
    static func finalize(_ session: Session, paths: AppPaths, db: AppDatabase) async throws -> Session {
        var s = session
        let dir = paths.sessionDir(s.id)
        do {
            let result = try await Task.detached(priority: .utility) { try AudioFinalizer.finalize(sessionDirectory: dir) }.value
            let sid = s.id
            let tracks = result.tracks.map { kind, url -> AudioTrack in
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                return AudioTrack(sessionID: sid, kind: kind, fileName: url.lastPathComponent, durationMs: result.durationMs, sizeBytes: size)
            }
            try SessionRepository(db).saveTracks(s.id, tracks)
            if s.endedAt == nil { s.endedAt = s.startedAt.addingTimeInterval(Double(result.durationMs) / 1000) }
            s.status = .ready
            try SessionRepository(db).update(s)
            Log.info(.session, "Finalized \(s.id): \(result.durationMs) ms, \(result.waveformPeaks) waveform peaks")
            return s
        } catch {
            s.status = .failed
            try? SessionRepository(db).update(s)
            Log.error(.session, "Finalize failed for \(s.id): \(error)")
            throw error
        }
    }

    /// At launch: sessions a crash left in recording/paused/finalizing → `interrupted`.
    @discardableResult
    public static func markInterrupted(db: AppDatabase) -> [SessionID] {
        let repo = SessionRepository(db)
        let ids = ((try? repo.needingRecovery()) ?? []).map(\.id)
        for id in ids { try? repo.setStatus(id, .interrupted) }
        if !ids.isEmpty { Log.info(.session, "Marked \(ids.count) interrupted session(s)") }
        return ids
    }

    /// Finalizes whatever closed chunks an interrupted session has (loses at most the open 30 s chunk).
    public static func recover(_ id: SessionID, paths: AppPaths, db: AppDatabase) async throws -> Session {
        guard let s = try SessionRepository(db).fetch(id) else { throw EMError.notFound("session") }
        return try await finalize(s, paths: paths, db: db)
    }
}
