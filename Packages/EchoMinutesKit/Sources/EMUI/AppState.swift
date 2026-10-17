import EMAudio
import EMCore
import EMDetection
import EMJobs
import EMSession
import EMStorage
import Foundation
import Observation

/// What the menu bar icon shows (Feature Spec §5.7).
public enum AppStatus: Equatable, Sendable {
    case idle
    case monitoring
    case recording(appName: String, since: Date)
    case processing(String)

    public var symbolName: String {
        switch self {
        case .idle: "waveform.circle"
        case .monitoring: "waveform.circle.fill"
        case .recording: "record.circle.fill"
        case .processing: "hourglass.circle"
        }
    }

    public var label: String {
        switch self {
        case .idle: "Idle — not monitoring yet"
        case .monitoring: "Watching for meetings"
        case .recording(let app, _): "Recording \(app)…"
        case .processing(let what): what
        }
    }
}

/// App-wide UI state (EM-028). Owns the database handles; views read it from the environment.
@MainActor
@Observable
public final class AppState {
    public var status: AppStatus = .idle
    public var selectedSessionID: SessionID?
    public private(set) var sessions: [Session] = []
    public private(set) var startupError: String?
    public var recording: ManualRecorder.State = .idle
    public var lastError: String?
    public let paths: AppPaths?
    public let database: AppDatabase?
    public let recorder: ManualRecorder?
    public let rules: DetectionRules?

    // Automatic detection (EM-070…076)
    public internal(set) var detectionPhase: MeetingStateMachine.Phase = .idle
    public internal(set) var detectionRunning = false
    /// Bumped to ask the always-present menu bar label to open the Library window (e.g. from a notification).
    public var libraryOpenRequest = 0
    @ObservationIgnored var coordinator: DetectionCoordinator?
    @ObservationIgnored var autoHandler: AutoRecordingHandler?
    @ObservationIgnored var activityMonitor: AudioActivityMonitor?
    @ObservationIgnored var sleepWatcher: SystemEventsWatcher?
    @ObservationIgnored var detectionTasks: [Task<Void, Never>] = []
    public let notifier = Notifier()
    /// Live transcript of the active recording (EM-140…148).
    public let live = LiveTranscript()
    @ObservationIgnored var liveStarting = false

    // Live recording extras (EM-073/074)
    public internal(set) var levels: ChunkWriter.Levels?
    public internal(set) var bookmarksThisRecording = 0
    public internal(set) var lastSnapshot: ActivitySnapshot = [:]
    public internal(set) var detectionLog: [Decision] = []          // newest last, capped
    @ObservationIgnored let miniWidget = MiniWidgetController()
    @ObservationIgnored var levelTask: Task<Void, Never>?
    @ObservationIgnored var lastActiveSessionID: SessionID?

    // Background jobs: transcription (EM-080…088)
    public struct JobProgress: Equatable, Sendable { public var fraction: Double; public var message: String }
    public internal(set) var jobProgress: [SessionID: JobProgress] = [:]
    public internal(set) var jobNotes: [SessionID: String] = [:]          // last failure / deferral per session
    public internal(set) var transcriptVersion = 0                         // bumped when a transcript is saved
    public internal(set) var summaryProgress: [SessionID: JobProgress] = [:]
    public internal(set) var summaryNotes: [SessionID: String] = [:]
    public internal(set) var summaryVersion = 0
    /// Bumped when user templates change (EM-170) / an Ask answer arrives (EM-175).
    public internal(set) var templatesVersion = 0
    public internal(set) var askVersion = 0
    public internal(set) var askBusy: Set<SessionID> = []
    @ObservationIgnored var jobRunner: JobRunner?
    public struct PlayRequest: Equatable, Sendable { public var sessionID: SessionID; public var ms: Int; public var nonce: Int }
    public internal(set) var playRequest: PlayRequest?
    @ObservationIgnored var handledPlayNonce = 0

    public init(paths: AppPaths?, database: AppDatabase?, startupError: String? = nil, rules: DetectionRules? = DetectionRules.bundled()) {
        self.paths = paths
        self.database = database
        self.startupError = startupError
        self.rules = rules
        if let paths, let database {
            recorder = ManualRecorder(paths: paths, db: database)
            ManualRecorder.markInterrupted(db: database)          // EM-056: crash recovery at launch
        } else {
            recorder = nil
        }
        reloadSessions()
        observeSessions()
    }

    /// Library list stays live (EM-120): any write to `sessions` — recording, transcription, summary title — re-emits.
    private func observeSessions() {
        guard let database else { return }
        let stream = SessionRepository(database).observeRecent(limit: 1000)
        Task { [weak self] in
            for await list in stream {
                guard let self else { return }
                if list != self.sessions { self.sessions = list }
            }
        }
    }

    /// Production wiring: ~/Library/Application Support/EchoMinutes + on-disk database.
    public static func live() -> AppState {
        do {
            let paths = try AppPaths.default()
            let db = try AppDatabase.onDisk(paths)
            Log.info(.app, "Storage ready at \(paths.root.path)")
            let state = AppState(paths: paths, database: db)
            state.notifier.setup(state: state)
            state.startDetection()
            state.registerHotKeys()
            MainThreadWatchdog.shared.start()
            state.startJobs()
            state.startRetentionTimer()
            return state
        } catch {
            Log.error(.app, "Storage failed to open: \(error)")
            return AppState(paths: nil, database: nil, startupError: "Couldn't open the EchoMinutes library: \(error.localizedDescription)")
        }
    }

    public var recentSessions: [Session] { Array(sessions.prefix(5)) }

    public func reloadSessions() {
        guard let database else { sessions = []; return }
        do { sessions = try SessionRepository(database).recent(limit: 500) }
        catch { Log.error(.storage, "Loading sessions failed: \(error)"); sessions = [] }
    }

    public func session(_ id: SessionID?) -> Session? { id.flatMap { id in sessions.first { $0.id == id } } }

    /// Debug helper until real recordings exist (S4): inserts a fake finished meeting.
    public func addSampleSession(now: Date = Date()) {
        guard let database else { return }
        let apps = [("teams", "Microsoft Teams"), ("zoom", "Zoom"), ("whatsapp", "WhatsApp")]
        let pick = apps[sessions.count % apps.count]
        var s = Session(title: "Sample \(pick.1) call", sourceAppID: pick.0, startedAt: now.addingTimeInterval(-1800), status: .ready, now: now)
        s.endedAt = now.addingTimeInterval(-1800 + Double(600 + sessions.count * 120))
        do { try SessionRepository(database).insert(s); reloadSessions(); selectedSessionID = s.id }
        catch { Log.error(.storage, "Sample insert failed: \(error)") }
    }

    public func deleteSession(_ id: SessionID) {
        guard let database else { return }
        do {
            try SessionRepository(database).delete(id)
            try paths?.deleteSession(id)
            if selectedSessionID == id { selectedSessionID = nil }
            reloadSessions()
        } catch { Log.error(.storage, "Delete failed: \(error)") }
    }
}
