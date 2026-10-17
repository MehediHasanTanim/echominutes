import EMAudio
import EMCore
import EMStorage
import Foundation

/// Start / Pause / Stop / Discard recording of one app + mic (EM-055), crash recovery (EM-056), and the
/// candidate (pre-roll) phase used by automatic detection (EM-070).
public actor ManualRecorder {
    /// Who started the recording: the user (menu) or meeting detection. Detection only ever stops its own.
    public enum Origin: String, Sendable, Equatable { case manual, auto }

    public struct Info: Sendable, Equatable {
        public let sessionID: SessionID
        public let appID: String
        public let appName: String
        public let startedAt: Date
        public let origin: Origin
        public init(sessionID: SessionID, appID: String, appName: String, startedAt: Date, origin: Origin) {
            self.sessionID = sessionID; self.appID = appID; self.appName = appName; self.startedAt = startedAt; self.origin = origin
        }
    }
    public enum State: Sendable, Equatable {
        case idle
        /// Capturing into the ring buffers only (nothing on disk yet, no session row).
        case candidate(Info)
        case recording(Info)
        case paused(Info)
        case finalizing(Info)
        public var info: Info? {
            switch self {
            case .idle: nil
            case .candidate(let i), .recording(let i), .paused(let i), .finalizing(let i): i
            }
        }
        /// Recording or paused (i.e. something Stop/Discard applies to).
        public var isActive: Bool {
            switch self { case .recording, .paused: true; default: false }
        }
    }

    private let paths: AppPaths
    private let db: AppDatabase
    private var capture: AggregateCapture?
    private var writer: ChunkWriter?
    private var session: Session?
    private var preRoll: TimeInterval = 0
    public private(set) var state: State = .idle

    public init(paths: AppPaths, db: AppDatabase) { self.paths = paths; self.db = db }

    /// Starts recording straight away (menu "Start Recording", or detection when no candidate capture exists).
    @discardableResult
    public func start(app: DetectionRules.App, includeMic: Bool = true, origin: Origin = .manual, now: Date = Date()) throws -> Session {
        guard case .idle = state else { throw EMError.invalidData("A recording is already in progress") }
        let s = try openCapture(app: app, includeMic: includeMic, mode: .persisting, now: now)
        do { try SessionRepository(db).insert(s) } catch { closeCapture(deleteFiles: true); throw error }
        state = .recording(Info(sessionID: s.id, appID: app.id, appName: app.name, startedAt: now, origin: origin))
        Log.info(.session, "Recording started (\(origin.rawValue)): \(s.id) \(app.name)")
        return s
    }

    /// Detection saw the mic come on: capture into the rings, keeping the last `preRoll` seconds (EM-070).
    public func startCandidate(app: DetectionRules.App, includeMic: Bool, preRoll: TimeInterval, now: Date = Date()) throws {
        guard case .idle = state else { throw EMError.invalidData("A recording is already in progress") }
        _ = try openCapture(app: app, includeMic: includeMic, mode: .candidate(preRollSeconds: preRoll), now: now)
        self.preRoll = preRoll
        state = .candidate(Info(sessionID: session!.id, appID: app.id, appName: app.name, startedAt: now, origin: .auto))
        Log.info(.session, "Candidate capture: \(app.name) (pre-roll \(Int(preRoll)) s)")
    }

    /// Debounce passed: keep the pre-roll and everything after it.
    @discardableResult
    public func commitCandidate(now: Date = Date()) throws -> Session {
        guard case .candidate(let info) = state, var s = session, let writer else { throw EMError.notFound("candidate capture") }
        // The rings hold at most `preRoll` seconds, so the audio starts no earlier than now − preRoll.
        let audioStart = max(info.startedAt, now.addingTimeInterval(-preRoll))
        writer.setMode(.persisting)
        s.startedAt = audioStart
        do { try SessionRepository(db).insert(s) } catch { closeCapture(deleteFiles: true); throw error }
        session = s
        state = .recording(Info(sessionID: s.id, appID: info.appID, appName: info.appName, startedAt: audioStart, origin: .auto))
        Log.info(.session, "Recording started (auto): \(s.id) \(info.appName), pre-roll from \(audioStart)")
        return s
    }

    /// Debounce failed (voice note, declined ask…): stop capture and delete the empty session folder.
    public func cancelCandidate() {
        guard case .candidate(let info) = state else { return }
        closeCapture(deleteFiles: true)
        Log.info(.session, "Candidate cancelled: \(info.appName)")
    }

    private func openCapture(app: DetectionRules.App, includeMic: Bool, mode: ChunkWriter.Mode, now: Date) throws -> Session {
        let procs = AudioProcesses.resolve(app, in: AudioProcesses.current())
        guard !procs.isEmpty else { throw AudioCaptureError.noTargetProcesses(app.name) }
        var s = Session(title: "\(app.name) call", sourceAppID: app.id, sourceBundleID: procs.first?.bundleID,
                        startedAt: now, status: .recording, now: now)
        let route = OutputRoute.current()          // EM-092: speakers → the mic will hear the call (echo)
        s.echoRisk = route.isBuiltInSpeakers
        Log.info(.session, "Output: \(route.summary)")
        let dir = try paths.createSessionDirectories(s.id)
        let cap = AggregateCapture(processObjectIDs: procs.map(\.objectID), includeMic: includeMic)
        do {
            try cap.start()
            let w = try ChunkWriter(source: cap, sessionDirectory: dir, startedAt: now, mode: mode, devices: cap.deviceSummary,
                                    liveTranscript: LivePreferences.enabled)
            w.start()
            capture = cap; writer = w; session = s
        } catch {
            cap.stop()
            try? paths.deleteSession(s.id)
            throw error
        }
        return s
    }

    private func closeCapture(deleteFiles: Bool) {
        writer?.finish(); capture?.stop()
        if deleteFiles, let id = session?.id { try? paths.deleteSession(id) }
        writer = nil; capture = nil; session = nil; preRoll = 0
        state = .idle
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

    /// Live meter levels of the active capture (nil when idle / candidate).
    public var levels: ChunkWriter.Levels? {
        guard state.isActive, let writer else { return nil }
        return writer.levels
    }

    /// Audio feed for the live transcript of the active recording (EM-141); nil when off or idle.
    public var liveTap: LiveAudioTap? {
        guard state.isActive else { return nil }
        return writer?.live
    }

    /// Milliseconds of audio saved so far (pauses excluded) — the position a bookmark refers to.
    public var elapsedMs: Int? {
        guard state.isActive, let writer else { return nil }
        return writer.persistedMs
    }

    /// Marks "this moment" in the active recording (EM-074).
    @discardableResult
    public func addBookmark(note: String? = nil) throws -> Bookmark {
        guard state.isActive, let info = state.info, let writer else { throw EMError.notFound("active recording") }
        let b = Bookmark(sessionID: info.sessionID, atMs: writer.persistedMs, note: note)
        try SessionRepository(db).addBookmark(b)
        Log.info(.session, "Bookmark at \(b.atMs) ms in \(info.sessionID)")
        return b
    }

    /// Stops capture, finalizes audio and marks the session ready.
    @discardableResult
    public func stop(now: Date = Date()) async throws -> Session {
        guard state.isActive, let info = state.info, var s = session, let writer, let capture else { throw EMError.notFound("active recording") }
        state = .finalizing(info)
        writer.finish()
        capture.stop()
        self.writer = nil; self.capture = nil; preRoll = 0
        defer { state = .idle; session = nil }
        s.endedAt = now
        s.status = .finalizing
        try SessionRepository(db).update(s)
        return try await Self.finalize(s, paths: paths, db: db)
    }

    /// Stops and deletes everything of the current recording.
    public func discard() throws {
        guard let info = state.info else { return }
        if case .candidate = state { cancelCandidate(); return }
        writer?.finish(); capture?.stop()
        writer = nil; capture = nil; session = nil; preRoll = 0
        state = .idle
        try SessionRepository(db).delete(info.sessionID)
        try paths.deleteSession(info.sessionID)
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
