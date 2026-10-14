import EMCore
import EMDetection
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
